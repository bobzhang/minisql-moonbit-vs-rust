// Query planning and execution: FROM sources and joins, filtering,
// aggregation, compound operators, ordering and limits.

use std::borrow::Cow;
use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

use crate::agg::{self, AggKind, AggSpec, Group};
use crate::ast::*;
use crate::access::{self, conjuncts, Access, AutoIndex, AutoKey};
use crate::db::{is_schema_table, key, key_val, Database, KeyVal, Table};
use crate::eval::{
    affinity, bind, check_coll, eval, expr_coll, make_cmp, outer_agg_level, resolves_column, source_col, BExpr, Env,
    Scope, Source, SrcCol,
};
use crate::value::{apply_affinity, Affinity, Coll, Value};

pub type Rows = Vec<Vec<Value>>;

/// Name, affinity and collation of a result column.
#[derive(Debug, Clone)]
pub struct ColMeta {
    pub name: String,
    pub aff: Affinity,
    pub coll: Option<Coll>,
}

#[derive(Debug)]
pub struct QueryPlan {
    pub columns: Vec<ColMeta>,
    cores: Vec<CorePlan>,
    ops: Vec<CompoundOp>,
    /// Collations used to compare rows of a compound.
    colls: Vec<Coll>,
    /// ORDER BY of a compound (or VALUES): result column, desc, nulls first,
    /// collation.
    order: Vec<(usize, bool, bool, Coll)>,
    limit: Option<BExpr>,
    offset: Option<BExpr>,
    /// Estimated number of result rows (LogEst), for the planner of an
    /// enclosing query.
    pub rows: i32,
}

#[derive(Debug)]
enum CorePlan {
    Select(Box<SelectPlan>),
    Values(Vec<Vec<BExpr>>),
}

#[derive(Debug)]
enum SortKey {
    Result(usize),
    Expr(BExpr),
}

#[derive(Debug)]
struct OrderSpec {
    key: SortKey,
    desc: bool,
    nulls_first: bool,
    coll: Coll,
}

#[derive(Debug)]
enum SrcPlan {
    Table(String),
    /// A subquery; views keep their rows for the whole statement.
    Query(Rc<QueryPlan>, Option<Rc<std::cell::OnceCell<Rows>>>),
    /// The sqlite_schema table (true: sqlite_temp_schema).
    Schema(bool),
    /// A recursive CTE.
    Recursive(Rc<RecPlan>, Option<Rc<std::cell::OnceCell<Rows>>>),
    /// The current row of a recursive CTE, inside its recursive selects.
    Queue(Rc<RefCell<Rows>>),
}

/// A recursive common table expression.
#[derive(Debug)]
struct RecPlan {
    /// The non-recursive selects.
    setup: QueryPlan,
    /// The recursive selects, run once per queued row.
    arms: Vec<QueryPlan>,
    /// The row the recursive selects read (plus its rowid slot).
    slot: Rc<RefCell<Rows>>,
    /// UNION: rows already seen are not queued again.
    distinct: bool,
    colls: Vec<Coll>,
    /// ORDER BY: the queue is a priority queue.
    order: Vec<(usize, bool, bool, Coll)>,
    limit: Option<BExpr>,
    offset: Option<BExpr>,
}

#[derive(Debug)]
struct JoinStep {
    src: SrcPlan,
    kind: JoinKind,
    /// CROSS JOIN: tables to the left stay outer.
    cross: bool,
    /// The source is a view.
    view: bool,
    /// Conditions deciding whether a row of this level matches (the ON
    /// clause, plus WHERE terms pushed down to an inner join level).
    filters: Vec<BExpr>,
    /// WHERE terms checked once this level's row (or its NULL row for an
    /// outer join) is in place.
    post: Vec<BExpr>,
    access: Access,
    auto: Option<AutoKey>,
    /// Position of the first column in the joined row.
    offset: usize,
    /// Columns + rowid slot.
    width: usize,
}

#[derive(Debug)]
struct SelectPlan {
    steps: Vec<JoinStep>,
    /// Nesting order of the join loops (indexes into `steps`).
    loop_order: Vec<usize>,
    width: usize,
    where_: Option<BExpr>,
    is_agg: bool,
    group_by: Vec<(BExpr, Coll)>,
    /// Groups come out in descending order of these GROUP BY terms (SQLite
    /// copies ASC/DESC from an ORDER BY with as many terms).
    group_desc: Vec<bool>,
    /// The loops deliver rows grouped: groups come out in that order.
    groups_in_scan_order: bool,
    having: Option<BExpr>,
    specs: Vec<AggSpec>,
    outs: Vec<BExpr>,
    distinct: bool,
    distinct_colls: Vec<Coll>,
    keys: Vec<OrderSpec>,
    /// Window functions, computed over the rows that pass WHERE/HAVING.
    win: Option<crate::window::WinPlan>,
}

pub fn table_source(t: &Table, name: &str, offset: usize, qualified_only: bool) -> Source {
    Source {
        name: name.to_string(),
        columns: t
            .columns
            .iter()
            .map(|c| SrcCol::new(&c.name, c.affinity, Some(c.coll.unwrap_or(Coll::Binary))))
            .collect(),
        offset,
        qualified_only,
        has_rowid: true,
    }
}

pub fn table_scope(t: &Table, name: &str) -> Scope {
    let mut s = Scope::empty();
    s.sources.push(table_source(t, name, 0, false));
    s
}

/// Plans and runs a top-level query.
pub fn select(db: &Database, sel: &Select) -> Result<Rows, String> {
    let plan = plan_query(db, sel, None, Rc::new(Cell::new(0)))?;
    run_query(&plan, &Env::new(db), None)
}

pub fn ordinal(n: usize) -> String {
    let suffix = match (n % 10, n % 100) {
        (1, x) if x != 11 => "st",
        (2, x) if x != 12 => "nd",
        (3, x) if x != 13 => "rd",
        _ => "th",
    };
    format!("{}{}", n, suffix)
}

// ---------- AST inspection ----------

/// Whether any subquery inside the expression reads table `name`.
pub fn expr_reads_table(e: &Expr, name: &str) -> bool {
    let mut found = false;
    let _ = agg::map_expr(e, &mut |x| {
        match x {
            Expr::Subquery(q) | Expr::Exists(q) | Expr::InSelect { query: q, .. } => {
                if select_reads_table(q, name) {
                    found = true;
                }
            }
            _ => {}
        }
        Ok(None)
    });
    found
}

pub fn select_reads_table(q: &Select, name: &str) -> bool {
    if let Some(w) = &q.with {
        if w.ctes.iter().any(|c| select_reads_table(&c.select, name)) {
            return true;
        }
    }
    let item_reads = |it: &TableItem| match it {
        TableItem::Table { name: n, .. } => n.eq_ignore_ascii_case(name),
        TableItem::Subquery { query, .. } => select_reads_table(query, name),
    };
    let mut exprs: Vec<&Expr> = Vec::new();
    for core in &q.cores {
        match core {
            SelectCore::Values(rows) => exprs.extend(rows.iter().flatten()),
            SelectCore::Select(b) => {
                if let Some(f) = &b.from {
                    if item_reads(&f.first) || f.joins.iter().any(|j| item_reads(&j.item)) {
                        return true;
                    }
                    exprs.extend(f.joins.iter().filter_map(|j| j.on.as_ref()));
                }
                for c in &b.columns {
                    if let ResultColumn::Expr(e, _, _) = c {
                        exprs.push(e);
                    }
                }
                exprs.extend(b.where_.iter());
                exprs.extend(b.group_by.iter());
                exprs.extend(b.having.iter());
            }
        }
    }
    exprs.extend(q.order_by.iter().map(|t| &t.expr));
    exprs.into_iter().any(|e| expr_reads_table(e, name))
}

// ---------- planning ----------

/// A planned core with its result expressions (for compound ORDER BY
/// matching).
struct CoreInfo {
    plan: CorePlan,
    columns: Vec<ColMeta>,
    exprs: Vec<Option<Expr>>,
    /// Result expression collations (None = no collation).
    colls: Vec<Option<Coll>>,
    /// Estimated number of rows (LogEst).
    rows: i32,
}

pub fn plan_query(db: &Database, q: &Select, parent: Option<Rc<Scope>>, corr: Rc<Cell<usize>>) -> Result<QueryPlan, String> {
    if q.with.is_some() {
        return crate::cte::with_scope(q.with.as_ref(), || plan_query_body(db, q, parent, corr));
    }
    plan_query_body(db, q, parent, corr)
}

fn plan_query_body(db: &Database, q: &Select, parent: Option<Rc<Scope>>, corr: Rc<Cell<usize>>) -> Result<QueryPlan, String> {
    let limit_scope = Scope::child(parent.clone(), corr.clone());
    let limit = match &q.limit {
        Some(e) => Some(bind(e, &limit_scope, db)?),
        None => None,
    };
    let offset = match &q.offset {
        Some(e) => Some(bind(e, &limit_scope, db)?),
        None => None,
    };
    let simple = q.cores.len() == 1 && matches!(q.cores[0], SelectCore::Select(_));
    if simple {
        let SelectCore::Select(body) = &q.cores[0] else { unreachable!() };
        let limit_n = match &q.limit {
            Some(Expr::Literal(Value::Integer(n))) => Some(*n),
            _ => None,
        };
        let info = plan_select(db, body, parent, corr, &q.order_by, limit_n)?;
        let rows = limit_rows(info.rows, limit_n);
        return Ok(QueryPlan {
            columns: info.columns,
            cores: vec![info.plan],
            ops: Vec::new(),
            colls: Vec::new(),
            order: Vec::new(),
            limit,
            offset,
            rows,
        });
    }
    let mut infos: Vec<CoreInfo> = Vec::new();
    for (i, core) in q.cores.iter().enumerate() {
        let info = match core {
            SelectCore::Select(body) => plan_select(db, body, parent.clone(), corr.clone(), &[], None)?,
            SelectCore::Values(rows) => plan_values(db, rows, parent.clone(), corr.clone())?,
        };
        if let Some(first) = infos.first() {
            if first.columns.len() != info.columns.len() {
                return Err(format!(
                    "SELECTs to the left and right of {} do not have the same number of result columns",
                    q.ops[i - 1].name()
                ));
            }
        }
        infos.push(info);
    }
    let ncols = infos[0].columns.len();
    // column collation: leftmost core whose column has one
    let colls: Vec<Coll> = (0..ncols)
        .map(|c| infos.iter().find_map(|inf| inf.colls[c]).unwrap_or(Coll::Binary))
        .collect();
    let mut columns = infos[0].columns.clone();
    for (c, col) in columns.iter_mut().enumerate() {
        if infos.iter().any(|inf| inf.columns[c].aff != col.aff) {
            col.aff = Affinity::None;
        }
        col.coll = Some(colls[c]);
    }
    // ORDER BY terms must name result columns
    let mut order = Vec::new();
    for (ti, term) in q.order_by.iter().enumerate() {
        let mut inner = &term.expr;
        let mut explicit: Option<&str> = None;
        while let Expr::Collate(x, c) = inner {
            explicit.get_or_insert(c.as_str());
            inner = x;
        }
        let idx = match inner {
            Expr::Literal(Value::Integer(n)) => {
                if *n < 1 || *n as usize > ncols {
                    return Err(format!(
                        "{} ORDER BY term out of range - should be between 1 and {}",
                        ordinal(ti + 1),
                        ncols
                    ));
                }
                Some(*n as usize - 1)
            }
            _ => match_result_column(inner, &infos),
        };
        let Some(idx) = idx else {
            return Err(format!("{} ORDER BY term does not match any column in the result set", ordinal(ti + 1)));
        };
        let coll = match explicit {
            Some(c) => Coll::from_name(c)?,
            None => colls[idx],
        };
        order.push((idx, term.desc, term.nulls_first.unwrap_or(!term.desc), coll));
    }
    let mut rows = infos[0].rows;
    for (op, inf) in q.ops.iter().zip(&infos[1..]) {
        rows = match op {
            CompoundOp::UnionAll | CompoundOp::Union => access::log_add(rows, inf.rows),
            CompoundOp::Intersect => rows.min(inf.rows),
            CompoundOp::Except => rows,
        };
    }
    let limit_n = match &q.limit {
        Some(Expr::Literal(Value::Integer(n))) => Some(*n),
        _ => None,
    };
    let rows = limit_rows(rows, limit_n);
    Ok(QueryPlan {
        rows,
        columns,
        cores: infos.into_iter().map(|i| i.plan).collect(),
        ops: q.ops.clone(),
        colls,
        order,
        limit,
        offset,
    })
}

/// Row estimate capped by a constant LIMIT.
fn limit_rows(rows: i32, limit: Option<i64>) -> i32 {
    match limit {
        Some(n) if n >= 0 => rows.min(access::log_est(n as u64)),
        _ => rows,
    }
}

/// Finds the result column a compound ORDER BY term refers to.
fn match_result_column(e: &Expr, infos: &[CoreInfo]) -> Option<usize> {
    if let Expr::Column { table: None, name, .. } = e {
        for inf in infos {
            if let Some(i) = inf.columns.iter().position(|c| c.name.eq_ignore_ascii_case(name)) {
                return Some(i);
            }
        }
    }
    let text = format!("{:?}", e);
    for inf in infos {
        if let Some(i) = inf.exprs.iter().position(|x| x.as_ref().is_some_and(|x| format!("{:?}", x) == text)) {
            return Some(i);
        }
    }
    None
}

fn plan_values(db: &Database, rows: &[Vec<Expr>], parent: Option<Rc<Scope>>, corr: Rc<Cell<usize>>) -> Result<CoreInfo, String> {
    let scope = Scope::child(parent, corr);
    let mut bound = Vec::with_capacity(rows.len());
    for r in rows {
        let mut br = Vec::with_capacity(r.len());
        for e in r {
            br.push(bind(e, &scope, db)?);
        }
        bound.push(br);
    }
    let n = rows.first().map(|r| r.len()).unwrap_or(0);
    let columns = (0..n)
        .map(|i| ColMeta {
            name: format!("column{}", i + 1),
            aff: affinity(&bound[0][i]),
            coll: expr_coll(&bound[0][i]),
        })
        .collect();
    let colls = (0..n).map(|i| expr_coll(&bound[0][i])).collect();
    let rows = access::log_est(bound.len() as u64);
    Ok(CoreInfo { plan: CorePlan::Values(bound), columns, exprs: vec![None; n], colls, rows })
}

/// Result columns with `*` expanded: (expression, alias, name).
fn expand_columns(cols: &[ResultColumn], scope: &Scope) -> Result<Vec<(Expr, Option<String>, String)>, String> {
    let mut out = Vec::new();
    for rc in cols {
        match rc {
            ResultColumn::Star => {
                if scope.sources.is_empty() {
                    return Err("no tables specified".to_string());
                }
                for (si, s) in scope.sources.iter().enumerate().filter(|(_, s)| !s.qualified_only) {
                    for (ci, c) in s.columns.iter().enumerate().filter(|(_, c)| !c.hidden) {
                        out.push((Expr::SourceCol { src: si, col: ci }, None, c.name.clone()));
                    }
                }
            }
            ResultColumn::TableStar(t) => {
                let s = scope
                    .sources
                    .iter()
                    .find(|s| s.name.eq_ignore_ascii_case(t))
                    .ok_or_else(|| format!("no such table: {}", t))?;
                for c in &s.columns {
                    let e = Expr::Column { table: Some(s.name.clone()), name: c.name.clone(), dq: false };
                    out.push((e, None, c.name.clone()));
                }
            }
            ResultColumn::Expr(e, alias, text) => {
                let name = match (alias, e) {
                    (Some(a), _) => a.clone(),
                    (None, Expr::Column { name, .. }) => name.clone(),
                    _ => text.clone(),
                };
                out.push((e.clone(), alias.clone(), name));
            }
        }
    }
    Ok(out)
}

/// Replaces unqualified names that are not columns but match a result
/// column alias with the aliased expression.
fn subst_aliases(e: &Expr, cols: &[(Expr, Option<String>, String)], scope: &Scope) -> Result<Expr, String> {
    agg::map_expr(e, &mut |x| {
        if let Expr::Column { table: None, name, .. } = x {
            if !resolves_column(name, scope) {
                if let Some((ae, _, _)) =
                    cols.iter().find(|(_, a, _)| a.as_deref().is_some_and(|a| a.eq_ignore_ascii_case(name)))
                {
                    return Ok(Some(ae.clone()));
                }
            }
        }
        Ok(None)
    })
}

thread_local! {
    static VIEW_DEPTH: Cell<usize> = const { Cell::new(0) };
}

/// Plans the query of a view (views see no enclosing query).
fn plan_view(db: &Database, v: &crate::db::View) -> Result<QueryPlan, String> {
    let depth = VIEW_DEPTH.with(|d| d.get());
    if depth > 64 {
        return Err(format!("view {} is circularly defined", v.name));
    }
    VIEW_DEPTH.with(|d| d.set(depth + 1));
    let r = crate::cte::without_ctes(|| plan_query(db, &v.select, None, Rc::new(Cell::new(0))));
    VIEW_DEPTH.with(|d| d.set(depth));
    r
}

fn view_column_names(v: &crate::db::View, plan: &QueryPlan) -> Result<Vec<String>, String> {
    if let Some(names) = &v.columns {
        if names.len() != plan.columns.len() {
            return Err(format!(
                "expected {} columns for '{}' but got {}",
                names.len(),
                v.name,
                plan.columns.len()
            ));
        }
        return Ok(names.clone());
    }
    Ok(unique_names(&plan.columns))
}

/// Column names made unique with `:N` suffixes.
fn unique_names(cols: &[ColMeta]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for c in cols {
        let mut n = c.name.clone();
        let mut k = 0;
        while out.iter().any(|x| x.eq_ignore_ascii_case(&n)) {
            k += 1;
            n = format!("{}:{}", c.name, k);
        }
        out.push(n);
    }
    out
}

/// Number of FROM items of a core that name `name` directly.
fn direct_refs(core: &SelectCore, name: &str) -> usize {
    let SelectCore::Select(b) = core else { return 0 };
    let Some(f) = &b.from else { return 0 };
    std::iter::once(&f.first)
        .chain(f.joins.iter().map(|j| &j.item))
        .filter(|it| matches!(it, TableItem::Table { name: n, .. } if n.eq_ignore_ascii_case(name)))
        .count()
}

/// Whether a subquery anywhere in a core reads table `name`.
fn core_subqueries_read(core: &SelectCore, name: &str) -> bool {
    match core {
        SelectCore::Values(rows) => rows.iter().flatten().any(|e| expr_reads_table(e, name)),
        SelectCore::Select(b) => {
            if let Some(f) = &b.from {
                let items = std::iter::once(&f.first).chain(f.joins.iter().map(|j| &j.item));
                for it in items {
                    if let TableItem::Subquery { query, .. } = it {
                        if select_reads_table(query, name) {
                            return true;
                        }
                    }
                }
                if f.joins.iter().filter_map(|j| j.on.as_ref()).any(|e| expr_reads_table(e, name)) {
                    return true;
                }
            }
            let mut exprs: Vec<&Expr> = Vec::new();
            for c in &b.columns {
                if let ResultColumn::Expr(e, _, _) = c {
                    exprs.push(e);
                }
            }
            exprs.extend(b.where_.iter());
            exprs.extend(b.group_by.iter());
            exprs.extend(b.having.iter());
            exprs.into_iter().any(|e| expr_reads_table(e, name))
        }
    }
}

/// Resolves a FROM name that refers to a common table expression in scope.
fn cte_source(
    db: &Database,
    name: &str,
    alias: &Option<String>,
    scope: &mut Scope,
    offset: usize,
    parent: &Option<Rc<Scope>>,
    corr: &Rc<Cell<usize>>,
) -> Result<Option<SrcPlan>, String> {
    use crate::cte::State;
    let Some((frame, depth, ei)) = crate::cte::lookup(name) else { return Ok(None) };
    let entry = &frame.entries[ei];
    let src_name = alias.clone().unwrap_or_else(|| entry.cte.name.clone());
    match &*entry.state.borrow() {
        State::Expanding => return Err(format!("circular reference: {}", entry.cte.name)),
        State::Recursive { slot, cols } => {
            scope.sources.push(Source {
                name: src_name,
                columns: cols.clone(),
                offset,
                qualified_only: false,
                has_rowid: false,
            });
            return Ok(Some(SrcPlan::Queue(slot.clone())));
        }
        State::Idle => {}
    }
    *entry.state.borrow_mut() = State::Expanding;
    let c2 = Rc::new(Cell::new(0));
    let r = crate::cte::upto(depth, || plan_cte(db, entry, parent, &c2));
    *entry.state.borrow_mut() = State::Idle;
    let (src, columns) = r?;
    corr.set(corr.get().max(c2.get()));
    let names = match &entry.cte.columns {
        Some(names) => {
            if names.len() != columns.len() {
                return Err(format!(
                    "table {} has {} values for {} columns",
                    entry.cte.name,
                    columns.len(),
                    names.len()
                ));
            }
            names.clone()
        }
        None => unique_names(&columns),
    };
    scope.sources.push(Source {
        name: src_name,
        columns: columns.iter().zip(names).map(|(c, n)| SrcCol::new(&n, c.aff, c.coll)).collect(),
        offset,
        qualified_only: false,
        has_rowid: false,
    });
    let cache = if c2.get() == 0 { Some(entry.cache.clone()) } else { None };
    Ok(Some(match src {
        CteBody::Plain(p) => SrcPlan::Query(Rc::new(p), cache),
        CteBody::Recursive(r) => SrcPlan::Recursive(Rc::new(r), cache),
    }))
}

enum CteBody {
    Plain(QueryPlan),
    Recursive(RecPlan),
}

/// Plans the body of a CTE (its entry is marked as expanding).
fn plan_cte(
    db: &Database,
    entry: &crate::cte::Entry,
    parent: &Option<Rc<Scope>>,
    corr: &Rc<Cell<usize>>,
) -> Result<(CteBody, Vec<ColMeta>), String> {
    let q = &entry.cte.select;
    let name = &entry.cte.name;
    crate::cte::with_scope(q.with.as_ref(), || {
        let n = q.cores.len();
        // trailing selects with the same UNION [ALL] that read the CTE in
        // their FROM clause are recursive
        let mut k = 0;
        if let Some(&last_op) = q.ops.last() {
            if matches!(last_op, CompoundOp::Union | CompoundOp::UnionAll) {
                while k + 1 < n && q.ops[n - 2 - k] == last_op {
                    let refs = direct_refs(&q.cores[n - 1 - k], name);
                    if refs == 0 {
                        break;
                    }
                    if refs > 1 {
                        return Err(format!("multiple references to recursive table: {}", name));
                    }
                    k += 1;
                }
            }
        }
        if k == 0 {
            let plan = plan_query(db, q, parent.clone(), corr.clone())?;
            let cols = plan.columns.clone();
            return Ok((CteBody::Plain(plan), cols));
        }
        let first_rec = n - k;
        for core in &q.cores[first_rec..] {
            if let SelectCore::Select(b) = core {
                let agg = !b.group_by.is_empty()
                    || b.columns.iter().any(|c| matches!(c, ResultColumn::Expr(e, _, _) if agg::contains_agg(e, &|_| true)));
                if agg {
                    return Err("recursive aggregate queries not supported".to_string());
                }
            }
            if core_subqueries_read(core, name) {
                return Err(format!("multiple recursive references: {}", name));
            }
        }
        let setup_sel = Select {
            with: None,
            cores: q.cores[..first_rec].to_vec(),
            ops: q.ops[..first_rec - 1].to_vec(),
            order_by: Vec::new(),
            limit: None,
            offset: None,
        };
        let setup = plan_query(db, &setup_sel, parent.clone(), corr.clone())?;
        let columns = setup.columns.clone();
        let names = match &entry.cte.columns {
            Some(ns) if ns.len() == columns.len() => ns.clone(),
            Some(ns) => {
                return Err(format!("table {} has {} values for {} columns", name, columns.len(), ns.len()));
            }
            None => unique_names(&columns),
        };
        let slot: Rc<RefCell<Rows>> = Rc::new(RefCell::new(Vec::new()));
        let qcols: Vec<SrcCol> = columns.iter().zip(&names).map(|(c, n)| SrcCol::new(n, c.aff, c.coll)).collect();
        *entry.state.borrow_mut() = crate::cte::State::Recursive { slot: slot.clone(), cols: qcols };
        let mut arms = Vec::new();
        let mut res: Result<(), String> = Ok(());
        for (j, core) in q.cores.iter().enumerate().skip(first_rec) {
            let arm = Select {
                with: None,
                cores: vec![core.clone()],
                ops: Vec::new(),
                order_by: Vec::new(),
                limit: None,
                offset: None,
            };
            match plan_query(db, &arm, parent.clone(), corr.clone()) {
                Ok(p) => {
                    if p.columns.len() != columns.len() {
                        res = Err(format!(
                            "SELECTs to the left and right of {} do not have the same number of result columns",
                            q.ops[j - 1].name()
                        ));
                        break;
                    }
                    arms.push(p);
                }
                Err(e) => {
                    res = Err(e);
                    break;
                }
            }
        }
        *entry.state.borrow_mut() = crate::cte::State::Expanding;
        res?;
        let colls: Vec<Coll> = columns.iter().map(|c| c.coll.unwrap_or(Coll::Binary)).collect();
        // ORDER BY terms name result columns
        let mut order = Vec::new();
        for (ti, term) in q.order_by.iter().enumerate() {
            let mut inner = &term.expr;
            let mut explicit: Option<&str> = None;
            while let Expr::Collate(x, c) = inner {
                explicit.get_or_insert(c.as_str());
                inner = x;
            }
            let idx = match inner {
                Expr::Literal(Value::Integer(i)) => {
                    if *i < 1 || *i as usize > columns.len() {
                        return Err(format!(
                            "{} ORDER BY term out of range - should be between 1 and {}",
                            ordinal(ti + 1),
                            columns.len()
                        ));
                    }
                    Some(*i as usize - 1)
                }
                Expr::Column { table: None, name: cn, .. } => columns
                    .iter()
                    .position(|c| c.name.eq_ignore_ascii_case(cn))
                    .or_else(|| arms.iter().find_map(|a| a.columns.iter().position(|c| c.name.eq_ignore_ascii_case(cn)))),
                _ => None,
            };
            let Some(idx) = idx else {
                return Err(format!("{} ORDER BY term does not match any column in the result set", ordinal(ti + 1)));
            };
            let coll = match explicit {
                Some(c) => Coll::from_name(c)?,
                None => colls[idx],
            };
            order.push((idx, term.desc, term.nulls_first.unwrap_or(!term.desc), coll));
        }
        let limit_scope = Scope::child(parent.clone(), corr.clone());
        let limit = match &q.limit {
            Some(e) => Some(bind(e, &limit_scope, db)?),
            None => None,
        };
        let offset = match &q.offset {
            Some(e) => Some(bind(e, &limit_scope, db)?),
            None => None,
        };
        let rec = RecPlan {
            setup,
            arms,
            slot,
            distinct: *q.ops.last().unwrap() == CompoundOp::Union,
            colls,
            order,
            limit,
            offset,
        };
        Ok((CteBody::Recursive(rec), columns))
    })
}

/// Rows of sqlite_schema (type, name, tbl_name, rootpage, sql, rowid).
fn schema_rows(db: &Database, temp: bool) -> Rows {
    let text = |s: &str| Value::Text(s.to_string());
    let mut objs: Vec<(u64, Vec<Value>)> = Vec::new();
    for t in db.tables.values().filter(|t| t.temp == temp) {
        objs.push((t.order, vec![text("table"), text(&t.name), text(&t.name), Value::Integer(-t.root), text(&t.sql)]));
        for i in &t.indexes {
            let sql = match &i.def {
                Some(d) => text(&d.sql),
                None => Value::Null,
            };
            objs.push((i.order, vec![text("index"), text(&i.name), text(&t.name), Value::Integer(-i.root), sql]));
        }
    }
    for v in db.views.values().filter(|v| v.temp == temp) {
        objs.push((v.order, vec![text("view"), text(&v.name), text(&v.name), Value::Integer(0), text(&v.sql)]));
    }
    objs.sort_by_key(|o| o.0);
    // objects stored in a database file keep their root page (stored
    // negated above); the others get pages after the highest one
    let mut page = objs.iter().map(|o| if let Value::Integer(p) = o.1[3] { -p } else { 0 }).max().unwrap_or(0).max(1);
    objs.into_iter()
        .enumerate()
        .map(|(i, (_, mut r))| {
            match r[3] {
                Value::Integer(0) if !matches!(&r[0], Value::Text(s) if s == "view") => {
                    page += 1;
                    r[3] = Value::Integer(page);
                }
                Value::Integer(p) => r[3] = Value::Integer(-p),
                _ => {}
            }
            r.push(Value::Integer(i as i64 + 1));
            r
        })
        .collect()
}

/// Adds a FROM item to the scope; returns its source plan.
fn add_source(
    db: &Database,
    item: &TableItem,
    scope: &mut Scope,
    offset: usize,
    parent: &Option<Rc<Scope>>,
    corr: &Rc<Cell<usize>>,
) -> Result<SrcPlan, String> {
    match item {
        TableItem::Table { name, alias } => {
            if let Some(src) = cte_source(db, name, alias, scope, offset, parent, corr)? {
                return Ok(src);
            }
            let k = key(name);
            if let Some(t) = db.tables.get(&k) {
                scope.sources.push(table_source(t, alias.as_deref().unwrap_or(&t.name), offset, false));
                return Ok(SrcPlan::Table(k));
            }
            if let Some(v) = db.views.get(&k) {
                let plan = plan_view(db, v)?;
                let names = view_column_names(v, &plan)?;
                let columns = plan.columns.iter().zip(names).map(|(c, n)| SrcCol::new(&n, c.aff, c.coll)).collect();
                scope.sources.push(Source {
                    name: alias.clone().unwrap_or_else(|| v.name.clone()),
                    columns,
                    offset,
                    qualified_only: false,
                    has_rowid: false,
                });
                return Ok(SrcPlan::Query(Rc::new(plan), Some(Rc::new(std::cell::OnceCell::new()))));
            }
            if is_schema_table(name) {
                let columns = [
                    ("type", Affinity::Text),
                    ("name", Affinity::Text),
                    ("tbl_name", Affinity::Text),
                    ("rootpage", Affinity::Integer),
                    ("sql", Affinity::Text),
                ]
                .iter()
                .map(|(n, a)| SrcCol::new(n, *a, Some(Coll::Binary)))
                .collect();
                scope.sources.push(Source {
                    name: alias.clone().unwrap_or_else(|| name.clone()),
                    columns,
                    offset,
                    qualified_only: false,
                    has_rowid: true,
                });
                return Ok(SrcPlan::Schema(crate::db::is_temp_schema_table(name)));
            }
            Err(format!("no such table: {}", name))
        }
        TableItem::Subquery { query, alias } => {
            // a derived table sees the enclosing query, not its siblings
            let plan = plan_query(db, query, parent.clone(), corr.clone())?;
            let columns = plan.columns.iter().map(|c| SrcCol::new(&c.name, c.aff, c.coll)).collect();
            scope.sources.push(Source {
                name: alias.clone().unwrap_or_default(),
                columns,
                offset,
                qualified_only: false,
                has_rowid: false,
            });
            Ok(SrcPlan::Query(Rc::new(plan), None))
        }
    }
}

fn is_view_item(db: &Database, it: &TableItem) -> bool {
    match it {
        TableItem::Table { name, .. } if crate::cte::is_cte(name) => false,
        TableItem::Table { name, .. } => !db.tables.contains_key(&key(name)) && db.views.contains_key(&key(name)),
        TableItem::Subquery { .. } => false,
    }
}

/// Plans the FROM clause into join steps, filling the scope.
fn plan_from(
    db: &Database,
    from: &From,
    scope: &mut Scope,
    parent: &Option<Rc<Scope>>,
    corr: &Rc<Cell<usize>>,
) -> Result<(Vec<JoinStep>, usize), String> {
    let mut steps = Vec::new();
    let mut offset = 0;
    let src = add_source(db, &from.first, scope, offset, parent, corr)?;
    let width = scope.sources[0].columns.len() + 1;
    steps.push(JoinStep {
        src,
        kind: JoinKind::Inner,
        cross: false,
        view: is_view_item(db, &from.first),
        filters: Vec::new(),
        post: Vec::new(),
        access: Access::Scan { reverse: false },
        auto: None,
        offset,
        width,
    });
    offset += width;
    for j in &from.joins {
        let src = add_source(db, &j.item, scope, offset, parent, corr)?;
        let si = scope.sources.len() - 1;
        let width = scope.sources[si].columns.len() + 1;
        // USING / NATURAL columns
        let names: Vec<String> = if j.natural {
            scope.sources[si]
                .columns
                .iter()
                .map(|c| c.name.clone())
                .filter(|n| left_column(scope, si, n).is_some())
                .collect()
        } else {
            j.using.clone().unwrap_or_default()
        };
        let mut cond: Option<BExpr> = None;
        for n in &names {
            let Some((ls, lc)) = left_column(scope, si, n) else {
                return Err(format!("cannot join using column {} - column not present in both tables", n));
            };
            let Some(rc) = scope.sources[si].columns.iter().position(|c| c.name.eq_ignore_ascii_case(n)) else {
                return Err(format!("cannot join using column {} - column not present in both tables", n));
            };
            let left = source_col(scope, 0, &scope.sources[ls], lc);
            let rcol = &scope.sources[si].columns[rc];
            let right = BExpr::Col { idx: offset + rc, aff: rcol.aff, coll: rcol.coll };
            let eq = make_cmp(BinOp::Eq, left, right)?;
            cond = Some(match cond {
                None => eq,
                Some(c) => BExpr::And(Box::new(c), Box::new(eq)),
            });
            scope.sources[si].columns[rc].hidden = true;
            if matches!(j.kind, JoinKind::Right | JoinKind::Full) {
                scope.sources[ls].columns[lc].merged.push(offset + rc);
            }
        }
        if let Some(on) = &j.on {
            let b = bind(on, scope, db)?;
            cond = Some(match cond {
                None => b,
                Some(c) => BExpr::And(Box::new(c), Box::new(b)),
            });
        }
        let mut filters = Vec::new();
        if let Some(c) = cond {
            conjuncts(c, &mut filters);
        }
        steps.push(JoinStep {
            src,
            kind: j.kind,
            cross: j.cross,
            view: is_view_item(db, &j.item),
            filters,
            post: Vec::new(),
            access: Access::Scan { reverse: false },
            auto: None,
            offset,
            width,
        });
        offset += width;
    }
    Ok((steps, offset))
}

/// The visible column named `n` among sources before `upto`.
fn left_column(scope: &Scope, upto: usize, n: &str) -> Option<(usize, usize)> {
    for (si, s) in scope.sources[..upto].iter().enumerate() {
        if let Some(ci) = s.columns.iter().position(|c| !c.hidden && c.name.eq_ignore_ascii_case(n)) {
            return Some((si, ci));
        }
    }
    None
}

fn plan_select(
    db: &Database,
    sel: &SelectBody,
    parent: Option<Rc<Scope>>,
    corr: Rc<Cell<usize>>,
    order_by: &[OrderTerm],
    limit: Option<i64>,
) -> Result<CoreInfo, String> {
    plan_select_mode(db, sel, parent, corr, order_by, limit, false)
}

fn plan_select_mode(
    db: &Database,
    sel: &SelectBody,
    parent: Option<Rc<Scope>>,
    corr: Rc<Cell<usize>>,
    order_by: &[OrderTerm],
    limit: Option<i64>,
    force_agg: bool,
) -> Result<CoreInfo, String> {
    // merge simple views and subqueries into this query
    let mut flat: Option<(SelectBody, Vec<OrderTerm>)> = None;
    for _ in 0..16 {
        let (b, o) = match &flat {
            Some((b, o)) => (b, &o[..]),
            None => (sel, order_by),
        };
        match crate::flatten::flatten(db, b, o) {
            Some(f) => flat = Some(f),
            None => break,
        }
    }
    let (sel, order_by) = match &flat {
        Some((b, o)) => (b, &o[..]),
        None => (sel, order_by),
    };
    let mut scope = Scope::child(parent.clone(), corr.clone());
    let (steps, width) = match &sel.from {
        Some(f) => plan_from(db, f, &mut scope, &parent, &corr)?,
        None => (Vec::new(), 0),
    };
    let mut cols = expand_columns(&sel.columns, &scope)?;
    let aliases: Vec<Option<String>> = cols.iter().map(|(_, a, _)| a.clone()).collect();

    // aggregates in HAVING or ORDER BY alone do not make an aggregate query;
    // aggregates over outer columns belong to the outer query
    let is_local = |fc: &FuncCall| outer_agg_level(fc, &scope).is_none();
    let is_agg =
        force_agg || !sel.group_by.is_empty() || cols.iter().any(|(e, _, _)| agg::contains_agg(e, &is_local));

    // window function calls of the result columns and ORDER BY become
    // references to result slots
    let orig_order_by = order_by;
    let mut win_calls: Vec<FuncCall> = Vec::new();
    for c in cols.iter_mut() {
        c.0 = crate::window::extract(&c.0, &sel.windows, &mut win_calls)?;
    }
    let mut order_terms: Vec<OrderTerm> = order_by.to_vec();
    for t in order_terms.iter_mut() {
        t.expr = crate::window::extract(&t.expr, &sel.windows, &mut win_calls)?;
    }
    let order_by = &order_terms[..];
    let n_win = win_calls.len();
    if sel.having.is_some() && !is_agg {
        return Err("HAVING clause on a non-aggregate query".to_string());
    }

    let where_ = match &sel.where_ {
        Some(w) => Some(bind(&subst_aliases(w, &cols, &scope)?, &scope, db)?),
        None => None,
    };
    let mut steps = steps;

    let mut out_scope = scope.clone();
    let aggs: Rc<RefCell<Vec<FuncCall>>> = Rc::new(RefCell::new(Vec::new()));
    let agg_request = Rc::new(Cell::new(false));
    if n_win > 0 {
        out_scope.win_base = Some(width);
    }
    if is_agg {
        out_scope.agg_base = Some(width + n_win);
        out_scope.aggs = Some(aggs.clone());
    } else {
        out_scope.agg_request = Some(agg_request.clone());
    }
    let bind_out = |e: &Expr| -> Result<BExpr, String> {
        if is_agg {
            let x = agg::extract(e, &aggs, &is_local)?;
            bind(&x, &out_scope, db)
        } else {
            bind(e, &out_scope, db)
        }
    };

    let mut outs = Vec::with_capacity(cols.len());
    for (e, _, _) in &cols {
        outs.push(bind_out(e)?);
    }

    // GROUP BY terms and their collations
    let mut group_by: Vec<(BExpr, Coll)> = Vec::new();
    for (gi, g) in sel.group_by.iter().enumerate() {
        let mut inner = g;
        while let Expr::Collate(x, _) = inner {
            inner = x;
        }
        let e = match inner {
            Expr::Literal(Value::Integer(n)) => {
                if *n < 1 || *n as usize > cols.len() {
                    return Err(format!(
                        "{} GROUP BY term out of range - should be between 1 and {}",
                        ordinal(gi + 1),
                        cols.len()
                    ));
                }
                let mut e = cols[*n as usize - 1].0.clone();
                if let Expr::Collate(_, c) = g {
                    e = Expr::Collate(Box::new(e), c.clone());
                }
                e
            }
            _ => subst_aliases(g, &cols, &scope)?,
        };
        if agg::contains_agg(&e, &is_local) {
            return Err("aggregate functions are not allowed in the GROUP BY clause".to_string());
        }
        let b = bind(&e, &scope, db)?;
        let coll = check_coll(expr_coll(&b).unwrap_or(Coll::Binary))?;
        group_by.push((b, coll));
    }

    let having = match &sel.having {
        Some(h) => Some(bind_out(&subst_aliases(h, &cols, &scope)?)?),
        None => None,
    };

    let mut keys: Vec<OrderSpec> = Vec::new();
    for term in order_by {
        // look through COLLATE for ordinals and aliases
        let mut inner = &term.expr;
        let mut explicit: Option<&str> = None;
        while let Expr::Collate(x, c) = inner {
            explicit.get_or_insert(c.as_str());
            inner = x;
        }
        let key = match inner {
            Expr::Literal(Value::Integer(n)) => {
                if *n < 1 || *n as usize > outs.len() {
                    return Err(format!(
                        "{} ORDER BY term out of range - should be between 1 and {}",
                        ordinal(keys.len() + 1),
                        outs.len()
                    ));
                }
                SortKey::Result(*n as usize - 1)
            }
            Expr::Column { table: None, name, .. }
                if aliases.iter().any(|a| a.as_deref().is_some_and(|a| a.eq_ignore_ascii_case(name))) =>
            {
                let i = aliases
                    .iter()
                    .position(|a| a.as_deref().is_some_and(|a| a.eq_ignore_ascii_case(name)))
                    .unwrap();
                SortKey::Result(i)
            }
            _ => SortKey::Expr(bind_out(&subst_aliases(&term.expr, &cols, &scope)?)?),
        };
        let coll = match (&key, explicit) {
            (SortKey::Result(_), Some(c)) => Coll::from_name(c)?,
            (SortKey::Result(i), None) => expr_coll(&outs[*i]).unwrap_or(Coll::Binary),
            (SortKey::Expr(e), _) => expr_coll(e).unwrap_or(Coll::Binary),
        };
        let coll = check_coll(coll)?;
        keys.push(OrderSpec { key, desc: term.desc, nulls_first: term.nulls_first.unwrap_or(!term.desc), coll });
    }

    let win = if n_win > 0 { Some(crate::window::plan(&win_calls, width, &bind_out)?) } else { None };

    if agg_request.get() {
        return plan_select_mode(db, sel, parent, corr, orig_order_by, limit, true);
    }

    // bind the aggregate calls against the source rows (binding may find
    // more aggregates of this query inside subqueries)
    let mut specs: Vec<AggSpec> = Vec::new();
    while specs.len() < aggs.borrow().len() {
        let fc = aggs.borrow()[specs.len()].clone();
        let kind = agg::agg_kind(&fc)?;
        let mut args = Vec::with_capacity(fc.args.len());
        for a in &fc.args {
            args.push(bind(a, &scope, db)?);
        }
        let filter = match &fc.filter {
            Some(f) => Some(bind(f, &scope, db)?),
            None => None,
        };
        let mut order = Vec::with_capacity(fc.order_by.len());
        for t in &fc.order_by {
            let b = bind(&t.expr, &scope, db)?;
            let coll = check_coll(expr_coll(&b).unwrap_or(Coll::Binary))?;
            order.push((b, t.desc, t.nulls_first.unwrap_or(!t.desc), coll));
        }
        let coll = args.first().and_then(expr_coll).unwrap_or(Coll::Binary);
        let coll = if kind == AggKind::Min || kind == AggKind::Max || fc.distinct { check_coll(coll)? } else { coll };
        specs.push(AggSpec { kind, args, distinct: fc.distinct, filter, order, coll });
    }

    // choose access paths and the join order
    let group_desc: Vec<bool> = if order_by.len() == group_by.len() {
        order_by.iter().map(|t| t.desc).collect()
    } else {
        vec![false; group_by.len()]
    };
    let mut used: Vec<usize> = Vec::new();
    {
        let mut all: Vec<&BExpr> = Vec::new();
        all.extend(where_.iter());
        for st in &steps {
            all.extend(st.filters.iter());
        }
        all.extend(outs.iter());
        all.extend(group_by.iter().map(|(g, _)| g));
        all.extend(having.iter());
        for k in &keys {
            if let SortKey::Expr(e) = &k.key {
                all.push(e);
            }
        }
        for sp in &specs {
            all.extend(sp.args.iter());
            all.extend(sp.filter.iter());
            all.extend(sp.order.iter().map(|o| &o.0));
        }
        if let Some(w) = &win {
            all.extend(w.exprs());
        }
        for e in all {
            expr_cols(e, 0, &mut used);
        }
    }
    let mut reqs: Vec<access::OrderReq> = Vec::new();
    let mut mode = access::OrderMode::Order;
    if win.is_some() && !is_agg {
        // rows are reordered by the windows
    } else if !is_agg {
        for k in &keys {
            let e = match &k.key {
                SortKey::Result(i) => outs[*i].clone(),
                SortKey::Expr(e) => e.clone(),
            };
            reqs.push(access::OrderReq { e, desc: k.desc, nulls_first: k.nulls_first, coll: k.coll });
        }
        if keys.is_empty() && sel.distinct && !distinct_redundant(db, &steps, &outs) {
            mode = access::OrderMode::Distinct;
            for (o, c) in outs.iter().zip(outs.iter().map(|o| expr_coll(o).unwrap_or(Coll::Binary))) {
                reqs.push(access::OrderReq { e: o.clone(), desc: false, nulls_first: true, coll: c });
            }
        }
    } else {
        mode = access::OrderMode::Group;
        for ((g, c), d) in group_by.iter().zip(&group_desc) {
            reqs.push(access::OrderReq { e: g.clone(), desc: *d, nulls_first: !*d, coll: *c });
        }
    }
    let (where_, loop_order, ordered, where_rows) = plan_levels(
        db,
        &mut steps,
        where_,
        &used,
        reqs,
        mode,
        outs.len(),
        if keys.is_empty() || win.is_some() { None } else { limit },
    );

    let distinct_colls: Vec<Coll> = outs.iter().map(|o| expr_coll(o).unwrap_or(Coll::Binary)).collect();
    let columns: Vec<ColMeta> = cols
        .iter()
        .zip(&outs)
        .map(|((_, _, name), o)| ColMeta { name: name.clone(), aff: affinity(o), coll: expr_coll(o) })
        .collect();
    let colls = outs.iter().map(expr_coll).collect();
    let exprs = cols.iter().map(|(e, _, _)| Some(e.clone())).collect();
    let group_by_empty = group_by.is_empty();
    let plan = SelectPlan {
        steps,
        loop_order,
        width,
        where_,
        is_agg,
        group_desc,
        groups_in_scan_order: is_agg && ordered && !group_by.is_empty(),
        group_by,
        having,
        specs,
        outs,
        distinct: sel.distinct,
        distinct_colls,
        keys,
        win,
    };
    // SQLite's nSelectRow: one row for an aggregate, at most 100 groups
    let rows = if !is_agg {
        where_rows
    } else if group_by_empty {
        0
    } else {
        where_rows.min(66)
    };
    Ok(CoreInfo { plan: CorePlan::Select(Box::new(plan)), columns, exprs, colls, rows })
}

/// DISTINCT on a single table whose result includes the rowid does nothing.
fn distinct_redundant(db: &Database, steps: &[JoinStep], outs: &[BExpr]) -> bool {
    if steps.len() != 1 {
        return false;
    }
    let SrcPlan::Table(k) = &steps[0].src else { return false };
    let Some(t) = db.tables.get(k) else { return false };
    let n = t.columns.len();
    outs.iter().any(|o| match o {
        BExpr::Col { idx, .. } => *idx == n || Some(*idx) == t.ipk,
        _ => false,
    })
}

/// Positions read by an expression at query level `depth` (0 = this
/// level's own row; Outer references of subqueries `depth` levels down).
fn expr_cols(e: &BExpr, depth: usize, out: &mut Vec<usize>) {
    match e {
        BExpr::Col { idx, .. } if depth == 0 => out.push(*idx),
        BExpr::Outer { depth: d, idx, .. } if *d == depth => out.push(*idx),
        BExpr::Sub(sq) => {
            if sq.correlated {
                plan_cols(&sq.plan, depth + 1, out);
            }
            if let crate::eval::SubKind::In { e, .. } = &sq.kind {
                expr_cols(e, depth, out);
            }
        }
        _ => {
            for c in crate::eval::children(e) {
                expr_cols(c, depth, out);
            }
        }
    }
}

/// Positions of the query `depth` levels up that a subquery plan reads.
fn plan_cols(plan: &QueryPlan, depth: usize, out: &mut Vec<usize>) {
    for core in &plan.cores {
        match core {
            CorePlan::Values(rows) => {
                for e in rows.iter().flatten() {
                    expr_cols(e, depth, out);
                }
            }
            CorePlan::Select(sp) => {
                let mut all: Vec<&BExpr> = Vec::new();
                all.extend(sp.where_.iter());
                for st in &sp.steps {
                    all.extend(st.filters.iter());
                    all.extend(st.post.iter());
                    match &st.src {
                        SrcPlan::Query(q, _) => plan_cols(q, depth, out),
                        SrcPlan::Recursive(r, _) => {
                            plan_cols(&r.setup, depth, out);
                            for a in &r.arms {
                                plan_cols(a, depth, out);
                            }
                        }
                        _ => {}
                    }
                }
                all.extend(sp.outs.iter());
                all.extend(sp.group_by.iter().map(|(g, _)| g));
                all.extend(sp.having.iter());
                for k in &sp.keys {
                    if let SortKey::Expr(e) = &k.key {
                        all.push(e);
                    }
                }
                for s in &sp.specs {
                    all.extend(s.args.iter());
                    all.extend(s.filter.iter());
                    all.extend(s.order.iter().map(|o| &o.0));
                }
                if let Some(w) = &sp.win {
                    all.extend(w.exprs());
                }
                for e in all {
                    expr_cols(e, depth, out);
                }
            }
        }
    }
    for e in plan.limit.iter().chain(plan.offset.iter()) {
        expr_cols(e, depth, out);
    }
}

/// Chooses each level's access path and the join order, and places the
/// WHERE terms at the loops where they can first be checked; returns the
/// part of the WHERE clause left for the joined rows, the loop order and
/// whether rows come out in the required order.
#[allow(clippy::too_many_arguments)]
fn plan_levels(
    db: &Database,
    steps: &mut [JoinStep],
    where_: Option<BExpr>,
    used: &[usize],
    order_by: Vec<access::OrderReq>,
    mode: access::OrderMode,
    n_cols: usize,
    limit: Option<i64>,
) -> (Option<BExpr>, Vec<usize>, bool, i32) {
    let identity: Vec<usize> = (0..steps.len()).collect();
    if steps.is_empty() {
        return (where_, identity, false, 0);
    }
    let mut levels: Vec<access::Level> = steps
        .iter()
        .map(|s| {
            let table = match &s.src {
                SrcPlan::Table(k) => db.tables.get(k),
                _ => None,
            };
            let ncols = s.width - 1;
            let mut u = vec![false; ncols];
            for &p in used {
                if p >= s.offset && p < s.offset + ncols {
                    u[p - s.offset] = true;
                }
            }
            let rows = match &s.src {
                SrcPlan::Query(q, _) => q.rows,
                SrcPlan::Queue(_) => 0,
                _ => access::TABLE_ROWS,
            };
            access::Level {
                table,
                offset: s.offset,
                width: s.width,
                used: u,
                nullable: false,
                was_outer: s.kind == JoinKind::Left,
                prereq: 0,
                rows,
                is_view: s.view,
            }
        })
        .collect();
    let all_prior = |k: usize| (1u64 << k) - 1;
    if steps.iter().any(|s| matches!(s.kind, JoinKind::Right | JoinKind::Full)) {
        // keep the FROM order; inner levels may still use transient indexes
        let mut terms = Vec::new();
        for (k, s) in steps.iter().enumerate() {
            levels[k].nullable = true;
            levels[k].prereq = all_prior(k);
            for f in &s.filters {
                access::plan_terms(f, &levels, Some(k), &mut terms);
            }
        }
        let planner = access::Planner {
            db,
            levels,
            terms,
            order_by: Vec::new(),
            mode: access::OrderMode::Order,
            n_cols,
            limit: None,
            covering_scans: true,
        };
        for (k, step) in steps.iter_mut().enumerate().skip(1) {
            step.auto = planner.exec_auto(k, all_prior(k));
        }
        return (where_, identity, false, access::TABLE_ROWS);
    }
    let mut wterms = Vec::new();
    if let Some(w) = where_ {
        conjuncts(w, &mut wterms);
    }
    // a LEFT JOIN whose right side the WHERE clause requires to be non-NULL
    // is an inner join
    for s in steps.iter_mut() {
        if s.kind == JoinKind::Left
            && wterms.iter().any(|t| access::implies_non_null(t, s.offset, s.offset + s.width))
        {
            s.kind = JoinKind::Inner;
        }
    }
    // outer joins and CROSS JOINs keep the tables to their left outer
    let mut prior = 0u64;
    let mut prereq = 0u64;
    for (k, s) in steps.iter().enumerate() {
        levels[k].nullable = s.kind == JoinKind::Left;
        if s.kind == JoinKind::Left || s.cross {
            prereq |= prior;
        } else {
            prereq = 0;
        }
        levels[k].prereq = prereq;
        prior |= 1u64 << k;
    }
    // WHERE terms come first, then the ON terms (as SQLite orders them)
    let mut terms: Vec<access::Term> = Vec::new();
    for t in &wterms {
        access::plan_terms(t, &levels, None, &mut terms);
    }
    for (k, s) in steps.iter_mut().enumerate() {
        let owner = if s.kind == JoinKind::Left { Some(k) } else { None };
        for f in std::mem::take(&mut s.filters) {
            access::plan_terms(&f, &levels, owner, &mut terms);
        }
    }
    let planner = access::Planner {
        db,
        levels,
        terms,
        order_by,
        mode,
        n_cols,
        limit,
        covering_scans: true,
    };
    let plan = planner.plan();
    for (k, (acc, auto)) in plan.loops.into_iter().enumerate() {
        steps[k].access = acc;
        steps[k].auto = auto;
    }
    let mut pos_of = vec![0; steps.len()];
    for (p, &l) in plan.order.iter().enumerate() {
        pos_of[l] = p;
    }
    for t in planner.terms.into_iter().filter(|t| !t.virt) {
        if let Some(k) = t.owner {
            steps[k].filters.push(t.e);
            continue;
        }
        let p = if t.mask == u64::MAX {
            steps.len() - 1
        } else {
            (0..steps.len()).filter(|l| t.mask & (1u64 << l) != 0).map(|l| pos_of[l]).max().unwrap_or(0)
        };
        let k = plan.order[p];
        if steps[k].kind == JoinKind::Left {
            steps[k].post.push(t.e);
        } else {
            steps[k].filters.push(t.e);
        }
    }
    (None, plan.order, plan.ordered, plan.n_row)
}

// ---------- execution ----------

/// Evaluates a LIMIT/OFFSET expression.
fn limit_value(e: &BExpr, env: &Env) -> Result<i64, String> {
    let v = eval(e, &[], env)?;
    match apply_affinity(v, Affinity::Integer) {
        Value::Integer(i) => Ok(i),
        _ => Err("datatype mismatch".to_string()),
    }
}

/// Runs a query; `max_rows` caps the number of rows wanted by the caller.
pub fn run_query(plan: &QueryPlan, env: &Env, max_rows: Option<usize>) -> Result<Rows, String> {
    let limit = match &plan.limit {
        Some(e) => limit_value(e, env)?,
        None => -1,
    };
    let offset = match &plan.offset {
        Some(e) => limit_value(e, env)?.max(0) as usize,
        None => 0,
    };
    let mut want: Option<usize> = if limit < 0 { None } else { Some(limit as usize) };
    if let Some(m) = max_rows {
        want = Some(want.map_or(m, |w| w.min(m)));
    }
    if want == Some(0) {
        return Ok(Vec::new());
    }
    let finish = |rows: Rows| -> Rows {
        let it = rows.into_iter().skip(offset);
        match want {
            Some(w) => it.take(w).collect(),
            None => it.collect(),
        }
    };
    if plan.ops.is_empty() && plan.order.is_empty() {
        let stop = want.map(|w| w + offset);
        let rows = match &plan.cores[0] {
            CorePlan::Select(sp) => run_select(sp, env, stop)?,
            CorePlan::Values(rows) => run_values(rows, env)?,
        };
        return Ok(finish(rows));
    }
    let mut acc: Rows = match &plan.cores[0] {
        CorePlan::Select(sp) => run_select(sp, env, None)?,
        CorePlan::Values(rows) => run_values(rows, env)?,
    };
    let key = |r: &[Value]| -> Vec<KeyVal> { r.iter().zip(&plan.colls).map(|(v, c)| key_val(v, *c)).collect() };
    for (op, core) in plan.ops.iter().zip(&plan.cores[1..]) {
        let rows = match core {
            CorePlan::Select(sp) => run_select(sp, env, None)?,
            CorePlan::Values(rows) => run_values(rows, env)?,
        };
        acc = match op {
            CompoundOp::UnionAll => {
                acc.extend(rows);
                acc
            }
            CompoundOp::Union => {
                // later duplicates replace earlier ones; output is in key order
                let mut m: BTreeMap<Vec<KeyVal>, Vec<Value>> = BTreeMap::new();
                for r in acc.into_iter().chain(rows) {
                    m.insert(key(&r), r);
                }
                m.into_values().collect()
            }
            CompoundOp::Intersect | CompoundOp::Except => {
                let right: BTreeSet<Vec<KeyVal>> = rows.iter().map(|r| key(r)).collect();
                let keep = *op == CompoundOp::Intersect;
                let mut m: BTreeMap<Vec<KeyVal>, Vec<Value>> = BTreeMap::new();
                for r in acc {
                    let k = key(&r);
                    if right.contains(&k) == keep {
                        m.insert(k, r);
                    }
                }
                m.into_values().collect()
            }
        };
    }
    if !plan.order.is_empty() {
        let terms: Vec<(bool, bool, Coll)> = plan.order.iter().map(|&(_, d, n, c)| (d, n, c)).collect();
        let mut keyed: Vec<(Vec<Value>, Vec<Value>)> = acc
            .into_iter()
            .map(|r| (plan.order.iter().map(|&(i, ..)| r[i].clone()).collect(), r))
            .collect();
        keyed.sort_by(|a, b| agg::cmp_order(&a.0, &b.0, &terms));
        acc = keyed.into_iter().map(|(_, r)| r).collect();
    }
    Ok(finish(acc))
}

/// A queued row of a recursive CTE with an ORDER BY: smallest key first,
/// then first queued.
struct Queued {
    keys: Vec<Value>,
    seq: u64,
    row: Vec<Value>,
    terms: Rc<Vec<(bool, bool, Coll)>>,
}

impl PartialEq for Queued {
    fn eq(&self, o: &Self) -> bool {
        self.cmp(o) == std::cmp::Ordering::Equal
    }
}
impl Eq for Queued {}
impl PartialOrd for Queued {
    fn partial_cmp(&self, o: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(o))
    }
}
impl Ord for Queued {
    fn cmp(&self, o: &Self) -> std::cmp::Ordering {
        // BinaryHeap pops the greatest: reverse
        agg::cmp_order(&self.keys, &o.keys, &self.terms).then(self.seq.cmp(&o.seq)).reverse()
    }
}

/// Runs a recursive CTE: queued rows are output one at a time and fed to
/// the recursive selects.
fn run_recursive(rp: &RecPlan, env: &Env) -> Result<Rows, String> {
    let limit = match &rp.limit {
        Some(e) => limit_value(e, env)?,
        None => -1,
    };
    let mut offset = match &rp.offset {
        Some(e) => limit_value(e, env)?.max(0),
        None => 0,
    };
    let mut out: Rows = Vec::new();
    if limit == 0 {
        return Ok(out);
    }
    let terms: Rc<Vec<(bool, bool, Coll)>> = Rc::new(rp.order.iter().map(|&(_, d, n, c)| (d, n, c)).collect());
    let mut seen: BTreeSet<Vec<KeyVal>> = BTreeSet::new();
    let mut fifo: std::collections::VecDeque<Vec<Value>> = std::collections::VecDeque::new();
    let mut heap: std::collections::BinaryHeap<Queued> = std::collections::BinaryHeap::new();
    let mut seq = 0u64;
    let mut push = |row: Vec<Value>, fifo: &mut std::collections::VecDeque<Vec<Value>>, heap: &mut std::collections::BinaryHeap<Queued>| {
        if rp.distinct {
            let k: Vec<KeyVal> = row.iter().zip(&rp.colls).map(|(v, c)| key_val(v, *c)).collect();
            if !seen.insert(k) {
                return;
            }
        }
        if rp.order.is_empty() {
            fifo.push_back(row);
        } else {
            let keys = rp.order.iter().map(|&(i, ..)| row[i].clone()).collect();
            seq += 1;
            heap.push(Queued { keys, seq, row, terms: terms.clone() });
        }
    };
    for r in run_query(&rp.setup, env, None)? {
        push(r, &mut fifo, &mut heap);
    }
    loop {
        let row = if rp.order.is_empty() {
            fifo.pop_front()
        } else {
            heap.pop().map(|q| q.row)
        };
        let Some(row) = row else { break };
        if offset > 0 {
            offset -= 1;
        } else {
            out.push(row.clone());
            if limit > 0 && out.len() as i64 >= limit {
                break;
            }
        }
        let mut cur = row;
        cur.push(Value::Null);
        *rp.slot.borrow_mut() = vec![cur];
        for arm in &rp.arms {
            for r in run_query(arm, env, None)? {
                push(r, &mut fifo, &mut heap);
            }
        }
    }
    rp.slot.borrow_mut().clear();
    Ok(out)
}

fn run_values(rows: &[Vec<BExpr>], env: &Env) -> Result<Rows, String> {
    let mut out = Vec::with_capacity(rows.len());
    for r in rows {
        let mut vals = Vec::with_capacity(r.len());
        for e in r {
            vals.push(eval(e, &[], env)?);
        }
        out.push(vals);
    }
    Ok(out)
}

/// Rows of one FROM source for a query execution.
enum Mat<'a> {
    Table(&'a Table),
    Rows(Cow<'a, Rows>),
}

impl Mat<'_> {
    fn len(&self) -> usize {
        match self {
            Mat::Table(t) => t.rows.len(),
            Mat::Rows(r) => r.len(),
        }
    }
}

type Sink<'s> = dyn FnMut(&[Value]) -> Result<bool, String> + 's;

/// A transient index over one join level: keys and the rows they index.
struct Auto<'a> {
    map: AutoIndex,
    /// For table levels, the rows by position.
    rows: Vec<(i64, &'a Vec<Value>)>,
}

struct Joiner<'a, 'e> {
    steps: &'a [JoinStep],
    order: &'a [usize],
    mats: Vec<Mat<'a>>,
    autos: Vec<RefCell<Option<Auto<'a>>>>,
    env: &'e Env<'e>,
}

fn all_true(conds: &[BExpr], row: &[Value], env: &Env) -> Result<bool, String> {
    for c in conds {
        if eval(c, row, env)?.truth() != Some(true) {
            return Ok(false);
        }
    }
    Ok(true)
}

impl<'a> Joiner<'a, '_> {
    fn build_auto(&self, k: usize, ak: &AutoKey) -> Result<Auto<'a>, String> {
        let step = &self.steps[k];
        let mut map = AutoIndex::new();
        let mut tmp: Vec<Value> = vec![Value::Null; step.offset];
        let mut rows = Vec::new();
        let mut add = |pos: usize, r: &[Value], rowid: Option<i64>, tmp: &mut Vec<Value>| -> Result<(), String> {
            tmp.truncate(step.offset);
            tmp.extend_from_slice(r);
            if let Some(id) = rowid {
                tmp.push(Value::Integer(id));
            }
            if let Some(key) = access::auto_key(eval(&ak.key, tmp, self.env)?, ak.aff, ak.coll, ak.null_ok) {
                map.entry(key).or_default().push(pos);
            }
            Ok(())
        };
        match &self.mats[k] {
            Mat::Table(t) => {
                for (i, (rowid, r)) in t.rows.iter().enumerate() {
                    add(i, r, Some(*rowid), &mut tmp)?;
                    rows.push((*rowid, r));
                }
            }
            Mat::Rows(rs) => {
                for (i, r) in rs.iter().enumerate() {
                    add(i, r, None, &mut tmp)?;
                }
            }
        }
        if !ak.sort_cols.is_empty() {
            let row_at = |i: usize| -> &[Value] {
                match &self.mats[k] {
                    Mat::Table(_) => rows[i].1,
                    Mat::Rows(rs) => &rs[i],
                }
            };
            for positions in map.values_mut() {
                positions.sort_by(|&a, &b| {
                    let (ra, rb) = (row_at(a), row_at(b));
                    for &c in &ak.sort_cols {
                        let o = crate::value::compare(&ra[c], &rb[c]);
                        if o != std::cmp::Ordering::Equal {
                            return o;
                        }
                    }
                    a.cmp(&b)
                });
            }
        }
        Ok(Auto { map, rows })
    }

    /// Enumerates the joined rows of the loops from position `pos` on,
    /// filling their slots of `buf`; returns false once the sink asks to
    /// stop.
    fn level(&self, pos: usize, buf: &mut [Value], matched: &mut [Vec<bool>], sink: &mut Sink) -> Result<bool, String> {
        if pos == self.order.len() {
            return sink(buf);
        }
        let k = self.order[pos];
        let step = &self.steps[k];
        let off = step.offset;
        let track = matches!(step.kind, JoinKind::Right | JoinKind::Full);
        let mut any = false;
        macro_rules! visit {
            ($i:expr) => {{
                if all_true(&step.filters, buf, self.env)? {
                    any = true;
                    if track {
                        matched[k][$i] = true;
                    }
                    if all_true(&step.post, buf, self.env)? && !self.level(pos + 1, buf, matched, sink)? {
                        return Ok(false);
                    }
                }
            }};
        }
        macro_rules! put_row {
            ($r:expr, $rowid:expr) => {{
                let r: &[Value] = $r;
                buf[off..off + r.len()].clone_from_slice(r);
                buf[off + r.len()] = Value::Integer($rowid);
            }};
        }
        if let Some(ak) = &step.auto {
            if self.autos[k].borrow().is_none() {
                let a = self.build_auto(k, ak)?;
                *self.autos[k].borrow_mut() = Some(a);
            }
            let probe = eval(&ak.probe, buf, self.env)?;
            let auto = self.autos[k].borrow();
            let auto = auto.as_ref().unwrap();
            if let Some(key) = access::auto_key(probe, ak.aff, ak.coll, ak.null_ok) {
                if let Some(positions) = auto.map.get(&key) {
                    for &i in positions {
                        match &self.mats[k] {
                            Mat::Table(_) => {
                                let (rowid, r) = auto.rows[i];
                                put_row!(r, rowid);
                            }
                            Mat::Rows(rows) => buf[off..off + rows[i].len()].clone_from_slice(&rows[i]),
                        }
                        visit!(i);
                    }
                }
            }
        } else {
            match &self.mats[k] {
                Mat::Table(t) => {
                    if step.access.is_scan() {
                        for (i, (rowid, r)) in t.rows.iter().enumerate() {
                            put_row!(r, *rowid);
                            visit!(i);
                        }
                    } else {
                        for rowid in access::rowids(t, &step.access, buf, self.env)? {
                            let Some(r) = t.rows.get(&rowid) else { continue };
                            put_row!(r, rowid);
                            visit!(0);
                        }
                    }
                }
                Mat::Rows(rows) => {
                    for (i, r) in rows.iter().enumerate() {
                        buf[off..off + r.len()].clone_from_slice(r);
                        visit!(i);
                    }
                }
            }
        }
        if !any && matches!(step.kind, JoinKind::Left | JoinKind::Full) {
            for v in &mut buf[off..off + step.width] {
                *v = Value::Null;
            }
            if all_true(&step.post, buf, self.env)? {
                return self.level(pos + 1, buf, matched, sink);
            }
        }
        Ok(true)
    }

    fn run(&self, sink: &mut Sink) -> Result<(), String> {
        let mut matched: Vec<Vec<bool>> = self
            .steps
            .iter()
            .zip(&self.mats)
            .map(|(s, m)| if matches!(s.kind, JoinKind::Right | JoinKind::Full) { vec![false; m.len()] } else { Vec::new() })
            .collect();
        let total: usize = self.steps.iter().map(|s| s.width).sum();
        let mut buf = vec![Value::Null; total];
        if !self.level(0, &mut buf, &mut matched, sink)? {
            return Ok(());
        }
        // unmatched rows of RIGHT/FULL joins, NULL-extended on the left
        // (these queries keep the FROM order)
        for k in 0..self.steps.len() {
            if matches!(self.steps[k].kind, JoinKind::Right | JoinKind::Full) {
                let off = self.steps[k].offset;
                let unmatched: Vec<Vec<Value>> = match &self.mats[k] {
                    Mat::Table(t) => t
                        .rows
                        .iter()
                        .enumerate()
                        .filter(|(i, _)| !matched[k][*i])
                        .map(|(_, (rowid, r))| {
                            let mut v = r.clone();
                            v.push(Value::Integer(*rowid));
                            v
                        })
                        .collect(),
                    Mat::Rows(rows) => {
                        rows.iter().enumerate().filter(|(i, _)| !matched[k][*i]).map(|(_, r)| r.clone()).collect()
                    }
                };
                for r in unmatched {
                    for v in &mut buf[..off] {
                        *v = Value::Null;
                    }
                    buf[off..off + r.len()].clone_from_slice(&r);
                    if !self.level(k + 1, &mut buf, &mut matched, sink)? {
                        return Ok(());
                    }
                }
            }
        }
        Ok(())
    }
}

/// Runs a SELECT core; `stop` is the number of rows after which the caller
/// needs no more (only honored when rows come out in final order).
fn run_select(p: &SelectPlan, env: &Env, stop: Option<usize>) -> Result<Rows, String> {
    let mut mats = Vec::with_capacity(p.steps.len());
    for s in &p.steps {
        mats.push(match &s.src {
            SrcPlan::Table(k) => Mat::Table(env.db.tables.get(k).ok_or_else(|| format!("no such table: {}", k))?),
            SrcPlan::Query(q, cache) => {
                let run = || -> Result<Rows, String> {
                    let rows = run_query(q, env, None)?;
                    Ok(rows
                        .into_iter()
                        .map(|mut r| {
                            r.push(Value::Null);
                            r
                        })
                        .collect())
                };
                match cache {
                    Some(c) => {
                        if c.get().is_none() {
                            let _ = c.set(run()?);
                        }
                        Mat::Rows(Cow::Borrowed(c.get().unwrap()))
                    }
                    None => Mat::Rows(Cow::Owned(run()?)),
                }
            }
            SrcPlan::Schema(temp) => Mat::Rows(Cow::Owned(schema_rows(env.db, *temp))),
            SrcPlan::Queue(slot) => Mat::Rows(Cow::Owned(slot.borrow().clone())),
            SrcPlan::Recursive(rp, cache) => {
                let run = || -> Result<Rows, String> {
                    let rows = run_recursive(rp, env)?;
                    Ok(rows
                        .into_iter()
                        .map(|mut r| {
                            r.push(Value::Null);
                            r
                        })
                        .collect())
                };
                match cache {
                    Some(c) => {
                        if c.get().is_none() {
                            let _ = c.set(run()?);
                        }
                        Mat::Rows(Cow::Borrowed(c.get().unwrap()))
                    }
                    None => Mat::Rows(Cow::Owned(run()?)),
                }
            }
        });
    }
    let autos = p.steps.iter().map(|_| RefCell::new(None)).collect();
    let joiner = Joiner { steps: &p.steps, order: &p.loop_order, mats, autos, env };
    let stop = if p.keys.is_empty() && !p.is_agg && p.win.is_none() { stop } else { None };
    let n_win = p.win.as_ref().map_or(0, |w| w.calls.len());

    let mut seen: BTreeSet<Vec<KeyVal>> = BTreeSet::new();
    let mut results: Vec<(Vec<Value>, Vec<Value>)> = Vec::new();
    let cond = if p.is_agg { p.having.as_ref() } else { p.where_.as_ref() };
    let mut pending: Rows = Vec::new();
    let mut emit = |row: &[Value]| -> Result<bool, String> {
        let out = p.outs.iter().map(|e| eval(e, row, env)).collect::<Result<Vec<_>, _>>()?;
        if p.distinct {
            let k: Vec<KeyVal> = out.iter().zip(&p.distinct_colls).map(|(v, c)| key_val(v, *c)).collect();
            if !seen.insert(k) {
                return Ok(true);
            }
        }
        let mut kv = Vec::with_capacity(p.keys.len());
        for k in &p.keys {
            kv.push(match &k.key {
                SortKey::Result(i) => out[*i].clone(),
                SortKey::Expr(e) => eval(e, row, env)?,
            });
        }
        results.push((out, kv));
        Ok(stop.is_none_or(|s| results.len() < s))
    };
    let mut process = |row: &[Value]| -> Result<bool, String> {
        if let Some(w) = cond {
            if eval(w, row, env)?.truth() != Some(true) {
                return Ok(true);
            }
        }
        if p.win.is_some() {
            let mut r = row.to_vec();
            if !p.is_agg {
                r.resize(p.width + n_win, Value::Null);
            }
            pending.push(r);
            return Ok(true);
        }
        emit(row)
    };
    if p.is_agg {
        let mut groups: BTreeMap<Vec<KeyVal>, Group> = BTreeMap::new();
        let mut first_seen: Vec<Vec<KeyVal>> = Vec::new();
        let mut feed = |row: &[Value]| -> Result<bool, String> {
            if let Some(w) = &p.where_ {
                if eval(w, row, env)?.truth() != Some(true) {
                    return Ok(true);
                }
            }
            let mut k = Vec::with_capacity(p.group_by.len());
            for (g, coll) in &p.group_by {
                k.push(key_val(&eval(g, row, env)?, *coll));
            }
            if p.groups_in_scan_order && !groups.contains_key(&k) {
                first_seen.push(k.clone());
            }
            groups.entry(k).or_insert_with(|| Group::new(p.specs.len())).step(&p.specs, row, env)?;
            Ok(true)
        };
        if p.steps.is_empty() {
            feed(&[])?;
        } else {
            joiner.run(&mut feed)?;
        }
        if p.group_by.is_empty() && groups.is_empty() {
            groups.insert(Vec::new(), Group::new(p.specs.len()));
        }
        let mut groups: Vec<(Vec<KeyVal>, Group)> = if p.groups_in_scan_order {
            first_seen.into_iter().map(|k| (k.clone(), groups.remove(&k).unwrap())).collect()
        } else {
            groups.into_iter().collect()
        };
        if p.group_desc.iter().any(|d| *d) && !p.groups_in_scan_order {
            groups.sort_by(|a, b| {
                for ((x, y), d) in a.0.iter().zip(&b.0).zip(&p.group_desc) {
                    let o = x.cmp(y);
                    if o != std::cmp::Ordering::Equal {
                        return if *d { o.reverse() } else { o };
                    }
                }
                std::cmp::Ordering::Equal
            });
        }
        for (_, mut g) in groups {
            let vals = g.finish(&p.specs)?;
            let mut row = g.rep.take().unwrap_or_else(|| vec![Value::Null; p.width]);
            row.resize(p.width + n_win, Value::Null);
            row.extend(vals);
            if !process(&row)? {
                break;
            }
        }
    } else if p.steps.is_empty() {
        process(&[])?;
    } else {
        joiner.run(&mut process)?;
    }
    if let Some(w) = &p.win {
        crate::window::compute(w, &mut pending, env)?;
        for r in &pending {
            if !emit(r)? {
                break;
            }
        }
    }

    if !p.keys.is_empty() {
        let terms: Vec<(bool, bool, Coll)> = p.keys.iter().map(|k| (k.desc, k.nulls_first, k.coll)).collect();
        results.sort_by(|a, b| agg::cmp_order(&a.1, &b.1, &terms));
    }
    Ok(results.into_iter().map(|(o, _)| o).collect())
}
