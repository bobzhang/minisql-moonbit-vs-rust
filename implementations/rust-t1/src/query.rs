// Query planning (name binding) and execution: joins, aggregation,
// compound queries, VALUES and subqueries in FROM.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

use crate::access::{auto_key, conjuncts, lookup_rowids, plan_access, plan_auto, refs_of, Access, AutoMap};
use crate::agg::{cmp_keys, AggCollector, AggSpec, AggState, SortSpec};
use crate::ast::*;
use crate::db::{is_schema_table, is_sequence_table, key, normalize, IdxKey};
use crate::error::{err, Result};
use crate::eval::{bind, eval, expr_affinity, expr_collation, for_each_child, has_explicit_coll, Cx, Scope, Source};
use crate::value::{Affinity, Collation, Value};

pub type Row = Vec<Value>;

/// Metadata of one result column.
#[derive(Clone, Debug)]
pub struct ColMeta {
    pub name: String,
    pub aff: Option<Affinity>,
    pub coll: Option<Collation>,
    pub explicit_coll: bool,
}

/// Cached result of an uncorrelated subquery.
#[derive(Debug)]
pub enum SubResult {
    Value(Value),
    Bool(bool),
    /// IN: normalized keys of the non-NULL values.
    Set { keys: BTreeSet<IdxKey>, has_null: bool, empty: bool },
}

#[derive(Debug)]
pub struct QueryPlan {
    pub body: Body,
    pub cols: Vec<ColMeta>,
    /// ORDER BY sort specification.
    pub sort: Vec<SortSpec>,
    /// For compounds: the output column of each sort key.
    pub compound_keys: Vec<usize>,
    pub limit: Option<Expr>,
    pub offset: Option<Expr>,
}

#[derive(Debug)]
pub enum Body {
    Core(Box<CorePlan>),
    Values(Vec<Vec<Expr>>),
    Compound { op: CompoundOp, left: Box<Body>, right: Box<Body>, colls: Vec<Collation> },
}

#[derive(Debug)]
pub enum SourcePlan {
    /// Table key in the catalog.
    Table(String),
    /// The sqlite_schema table.
    Schema,
    /// The sqlite_sequence table.
    Sequence,
    /// Subquery in FROM (evaluated with an empty row for the enclosing level).
    Query(Rc<QueryPlan>),
    /// Recursive CTE.
    Recursive(Rc<RecPlan>),
    /// The working row of a recursive CTE, inside its recursive part.
    Working(Rc<RefCell<Vec<Row>>>),
}

/// A recursive CTE: anchor rows seed a queue; each row taken from the
/// queue is output and fed (as the working table) to the recursive arms.
#[derive(Debug)]
pub struct RecPlan {
    pub anchor: Body,
    pub arms: Vec<Body>,
    pub union_all: bool,
    pub working: Rc<RefCell<Vec<Row>>>,
    pub colls: Vec<Collation>,
    /// ORDER BY: the queue is a priority queue on these output columns.
    pub sort: Vec<SortSpec>,
    pub keys: Vec<usize>,
    pub limit: Option<Expr>,
    pub offset: Option<Expr>,
}

/// Common table expressions of one WITH clause, chained to the enclosing
/// ones.
#[derive(Debug)]
pub struct CteEnv {
    pub defs: Vec<CteDef>,
    pub parent: Option<Rc<CteEnv>>,
}

#[derive(Debug)]
pub struct CteDef {
    pub name: String,
    pub cols: Option<Vec<String>>,
    pub select: Select,
    pub state: RefCell<CteState>,
}

#[derive(Debug, Clone, Default)]
pub enum CteState {
    #[default]
    Idle,
    /// The body is being planned: a reference is circular.
    Planning,
    /// The recursive arms are being planned: references read the working
    /// table.
    Recursive { working: Rc<RefCell<Vec<Row>>>, cols: Vec<(String, Affinity, Collation)> },
}

/// Build the CTE environment of a WITH clause.
pub fn with_env(with: &Option<Box<With>>, parent: Option<Rc<CteEnv>>) -> Result<Option<Rc<CteEnv>>> {
    let Some(w) = with else { return Ok(parent) };
    let mut defs: Vec<CteDef> = Vec::new();
    for c in &w.ctes {
        if defs.iter().any(|d| d.name.eq_ignore_ascii_case(&c.name)) {
            return err!("duplicate WITH table name: {}", c.name);
        }
        defs.push(CteDef {
            name: c.name.clone(),
            cols: c.cols.clone(),
            select: (*c.select).clone(),
            state: RefCell::new(CteState::Idle),
        });
    }
    Ok(Some(Rc::new(CteEnv { defs, parent })))
}

fn lookup_cte(env: &Option<Rc<CteEnv>>, name: &str) -> Option<(Rc<CteEnv>, usize)> {
    let mut e = env.clone();
    while let Some(x) = e {
        if let Some(i) = x.defs.iter().position(|d| d.name.eq_ignore_ascii_case(name)) {
            return Some((x, i));
        }
        e = x.parent.clone();
    }
    None
}

/// References to table `name` in a query: (in its own FROM clauses, in
/// nested subqueries).
fn select_refs(sel: &Select, name: &str) -> (usize, usize) {
    let mut d = 0;
    let mut n = 0;
    if let Some(w) = &sel.with {
        for c in &w.ctes {
            let (a, b) = select_refs(&c.select, name);
            n += a + b;
        }
    }
    for core in std::iter::once(&sel.first).chain(sel.rest.iter().map(|(_, c)| c)) {
        let (a, b) = core_refs(core, name);
        d += a;
        n += b;
    }
    for t in &sel.order_by {
        n += expr_refs(&t.expr, name);
    }
    (d, n)
}

fn core_refs(core: &Core, name: &str) -> (usize, usize) {
    let mut d = 0;
    let mut n = 0;
    match core {
        Core::Values(rows) => {
            for r in rows {
                for e in r {
                    n += expr_refs(e, name);
                }
            }
        }
        Core::Select(s) => {
            for t in &s.from {
                match &t.source {
                    TableSource::Table { name: tn, .. } => {
                        if tn.eq_ignore_ascii_case(name) {
                            d += 1;
                        }
                    }
                    TableSource::Subquery { query, .. } => {
                        let (a, b) = select_refs(query, name);
                        n += a + b;
                    }
                }
                if let Some(on) = &t.on {
                    n += expr_refs(on, name);
                }
            }
            for rc in &s.columns {
                if let ResultCol::Expr { expr, .. } = rc {
                    n += expr_refs(expr, name);
                }
            }
            for e in s.where_.iter().chain(&s.group_by).chain(s.having.iter()) {
                n += expr_refs(e, name);
            }
        }
    }
    (d, n)
}

fn expr_refs(e: &Expr, name: &str) -> usize {
    match e {
        Expr::Subquery(q) | Expr::Exists(q) => {
            let (a, b) = select_refs(q, name);
            a + b
        }
        Expr::InSelect { e, query, .. } => {
            let (a, b) = select_refs(query, name);
            expr_refs(e, name) + a + b
        }
        Expr::Window { func, .. } => expr_refs(func, name),
        _ => {
            let mut n = 0;
            for_each_child(e, &mut |c| n += expr_refs(c, name));
            n
        }
    }
}

/// In a recursive arm, put the recursive table first in the join order
/// (it holds a single row) when that is equivalent: inner joins only.
fn recursive_first(core: &mut Core, name: &str) {
    let Core::Select(s) = core else { return };
    let Some(pos) = s.from.iter().position(|t| matches!(&t.source, TableSource::Table { name: n, .. } if n.eq_ignore_ascii_case(name)))
    else {
        return;
    };
    if pos == 0
        || s.from.iter().enumerate().any(|(i, t)| i > 0 && (t.join != JoinKind::Inner || t.natural || t.using.is_some()))
        || s.columns.iter().any(|c| matches!(c, ResultCol::Star))
    {
        return;
    }
    let mut conds: Vec<Expr> = Vec::new();
    for t in s.from.iter_mut() {
        if let Some(on) = t.on.take() {
            conds.push(on);
        }
    }
    if let Some(w) = s.where_.take() {
        conds.push(w);
    }
    let t = s.from.remove(pos);
    s.from.insert(0, t);
    s.where_ = conds.into_iter().reduce(|a, b| Expr::Binary(BinOp::And, Box::new(a), Box::new(b)));
}

/// Plan a reference to CTE `env.defs[i]` from a FROM clause planned in
/// `barrier`'s level.
fn plan_cte_ref(
    env: &Rc<CteEnv>,
    i: usize,
    barrier: &Scope,
) -> Result<(SourcePlan, Vec<(String, Affinity, Collation)>)> {
    let def = &env.defs[i];
    let state = def.state.borrow().clone();
    match state {
        CteState::Planning => return err!("circular reference: {}", def.name),
        CteState::Recursive { working, cols } => return Ok((SourcePlan::Working(working), cols)),
        CteState::Idle => {}
    }
    let db = barrier.db.expect("database");
    let child = Scope { db: Some(db), parent: Some(barrier), ctes: Some(env.clone()), ..Default::default() };
    *def.state.borrow_mut() = CteState::Planning;
    let res = plan_cte_body(def, &child);
    *def.state.borrow_mut() = CteState::Idle;
    res
}

fn rename_cols(cols: &mut [ColMeta], names: &Option<Vec<String>>, cte: &str) -> Result<()> {
    if let Some(names) = names {
        if names.len() != cols.len() {
            return err!("table {} has {} values for {} columns", cte, cols.len(), names.len());
        }
        for (c, n) in cols.iter_mut().zip(names) {
            c.name = n.clone();
        }
    }
    Ok(())
}

fn plan_cte_body(def: &CteDef, child: &Scope) -> Result<(SourcePlan, Vec<(String, Affinity, Collation)>)> {
    let sel = &def.select;
    let arms: Vec<&Core> = std::iter::once(&sel.first).chain(sel.rest.iter().map(|(_, c)| c)).collect();
    let refs: Vec<(usize, usize)> = arms.iter().map(|c| core_refs(c, &def.name)).collect();
    let k = refs.iter().position(|(a, b)| a + b > 0);
    let recursive = match k {
        Some(k) if k > 0 => {
            refs[k..].iter().all(|(a, b)| a + b > 0)
                && sel.rest[k - 1..].iter().all(|(op, _)| matches!(op, CompoundOp::Union | CompoundOp::UnionAll))
        }
        _ => false,
    };
    if !recursive {
        let mut plan = plan_select(sel, child)?;
        rename_cols(&mut plan.cols, &def.cols, &def.name)?;
        let cols = derived_cols(&plan);
        return Ok((SourcePlan::Query(Rc::new(plan)), cols));
    }
    let k = k.unwrap();
    for (a, b) in &refs[k..] {
        if a + b > 1 {
            return if *a > 1 {
                err!("multiple references to recursive table: {}", def.name)
            } else {
                err!("multiple recursive references: {}", def.name)
            };
        }
        if *a == 0 {
            return err!("recursive reference in a subquery: {}", def.name);
        }
    }
    let anchor_sel = Select {
        with: sel.with.clone(),
        first: sel.first.clone(),
        rest: sel.rest[..k - 1].to_vec(),
        order_by: vec![],
        limit: None,
        offset: None,
    };
    let mut aplan = plan_select(&anchor_sel, child)?;
    rename_cols(&mut aplan.cols, &def.cols, &def.name)?;
    let cols = derived_cols(&aplan);
    let working: Rc<RefCell<Vec<Row>>> = Rc::new(RefCell::new(Vec::new()));
    *def.state.borrow_mut() = CteState::Recursive { working: working.clone(), cols: cols.clone() };
    let mut body_sel = sel.clone();
    for (_, core) in body_sel.rest[k - 1..].iter_mut() {
        recursive_first(core, &def.name);
    }
    let plan = plan_select(&body_sel, child)?;
    let union_all = sel.rest[k - 1].0 == CompoundOp::UnionAll;
    let colls: Vec<Collation> = plan.cols.iter().map(|c| c.coll.unwrap_or(Collation::Binary)).collect();
    let QueryPlan { body, sort, compound_keys, limit, offset, .. } = plan;
    let nrec = arms.len() - k;
    let mut rec: Vec<Body> = Vec::new();
    let mut b = body;
    while rec.len() < nrec {
        match b {
            Body::Compound { left, right, .. } => {
                rec.push(*right);
                b = *left;
            }
            _ => return err!("internal error: recursive CTE"),
        }
    }
    rec.reverse();
    for r in &rec {
        if let Body::Core(c) = r {
            if c.is_agg {
                return err!("recursive aggregate queries not supported");
            }
        }
    }
    let rp = RecPlan { anchor: b, arms: rec, union_all, working, colls, sort, keys: compound_keys, limit, offset };
    Ok((SourcePlan::Recursive(Rc::new(rp)), cols))
}

#[derive(Debug)]
pub struct JoinPlan {
    pub source: SourcePlan,
    pub offset: usize,
    pub width: usize,
    pub kind: JoinKind,
    pub on: Option<Expr>,
    pub access: Access,
    /// Times this FROM item has been scanned (repeated scans come from
    /// correlated subqueries).
    pub runs: std::cell::Cell<u32>,
    /// Automatic index over a table: (table version, key -> rowids).
    pub auto_cache: RefCell<Option<(u64, BTreeMap<IdxKey, Vec<i64>>)>>,
}

/// ORDER BY key: a result column or an expression.
#[derive(Debug)]
pub enum Key {
    Out(usize),
    Expr(Expr),
}

#[derive(Debug)]
pub struct CorePlan {
    pub from: Vec<JoinPlan>,
    /// Width of a source row (all FROM items).
    pub width: usize,
    pub where_: Option<Expr>,
    /// WHERE conjuncts, by the FROM level after which they are tested.
    pub filters: Vec<Vec<Expr>>,
    pub outputs: Vec<Expr>,
    pub group_by: Vec<Expr>,
    pub having: Option<Expr>,
    pub aggs: Vec<AggSpec>,
    pub is_agg: bool,
    pub distinct: bool,
    pub keys: Vec<Key>,
    /// Window functions, computed on the rows before projection; results
    /// at `win_base + slot`.
    pub windows: Vec<crate::window::WinGroup>,
    pub win_base: usize,
    pub win_slots: usize,
}

// ---------------------------------------------------------------- planning

/// Plan a query. `scope` provides the database, the enclosing level and the
/// correlation flag of the new level; its sources are ignored.
pub fn plan_select(sel: &Select, scope: &Scope) -> Result<QueryPlan> {
    let owned;
    let scope = if sel.with.is_some() {
        owned = Scope { ctes: with_env(&sel.with, scope.ctes.clone())?, ..scope.clone() };
        &owned
    } else {
        scope
    };
    // A lone SELECT core resolves ORDER BY in its own scope; compounds and
    // VALUES only by result column.
    let single = sel.rest.is_empty() && matches!(sel.first, Core::Select(_));
    let order: &[OrderTerm] = if single { &sel.order_by } else { &[] };
    let (mut body, mut cols, mut colls, sort) = plan_core(&sel.first, scope, order)?;
    let mut types: Vec<u8> = vec![0; cols.len()];
    let add_types = |body: &Body, types: &mut Vec<u8>| {
        let rows: Vec<&Vec<Expr>> = match body {
            Body::Core(c) => vec![&c.outputs],
            Body::Values(rows) => rows.iter().collect(),
            Body::Compound { .. } => vec![],
        };
        for r in rows {
            for (t, e) in types.iter_mut().zip(r) {
                *t |= data_type(e);
            }
        }
    };
    add_types(&body, &mut types);
    let mut names: Vec<Vec<(Option<String>, Option<String>)>> = vec![core_names(&sel.first)];
    for (op, core) in &sel.rest {
        let (rb, rcols, rcolls, _) = plan_core(core, scope, &[])?;
        if rcols.len() != cols.len() {
            return err!("SELECTs to the left and right of {} do not have the same number of result columns", op.name());
        }
        add_types(&rb, &mut types);
        let merged: Vec<Option<Collation>> = colls.iter().zip(&rcolls).map(|(l, r)| l.or(*r)).collect();
        for (c, m) in cols.iter_mut().zip(&merged) {
            c.coll = *m;
        }
        body = Body::Compound {
            op: *op,
            left: Box::new(body),
            right: Box::new(rb),
            colls: merged.iter().map(|c| c.unwrap_or(Collation::Binary)).collect(),
        };
        colls = merged;
        names.push(core_names(core));
    }
    // A compound column keeps the leftmost affinity only if no member can
    // produce a conflicting type.
    if !sel.rest.is_empty() || matches!(sel.first, Core::Values(_)) {
        for (c, t) in cols.iter_mut().zip(&types) {
            match c.aff {
                Some(Affinity::Text) if t & 1 != 0 => c.aff = Some(Affinity::Blob),
                Some(a) if a.is_numeric() && t & 2 != 0 => c.aff = Some(Affinity::Blob),
                _ => {}
            }
        }
    }
    let mut sort_spec = sort;
    let mut compound_keys = Vec::new();
    if !single {
        for (n, term) in sel.order_by.iter().enumerate() {
            let (peeled, coll_override) = peel_order_term(&term.expr)?;
            let idx = match ordinal_of(peeled) {
                Some(i) => {
                    if i < 1 || i as u64 > cols.len() as u64 {
                        return err!(
                            "{} ORDER BY term out of range - should be between 1 and {}",
                            ordinal(n + 1),
                            cols.len()
                        );
                    }
                    Some(i as usize - 1)
                }
                None => match peeled {
                    Expr::Column { table, name, .. } => {
                        let by_alias = if table.is_none() {
                            names.iter().find_map(|core| {
                                core.iter().position(|(a, _)| matches!(a, Some(a) if a.eq_ignore_ascii_case(name)))
                            })
                        } else {
                            None
                        };
                        by_alias.or_else(|| {
                            names.iter().find_map(|core| {
                                core.iter().position(|(_, c)| matches!(c, Some(c) if c.eq_ignore_ascii_case(name)))
                            })
                        })
                    }
                    _ => None,
                },
            };
            let Some(idx) = idx else {
                return err!("{} ORDER BY term does not match any column in the result set", ordinal(n + 1));
            };
            let coll = coll_override.or(colls[idx]).unwrap_or(Collation::Binary);
            sort_spec.push((term.desc, term.nulls_first, coll));
            compound_keys.push(idx);
        }
    }
    let lim_scope = Scope {
        db: scope.db,
        parent: scope.parent,
        correlated: scope.correlated.clone(),
        ctes: scope.ctes.clone(),
        ..Default::default()
    };
    let limit = sel.limit.as_ref().map(|e| bind(e, &lim_scope)).transpose()?;
    let offset = sel.offset.as_ref().map(|e| bind(e, &lim_scope)).transpose()?;
    Ok(QueryPlan { body, cols, sort: sort_spec, compound_keys, limit, offset })
}

/// Possible storage classes of an expression's values (sqlite3ExprDataType):
/// 1 = numeric, 2 = text, 4 = blob.
fn data_type(e: &Expr) -> u8 {
    match e {
        Expr::Collate(x, _) | Expr::Unary(UnOp::Pos, x) => data_type(x),
        Expr::Lit(Value::Null) => 0,
        Expr::Lit(Value::Text(_)) => 2,
        Expr::Lit(Value::Blob(_)) => 4,
        Expr::Lit(_) => 1,
        Expr::Binary(BinOp::Concat, ..) => 6,
        Expr::Func { .. } | Expr::AggRef { .. } => 7,
        Expr::Col { .. } | Expr::Cast(..) | Expr::Outer { .. } | Expr::SubPlan { kind: SubKind::Scalar, .. } => {
            match expr_affinity(e) {
                Some(a) if a.is_numeric() => 5,
                Some(Affinity::Text) => 6,
                _ => 7,
            }
        }
        Expr::Case { whens, else_, .. } => {
            let mut m = whens.iter().fold(0, |m, (_, t)| m | data_type(t));
            m |= else_.as_ref().map_or(0, |x| data_type(x));
            m
        }
        _ => 1,
    }
}

/// (alias, column name) of each result column, for compound ORDER BY.
fn core_names(core: &Core) -> Vec<(Option<String>, Option<String>)> {
    match core {
        Core::Values(_) => vec![],
        Core::Select(s) => s
            .columns
            .iter()
            .map(|rc| match rc {
                ResultCol::Expr { expr, alias, .. } => {
                    let col = match expr {
                        Expr::Column { name, .. } => Some(name.clone()),
                        _ => None,
                    };
                    (alias.clone(), col)
                }
                _ => (None, None),
            })
            .collect(),
    }
}

/// Strip COLLATE (the outermost wins) and unary plus from an ORDER BY term.
fn peel_order_term(e: &Expr) -> Result<(&Expr, Option<Collation>)> {
    let mut peeled = e;
    let mut coll_override: Option<Collation> = None;
    loop {
        match peeled {
            Expr::Collate(x, c) => {
                match Collation::from_name(c) {
                    Some(c) => {
                        coll_override.get_or_insert(c);
                    }
                    None => return err!("no such collation sequence: {}", c),
                }
                peeled = x;
            }
            Expr::Unary(UnOp::Pos, x) => peeled = x,
            _ => break,
        }
    }
    Ok((peeled, coll_override))
}

fn ordinal_of(e: &Expr) -> Option<i64> {
    match e {
        Expr::Lit(Value::Int(i)) => Some(*i),
        Expr::Unary(UnOp::Neg, x) => match x.as_ref() {
            Expr::Lit(Value::Int(i)) => Some(i.wrapping_neg()),
            _ => None,
        },
        _ => None,
    }
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

fn col_meta(e: &Expr, name: String) -> ColMeta {
    ColMeta { name, aff: expr_affinity(e), coll: expr_collation(e), explicit_coll: has_explicit_coll(e) }
}

/// Does a bound expression reference an aggregate of its own level?
fn has_local_aggref(e: &Expr) -> bool {
    if matches!(e, Expr::AggRef { .. }) {
        return true;
    }
    let mut found = false;
    for_each_child(e, &mut |c| found |= has_local_aggref(c));
    found
}

type CoreResult = (Body, Vec<ColMeta>, Vec<Option<Collation>>, Vec<SortSpec>);

/// Plan one SELECT core (or VALUES) with the ORDER BY terms that apply to it
/// when it is the whole query.
fn plan_core(core: &Core, base: &Scope, order_by: &[OrderTerm]) -> Result<CoreResult> {
    let db = base.db.expect("database");
    let level = || Scope {
        db: Some(db),
        parent: base.parent,
        correlated: base.correlated.clone(),
        ctes: base.ctes.clone(),
        ..Default::default()
    };
    let sel = match core {
        Core::Values(rows) => {
            let width = rows[0].len();
            if rows.iter().any(|r| r.len() != width) {
                return err!("all VALUES must have the same number of terms");
            }
            let scope = level();
            let bound = rows
                .iter()
                .map(|r| r.iter().map(|e| bind(e, &scope)).collect::<Result<Vec<_>>>())
                .collect::<Result<Vec<_>>>()?;
            let cols: Vec<ColMeta> =
                bound[0].iter().enumerate().map(|(i, e)| col_meta(e, format!("column{}", i + 1))).collect();
            let colls = cols.iter().map(|c| c.coll).collect();
            return Ok((Body::Values(bound), cols, colls, vec![]));
        }
        Core::Select(s) => s,
    };

    // FROM clause.
    let mut sources: Vec<Source> = Vec::new();
    let mut joins: Vec<JoinPlan> = Vec::new();
    let mut offset = 0;
    for (ti, term) in sel.from.iter().enumerate() {
        let (name, cols, has_rowid, source) = match &term.source {
            TableSource::Table { name, alias } => {
                if let Some((env, i)) = lookup_cte(&base.ctes, name) {
                    let barrier = level();
                    let (plan, cols) = plan_cte_ref(&env, i, &barrier)?;
                    (alias.clone().unwrap_or_else(|| env.defs[i].name.clone()), cols, false, plan)
                } else if let Some(t) = db.table(name) {
                    let cols: Vec<(String, Affinity, Collation)> =
                        t.columns.iter().map(|c| (c.name.clone(), c.affinity, c.coll())).collect();
                    (alias.clone().unwrap_or_else(|| t.name.clone()), cols, true, SourcePlan::Table(key(name)))
                } else if let Some(v) = db.view(name) {
                    let depth = VIEW_DEPTH.with(|d| d.get());
                    if depth > 64 {
                        return err!("view {} is circularly defined", v.name);
                    }
                    VIEW_DEPTH.with(|d| d.set(depth + 1));
                    let child = Scope { db: Some(db), ..Default::default() };
                    let res = plan_select(&v.select, &child);
                    VIEW_DEPTH.with(|d| d.set(depth));
                    let mut plan = res?;
                    if let Some(names) = &v.cols {
                        if names.len() != plan.cols.len() {
                            return err!(
                                "expected {} columns for '{}' but got {}",
                                names.len(),
                                v.name,
                                plan.cols.len()
                            );
                        }
                        for (c, n) in plan.cols.iter_mut().zip(names) {
                            c.name = n.clone();
                        }
                    }
                    let cols = derived_cols(&plan);
                    (alias.clone().unwrap_or_else(|| v.name.clone()), cols, false, SourcePlan::Query(Rc::new(plan)))
                } else if is_schema_table(name) {
                    let cols: Vec<(String, Affinity, Collation)> = [
                        ("type", Affinity::Text),
                        ("name", Affinity::Text),
                        ("tbl_name", Affinity::Text),
                        ("rootpage", Affinity::Integer),
                        ("sql", Affinity::Text),
                    ]
                    .iter()
                    .map(|(n, a)| (n.to_string(), *a, Collation::Binary))
                    .collect();
                    (alias.clone().unwrap_or_else(|| name.clone()), cols, false, SourcePlan::Schema)
                } else if is_sequence_table(name) && db.sequence_seq.is_some() {
                    let cols = vec![
                        ("name".to_string(), Affinity::Blob, Collation::Binary),
                        ("seq".to_string(), Affinity::Blob, Collation::Binary),
                    ];
                    (alias.clone().unwrap_or_else(|| name.clone()), cols, false, SourcePlan::Sequence)
                } else {
                    return err!("no such table: {}", name);
                }
            }
            TableSource::Subquery { query, alias } => {
                // A derived table sees the enclosing queries but not its
                // siblings: an empty barrier level stands for this one.
                let barrier = level();
                let child = Scope { db: Some(db), parent: Some(&barrier), ctes: base.ctes.clone(), ..Default::default() };
                let plan = plan_select(query, &child)?;
                let cols = derived_cols(&plan);
                let name = alias.clone().unwrap_or_else(|| format!("(subquery-{})", ti + 1));
                (name, cols, false, SourcePlan::Query(Rc::new(plan)))
            }
        };
        let ncols = cols.len();
        let width = ncols + has_rowid as usize;
        let mut src = Source::new(name, cols, offset, if has_rowid { Some(offset + ncols) } else { None });
        let mut on: Option<Expr> = None;
        if ti > 0 {
            let using: Vec<String> = if term.natural {
                src.columns
                    .iter()
                    .filter(|(c, _, _)| {
                        sources.iter().any(|s| {
                            s.columns.iter().enumerate().any(|(i, (x, _, _))| !s.is_hidden(i) && x.eq_ignore_ascii_case(c))
                        })
                    })
                    .map(|(c, _, _)| c.clone())
                    .collect()
            } else {
                term.using.clone().unwrap_or_default()
            };
            if !using.is_empty() {
                src.hidden = vec![false; ncols];
                src.merged = vec![None; ncols];
            }
            for u in &using {
                let Some(ri) = src.columns.iter().position(|(c, _, _)| c.eq_ignore_ascii_case(u)) else {
                    return err!("cannot join using column {} - column not present in both tables", u);
                };
                let mut left: Option<(usize, usize)> = None;
                for (si, s) in sources.iter().enumerate() {
                    if let Some(li) =
                        s.columns.iter().enumerate().position(|(i, (x, _, _))| !s.is_hidden(i) && x.eq_ignore_ascii_case(u))
                    {
                        left = Some((si, li));
                        break;
                    }
                }
                let Some((si, li)) = left else {
                    return err!("cannot join using column {} - column not present in both tables", u);
                };
                let l = sources[si].col_expr(li);
                let r = src.raw_col(ri);
                let scope = Scope::with_sources(vec![]);
                let cond = bind(&Expr::Binary(BinOp::Eq, Box::new(l.clone()), Box::new(r.clone())), &scope)?;
                on = Some(match on {
                    None => cond,
                    Some(p) => Expr::Binary(BinOp::And, Box::new(p), Box::new(cond)),
                });
                src.hidden[ri] = true;
                if matches!(term.join, JoinKind::Right | JoinKind::Full) {
                    let s = &mut sources[si];
                    if s.merged.is_empty() {
                        s.merged = vec![None; s.columns.len()];
                        s.hidden = vec![false; s.columns.len()];
                    }
                    s.merged[li] = Some(Expr::Func {
                        name: "coalesce".into(),
                        args: vec![l, r],
                        star: false,
                        distinct: false,
                        coll: Collation::Binary,
                        filter: None,
                        order_by: vec![],
                    });
                }
            }
        }
        sources.push(src);
        joins.push(JoinPlan {
            source,
            offset,
            width,
            kind: term.join,
            on,
            access: Access::Full,
            runs: Default::default(),
            auto_cache: Default::default(),
        });
        offset += width;
    }
    // ON clauses see every FROM item.
    {
        let mut scope = level();
        scope.sources = sources.clone();
        for (j, term) in joins.iter_mut().zip(&sel.from) {
            if let Some(e) = &term.on {
                let cond = bind(e, &scope)?;
                j.on = Some(match j.on.take() {
                    None => cond,
                    Some(p) => Expr::Binary(BinOp::And, Box::new(p), Box::new(cond)),
                });
            }
        }
    }
    let width = offset;
    let collector = Rc::new(RefCell::new(AggCollector::new(width)));
    let mut scope = level();
    scope.sources = sources;
    scope.aggs = Some(collector.clone());
    let wins = Rc::new(RefCell::new(crate::window::WinCollector::default()));
    for (_, d) in &sel.windows {
        crate::window::resolve_def(&Over::Spec(d.clone()), &sel.windows, 0)?;
    }
    wins.borrow_mut().defs = sel.windows.clone();
    let mut agg_scope = scope.clone();
    agg_scope.allow_agg = true;
    agg_scope.wins = Some(wins.clone());

    // Result columns.
    let mut outputs: Vec<(Expr, Option<String>)> = Vec::new();
    let mut cols: Vec<ColMeta> = Vec::new();
    for rc in &sel.columns {
        match rc {
            ResultCol::Star => {
                if scope.sources.is_empty() {
                    return err!("no tables specified");
                }
                for s in &scope.sources {
                    for (i, (n, _, _)) in s.columns.iter().enumerate() {
                        if s.is_hidden(i) {
                            continue;
                        }
                        let e = s.col_expr(i);
                        cols.push(col_meta(&e, n.clone()));
                        outputs.push((e, None));
                    }
                }
            }
            ResultCol::TableStar(t) => {
                let s = match scope.sources.iter().find(|s| s.name.eq_ignore_ascii_case(t)) {
                    Some(s) => s,
                    None => return err!("no such table: {}", t),
                };
                for (i, (n, _, _)) in s.columns.iter().enumerate() {
                    let e = s.raw_col(i);
                    cols.push(col_meta(&e, n.clone()));
                    outputs.push((e, None));
                }
            }
            ResultCol::Expr { expr, alias, span } => {
                let e = bind(expr, &agg_scope)?;
                let name = match (alias, expr) {
                    (Some(a), _) => a.clone(),
                    (None, Expr::Column { name, .. }) => name.clone(),
                    (None, _) => span.clone(),
                };
                cols.push(col_meta(&e, name));
                outputs.push((e, alias.clone()));
            }
        }
    }
    // Scope for GROUP BY, HAVING and ORDER BY: result aliases visible.
    let mut alias_scope = agg_scope.clone();
    alias_scope.aliases = outputs.iter().filter_map(|(e, a)| a.as_ref().map(|a| (a.clone(), e.clone()))).collect();
    let where_ = match &sel.where_ {
        Some(w) => {
            let mut ws = alias_scope.clone();
            ws.allow_agg = false;
            ws.wins = None;
            let e = bind(w, &ws)?;
            if crate::window::has_win_ref(&e) {
                return err!("misuse of aliased window function");
            }
            if has_local_aggref(&e) {
                return err!("misuse of aggregate");
            }
            Some(e)
        }
        None => None,
    };

    let mut group_by: Vec<Expr> = Vec::new();
    for (n, g) in sel.group_by.iter().enumerate() {
        let e = match g {
            Expr::Lit(Value::Int(i)) => {
                if *i < 1 || *i as u64 > outputs.len() as u64 {
                    return err!(
                        "{} GROUP BY term out of range - should be between 1 and {}",
                        ordinal(n + 1),
                        outputs.len()
                    );
                }
                outputs[*i as usize - 1].0.clone()
            }
            _ => {
                let mut gs = alias_scope.clone();
                gs.allow_agg = false;
                gs.wins = None;
                bind(g, &gs)?
            }
        };
        if crate::window::has_win_ref(&e) {
            return err!("misuse of window function in GROUP BY");
        }
        if has_local_aggref(&e) {
            return err!("aggregate functions are not allowed in the GROUP BY clause");
        }
        group_by.push(e);
    }
    let having = match &sel.having {
        Some(h) => {
            let mut hs = alias_scope.clone();
            hs.wins = None;
            let e = bind(h, &hs)?;
            if crate::window::has_win_ref(&e) {
                return err!("misuse of aliased window function");
            }
            Some(e)
        }
        None => None,
    };

    let mut keys: Vec<Key> = Vec::new();
    let mut sort: Vec<SortSpec> = Vec::new();
    for (n, term) in order_by.iter().enumerate() {
        let (peeled, coll_override) = peel_order_term(&term.expr)?;
        let alias_idx = match peeled {
            Expr::Column { table: None, name, .. } => {
                outputs.iter().position(|(_, a)| matches!(a, Some(a) if a.eq_ignore_ascii_case(name)))
            }
            _ => None,
        };
        let k = if let Some(i) = ordinal_of(peeled) {
            if i < 1 || i as u64 > outputs.len() as u64 {
                return err!(
                    "{} ORDER BY term out of range - should be between 1 and {}",
                    ordinal(n + 1),
                    outputs.len()
                );
            }
            Key::Out(i as usize - 1)
        } else if let Some(idx) = alias_idx {
            Key::Out(idx)
        } else {
            Key::Expr(bind(&term.expr, &alias_scope)?)
        };
        let coll = match &k {
            Key::Out(i) => coll_override.or_else(|| expr_collation(&outputs[*i].0)),
            Key::Expr(e) => expr_collation(e),
        }
        .unwrap_or(Collation::Binary);
        keys.push(k);
        sort.push((term.desc, term.nulls_first, coll));
    }

    drop(alias_scope);
    drop(agg_scope);
    drop(scope);
    let aggs = std::mem::take(&mut collector.borrow_mut().specs);
    let is_agg = !group_by.is_empty() || !aggs.is_empty();
    if having.is_some() && !is_agg {
        return err!("HAVING clause on a non-aggregate query");
    }
    let wc = std::mem::take(&mut *wins.borrow_mut());
    let win_base = if is_agg { width + aggs.len() } else { width };
    let mut outputs: Vec<Expr> = outputs.into_iter().map(|(e, _)| e).collect();
    if wc.nslots > 0 {
        for e in outputs.iter_mut() {
            crate::window::place_refs(e, win_base);
        }
        for k in keys.iter_mut() {
            if let Key::Expr(e) = k {
                crate::window::place_refs(e, win_base);
            }
        }
    }
    let colls = cols.iter().map(|c| c.coll).collect();
    let filters = plan_access_paths(db, &mut joins, &where_);
    let plan = CorePlan {
        from: joins,
        width,
        where_,
        filters,
        outputs,
        group_by,
        having,
        aggs,
        is_agg,
        distinct: sel.distinct,
        keys,
        windows: wc.groups,
        win_base,
        win_slots: wc.nslots,
    };
    Ok((Body::Core(Box::new(plan)), cols, colls, sort))
}

thread_local! {
    static VIEW_DEPTH: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// Column descriptions of a derived table (subquery or view).
fn derived_cols(plan: &QueryPlan) -> Vec<(String, Affinity, Collation)> {
    let mut cols: Vec<(String, Affinity, Collation)> = Vec::new();
    for c in &plan.cols {
        let mut n = c.name.clone();
        let mut k = 0;
        while cols.iter().any(|(x, _, _)| x.eq_ignore_ascii_case(&n)) {
            k += 1;
            n = format!("{}:{}", c.name, k);
        }
        cols.push((n, c.aff.unwrap_or(Affinity::Blob), c.coll.unwrap_or(Collation::Binary)));
    }
    cols
}

/// Choose an access path for each FROM item and assign each WHERE conjunct
/// to the earliest level at which it can be tested.
fn plan_access_paths(db: &crate::db::Database, joins: &mut [JoinPlan], where_: &Option<Expr>) -> Vec<Vec<Expr>> {
    let n = joins.len();
    let mut filters: Vec<Vec<Expr>> = vec![Vec::new(); n.max(1)];
    let mut wc: Vec<&Expr> = Vec::new();
    if let Some(w) = where_ {
        conjuncts(w, &mut wc);
    }
    if n == 0 {
        return filters;
    }
    let outer = |j: &JoinPlan| matches!(j.kind, JoinKind::Right | JoinKind::Full);
    let last_outer = joins.iter().enumerate().skip(1).filter(|(_, j)| outer(j)).map(|(i, _)| i).last();
    for c in &wc {
        let r = refs_of(c);
        let lvl = if r.poison {
            n - 1
        } else {
            match r.max {
                None => 0,
                Some(m) => joins.iter().position(|j| m < j.offset + j.width).unwrap_or(n - 1),
            }
        };
        filters[lvl.max(last_outer.unwrap_or(0))].push((*c).clone());
    }
    for (ji, j) in joins.iter_mut().enumerate() {
        if ji > 0 && outer(j) {
            continue;
        }
        let mut conjs: Vec<&Expr> = Vec::new();
        if let Some(on) = &j.on {
            conjuncts(on, &mut conjs);
        }
        if last_outer.is_none() && (ji == 0 || j.kind == JoinKind::Inner) {
            conjs.extend(wc.iter().copied());
        }
        if conjs.is_empty() {
            continue;
        }
        j.access = match &j.source {
            SourcePlan::Table(k) => match db.tables.get(k) {
                Some(t) => plan_access(t, j.offset, &conjs, true),
                None => Access::Full,
            },
            _ if ji > 0 => plan_auto(j.offset, j.width, &conjs),
            _ => Access::Full,
        };
    }
    filters
}

// ---------------------------------------------------------------- execution

/// Evaluate a LIMIT/OFFSET expression, which must be an integer.
fn limit_value(e: &Expr, cx: &Cx) -> Result<i64> {
    match eval(e, &[], cx)?.apply_affinity(Affinity::Integer) {
        Value::Int(i) => Ok(i),
        _ => err!("datatype mismatch"),
    }
}

/// Run a query. `want` is a hint that only that many rows are needed.
pub fn exec_query(plan: &QueryPlan, cx: &Cx, want: Option<usize>) -> Result<Vec<Row>> {
    let limit = match &plan.limit {
        Some(e) => Some(limit_value(e, cx)?),
        None => None,
    };
    let offset = match &plan.offset {
        Some(e) => limit_value(e, cx)?.max(0) as usize,
        None => 0,
    };
    let _ = want;
    let rows: Vec<Row> = match &plan.body {
        Body::Core(core) if plan.compound_keys.is_empty() => {
            let mut rk = exec_core(core, cx)?;
            if !plan.sort.is_empty() {
                rk.sort_by(|a, b| cmp_keys(&a.1, &b.1, &plan.sort));
            }
            rk.into_iter().map(|(r, _)| r).collect()
        }
        body => {
            let mut rows = exec_body(body, cx)?;
            if !plan.sort.is_empty() {
                let keys = &plan.compound_keys;
                let mut rk: Vec<(Row, Vec<Value>)> = rows
                    .into_iter()
                    .map(|r| {
                        let k = keys.iter().map(|&i| r[i].clone()).collect();
                        (r, k)
                    })
                    .collect();
                rk.sort_by(|a, b| cmp_keys(&a.1, &b.1, &plan.sort));
                rows = rk.into_iter().map(|(r, _)| r).collect();
            }
            rows
        }
    };
    Ok(match limit {
        Some(l) if l >= 0 => rows.into_iter().skip(offset).take(l as usize).collect(),
        _ => rows.into_iter().skip(offset).collect(),
    })
}

fn row_key(r: &[Value], colls: &[Collation]) -> IdxKey {
    IdxKey(r.iter().zip(colls).map(|(v, c)| normalize(v, *c)).collect())
}

fn exec_body(body: &Body, cx: &Cx) -> Result<Vec<Row>> {
    match body {
        Body::Core(core) => Ok(exec_core(core, cx)?.into_iter().map(|(r, _)| r).collect()),
        Body::Values(rows) => {
            rows.iter().map(|r| r.iter().map(|e| eval(e, &[], cx)).collect::<Result<Row>>()).collect()
        }
        Body::Compound { op, left, right, colls } => {
            let l = exec_body(left, cx)?;
            let r = exec_body(right, cx)?;
            if *op == CompoundOp::UnionAll {
                let mut l = l;
                l.extend(r);
                return Ok(l);
            }
            // Set operations keep the last of equal rows, in key order.
            let mut map: BTreeMap<IdxKey, Row> = BTreeMap::new();
            for row in l {
                map.insert(row_key(&row, colls), row);
            }
            match op {
                CompoundOp::Union => {
                    for row in r {
                        map.insert(row_key(&row, colls), row);
                    }
                }
                CompoundOp::Intersect => {
                    let rs: BTreeSet<IdxKey> = r.iter().map(|row| row_key(row, colls)).collect();
                    map.retain(|k, _| rs.contains(k));
                }
                CompoundOp::Except => {
                    for row in &r {
                        map.remove(&row_key(row, colls));
                    }
                }
                CompoundOp::UnionAll => unreachable!(),
            }
            Ok(map.into_values().collect())
        }
    }
}

/// Rows of a FROM item: a table read in place or materialized rows.
enum Right<'a> {
    Table(&'a crate::db::Table),
    Rows(Vec<Row>),
}

impl Right<'_> {
    fn len(&self) -> usize {
        match self {
            Right::Table(t) => t.rows.len(),
            Right::Rows(r) => r.len(),
        }
    }

    /// Call `f(index, row slot)` for each row after writing it into
    /// `buf[offset..]`.
    fn for_each(&self, buf: &mut [Value], offset: usize, f: &mut dyn FnMut(usize, &mut [Value]) -> Result<()>) -> Result<()> {
        match self {
            Right::Table(t) => {
                let n = t.columns.len();
                for (i, (rowid, vals)) in t.rows.iter().enumerate() {
                    buf[offset..offset + n].clone_from_slice(vals);
                    buf[offset + n] = Value::Int(*rowid);
                    f(i, buf)?;
                }
            }
            Right::Rows(rows) => {
                for (i, r) in rows.iter().enumerate() {
                    buf[offset..offset + r.len()].clone_from_slice(r);
                    f(i, buf)?;
                }
            }
        }
        Ok(())
    }
}

/// Materialized positional rows for an automatic index: (rowid, values).
struct AutoRows<'a> {
    rows: Vec<(Option<i64>, &'a [Value])>,
    map: AutoMap,
}

fn right_rows<'a>(j: &JoinPlan, cx: &Cx<'a>) -> Result<Right<'a>> {
    match &j.source {
        SourcePlan::Table(k) => match cx.db.tables.get(k) {
            Some(t) => Ok(Right::Table(t)),
            None => err!("no such table: {}", k),
        },
        SourcePlan::Schema => Ok(Right::Rows(cx.db.schema_rows())),
        SourcePlan::Sequence => Ok(Right::Rows(cx.db.sequence_rows())),
        SourcePlan::Query(p) => {
            let sub = Cx { db: cx.db, outer: Some((&[], cx)) };
            Ok(Right::Rows(exec_query(p, &sub, None)?))
        }
        SourcePlan::Recursive(p) => {
            let sub = Cx { db: cx.db, outer: Some((&[], cx)) };
            Ok(Right::Rows(exec_recursive(p, &sub)?))
        }
        SourcePlan::Working(w) => Ok(Right::Rows(w.borrow().clone())),
    }
}

/// Queue of a recursive CTE: FIFO, or ordered by the CTE's ORDER BY with
/// FIFO among equal keys.
struct RecQueue<'a> {
    fifo: std::collections::VecDeque<Row>,
    heap: Vec<(Vec<Value>, u64, Row)>,
    seq: u64,
    rp: &'a RecPlan,
}

impl RecQueue<'_> {
    fn less(&self, a: usize, b: usize) -> bool {
        let (x, y) = (&self.heap[a], &self.heap[b]);
        match cmp_keys(&x.0, &y.0, &self.rp.sort) {
            std::cmp::Ordering::Equal => x.1 < y.1,
            o => o == std::cmp::Ordering::Less,
        }
    }

    fn push(&mut self, r: Row) {
        if self.rp.sort.is_empty() {
            self.fifo.push_back(r);
            return;
        }
        let k: Vec<Value> = self.rp.keys.iter().map(|&i| r[i].clone()).collect();
        self.seq += 1;
        self.heap.push((k, self.seq, r));
        let mut i = self.heap.len() - 1;
        while i > 0 {
            let p = (i - 1) / 2;
            if self.less(i, p) {
                self.heap.swap(i, p);
                i = p;
            } else {
                break;
            }
        }
    }

    fn pop(&mut self) -> Option<Row> {
        if self.rp.sort.is_empty() {
            return self.fifo.pop_front();
        }
        if self.heap.is_empty() {
            return None;
        }
        let n = self.heap.len();
        self.heap.swap(0, n - 1);
        let top = self.heap.pop().unwrap();
        let n = self.heap.len();
        let mut i = 0;
        loop {
            let (l, r) = (2 * i + 1, 2 * i + 2);
            let mut m = i;
            if l < n && self.less(l, m) {
                m = l;
            }
            if r < n && self.less(r, m) {
                m = r;
            }
            if m == i {
                break;
            }
            self.heap.swap(i, m);
            i = m;
        }
        Some(top.2)
    }
}

fn exec_recursive(rp: &RecPlan, cx: &Cx) -> Result<Vec<Row>> {
    let limit = match &rp.limit {
        Some(e) => Some(limit_value(e, cx)?),
        None => None,
    };
    let mut offset = match &rp.offset {
        Some(e) => limit_value(e, cx)?.max(0),
        None => 0,
    };
    let mut out: Vec<Row> = Vec::new();
    if limit == Some(0) {
        return Ok(out);
    }
    let mut seen: BTreeSet<IdxKey> = BTreeSet::new();
    let mut q = RecQueue { fifo: Default::default(), heap: vec![], seq: 0, rp };
    let mut add = |q: &mut RecQueue, r: Row| {
        if rp.union_all || seen.insert(row_key(&r, &rp.colls)) {
            q.push(r);
        }
    };
    for r in exec_body(&rp.anchor, cx)? {
        add(&mut q, r);
    }
    while let Some(row) = q.pop() {
        if offset > 0 {
            offset -= 1;
        } else {
            out.push(row.clone());
            if limit.is_some_and(|l| l >= 0 && out.len() as i64 >= l) {
                break;
            }
        }
        *rp.working.borrow_mut() = vec![row];
        for arm in &rp.arms {
            let rows = exec_body(arm, cx);
            let rows = match rows {
                Ok(r) => r,
                Err(e) => {
                    rp.working.borrow_mut().clear();
                    return Err(e);
                }
            };
            for r in rows {
                add(&mut q, r);
            }
        }
    }
    rp.working.borrow_mut().clear();
    Ok(out)
}

fn pass_all(filters: &[Expr], r: &[Value], cx: &Cx) -> Result<bool> {
    for f in filters {
        if eval(f, r, cx)?.truthy() != Some(true) {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Feed the rows produced by the FROM clause and WHERE filter to `sink`.
fn scan(core: &CorePlan, cx: &Cx, sink: &mut dyn FnMut(&[Value]) -> Result<()>) -> Result<()> {
    let width = core.width;
    if core.from.is_empty() {
        let ok = match &core.where_ {
            Some(w) => eval(w, &[], cx)?.truthy() == Some(true),
            None => true,
        };
        if ok {
            sink(&[])?;
        }
        return Ok(());
    }
    let nlev = core.from.len();
    let mut rows: Vec<Row> = vec![vec![Value::Null; width]];
    for (ji, j) in core.from.iter().enumerate() {
        let filters = &core.filters[ji];
        let right = right_rows(j, cx)?;
        let mut out: Vec<Row> = Vec::new();
        let is_last = ji + 1 == nlev;
        let mut emit = |r: &[Value]| -> Result<()> {
            if is_last {
                sink(r)
            } else {
                out.push(r.to_vec());
                Ok(())
            }
        };
        let mut right_matched = vec![false; if matches!(j.kind, JoinKind::Right | JoinKind::Full) { right.len() } else { 0 }];
        let keep_left = matches!(j.kind, JoinKind::Left | JoinKind::Full);
        let mut buf: Row = vec![Value::Null; width];
        let mut auto: Option<AutoRows> = None;
        let runs = j.runs.get();
        j.runs.set(runs.saturating_add(1));
        // Tables: a cached key -> rowids map, reused while the table is
        // unchanged.
        let table_auto = match (&j.access, &right) {
            (Access::Auto { col, key }, Right::Table(t)) if rows.len() > 1 || runs > 0 => {
                let fresh = matches!(&*j.auto_cache.borrow(), Some((v, _)) if *v == t.version);
                if !fresh {
                    let mut map: BTreeMap<IdxKey, Vec<i64>> = BTreeMap::new();
                    let n = t.columns.len();
                    for (rowid, vals) in &t.rows {
                        let v = if *col < n { vals[*col].clone() } else { Value::Int(*rowid) };
                        if let Some(k) = auto_key(&v, key) {
                            map.entry(k).or_default().push(*rowid);
                        }
                    }
                    *j.auto_cache.borrow_mut() = Some((t.version, map));
                }
                true
            }
            _ => false,
        };
        let use_auto = !table_auto && matches!(j.access, Access::Auto { .. }) && rows.len() > 1;
        if use_auto {
            let Access::Auto { col, key } = &j.access else { unreachable!() };
            let list: Vec<(Option<i64>, &[Value])> = match &right {
                Right::Table(t) => t.rows.iter().map(|(r, v)| (Some(*r), v.as_slice())).collect(),
                Right::Rows(rs) => rs.iter().map(|v| (None, v.as_slice())).collect(),
            };
            let mut map = AutoMap::new();
            for (i, (rowid, vals)) in list.iter().enumerate() {
                let v = if *col < vals.len() { vals[*col].clone() } else { Value::Int(rowid.unwrap_or(0)) };
                if let Some(k) = auto_key(&v, key) {
                    map.entry(k).or_default().push(i);
                }
            }
            auto = Some(AutoRows { rows: list, map });
        }
        for l in &rows {
            buf.clone_from(l);
            let mut any = false;
            let mut visit = |ri: usize, c: &mut [Value]| -> Result<()> {
                let ok = match &j.on {
                    Some(on) => eval(on, c, cx)?.truthy() == Some(true),
                    None => true,
                };
                if ok {
                    any = true;
                    if let Some(m) = right_matched.get_mut(ri) {
                        *m = true;
                    }
                    if pass_all(filters, c, cx)? {
                        emit(c)?;
                    }
                }
                Ok(())
            };
            match (&j.access, &right) {
                (Access::Auto { key, .. }, Right::Table(t)) if table_auto => {
                    let cache = j.auto_cache.borrow();
                    let (_, map) = cache.as_ref().unwrap();
                    if let Some(k) = crate::access::key_value(key, &buf, cx)? {
                        if let Some(list) = map.get(&IdxKey(vec![k])) {
                            let n = t.columns.len();
                            for &rowid in list {
                                if let Some(vals) = t.rows.get(&rowid) {
                                    buf[j.offset..j.offset + n].clone_from_slice(vals);
                                    buf[j.offset + n] = Value::Int(rowid);
                                    visit(0, &mut buf)?;
                                }
                            }
                        }
                    }
                }
                (Access::Auto { key, .. }, _) if use_auto => {
                    let a = auto.as_ref().unwrap();
                    if let Some(k) = crate::access::key_value(key, &buf, cx)? {
                        if let Some(list) = a.map.get(&IdxKey(vec![k])) {
                            for &i in list {
                                let (rowid, vals) = a.rows[i];
                                buf[j.offset..j.offset + vals.len()].clone_from_slice(vals);
                                if let Some(r) = rowid {
                                    buf[j.offset + vals.len()] = Value::Int(r);
                                }
                                visit(i, &mut buf)?;
                            }
                        }
                    }
                }
                (Access::Rowid(_) | Access::Index(..), Right::Table(t)) => {
                    let n = t.columns.len();
                    for rowid in lookup_rowids(t, &j.access, &buf, cx)? {
                        if let Some(vals) = t.rows.get(&rowid) {
                            buf[j.offset..j.offset + n].clone_from_slice(vals);
                            buf[j.offset + n] = Value::Int(rowid);
                            visit(0, &mut buf)?;
                        }
                    }
                }
                _ => right.for_each(&mut buf, j.offset, &mut visit)?,
            }
            if !any && keep_left && pass_all(filters, l, cx)? {
                emit(l)?;
            }
        }
        if !right_matched.is_empty() {
            let mut buf: Row = vec![Value::Null; width];
            right.for_each(&mut buf, j.offset, &mut |ri, c| {
                if !right_matched[ri] && pass_all(filters, c, cx)? {
                    emit(c)?;
                }
                Ok(())
            })?;
        }
        drop(emit);
        rows = out;
    }
    Ok(())
}

/// Run one SELECT core: result rows with their ORDER BY key values.
fn exec_core(core: &CorePlan, cx: &Cx) -> Result<Vec<(Row, Vec<Value>)>> {
    let width = core.width;
    let specs = &core.aggs;
    let mut results: Vec<(Row, Vec<Value>)> = Vec::new();
    let mut seen: BTreeSet<IdxKey> = BTreeSet::new();
    let colls: Vec<Collation> = if core.distinct {
        core.outputs.iter().map(|e| expr_collation(e).unwrap_or(Collation::Binary)).collect()
    } else {
        vec![]
    };
    // Project one (source or group) row.
    let mut project = |row: &[Value]| -> Result<()> {
        let mut out = Vec::with_capacity(core.outputs.len());
        for e in &core.outputs {
            out.push(eval(e, row, cx)?);
        }
        if core.distinct && !seen.insert(row_key(&out, &colls)) {
            return Ok(());
        }
        let mut ks = Vec::with_capacity(core.keys.len());
        for k in &core.keys {
            ks.push(match k {
                Key::Out(i) => out[*i].clone(),
                Key::Expr(e) => eval(e, row, cx)?,
            });
        }
        results.push((out, ks));
        Ok(())
    };

    let has_win = core.win_slots > 0;
    let mut staged: Vec<Row> = Vec::new();
    if !core.is_agg {
        if has_win {
            scan(core, cx, &mut |r: &[Value]| {
                staged.push(r.to_vec());
                Ok(())
            })?;
            for r in crate::window::compute(&core.windows, staged, core.win_base, core.win_slots, cx)? {
                project(&r)?;
            }
        } else {
            scan(core, cx, &mut project)?;
        }
        return Ok(results);
    }

    struct Group {
        bare: Row,
        states: Vec<AggState>,
    }
    let group_by = &core.group_by;
    let gcolls: Vec<Collation> = group_by.iter().map(|e| expr_collation(e).unwrap_or(Collation::Binary)).collect();
    let mut index: BTreeMap<IdxKey, usize> = Default::default();
    let mut groups: Vec<Group> = Vec::new();
    scan(core, cx, &mut |row: &[Value]| -> Result<()> {
        let mut k = Vec::with_capacity(group_by.len());
        for (e, c) in group_by.iter().zip(&gcolls) {
            k.push(normalize(&eval(e, row, cx)?, *c));
        }
        let key = IdxKey(k);
        let mut first = false;
        let gi = match index.get(&key) {
            Some(g) => *g,
            None => {
                first = true;
                groups.push(Group { bare: vec![Value::Null; width], states: specs.iter().map(AggState::new).collect() });
                index.insert(key, groups.len() - 1);
                groups.len() - 1
            }
        };
        let g = &mut groups[gi];
        // Bare columns come from the first row of the group, or with
        // min()/max() from the row that produced the extremum (the
        // last min/max call of the row decides).
        let mut skip = true;
        for (st, spec) in g.states.iter_mut().zip(specs) {
            if let Some(s) = st.update(spec, row, cx)? {
                if spec.is_minmax() {
                    skip = s;
                }
            }
        }
        if first || !skip {
            g.bare.clear();
            g.bare.extend_from_slice(row);
        }
        Ok(())
    })?;
    let order: Vec<usize> = if group_by.is_empty() {
        if groups.is_empty() {
            groups.push(Group { bare: vec![Value::Null; width], states: specs.iter().map(AggState::new).collect() });
        }
        vec![0]
    } else {
        index.values().copied().collect()
    };
    let mut groups: Vec<Option<Group>> = groups.into_iter().map(Some).collect();
    for gi in order {
        let g = groups[gi].take().unwrap();
        let mut row = g.bare;
        for (st, spec) in g.states.into_iter().zip(specs) {
            row.push(st.finish(spec)?);
        }
        if let Some(h) = &core.having {
            if eval(h, &row, cx)?.truthy() != Some(true) {
                continue;
            }
        }
        if has_win {
            staged.push(row);
        } else {
            project(&row)?;
        }
    }
    if has_win {
        for r in crate::window::compute(&core.windows, staged, core.win_base, core.win_slots, cx)? {
            project(&r)?;
        }
    }
    Ok(results)
}
