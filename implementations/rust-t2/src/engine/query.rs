// Query planning and execution: joins, subqueries and compound queries.

use std::fmt;

use super::*;

/// A subquery used in an expression (scalar, EXISTS or IN).
pub struct SubExpr {
    pub plan: QueryPlan,
    volatile: bool,
    /// Result of an uncorrelated subquery, computed once per statement
    /// (per generation, see `Database::gen`).
    cache: RefCell<Option<(u64, Cached)>>,
}

impl fmt::Debug for SubExpr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "SubExpr({} columns)", self.plan.ncols)
    }
}

enum Cached {
    Val(Value),
    Bool(bool),
    Set(Rc<InSet>),
}

/// Right-hand side of `x IN (SELECT ...)`.
struct InSet {
    keys: BTreeSet<IdxKey>,
    has_null: bool,
    empty: bool,
}

type SortSpec = (SortKey, bool, Option<bool>, Coll);

pub struct QueryPlan {
    cores: Vec<CorePlan>,
    ops: Vec<SetOp>,
    keys: Vec<SortSpec>,
    limit: Option<BExpr>,
    offset: Option<BExpr>,
    pub ncols: usize,
    /// Column names, affinities and collations when used as a FROM source.
    pub names: Vec<String>,
    pub affs: Vec<Affinity>,
    pub colls: Vec<Coll>,
    /// Collations used to compare rows in compound operators.
    set_colls: Vec<Coll>,
    /// Refers to columns of an enclosing query.
    pub correlated: bool,
}

impl QueryPlan {
    /// The first result expression of the leftmost SELECT.
    pub fn first_expr(&self) -> Option<&BExpr> {
        match &self.cores[0] {
            CorePlan::Select(sp) => sp.outs.first().map(|(e, _)| e),
            CorePlan::Values(_) => None,
        }
    }
}

enum CorePlan {
    Select(SelectPlan),
    Values(Vec<Vec<BExpr>>),
}

struct SelectPlan {
    sources: Vec<SrcPlan>,
    /// WHERE conjuncts evaluated after all joins.
    final_filter: Vec<BExpr>,
    width: usize,
    is_agg: bool,
    group_by: Vec<(BExpr, Coll)>,
    having: Option<BExpr>,
    calls: Vec<AggCall>,
    outs: Vec<(BExpr, Option<String>)>,
    distinct: bool,
    wins: Vec<window::WinCall>,
    /// Environment slot of the first window function result.
    win_base: usize,
}

enum SrcKind {
    Table(String),
    /// Rows computed when the query is compiled (sqlite_schema).
    Static(Rc<Vec<Row>>),
    /// Derived table; the flag marks it volatile (inside RETURNING).
    Sub(Box<QueryPlan>, bool),
    /// Recursive CTE (volatile flag as for Sub).
    RecCte(Box<RecPlan>, bool),
    /// The current row of a recursive CTE, inside its recursive part.
    RecSelf(Rc<SelfRef>),
}

// ---------------------------------------------------------------------
// Common table expressions
// ---------------------------------------------------------------------

/// The CTEs of one WITH clause, chained to those of enclosing clauses.
pub struct CteEnv {
    entries: Vec<CteEntry>,
    parent: Option<Rc<CteEnv>>,
}

enum CteEntry {
    Def(CteDef),
    SelfRef(Rc<SelfRef>),
}

struct CteDef {
    name: String,
    columns: Option<Vec<String>>,
    query: Select,
    /// Set while the CTE's body is being compiled (circular references).
    busy: Cell<bool>,
}

/// The recursive table as seen from a recursive SELECT: the row being
/// processed.
pub struct SelfRef {
    name: String,
    names: Vec<String>,
    affs: Vec<Affinity>,
    colls: Vec<Coll>,
    rows: RefCell<Rc<Vec<Row>>>,
    uses: Cell<usize>,
}

impl CteEnv {
    pub fn new(with: &With, parent: Option<Rc<CteEnv>>) -> Rc<CteEnv> {
        let entries = with
            .ctes
            .iter()
            .map(|c| {
                CteEntry::Def(CteDef {
                    name: fold(&c.name),
                    columns: c.columns.clone(),
                    query: c.query.clone(),
                    busy: Cell::new(false),
                })
            })
            .collect();
        Rc::new(CteEnv { entries, parent })
    }
}

/// Find a CTE by name: the environment node defining it and its index.
fn find_cte(env: &Option<Rc<CteEnv>>, name: &str) -> Option<(Rc<CteEnv>, usize)> {
    let lname = fold(name);
    let mut e = env.clone();
    while let Some(node) = e {
        let pos = node.entries.iter().rposition(|x| match x {
            CteEntry::Def(d) => d.name == lname,
            CteEntry::SelfRef(r) => r.name == lname,
        });
        if let Some(i) = pos {
            return Some((node, i));
        }
        e = node.parent.clone();
    }
    None
}

/// A recursive CTE: anchor query, recursive SELECTs and queue control.
pub struct RecPlan {
    anchor: QueryPlan,
    recs: Vec<SelectPlan>,
    this: Rc<SelfRef>,
    distinct: bool,
    keys: Vec<(usize, bool, Option<bool>, Coll)>,
    limit: Option<BExpr>,
    offset: Option<BExpr>,
    set_colls: Vec<Coll>,
}

/// Number of FROM items of a SELECT (not descending into subqueries) that
/// name `name`.
fn direct_refs(core: &Core, name: &str) -> usize {
    match core {
        Core::Select(c) => c
            .from
            .iter()
            .filter(|t| matches!(&t.source, TableRef::Table { name: n, .. } if fold(n) == name))
            .count(),
        Core::Values(_) => 0,
    }
}

/// For an inner-join recursive SELECT, move the recursive table to the
/// front of the FROM clause so each step starts from the current row.
fn rec_first(core: &SelectCore, name: &str) -> SelectCore {
    let pos = core
        .from
        .iter()
        .position(|t| matches!(&t.source, TableRef::Table { name: n, .. } if fold(n) == name));
    let simple = core
        .from
        .iter()
        .all(|t| t.kind == JoinKind::Inner && !t.natural && t.using.is_none())
        && !core.columns.iter().any(|c| matches!(c, ResultCol::Star));
    let mut c = core.clone();
    match pos {
        Some(p) if p > 0 && simple => {
            let mut conds: Vec<Expr> = Vec::new();
            for t in c.from.iter_mut() {
                if let Some(on) = t.on.take() {
                    conds.push(on);
                }
            }
            if let Some(w) = c.where_.take() {
                conds.push(w);
            }
            c.where_ = conds
                .into_iter()
                .reduce(|a, b| Expr::Binary(BinOp::And, Box::new(a), Box::new(b)));
            let t = c.from.remove(p);
            c.from.insert(0, t);
            c
        }
        _ => c,
    }
}

/// Resolve the ORDER BY of a compound query to result columns.
fn compound_keys(
    order_by: &[OrderTerm],
    ncols: usize,
    all_names: &[Vec<String>],
    all_dbg: &[Vec<String>],
    set_colls: &[Coll],
) -> Result<Vec<(usize, bool, Option<bool>, Coll)>, String> {
    let mut keys = Vec::new();
    for (ti, t) in order_by.iter().enumerate() {
        let (base, coll_name) = match &t.expr {
            Expr::Collate(inner, c) => (&**inner, Some(c)),
            e => (e, None),
        };
        let idx = match base {
            Expr::Lit(Value::Integer(n)) => {
                if *n < 1 || *n as usize > ncols {
                    return Err(format!(
                        "{} ORDER BY term out of range - should be between 1 and {}",
                        ordinal(ti + 1),
                        ncols
                    ));
                }
                *n as usize - 1
            }
            _ => {
                let by_name = match base {
                    Expr::Column { name, .. } => all_names
                        .iter()
                        .find_map(|ns| ns.iter().position(|x| fold(x) == fold(name))),
                    _ => None,
                };
                let d = format!("{:?}", base);
                by_name
                    .or_else(|| {
                        all_dbg
                            .iter()
                            .find_map(|ds| ds.iter().position(|x| *x == d))
                    })
                    .ok_or_else(|| {
                        format!(
                            "{} ORDER BY term does not match any column in the result set",
                            ordinal(ti + 1)
                        )
                    })?
            }
        };
        let coll = match coll_name {
            Some(c) => check_coll(Some(Coll::from_name(c).unwrap_or(Coll::Unknown)))?,
            None => set_colls[idx],
        };
        keys.push((idx, t.desc, t.nulls_first, coll));
    }
    Ok(keys)
}

/// Compile a reference to a CTE: (source kind, column names, affinities,
/// collations).
type CteSource = (SrcKind, Vec<String>, Vec<Affinity>, Vec<Coll>);

fn compile_cte(
    db: &Database,
    node: Rc<CteEnv>,
    idx: usize,
    volatile: bool,
) -> Result<CteSource, String> {
    let def = match &node.entries[idx] {
        CteEntry::SelfRef(r) => {
            r.uses.set(r.uses.get() + 1);
            return Ok((
                SrcKind::RecSelf(r.clone()),
                r.names.clone(),
                r.affs.clone(),
                r.colls.clone(),
            ));
        }
        CteEntry::Def(d) => d,
    };
    if def.busy.get() {
        return Err(format!("circular reference: {}", def.name));
    }
    def.busy.set(true);
    let r = compile_cte_body(db, &node, def, volatile);
    def.busy.set(false);
    r
}

fn compile_cte_body(
    db: &Database,
    node: &Rc<CteEnv>,
    def: &CteDef,
    volatile: bool,
) -> Result<CteSource, String> {
    let q = &def.query;
    let set_names = |names: Vec<String>, n: usize| -> Result<Vec<String>, String> {
        match &def.columns {
            Some(cols) if cols.len() != n => Err(format!(
                "table {} has {} values for {} columns",
                def.name,
                n,
                cols.len()
            )),
            Some(cols) => Ok(cols.clone()),
            None => Ok(names),
        }
    };
    // Recursive SELECTs: the trailing arms (joined by the same UNION /
    // UNION ALL operator) that read the CTE in their FROM clause.
    let mut nrec = 0;
    if let Some(&last) = q.ops.last() {
        if matches!(last, SetOp::Union | SetOp::UnionAll) {
            let mut i = q.cores.len() - 1;
            while i >= 1 && q.ops[i - 1] == last {
                match direct_refs(&q.cores[i], &def.name) {
                    0 => break,
                    1 => nrec += 1,
                    _ => {
                        return Err(format!(
                            "multiple references to recursive table: {}",
                            def.name
                        ))
                    }
                }
                i -= 1;
            }
        }
    }
    if nrec == 0 {
        let plan = compile_query(db, q, None, Some(node.clone()))?;
        let names = set_names(plan.names.clone(), plan.ncols)?;
        let (affs, colls) = (plan.affs.clone(), plan.colls.clone());
        return Ok((SrcKind::Sub(Box::new(plan), volatile), names, affs, colls));
    }
    let na = q.cores.len() - nrec;
    let anchor_sel = Select {
        with: q.with.clone(),
        cores: q.cores[..na].to_vec(),
        ops: q.ops[..na - 1].to_vec(),
        order_by: Vec::new(),
        limit: None,
        offset: None,
    };
    let anchor = compile_query(db, &anchor_sel, None, Some(node.clone()))?;
    let ncols = anchor.ncols;
    let names = set_names(anchor.names.clone(), ncols)?;
    let this = Rc::new(SelfRef {
        name: def.name.clone(),
        names: names.clone(),
        affs: anchor.affs.clone(),
        colls: anchor.colls.clone(),
        rows: RefCell::new(Rc::new(Vec::new())),
        uses: Cell::new(0),
    });
    // The recursive part sees the body's own WITH clause, then the CTE itself.
    let mut outer = Some(node.clone());
    if let Some(w) = &q.with {
        outer = Some(CteEnv::new(w, outer));
    }
    let env = Rc::new(CteEnv {
        entries: vec![CteEntry::SelfRef(this.clone())],
        parent: outer,
    });
    let mut recs = Vec::new();
    let mut all_names = vec![anchor.names.clone()];
    let mut all_dbg: Vec<Vec<String>> = Vec::new();
    for (k, core) in q.cores[na..].iter().enumerate() {
        let Core::Select(c) = core else {
            unreachable!()
        };
        let c = rec_first(c, &def.name);
        this.uses.set(0);
        let out = compile_core(db, &c, None, &[], Some(env.clone()))?;
        if this.uses.get() != 1 {
            return Err(format!("multiple recursive references: {}", def.name));
        }
        if out.plan.is_agg {
            return Err("recursive aggregate queries not supported".into());
        }
        if !out.plan.wins.is_empty() {
            return Err("cannot use window functions in recursive queries".into());
        }
        if out.names.len() != ncols {
            return Err(format!(
                "SELECTs to the left and right of {} do not have the same number of result columns",
                op_name(q.ops[na - 1 + k])
            ));
        }
        all_names.push(out.names);
        all_dbg.push(out.dbg);
        recs.push(out.plan);
    }
    let set_colls = anchor.set_colls.clone();
    let keys = compound_keys(&q.order_by, ncols, &all_names, &all_dbg, &set_colls)?;
    let lscope = child_scope(db, None, Some(node.clone()));
    let limit = q.limit.as_ref().map(|e| bind(e, &lscope)).transpose()?;
    let offset = q.offset.as_ref().map(|e| bind(e, &lscope)).transpose()?;
    let (affs, colls) = (anchor.affs.clone(), anchor.colls.clone());
    let plan = RecPlan {
        anchor,
        recs,
        this,
        distinct: *q.ops.last().unwrap() == SetOp::Union,
        keys,
        limit,
        offset,
        set_colls,
    };
    Ok((
        SrcKind::RecCte(Box::new(plan), volatile),
        names,
        affs,
        colls,
    ))
}

/// Queue entry of a recursive CTE with ORDER BY (smallest key first, then
/// insertion order).
struct QItem<'a> {
    keys: Vec<Value>,
    seq: u64,
    row: Row,
    spec: &'a [(usize, bool, Option<bool>, Coll)],
}

impl QItem<'_> {
    fn cmp_key(&self, o: &Self) -> Ordering {
        for (i, (_, desc, nf, coll)) in self.spec.iter().enumerate() {
            let c = agg::order_cmp(&self.keys[i], &o.keys[i], *desc, *nf, *coll);
            if c != Ordering::Equal {
                return c;
            }
        }
        self.seq.cmp(&o.seq)
    }
}

impl PartialEq for QItem<'_> {
    fn eq(&self, o: &Self) -> bool {
        self.cmp_key(o) == Ordering::Equal
    }
}
impl Eq for QItem<'_> {}
impl PartialOrd for QItem<'_> {
    fn partial_cmp(&self, o: &Self) -> Option<Ordering> {
        Some(self.cmp(o))
    }
}
impl Ord for QItem<'_> {
    fn cmp(&self, o: &Self) -> Ordering {
        // BinaryHeap is a max-heap.
        o.cmp_key(self)
    }
}

struct RecQueue<'p> {
    p: &'p RecPlan,
    seen: BTreeSet<IdxKey>,
    fifo: std::collections::VecDeque<Row>,
    heap: std::collections::BinaryHeap<QItem<'p>>,
    seq: u64,
}

impl<'p> RecQueue<'p> {
    fn push(&mut self, row: Row) {
        let p = self.p;
        if p.distinct {
            let k = IdxKey(
                row.iter()
                    .zip(&p.set_colls)
                    .map(|(v, c)| coll_key(v, *c))
                    .collect(),
            );
            if !self.seen.insert(k) {
                return;
            }
        }
        if p.keys.is_empty() {
            self.fifo.push_back(row);
        } else {
            let keys = p.keys.iter().map(|(i, ..)| row[*i].clone()).collect();
            self.seq += 1;
            self.heap.push(QItem {
                keys,
                seq: self.seq,
                row,
                spec: &p.keys,
            });
        }
    }
}

/// Run a recursive CTE: rows are taken from a queue one at a time,
/// emitted, and fed to the recursive SELECTs.
fn exec_rec(p: &RecPlan, cx: Cx) -> Result<Vec<Row>, String> {
    let mut limit = match &p.limit {
        Some(e) => eval_limit(e, cx)?,
        None => -1,
    };
    let mut offset = match &p.offset {
        Some(e) => eval_limit(e, cx)?.max(0),
        None => 0,
    };
    let mut out = Vec::new();
    if limit == 0 {
        return Ok(out);
    }
    let mut q = RecQueue {
        p,
        seen: BTreeSet::new(),
        fifo: std::collections::VecDeque::new(),
        heap: std::collections::BinaryHeap::new(),
        seq: 0,
    };
    for r in exec_query(&p.anchor, cx)? {
        q.push(r);
    }
    loop {
        let row = if p.keys.is_empty() {
            q.fifo.pop_front()
        } else {
            q.heap.pop().map(|x| x.row)
        };
        let Some(row) = row else { break };
        if offset > 0 {
            offset -= 1;
        } else {
            out.push(row.clone());
            if limit > 0 {
                limit -= 1;
                if limit == 0 {
                    break;
                }
            }
        }
        *p.this.rows.borrow_mut() = Rc::new(vec![row]);
        for sp in &p.recs {
            for (r, _) in exec_core(sp, &[], cx)? {
                q.push(r);
            }
        }
    }
    *p.this.rows.borrow_mut() = Rc::new(Vec::new());
    Ok(out)
}

struct SrcPlan {
    kind: SrcKind,
    /// Rows of the source (with the rowid appended for tables) and the
    /// table version / generation they were read at; not kept for
    /// correlated sources.
    cache: RefCell<Option<(u64, Rc<Vec<Row>>)>>,
    offset: usize,
    width: usize,
    join: JoinKind,
    /// Join condition conjuncts (ON / USING / NATURAL).
    on: Vec<BExpr>,
    /// WHERE conjuncts that can be checked once this source is joined.
    filters: Vec<BExpr>,
    /// Equality used to look up matching rows of this source by key.
    hash: Option<HashKey>,
    /// Lookup index built from `hash` over the cached rows.
    index: RefCell<Option<(Rc<Vec<Row>>, Rc<KeyIndex>)>>,
    /// Rowid or index lookup on a table source.
    access: Option<access::Access>,
    /// Full scan in the order of this index (reversed if the flag is set).
    scan: Option<(usize, bool)>,
}

type KeyIndex = BTreeMap<IdxKey, Vec<usize>>;

struct HashKey {
    /// Expression over this source's columns.
    right: BExpr,
    /// Expression over the preceding sources' columns.
    left: BExpr,
    aff: Affinity,
    coll: Coll,
}

// ---------------------------------------------------------------------
// Compilation
// ---------------------------------------------------------------------

fn child_scope<'a>(
    db: &'a Database,
    parent: Option<&'a Scope<'a>>,
    ctes: Option<Rc<CteEnv>>,
) -> Scope<'a> {
    Scope {
        db: Some(db),
        parent,
        volatile: parent.is_some_and(|p| p.volatile),
        ctes,
        ..Default::default()
    }
}

/// Compile a subquery nested in `scope`.
pub(super) fn compile_sub(sel: &Select, scope: &Scope) -> Result<SubExpr, String> {
    let db = scope
        .db
        .ok_or_else(|| "subqueries are not supported here".to_string())?;
    let plan = compile_query(db, sel, Some(scope), scope.ctes.clone())?;
    Ok(SubExpr {
        plan,
        volatile: scope.volatile,
        cache: RefCell::new(None),
    })
}

fn op_name(op: SetOp) -> &'static str {
    match op {
        SetOp::Union => "UNION",
        SetOp::UnionAll => "UNION ALL",
        SetOp::Intersect => "INTERSECT",
        SetOp::Except => "EXCEPT",
    }
}

fn compile_query<'a>(
    db: &'a Database,
    sel: &Select,
    parent: Option<&'a Scope<'a>>,
    env: Option<Rc<CteEnv>>,
) -> Result<QueryPlan, String> {
    let env = match &sel.with {
        Some(w) => Some(CteEnv::new(w, env)),
        None => env,
    };
    let single_select = sel.cores.len() == 1 && matches!(sel.cores[0], Core::Select(_));
    let mut cores = Vec::new();
    let mut keys = Vec::new();
    let mut correlated = false;
    let mut all_names: Vec<Vec<String>> = Vec::new();
    let mut all_dbg: Vec<Vec<String>> = Vec::new();
    for (ci, core) in sel.cores.iter().enumerate() {
        let (cp, names, dbg) = match core {
            Core::Select(c) => {
                let order: &[OrderTerm] = if single_select { &sel.order_by } else { &[] };
                let out = compile_core(db, c, parent, order, env.clone())?;
                correlated |= out.corr;
                if single_select {
                    keys = out.keys;
                }
                (CorePlan::Select(out.plan), out.names, out.dbg)
            }
            Core::Values(rows) => {
                let scope = child_scope(db, parent, env.clone());
                let mut bound = Vec::new();
                for r in rows {
                    bound.push(bind_all(r, &scope)?);
                }
                correlated |= scope.corr.get();
                let n = rows[0].len();
                let names: Vec<String> = (1..=n).map(|i| format!("column{}", i)).collect();
                let dbg = names.clone();
                (CorePlan::Values(bound), names, dbg)
            }
        };
        if ci > 0 && names.len() != all_names[0].len() {
            return Err(format!(
                "SELECTs to the left and right of {} do not have the same number of result columns",
                op_name(sel.ops[ci - 1])
            ));
        }
        cores.push(cp);
        all_names.push(names);
        all_dbg.push(dbg);
    }
    let ncols = all_names[0].len();

    let out_expr = |c: &CorePlan, i: usize| -> Option<BExpr> {
        match c {
            CorePlan::Select(sp) => Some(sp.outs[i].0.clone()),
            CorePlan::Values(rows) => Some(rows[0][i].clone()),
        }
    };
    let mut affs = Vec::with_capacity(ncols);
    let mut colls = Vec::with_capacity(ncols);
    let mut set_colls = Vec::with_capacity(ncols);
    for i in 0..ncols {
        let e = out_expr(&cores[0], i);
        affs.push(match (&cores[0], &e) {
            (CorePlan::Select(_), Some(e)) => expr_affinity(e),
            _ => Affinity::None,
        });
        colls.push(e.as_ref().and_then(expr_coll).unwrap_or(Coll::Binary));
        let sc = cores
            .iter()
            .find_map(|c| out_expr(c, i).as_ref().and_then(expr_coll))
            .unwrap_or(Coll::Binary);
        set_colls.push(sc);
    }

    if !single_select {
        keys = compound_keys(&sel.order_by, ncols, &all_names, &all_dbg, &set_colls)?
            .into_iter()
            .map(|(i, d, nf, c)| (SortKey::Result(i), d, nf, c))
            .collect();
    }

    // LIMIT and OFFSET may use subqueries, but not columns.
    let lscope = child_scope(db, parent, env.clone());
    let limit = sel.limit.as_ref().map(|e| bind(e, &lscope)).transpose()?;
    let offset = sel.offset.as_ref().map(|e| bind(e, &lscope)).transpose()?;
    correlated |= lscope.corr.get();

    // Names of a derived table's columns are made unique.
    let mut names = all_names.swap_remove(0);
    for i in 0..names.len() {
        let base = names[i].clone();
        let mut k = 0;
        while names[..i].iter().any(|x| fold(x) == fold(&names[i])) {
            k += 1;
            names[i] = format!("{}:{}", base, k);
        }
    }

    Ok(QueryPlan {
        cores,
        ops: sel.ops.clone(),
        keys,
        limit,
        offset,
        ncols,
        names,
        affs,
        colls,
        set_colls,
        correlated,
    })
}

/// Compile a view's query as a derived table.
fn compile_view(db: &Database, name: &str) -> Result<QueryPlan, String> {
    let key = fold(name);
    let v = &db.views[&key];
    if db.view_stack.borrow().contains(&key) {
        return Err(format!("view {} is circularly defined", v.name));
    }
    db.view_stack.borrow_mut().push(key);
    let r = compile_query(db, &v.query, None, None);
    db.view_stack.borrow_mut().pop();
    let mut plan = r?;
    if let Some(cols) = &v.columns {
        if cols.len() != plan.ncols {
            return Err(format!(
                "expected {} columns for '{}' but got {}",
                cols.len(),
                v.name,
                plan.ncols
            ));
        }
        plan.names = cols.clone();
    }
    Ok(plan)
}

struct CoreOut {
    plan: SelectPlan,
    keys: Vec<SortSpec>,
    names: Vec<String>,
    dbg: Vec<String>,
    corr: bool,
}

type BoundCols = (Vec<(BExpr, Option<String>)>, Vec<String>, Vec<String>);

/// Bind a SELECT's result columns; also returns their names and a textual
/// form used to match compound ORDER BY terms.
fn bind_select_cols(cols: &[ResultCol], scope: &Scope) -> Result<BoundCols, String> {
    let mut outs = Vec::new();
    let mut names = Vec::new();
    let mut dbg = Vec::new();
    let col_dbg = |name: &str| {
        format!(
            "{:?}",
            Expr::Column {
                table: None,
                name: name.to_string(),
                dq: false
            }
        )
    };
    for rc in cols {
        match rc {
            ResultCol::Star => {
                if scope.sources.is_empty() {
                    return Err("no tables specified".into());
                }
                for (si, s) in scope.sources.iter().enumerate() {
                    if !s.name.is_empty() && scope.sources[..si].iter().any(|x| x.name == s.name) {
                        let c = s.columns.first().map(String::as_str).unwrap_or("");
                        return Err(format!("ambiguous column name: {}.{}", s.name, c));
                    }
                    for i in 0..s.columns.len() {
                        if !s.merged[i] {
                            outs.push((s.col_expr(i, true), None));
                            names.push(s.columns[i].clone());
                            dbg.push(col_dbg(&s.columns[i]));
                        }
                    }
                }
            }
            ResultCol::TableStar(t) => {
                let lt = fold(t);
                let s = scope
                    .sources
                    .iter()
                    .find(|s| s.name == lt)
                    .ok_or_else(|| format!("no such table: {}", t))?;
                for i in 0..s.columns.len() {
                    outs.push((s.col_expr(i, false), None));
                    names.push(s.columns[i].clone());
                    dbg.push(col_dbg(&s.columns[i]));
                }
            }
            ResultCol::Expr(e, alias, text) => {
                outs.push((bind(e, scope)?, alias.clone()));
                names.push(match (alias, e) {
                    (Some(a), _) => a.clone(),
                    (None, Expr::Column { name, .. }) => name.clone(),
                    (None, _) => text.clone(),
                });
                dbg.push(format!("{:?}", e));
            }
        }
    }
    Ok((outs, names, dbg))
}

pub(super) fn split_and(e: BExpr, out: &mut Vec<BExpr>) {
    match e {
        BExpr::Binary(BinOp::And, l, r) => {
            split_and(*l, out);
            split_and(*r, out);
        }
        other => out.push(other),
    }
}

/// Column references of a bound expression.
#[derive(Default)]
pub(super) struct Refs {
    pub min: Option<usize>,
    pub max: Option<usize>,
    /// Refers to an enclosing query's row.
    pub outer: bool,
    /// Contains a subquery or an aggregate.
    pub opaque: bool,
}

pub(super) fn refs(e: &BExpr) -> Refs {
    fn walk(e: &BExpr, r: &mut Refs) {
        match e {
            BExpr::Col(i, _, _) => {
                r.min = Some(r.min.map_or(*i, |m| m.min(*i)));
                r.max = Some(r.max.map_or(*i, |m| m.max(*i)));
            }
            BExpr::Outer(..) => r.outer = true,
            BExpr::Scalar(_)
            | BExpr::Exists(_)
            | BExpr::InSelect { .. }
            | BExpr::Agg(..)
            | BExpr::Win(..) => r.opaque = true,
            _ => {}
        }
        let (l, list, rr) = coll_children(e);
        if let Some(l) = l {
            walk(l, r);
        }
        for x in list {
            walk(x, r);
        }
        if let Some(x) = rr {
            walk(x, r);
        }
    }
    let mut r = Refs::default();
    walk(e, &mut r);
    r
}

/// Whether an expression's subqueries are all uncorrelated (and it has no
/// aggregates), so it can be checked as soon as its columns are available.
fn pushable(e: &BExpr) -> bool {
    match e {
        BExpr::Agg(..) | BExpr::Win(..) => return false,
        BExpr::Scalar(s) | BExpr::Exists(s) | BExpr::InSelect { sub: s, .. }
            if s.plan.correlated =>
        {
            return false
        }
        _ => {}
    }
    let (l, list, r) = coll_children(e);
    l.is_none_or(pushable) && list.into_iter().all(pushable) && r.is_none_or(pushable)
}

/// Find an equality between this source's columns and earlier ones (or,
/// for the first source, the enclosing query's row).
fn pick_hash(off: usize, width: usize, conds: &[&BExpr]) -> Option<HashKey> {
    let in_right = |r: &Refs| {
        !r.opaque
            && !r.outer
            && r.min.is_some_and(|m| m >= off)
            && r.max.is_some_and(|m| m < off + width)
    };
    let in_left = |r: &Refs| !r.opaque && r.max.is_none_or(|m| m < off) && (off > 0 || r.outer);
    for c in conds {
        if let BExpr::Cmp(BinOp::Eq, a, b, aff, coll) = c {
            let (ra, rb) = (refs(a), refs(b));
            if in_right(&ra) && in_left(&rb) {
                return Some(HashKey {
                    right: (**a).clone(),
                    left: (**b).clone(),
                    aff: *aff,
                    coll: *coll,
                });
            }
            if in_right(&rb) && in_left(&ra) {
                return Some(HashKey {
                    right: (**b).clone(),
                    left: (**a).clone(),
                    aff: *aff,
                    coll: *coll,
                });
            }
        }
    }
    None
}

fn compile_core<'a>(
    db: &'a Database,
    c: &SelectCore,
    parent: Option<&'a Scope<'a>>,
    order_by: &[OrderTerm],
    env: Option<Rc<CteEnv>>,
) -> Result<CoreOut, String> {
    let mut scope = child_scope(db, parent, env);
    let mut srcs: Vec<SrcPlan> = Vec::new();
    let mut offset = 0;
    for term in &c.from {
        let cte = match &term.source {
            TableRef::Table { name, .. } => find_cte(&scope.ctes, name),
            _ => None,
        };
        let (kind, mut source) = match &term.source {
            TableRef::Table { name, alias } if cte.is_some() => {
                let (node, idx) = cte.unwrap();
                let (kind, columns, affinities, colls) =
                    compile_cte(db, node, idx, scope.volatile)?;
                let n = columns.len();
                let source = Source {
                    name: fold(alias.as_deref().unwrap_or(name)),
                    columns,
                    affinities,
                    colls,
                    offset,
                    rowid: None,
                    qualified_only: false,
                    merged: vec![false; n],
                    partners: vec![Vec::new(); n],
                };
                (kind, source)
            }
            TableRef::Table { name, alias } if db.tables.contains_key(&fold(name)) => {
                let t = db.table(name)?;
                (
                    SrcKind::Table(fold(name)),
                    t.source(alias.as_deref().unwrap_or(name), offset),
                )
            }
            TableRef::Table { name, alias } if db.views.contains_key(&fold(name)) => {
                let sub = compile_view(db, name)?;
                let n = sub.ncols;
                let source = Source {
                    name: fold(alias.as_deref().unwrap_or(name)),
                    columns: sub.names.clone(),
                    affinities: sub.affs.clone(),
                    colls: sub.colls.clone(),
                    offset,
                    rowid: None,
                    qualified_only: false,
                    merged: vec![false; n],
                    partners: vec![Vec::new(); n],
                };
                (SrcKind::Sub(Box::new(sub), scope.volatile), source)
            }
            TableRef::Table { name, alias } if is_schema_table(name) => {
                let cols = ["type", "name", "tbl_name", "rootpage", "sql"];
                let source = Source {
                    name: fold(alias.as_deref().unwrap_or(name)),
                    columns: cols.iter().map(|c| c.to_string()).collect(),
                    affinities: vec![
                        Affinity::Text,
                        Affinity::Text,
                        Affinity::Text,
                        Affinity::Integer,
                        Affinity::Text,
                    ],
                    colls: vec![Coll::Binary; 5],
                    offset,
                    rowid: Some(offset + 5),
                    qualified_only: false,
                    merged: vec![false; 5],
                    partners: vec![Vec::new(); 5],
                };
                (SrcKind::Static(Rc::new(db.schema_rows())), source)
            }
            TableRef::Table { name, alias }
                if name.eq_ignore_ascii_case("sqlite_sequence")
                    && db.sequence_rows().is_some() =>
            {
                let cols = ["name", "seq"];
                let source = Source {
                    name: fold(alias.as_deref().unwrap_or(name)),
                    columns: cols.iter().map(|c| c.to_string()).collect(),
                    affinities: vec![Affinity::Blob, Affinity::Blob],
                    colls: vec![Coll::Binary; 2],
                    offset,
                    rowid: Some(offset + 2),
                    qualified_only: false,
                    merged: vec![false; 2],
                    partners: vec![Vec::new(); 2],
                };
                (SrcKind::Static(Rc::new(db.sequence_rows().unwrap())), source)
            }
            TableRef::Table { name, .. } => return Err(format!("no such table: {}", name)),
            TableRef::Subquery { query, alias } => {
                // A derived table sees the enclosing queries but not its
                // sibling FROM items.
                let sub = compile_query(db, query, parent, scope.ctes.clone())?;
                if sub.correlated {
                    scope.corr.set(true);
                }
                let n = sub.ncols;
                let source = Source {
                    name: alias.as_deref().map(fold).unwrap_or_default(),
                    columns: sub.names.clone(),
                    affinities: sub.affs.clone(),
                    colls: sub.colls.clone(),
                    offset,
                    rowid: None,
                    qualified_only: false,
                    merged: vec![false; n],
                    partners: vec![Vec::new(); n],
                };
                (SrcKind::Sub(Box::new(sub), scope.volatile), source)
            }
        };
        let width = source.width();
        let mut on = Vec::new();
        if !srcs.is_empty() {
            let using: Vec<String> = if term.natural {
                source
                    .columns
                    .iter()
                    .filter(|c| {
                        scope.sources.iter().any(|s| {
                            s.columns
                                .iter()
                                .enumerate()
                                .any(|(i, x)| !s.merged[i] && fold(x) == fold(c))
                        })
                    })
                    .cloned()
                    .collect()
            } else {
                term.using.clone().unwrap_or_default()
            };
            for n in &using {
                let ln = fold(n);
                let ri = source.columns.iter().position(|c| fold(c) == ln);
                let left = scope.sources.iter().enumerate().find_map(|(si, s)| {
                    s.columns
                        .iter()
                        .enumerate()
                        .position(|(i, x)| !s.merged[i] && fold(x) == ln)
                        .map(|ci| (si, ci))
                });
                let (Some(ri), Some((si, ci))) = (ri, left) else {
                    return Err(format!(
                        "cannot join using column {} - column not present in both tables",
                        n
                    ));
                };
                let lexpr = scope.sources[si].col_expr(ci, true);
                let rexpr = BExpr::Col(offset + ri, source.affinities[ri], source.colls[ri]);
                source.merged[ri] = true;
                if matches!(term.kind, JoinKind::Right | JoinKind::Full) {
                    scope.sources[si].partners[ci].push((
                        offset + ri,
                        source.affinities[ri],
                        source.colls[ri],
                    ));
                }
                on.push(make_cmp(BinOp::Eq, lexpr, rexpr)?);
            }
        }
        scope.sources.push(source);
        if let Some(e) = &term.on {
            split_and(bind(e, &scope)?, &mut on);
        }
        srcs.push(SrcPlan {
            kind,
            cache: RefCell::new(None),
            offset,
            width,
            join: term.kind,
            on,
            filters: Vec::new(),
            hash: None,
            index: RefCell::new(None),
            access: None,
            scan: None,
        });
        offset += width;
    }
    let width = offset;

    // WHERE conjuncts are checked as soon as their columns are available,
    // unless a later RIGHT/FULL join could still NULL-extend them.
    let mut final_filter = Vec::new();
    if let Some(w) = &c.where_ {
        scope.where_aliases = c
            .columns
            .iter()
            .filter_map(|rc| match rc {
                ResultCol::Expr(e, Some(a), _) => Some((a.clone(), e.clone())),
                _ => None,
            })
            .collect();
        let mut conj = Vec::new();
        let bound = bind(w, &scope);
        scope.where_aliases.clear();
        split_and(bound?, &mut conj);
        for e in conj {
            let r = refs(&e);
            let level = if (r.opaque && !pushable(&e)) || srcs.is_empty() {
                None
            } else {
                let lvl = match r.max {
                    None => 0,
                    Some(m) => srcs.iter().rposition(|s| s.offset <= m).unwrap_or(0),
                };
                if srcs[lvl + 1..]
                    .iter()
                    .any(|s| matches!(s.join, JoinKind::Right | JoinKind::Full))
                {
                    None
                } else {
                    Some(lvl)
                }
            };
            match level {
                Some(l) => srcs[l].filters.push(e),
                None => final_filter.push(e),
            }
        }
    }
    for s in srcs.iter_mut() {
        let mut conds: Vec<&BExpr> = s.on.iter().collect();
        if s.join == JoinKind::Inner {
            conds.extend(s.filters.iter());
        }
        if let SrcKind::Table(key) = &s.kind {
            if !matches!(s.join, JoinKind::Right | JoinKind::Full) {
                s.access = access::choose(&db.tables[key], s.offset, &conds);
            }
        }
        if s.access.is_none() {
            s.hash = pick_hash(s.offset, s.width, &conds);
        }
    }

    *scope.agg.borrow_mut() = Some(AggCtx {
        base: width,
        calls: Vec::new(),
        depth: 0,
    });
    *scope.win.borrow_mut() = Some(window::WinCtx::new(c.windows.clone()));
    let (outs, names, dbg) = bind_select_cols(&c.columns, &scope)?;
    scope.aliases = outs
        .iter()
        .filter_map(|(e, a)| a.clone().map(|a| (a, e.clone())))
        .collect();
    // Window functions are not allowed in HAVING or GROUP BY.
    let wctx = scope.win.borrow_mut().take();
    let having = match &c.having {
        Some(h) => Some(bind(h, &scope)?),
        None => None,
    };
    let mut group_by = Vec::new();
    for (i, g) in c.group_by.iter().enumerate() {
        let e = match g {
            Expr::Lit(Value::Integer(n)) => {
                if *n < 1 || *n as usize > outs.len() {
                    return Err(format!(
                        "{} GROUP BY term out of range - should be between 1 and {}",
                        ordinal(i + 1),
                        outs.len()
                    ));
                }
                outs[*n as usize - 1].0.clone()
            }
            _ => bind(g, &scope)?,
        };
        if has_agg(&e) {
            return Err("aggregate functions are not allowed in the GROUP BY clause".into());
        }
        let coll = check_coll(expr_coll(&e))?;
        group_by.push((e, coll));
    }
    *scope.win.borrow_mut() = wctx;
    let is_agg = !c.group_by.is_empty()
        || scope
            .agg
            .borrow()
            .as_ref()
            .is_some_and(|c| !c.calls.is_empty());
    if having.is_some() && !is_agg {
        return Err("HAVING clause on a non-aggregate query".into());
    }
    if !is_agg {
        *scope.agg.borrow_mut() = None;
    }

    // ORDER BY: ordinals and aliases refer to result columns.
    let mut keys: Vec<SortSpec> = Vec::new();
    for t in order_by {
        let (base, coll_name) = match &t.expr {
            Expr::Collate(inner, c) => (&**inner, Some(c)),
            e => (e, None),
        };
        let k = match base {
            Expr::Lit(Value::Integer(n)) => {
                if *n < 1 || *n as usize > outs.len() {
                    return Err(format!(
                        "{} ORDER BY term out of range - should be between 1 and {}",
                        ordinal(keys.len() + 1),
                        outs.len()
                    ));
                }
                SortKey::Result(*n as usize - 1)
            }
            Expr::Column {
                table: None, name, ..
            } if outs
                .iter()
                .any(|(_, a)| a.as_deref().is_some_and(|a| fold(a) == fold(name))) =>
            {
                let ln = fold(name);
                SortKey::Result(
                    outs.iter()
                        .position(|(_, a)| a.as_deref().is_some_and(|a| fold(a) == ln))
                        .unwrap(),
                )
            }
            _ => SortKey::Expr(bind(&t.expr, &scope)?),
        };
        let coll = match (&k, coll_name) {
            (SortKey::Result(_), Some(c)) => Some(Coll::from_name(c).unwrap_or(Coll::Unknown)),
            (SortKey::Result(i), None) => expr_coll(&outs[*i].0),
            (SortKey::Expr(e), _) => expr_coll(e),
        };
        let coll = check_coll(coll)?;
        keys.push((k, t.desc, t.nulls_first, coll));
    }
    let calls = scope
        .agg
        .borrow_mut()
        .take()
        .map(|c| c.calls)
        .unwrap_or_default();
    let wctx = scope.win.borrow_mut().take().unwrap();
    let win_base = if is_agg { width + calls.len() } else { width };
    wctx.base.set(win_base);
    let mut plan = SelectPlan {
        sources: srcs,
        final_filter,
        width,
        is_agg,
        group_by,
        having,
        calls,
        outs,
        distinct: c.distinct,
        wins: wctx.calls,
        win_base,
    };
    // Full scans use a covering index where SQLite would (this fixes the
    // order of rows when no ORDER BY applies).
    if !plan
        .sources
        .iter()
        .any(|s| matches!(s.join, JoinKind::Right | JoinKind::Full))
    {
        let mut used = vec![false; plan.width];
        mark_core(&plan, &keys, 0, &mut used);
        // ORDER BY terms that are plain columns of the first source.
        let mut order_cols = Vec::new();
        if let Some(SrcPlan {
            kind: SrcKind::Table(key),
            ..
        }) = plan.sources.first()
        {
            let ncols = db.tables[key].columns.len();
            for (k, desc, _, coll) in &keys {
                let e = match k {
                    SortKey::Result(i) => &plan.outs[*i].0,
                    SortKey::Expr(e) => e,
                };
                match e {
                    BExpr::Col(c, _, _) if *c < ncols => order_cols.push((*c, *desc, *coll)),
                    _ => break,
                }
            }
        }
        for (si, s) in plan.sources.iter_mut().enumerate() {
            if let SrcKind::Table(key) = &s.kind {
                let t = &db.tables[key];
                let src_used = &used[s.offset..s.offset + s.width];
                if si == 0
                    && !order_cols.is_empty()
                    && !plan.is_agg
                    && s.access.as_ref().is_none_or(|a| !a.has_eq())
                {
                    if let Some(o) = access::order_index(t, &order_cols, src_used) {
                        s.access = None;
                        s.hash = None;
                        s.scan = Some(o);
                        continue;
                    }
                }
                if s.access.is_none() && s.hash.is_none() {
                    s.scan = access::covering_index(t, src_used).map(|i| (i, false));
                }
            }
        }
    }
    Ok(CoreOut {
        plan,
        keys,
        names,
        dbg,
        corr: scope.corr.get(),
    })
}

/// Mark the columns of the query `level` scopes up that `e` uses.
fn mark_used(e: &BExpr, level: usize, used: &mut [bool]) {
    match e {
        BExpr::Col(i, _, _) if level == 0 => {
            if let Some(u) = used.get_mut(*i) {
                *u = true;
            }
        }
        BExpr::Outer(k, i, _, _) if *k == level => {
            if let Some(u) = used.get_mut(*i) {
                *u = true;
            }
        }
        BExpr::Scalar(s) | BExpr::Exists(s) | BExpr::InSelect { sub: s, .. } => {
            mark_plan(&s.plan, level + 1, used)
        }
        _ => {}
    }
    let (l, list, r) = coll_children(e);
    if let Some(x) = l {
        mark_used(x, level, used);
    }
    for x in list {
        mark_used(x, level, used);
    }
    if let Some(x) = r {
        mark_used(x, level, used);
    }
}

fn mark_plan(p: &QueryPlan, level: usize, used: &mut [bool]) {
    for c in &p.cores {
        match c {
            CorePlan::Select(sp) => mark_core(sp, &p.keys, level, used),
            CorePlan::Values(rows) => rows
                .iter()
                .flatten()
                .for_each(|e| mark_used(e, level, used)),
        }
    }
    for e in p.limit.iter().chain(p.offset.iter()) {
        mark_used(e, level, used);
    }
}

fn mark_core(sp: &SelectPlan, keys: &[SortSpec], level: usize, used: &mut [bool]) {
    for s in &sp.sources {
        s.on.iter()
            .chain(s.filters.iter())
            .for_each(|e| mark_used(e, level, used));
        if let (SrcKind::Sub(p, _), true) = (&s.kind, level > 0) {
            // A derived table sees the scopes enclosing its query.
            mark_plan(p, level, used);
        }
    }
    sp.final_filter
        .iter()
        .for_each(|e| mark_used(e, level, used));
    sp.group_by
        .iter()
        .for_each(|(e, _)| mark_used(e, level, used));
    sp.having.iter().for_each(|e| mark_used(e, level, used));
    for c in &sp.calls {
        c.args
            .iter()
            .chain(c.filter.iter())
            .for_each(|e| mark_used(e, level, used));
        c.order.iter().for_each(|(e, ..)| mark_used(e, level, used));
    }
    sp.outs.iter().for_each(|(e, _)| mark_used(e, level, used));
    for w in &sp.wins {
        w.exprs()
            .into_iter()
            .for_each(|e| mark_used(e, level, used));
    }
    for (k, ..) in keys {
        if let SortKey::Expr(e) = k {
            mark_used(e, level, used);
        }
    }
}

// ---------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------

fn pass(conds: &[BExpr], row: &[Value], cx: Cx) -> Result<bool, String> {
    for c in conds {
        if eval(c, row, cx)?.truthy() != Some(true) {
            return Ok(false);
        }
    }
    Ok(true)
}

pub(super) fn exec_query(p: &QueryPlan, cx: Cx) -> Result<Vec<Row>, String> {
    let limit = match &p.limit {
        Some(e) => eval_limit(e, cx)?,
        None => -1,
    };
    let offset = match &p.offset {
        Some(e) => eval_limit(e, cx)?.max(0) as usize,
        None => 0,
    };
    let mut rows: Vec<(Row, Vec<Value>)> = match (&p.cores[..], p.ops.is_empty()) {
        ([CorePlan::Select(sp)], true) => exec_core(sp, &p.keys, cx)?,
        _ => {
            let rows = if p.ops.is_empty() {
                core_rows(&p.cores[0], cx)?
            } else {
                exec_compound(p, cx)?
            };
            rows.into_iter()
                .map(|r| {
                    let kv = p
                        .keys
                        .iter()
                        .map(|(k, ..)| match k {
                            SortKey::Result(i) => r[*i].clone(),
                            SortKey::Expr(_) => Value::Null,
                        })
                        .collect();
                    (r, kv)
                })
                .collect()
        }
    };
    if !p.keys.is_empty() {
        rows.sort_by(|a, b| {
            for (i, (_, desc, nulls_first, coll)) in p.keys.iter().enumerate() {
                let o = agg::order_cmp(&a.1[i], &b.1[i], *desc, *nulls_first, *coll);
                if o != Ordering::Equal {
                    return o;
                }
            }
            Ordering::Equal
        });
    }
    let it = rows.into_iter().map(|(r, _)| r).skip(offset);
    Ok(if limit >= 0 {
        it.take(limit as usize).collect()
    } else {
        it.collect()
    })
}

fn core_rows(c: &CorePlan, cx: Cx) -> Result<Vec<Row>, String> {
    match c {
        CorePlan::Select(sp) => Ok(exec_core(sp, &[], cx)?
            .into_iter()
            .map(|(r, _)| r)
            .collect()),
        CorePlan::Values(rows) => {
            let mut out = Vec::with_capacity(rows.len());
            for r in rows {
                let mut vals = Vec::with_capacity(r.len());
                for e in r {
                    vals.push(eval(e, &[], cx)?);
                }
                out.push(vals);
            }
            Ok(out)
        }
    }
}

/// Evaluate a compound query left to right. Distinct results are kept in
/// key order, like SQLite's temporary indexes; a later duplicate replaces
/// an earlier one.
fn exec_compound(p: &QueryPlan, cx: Cx) -> Result<Vec<Row>, String> {
    let key = |r: &Row| {
        IdxKey(
            r.iter()
                .zip(&p.set_colls)
                .map(|(v, c)| coll_key(v, *c))
                .collect(),
        )
    };
    let mut bag: Option<Vec<Row>> = Some(core_rows(&p.cores[0], cx)?);
    let mut set: BTreeMap<IdxKey, Row> = BTreeMap::new();
    for (op, core) in p.ops.iter().zip(&p.cores[1..]) {
        let right = core_rows(core, cx)?;
        if *op == SetOp::UnionAll {
            let mut v = match bag.take() {
                Some(v) => v,
                None => std::mem::take(&mut set).into_values().collect(),
            };
            v.extend(right);
            bag = Some(v);
            continue;
        }
        if let Some(v) = bag.take() {
            set.clear();
            for r in v {
                set.insert(key(&r), r);
            }
        }
        match op {
            SetOp::Union => {
                for r in right {
                    set.insert(key(&r), r);
                }
            }
            SetOp::Intersect => {
                let rk: BTreeSet<IdxKey> = right.iter().map(key).collect();
                set.retain(|k, _| rk.contains(k));
            }
            SetOp::Except => {
                let rk: BTreeSet<IdxKey> = right.iter().map(key).collect();
                set.retain(|k, _| !rk.contains(k));
            }
            SetOp::UnionAll => unreachable!(),
        }
    }
    Ok(match bag {
        Some(v) => v,
        None => set.into_values().collect(),
    })
}

fn exec_core(sp: &SelectPlan, keys: &[SortSpec], cx: Cx) -> Result<Vec<(Row, Vec<Value>)>, String> {
    let mut input = join_rows(sp, cx)?;
    if !sp.final_filter.is_empty() {
        let mut kept = Vec::with_capacity(input.len());
        for r in input {
            if pass(&sp.final_filter, &r, cx)? {
                kept.push(r);
            }
        }
        input = kept;
    }
    let mut envs = if sp.is_agg {
        group_rows(
            input,
            &sp.group_by,
            &sp.calls,
            sp.width,
            sp.having.as_ref(),
            cx,
        )?
    } else {
        input
    };
    if !sp.wins.is_empty() {
        window::compute(&sp.wins, sp.win_base, &mut envs, cx)?;
    }
    let distinct_colls: Vec<Coll> = if sp.distinct {
        sp.outs
            .iter()
            .map(|(e, _)| expr_coll(e).unwrap_or(Coll::Binary))
            .collect()
    } else {
        Vec::new()
    };
    let mut seen: BTreeSet<IdxKey> = BTreeSet::new();
    let mut rows = Vec::new();
    for r in &envs {
        let out = eval_row(&sp.outs, r, cx)?;
        if sp.distinct {
            let k = IdxKey(
                out.iter()
                    .zip(&distinct_colls)
                    .map(|(v, c)| coll_key(v, *c))
                    .collect(),
            );
            if !seen.insert(k) {
                continue;
            }
        }
        let mut kv = Vec::with_capacity(keys.len());
        for (k, _, _, _) in keys {
            kv.push(match k {
                SortKey::Result(i) => out[*i].clone(),
                SortKey::Expr(e) => eval(e, r, cx)?,
            });
        }
        rows.push((out, kv));
    }
    Ok(rows)
}

/// Cache generation for results of volatile subqueries.
fn generation(cx: Cx, volatile: bool) -> u64 {
    if volatile {
        cx.db.map_or(0, |d| d.gen.get())
    } else {
        0
    }
}

fn source_rows(src: &SrcPlan, cx: Cx) -> Result<Rc<Vec<Row>>, String> {
    match &src.kind {
        SrcKind::Table(key) => {
            let db = cx.db.ok_or_else(|| "no database".to_string())?;
            let t = db
                .tables
                .get(key)
                .ok_or_else(|| format!("no such table: {}", key))?;
            if let Some((v, r)) = src.cache.borrow().as_ref() {
                if *v == t.version {
                    return Ok(r.clone());
                }
            }
            let with_rowid = |rid: i64, row: &Row| {
                let mut r = Vec::with_capacity(row.len() + 1);
                r.extend(row.iter().cloned());
                r.push(Value::Integer(rid));
                r
            };
            let rows: Vec<Row> = match src.scan {
                Some((i, rev)) => {
                    let mut order = access::index_order(t, i);
                    if rev {
                        order.reverse();
                    }
                    order
                        .into_iter()
                        .map(|rid| with_rowid(rid, &t.rows[&rid]))
                        .collect()
                }
                None => t
                    .rows
                    .iter()
                    .map(|(&rid, row)| with_rowid(rid, row))
                    .collect(),
            };
            let rows = Rc::new(rows);
            *src.cache.borrow_mut() = Some((t.version, rows.clone()));
            Ok(rows)
        }
        SrcKind::Static(rows) => Ok(rows.clone()),
        SrcKind::Sub(p, volatile) => {
            let g = generation(cx, *volatile);
            if !p.correlated {
                if let Some((v, r)) = src.cache.borrow().as_ref() {
                    if *v == g {
                        return Ok(r.clone());
                    }
                }
            }
            let rows = Rc::new(exec_query(p, cx)?);
            if !p.correlated {
                *src.cache.borrow_mut() = Some((g, rows.clone()));
            }
            Ok(rows)
        }
        SrcKind::RecCte(p, volatile) => {
            let g = generation(cx, *volatile);
            if let Some((v, r)) = src.cache.borrow().as_ref() {
                if *v == g {
                    return Ok(r.clone());
                }
            }
            let rows = Rc::new(exec_rec(p, cx)?);
            *src.cache.borrow_mut() = Some((g, rows.clone()));
            Ok(rows)
        }
        SrcKind::RecSelf(r) => Ok(r.rows.borrow().clone()),
    }
}

fn hash_key(v: Value, h: &HashKey) -> Option<IdxKey> {
    if v.is_null() {
        return None;
    }
    Some(IdxKey(vec![coll_key(
        &apply_cmp_affinity(v, h.aff),
        h.coll,
    )]))
}

fn source_index(
    src: &SrcPlan,
    h: &HashKey,
    right: &Rc<Vec<Row>>,
    cx: Cx,
) -> Result<Rc<KeyIndex>, String> {
    if let Some((r, m)) = src.index.borrow().as_ref() {
        if Rc::ptr_eq(r, right) {
            return Ok(m.clone());
        }
    }
    let lw = src.offset;
    let mut m = KeyIndex::new();
    let mut buf = vec![Value::Null; lw];
    for (ri, r) in right.iter().enumerate() {
        buf.truncate(lw);
        buf.extend(r.iter().cloned());
        if let Some(k) = hash_key(eval(&h.right, &buf, cx)?, h) {
            m.entry(k).or_default().push(ri);
        }
    }
    let m = Rc::new(m);
    *src.index.borrow_mut() = Some((right.clone(), m.clone()));
    Ok(m)
}

/// Rows of the FROM clause after joins and pushed-down WHERE conjuncts.
fn join_rows(sp: &SelectPlan, cx: Cx) -> Result<Vec<Row>, String> {
    let mut rows: Vec<Row> = vec![Vec::new()];
    for src in &sp.sources {
        if let (Some(acc), SrcKind::Table(key)) = (&src.access, &src.kind) {
            rows = index_join(src, acc, key, rows, cx)?;
            continue;
        }
        let right = source_rows(src, cx)?;
        let lw = src.offset;
        let inner = src.join == JoinKind::Inner;
        let outer_left = matches!(src.join, JoinKind::Left | JoinKind::Full);
        let outer_right = matches!(src.join, JoinKind::Right | JoinKind::Full);
        let mut right_matched = vec![false; if outer_right { right.len() } else { 0 }];
        let index = match &src.hash {
            Some(h) => Some((h, source_index(src, h, &right, cx)?)),
            None => None,
        };
        let all: Vec<usize> = if index.is_some() {
            Vec::new()
        } else {
            (0..right.len()).collect()
        };
        let mut out = Vec::new();
        let mut buf: Row = Vec::with_capacity(lw + src.width);
        for l in rows {
            let cands: &[usize] = match &index {
                Some((h, m)) => match hash_key(eval(&h.left, &l, cx)?, h) {
                    Some(k) => m.get(&k).map(|v| v.as_slice()).unwrap_or(&[]),
                    None => &[],
                },
                None => &all,
            };
            let mut matched = false;
            for &ri in cands {
                buf.clear();
                buf.extend(l.iter().cloned());
                buf.extend(right[ri].iter().cloned());
                if !pass(&src.on, &buf, cx)? {
                    continue;
                }
                if inner && !pass(&src.filters, &buf, cx)? {
                    continue;
                }
                matched = true;
                if outer_right {
                    right_matched[ri] = true;
                }
                out.push(buf.clone());
            }
            if !matched && outer_left {
                let mut r = l;
                r.resize(lw + src.width, Value::Null);
                out.push(r);
            }
        }
        if outer_right {
            for (ri, m) in right_matched.iter().enumerate() {
                if !m {
                    let mut r = vec![Value::Null; lw];
                    r.extend(right[ri].iter().cloned());
                    out.push(r);
                }
            }
        }
        if !inner && !src.filters.is_empty() {
            let mut kept = Vec::with_capacity(out.len());
            for r in out {
                if pass(&src.filters, &r, cx)? {
                    kept.push(r);
                }
            }
            out = kept;
        }
        rows = out;
    }
    Ok(rows)
}

/// Join the rows so far with a table read through a rowid/index lookup.
fn index_join(
    src: &SrcPlan,
    acc: &access::Access,
    key: &str,
    rows: Vec<Row>,
    cx: Cx,
) -> Result<Vec<Row>, String> {
    let db = cx.db.ok_or_else(|| "no database".to_string())?;
    let t = db
        .tables
        .get(key)
        .ok_or_else(|| format!("no such table: {}", key))?;
    let lw = src.offset;
    let inner = src.join == JoinKind::Inner;
    let mut out = Vec::new();
    let mut buf: Row = Vec::with_capacity(lw + src.width);
    for l in rows {
        let mut matched = false;
        for rid in access::rowids(t, acc, &l, cx)? {
            let Some(row) = t.rows.get(&rid) else {
                continue;
            };
            buf.clear();
            buf.extend(l.iter().cloned());
            buf.extend(row.iter().cloned());
            buf.push(Value::Integer(rid));
            if !pass(&src.on, &buf, cx)? {
                continue;
            }
            if inner && !pass(&src.filters, &buf, cx)? {
                continue;
            }
            matched = true;
            out.push(buf.clone());
        }
        if !matched && !inner {
            let mut r = l;
            r.resize(lw + src.width, Value::Null);
            out.push(r);
        }
    }
    if !inner && !src.filters.is_empty() {
        let mut kept = Vec::with_capacity(out.len());
        for r in out {
            if pass(&src.filters, &r, cx)? {
                kept.push(r);
            }
        }
        out = kept;
    }
    Ok(out)
}

// ---------------------------------------------------------------------
// Subquery expressions
// ---------------------------------------------------------------------

fn run_sub(sub: &SubExpr, row: &[Value], cx: Cx) -> Result<Vec<Row>, String> {
    let frame = Frame { row, up: cx.outer };
    exec_query(
        &sub.plan,
        Cx {
            db: cx.db,
            outer: Some(&frame),
        },
    )
}

pub(super) fn eval_scalar(sub: &SubExpr, row: &[Value], cx: Cx) -> Result<Value, String> {
    let g = generation(cx, sub.volatile);
    if let Some((cg, Cached::Val(v))) = &*sub.cache.borrow() {
        if *cg == g {
            return Ok(v.clone());
        }
    }
    let rows = run_sub(sub, row, cx)?;
    let v = rows
        .into_iter()
        .next()
        .map(|mut r| r.swap_remove(0))
        .unwrap_or(Value::Null);
    if !sub.plan.correlated {
        *sub.cache.borrow_mut() = Some((g, Cached::Val(v.clone())));
    }
    Ok(v)
}

pub(super) fn eval_exists(sub: &SubExpr, row: &[Value], cx: Cx) -> Result<Value, String> {
    let g = generation(cx, sub.volatile);
    if let Some((cg, Cached::Bool(b))) = &*sub.cache.borrow() {
        if *cg == g {
            return Ok(bool_val(*b));
        }
    }
    let b = !run_sub(sub, row, cx)?.is_empty();
    if !sub.plan.correlated {
        *sub.cache.borrow_mut() = Some((g, Cached::Bool(b)));
    }
    Ok(bool_val(b))
}

pub(super) fn eval_in(
    sub: &SubExpr,
    v: Value,
    not: bool,
    aff: Affinity,
    coll: Coll,
    row: &[Value],
    cx: Cx,
) -> Result<Value, String> {
    let set = in_set(sub, aff, coll, row, cx)?;
    if set.empty {
        return Ok(bool_val(not));
    }
    if v.is_null() {
        return Ok(Value::Null);
    }
    if set
        .keys
        .contains(&IdxKey(vec![coll_key(&apply_cmp_affinity(v, aff), coll)]))
    {
        Ok(bool_val(!not))
    } else if set.has_null {
        Ok(Value::Null)
    } else {
        Ok(bool_val(not))
    }
}

/// Non-NULL values of an IN subquery, converted for comparison, in order.
pub(super) fn in_values(
    sub: &SubExpr,
    aff: Affinity,
    coll: Coll,
    row: &[Value],
    cx: Cx,
) -> Result<Vec<Value>, String> {
    let set = in_set(sub, aff, coll, row, cx)?;
    Ok(set.keys.iter().map(|k| k.0[0].clone()).collect())
}

fn in_set(
    sub: &SubExpr,
    aff: Affinity,
    coll: Coll,
    row: &[Value],
    cx: Cx,
) -> Result<Rc<InSet>, String> {
    let g = generation(cx, sub.volatile);
    let cached = match &*sub.cache.borrow() {
        Some((cg, Cached::Set(s))) if *cg == g => Some(s.clone()),
        _ => None,
    };
    Ok(match cached {
        Some(s) => s,
        None => {
            let rows = run_sub(sub, row, cx)?;
            let mut s = InSet {
                keys: BTreeSet::new(),
                has_null: false,
                empty: rows.is_empty(),
            };
            for mut r in rows {
                let x = r.swap_remove(0);
                if x.is_null() {
                    s.has_null = true;
                } else {
                    s.keys
                        .insert(IdxKey(vec![coll_key(&apply_cmp_affinity(x, aff), coll)]));
                }
            }
            let s = Rc::new(s);
            if !sub.plan.correlated {
                *sub.cache.borrow_mut() = Some((g, Cached::Set(s.clone())));
            }
            s
        }
    })
}
