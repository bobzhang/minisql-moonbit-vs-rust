// Database state, name binding and statement execution.

use std::cell::{Cell, RefCell};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

mod access;
mod file;
mod query;
mod schema;
mod sqltext;
mod window;
mod write;
pub use query::SubExpr;

use crate::agg::{self, AggCall, AggKind};
use crate::ast::*;
use crate::func::{self, ScalarFn};
use crate::value::*;

pub type Row = Vec<Value>;

#[derive(Clone)]
pub struct ColumnInfo {
    pub name: String,
    pub affinity: Affinity,
    pub coll: Coll,
    pub not_null: bool,
    pub not_null_conflict: Option<ConflictAction>,
    pub default: Option<BExpr>,
    /// Estimated stored size (for choosing covering index scans).
    pub sz_est: u32,
}

/// Index key: values compared with the BINARY rules after collation keys
/// have been applied (see `coll_key`).
#[derive(Debug, Clone)]
pub struct IdxKey(pub Vec<Value>);

impl PartialEq for IdxKey {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}
impl Eq for IdxKey {}
impl PartialOrd for IdxKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for IdxKey {
    fn cmp(&self, other: &Self) -> Ordering {
        for (a, b) in self.0.iter().zip(&other.0) {
            match compare_values(a, b) {
                Ordering::Equal => {}
                o => return o,
            }
        }
        self.0.len().cmp(&other.0.len())
    }
}

/// A value transformed so that BINARY comparison of the result matches
/// comparison of the original under `coll`.
pub fn coll_key(v: &Value, coll: Coll) -> Value {
    match (v, coll) {
        (Value::Text(s), Coll::NoCase) => Value::Text(s.to_ascii_lowercase()),
        (Value::Text(s), Coll::RTrim) => Value::Text(s.trim_end_matches(' ').to_string()),
        _ => v.clone(),
    }
}

/// One key part of an index: an expression over the table row (with the
/// rowid appended), its collation and sort direction.
#[derive(Clone)]
pub struct IdxPart {
    pub expr: BExpr,
    /// Set when the part is a plain table column.
    pub col: Option<usize>,
    pub coll: Coll,
    pub desc: bool,
}

#[derive(Clone)]
pub struct Index {
    pub name: String,
    /// Number of an automatic index (sqlite_autoindex_<table>_<n>).
    pub auto: Option<usize>,
    pub unique: bool,
    pub parts: Vec<IdxPart>,
    /// Partial index predicate.
    pub where_: Option<BExpr>,
    pub conflict: Option<ConflictAction>,
    pub entries: BTreeSet<(IdxKey, i64)>,
    pub schema_id: u64,
    pub ast: Vec<IndexedColumn>,
    pub where_ast: Option<Expr>,
    pub sql: Option<String>,
}

impl Index {
    /// Key of a row, or None if the row is outside a partial index.
    fn key(&self, row: &[Value], rowid: i64) -> Result<Option<IdxKey>, String> {
        if self.where_.is_none() && self.parts.iter().all(|p| p.col.is_some()) {
            return Ok(Some(IdxKey(
                self.parts
                    .iter()
                    .map(|p| coll_key(&row[p.col.unwrap()], p.coll))
                    .collect(),
            )));
        }
        let mut env = Vec::with_capacity(row.len() + 1);
        env.extend(row.iter().cloned());
        env.push(Value::Integer(rowid));
        if let Some(w) = &self.where_ {
            if eval(w, &env, Cx::default())?.truthy() != Some(true) {
                return Ok(None);
            }
        }
        let mut k = Vec::with_capacity(self.parts.len());
        for p in &self.parts {
            k.push(coll_key(&eval(&p.expr, &env, Cx::default())?, p.coll));
        }
        Ok(Some(IdxKey(k)))
    }

    /// Rowids of entries whose key equals `key`.
    fn find(&self, key: &IdxKey) -> Vec<i64> {
        self.entries
            .range((key.clone(), i64::MIN)..=(key.clone(), i64::MAX))
            .map(|(_, r)| *r)
            .collect()
    }

    /// Table columns of the key when every part is a plain column.
    fn col_list(&self) -> Option<Vec<usize>> {
        self.parts.iter().map(|p| p.col).collect()
    }
}

#[derive(Clone)]
pub struct Table {
    pub name: String,
    pub columns: Vec<ColumnInfo>,
    pub rows: BTreeMap<i64, Row>,
    /// INTEGER PRIMARY KEY column (rowid alias).
    pub ipk: Option<usize>,
    pub ipk_conflict: Option<ConflictAction>,
    pub autoinc: bool,
    /// Largest rowid ever used (AUTOINCREMENT).
    pub seq: i64,
    /// Constraint indexes and CREATE INDEX indexes, in creation order.
    pub indexes: Vec<Index>,
    pub checks: Vec<(BExpr, String)>,
    pub check_defs: Vec<CheckDef>,
    /// Bumped on every change (invalidates cached snapshots).
    pub version: u64,
    pub schema_id: u64,
    pub sql: String,
}

#[derive(Clone)]
pub struct View {
    pub name: String,
    pub columns: Option<Vec<String>>,
    pub query: Select,
    pub schema_id: u64,
    pub sql: String,
}

impl Table {
    fn insert_raw(&mut self, rowid: i64, row: Row) -> Result<(), String> {
        let mut keys = Vec::with_capacity(self.indexes.len());
        for idx in &self.indexes {
            keys.push(idx.key(&row, rowid)?);
        }
        self.version += 1;
        for (idx, k) in self.indexes.iter_mut().zip(keys) {
            if let Some(k) = k {
                idx.entries.insert((k, rowid));
            }
        }
        self.rows.insert(rowid, row);
        Ok(())
    }

    fn delete_raw(&mut self, rowid: i64) -> Option<Row> {
        let row = self.rows.remove(&rowid)?;
        self.version += 1;
        for idx in &mut self.indexes {
            if let Ok(Some(k)) = idx.key(&row, rowid) {
                idx.entries.remove(&(k, rowid));
            }
        }
        Some(row)
    }

    fn col_index(&self, name: &str) -> Option<usize> {
        self.columns
            .iter()
            .position(|c| c.name.eq_ignore_ascii_case(name))
    }

    fn source(&self, name: &str, offset: usize) -> Source {
        let n = self.columns.len();
        Source {
            name: fold(name),
            columns: self.columns.iter().map(|c| c.name.clone()).collect(),
            affinities: self.columns.iter().map(|c| c.affinity).collect(),
            colls: self.columns.iter().map(|c| c.coll).collect(),
            offset,
            rowid: Some(offset + n),
            qualified_only: false,
            merged: vec![false; n],
            partners: vec![Vec::new(); n],
        }
    }

    fn qualified(&self, col: usize) -> String {
        format!("{}.{}", self.name, self.columns[col].name)
    }

    /// Bind index parts and a partial-index predicate against this table.
    fn bind_index(
        &self,
        cols: &[IndexedColumn],
        where_: Option<&Expr>,
    ) -> Result<(Vec<IdxPart>, Option<BExpr>), String> {
        let mut scope = Scope::default();
        scope.sources.push(self.source(&self.name, 0));
        let n = self.columns.len();
        let mut parts = Vec::new();
        for ic in cols {
            if contains_subquery(&ic.expr) {
                return Err("subqueries prohibited in index expressions".into());
            }
            let e = bind(&ic.expr, &scope)?;
            let col = match &e {
                BExpr::Col(i, _, _) if *i < n => Some(*i),
                _ => None,
            };
            let coll = match &ic.collate {
                Some(c) => Coll::from_name(c)?,
                None => check_coll(expr_coll(&e))?,
            };
            parts.push(IdxPart {
                expr: e,
                col,
                coll,
                desc: ic.desc,
            });
        }
        let w = match where_ {
            Some(w) => {
                if contains_subquery(w) {
                    return Err("subqueries prohibited in partial index WHERE clauses".into());
                }
                Some(bind(w, &scope)?)
            }
            None => None,
        };
        Ok((parts, w))
    }

    /// Re-bind CHECK constraints and index expressions after the columns
    /// changed.
    fn rebind(&mut self) -> Result<(), String> {
        let mut scope = Scope::default();
        scope.sources.push(self.source(&self.name, 0));
        let mut checks = Vec::new();
        for ch in &self.check_defs {
            checks.push((bind(&ch.expr, &scope)?, ch.name.clone()));
        }
        self.checks = checks;
        for i in 0..self.indexes.len() {
            let (parts, w) =
                self.bind_index(&self.indexes[i].ast, self.indexes[i].where_ast.as_ref())?;
            self.indexes[i].parts = parts;
            self.indexes[i].where_ = w;
        }
        Ok(())
    }

    /// Recompute every index's entries from the rows.
    fn rebuild_indexes(&mut self) -> Result<(), String> {
        for i in 0..self.indexes.len() {
            let entries = build_entries(self, &self.indexes[i])?;
            self.indexes[i].entries = entries;
        }
        Ok(())
    }
}

/// Entries of an index over the table's rows; fails on a uniqueness
/// violation.
fn build_entries(t: &Table, idx: &Index) -> Result<BTreeSet<(IdxKey, i64)>, String> {
    let mut entries = BTreeSet::new();
    let mut prev: Option<IdxKey> = None;
    let mut keyed = Vec::new();
    for (&rid, row) in &t.rows {
        if let Some(k) = idx.key(row, rid)? {
            keyed.push((k, rid));
        }
    }
    keyed.sort();
    for (k, rid) in keyed {
        if idx.unique && prev.as_ref() == Some(&k) && !k.0.iter().any(Value::is_null) {
            return Err(format!("UNIQUE constraint failed: {}", index_desc(t, idx)));
        }
        prev = Some(k.clone());
        entries.insert((k, rid));
    }
    Ok(entries)
}

/// How a uniqueness failure names an index: its columns, or its name for
/// expression indexes.
fn index_desc(t: &Table, idx: &Index) -> String {
    match idx.col_list() {
        Some(cols) => cols
            .iter()
            .map(|&c| t.qualified(c))
            .collect::<Vec<_>>()
            .join(", "),
        None => format!("index '{}'", idx.name),
    }
}

fn contains_subquery(e: &Expr) -> bool {
    let mut found = false;
    schema::walk_expr(e, &mut |x| {
        if matches!(
            x,
            Expr::Subquery(_) | Expr::Exists(_) | Expr::InSelect { .. }
        ) {
            found = true;
        }
    });
    found
}

fn is_rowid_name(name: &str) -> bool {
    ["rowid", "oid", "_rowid_"]
        .iter()
        .any(|n| n.eq_ignore_ascii_case(name))
}

/// Undo log entry for statement atomicity and transactions.
enum Undo {
    Inserted(String, i64),
    Deleted(String, i64, Row),
    Seq(String, i64),
    /// Restore a table (None: remove it).
    Table(String, Option<Box<Table>>),
    View(String, Option<Box<View>>),
}

/// An open transaction: its undo log and savepoints (name, log position).
struct Txn {
    log: Vec<Undo>,
    savepoints: Vec<(String, usize)>,
    /// Started by BEGIN (rather than by a SAVEPOINT).
    explicit: bool,
}

#[derive(Default)]
pub struct Database {
    tables: BTreeMap<String, Table>,
    views: BTreeMap<String, View>,
    txn: Option<Txn>,
    /// Views being expanded (detects circular definitions).
    view_stack: RefCell<Vec<String>>,
    undo: Vec<Undo>,
    total_changes: i64,
    /// Set once a DML statement is past its prepare phase; errors before
    /// that leave changes() alone.
    started: std::cell::Cell<bool>,
    /// Bumped before each RETURNING row: subquery results cached under an
    /// older generation are recomputed.
    pub gen: Cell<u64>,
    /// Header of the database file this was loaded from.
    file_header: Option<[u8; 100]>,
    page_size: usize,
    /// Committed changes not yet written to the file.
    dirty: bool,
    schema_dirty: bool,
}

fn fold(name: &str) -> String {
    name.to_ascii_lowercase()
}

// ---------------------------------------------------------------------
// Bound expressions
// ---------------------------------------------------------------------

#[derive(Debug, Clone)]
pub enum BExpr {
    Lit(Value),
    Col(usize, Affinity, Coll),
    Unary(UnOp, Box<BExpr>),
    Binary(BinOp, Box<BExpr>, Box<BExpr>),
    /// Comparison with the affinity and collation to apply to its operands.
    Cmp(BinOp, Box<BExpr>, Box<BExpr>, Affinity, Coll),
    IsNull(Box<BExpr>),
    NotNull(Box<BExpr>),
    Between {
        expr: Box<BExpr>,
        lo: Box<BExpr>,
        hi: Box<BExpr>,
        not: bool,
        aff_lo: Affinity,
        aff_hi: Affinity,
        coll_lo: Coll,
        coll_hi: Coll,
    },
    InList {
        expr: Box<BExpr>,
        list: Vec<BExpr>,
        not: bool,
        aff: Affinity,
        coll: Coll,
    },
    Case {
        operand: Option<Box<BExpr>>,
        whens: Vec<(BExpr, BExpr, Affinity, Coll)>,
        else_: Option<Box<BExpr>>,
    },
    Cast(Box<BExpr>, Affinity),
    Collate(Box<BExpr>, Coll),
    Func(ScalarFn, Vec<BExpr>, Coll),
    Coalesce(Vec<BExpr>),
    /// Result of an aggregate: the value at this environment slot. The
    /// arguments are kept for collation lookup.
    Agg(usize, Vec<BExpr>),
    /// Slot of an enclosing query's row: (levels up, index, affinity,
    /// collation).
    Outer(usize, usize, Affinity, Option<Coll>),
    Scalar(Rc<SubExpr>),
    Exists(Rc<SubExpr>),
    InSelect {
        expr: Box<BExpr>,
        sub: Rc<SubExpr>,
        not: bool,
        aff: Affinity,
        coll: Coll,
    },
    /// Result of a window function: slot `index` after the shared base.
    Win(usize, Rc<Cell<usize>>),
}

/// Evaluation context: the database (for subqueries) and the rows of the
/// enclosing queries.
#[derive(Clone, Copy, Default)]
pub struct Cx<'a> {
    pub db: Option<&'a Database>,
    pub outer: Option<&'a Frame<'a>>,
}

pub struct Frame<'a> {
    pub row: &'a [Value],
    pub up: Option<&'a Frame<'a>>,
}

fn expr_affinity(e: &BExpr) -> Affinity {
    match e {
        BExpr::Col(_, a, _) => *a,
        BExpr::Cast(_, a) => *a,
        BExpr::Collate(inner, _) => expr_affinity(inner),
        BExpr::Outer(_, _, a, _) => *a,
        BExpr::Scalar(sub) => sub.plan.affs.first().copied().unwrap_or(Affinity::None),
        _ => Affinity::None,
    }
}

fn comparison_affinity(a: Affinity, b: Affinity) -> Affinity {
    if a > Affinity::None && b > Affinity::None {
        if a.is_numeric() || b.is_numeric() {
            Affinity::Numeric
        } else {
            Affinity::Blob
        }
    } else if a == Affinity::None {
        b
    } else {
        a
    }
}

/// Children of an expression as (left operand, argument list, right operand),
/// mirroring SQLite's Expr layout for collation lookup.
fn coll_children(e: &BExpr) -> (Option<&BExpr>, Vec<&BExpr>, Option<&BExpr>) {
    match e {
        BExpr::Unary(_, x)
        | BExpr::IsNull(x)
        | BExpr::NotNull(x)
        | BExpr::Cast(x, _)
        | BExpr::Collate(x, _)
        | BExpr::InSelect { expr: x, .. } => (Some(x), vec![], None),
        BExpr::Binary(_, l, r) | BExpr::Cmp(_, l, r, _, _) => (Some(l), vec![], Some(r)),
        BExpr::Between { expr, lo, hi, .. } => (Some(expr), vec![lo, hi], None),
        BExpr::InList { expr, list, .. } => (Some(expr), list.iter().collect(), None),
        BExpr::Case {
            operand,
            whens,
            else_,
        } => {
            let mut v = Vec::new();
            for (w, t, _, _) in whens {
                v.push(w);
                v.push(t);
            }
            if let Some(x) = else_ {
                v.push(&**x);
            }
            (operand.as_deref(), v, None)
        }
        BExpr::Func(_, args, _) | BExpr::Coalesce(args) | BExpr::Agg(_, args) => {
            (None, args.iter().collect(), None)
        }
        BExpr::Lit(_)
        | BExpr::Col(..)
        | BExpr::Outer(..)
        | BExpr::Scalar(_)
        | BExpr::Exists(_)
        | BExpr::Win(..) => (None, vec![], None),
    }
}

/// SQLite's EP_Collate: the expression contains an explicit COLLATE.
fn has_collate(e: &BExpr) -> bool {
    if let BExpr::Collate(..) = e {
        return true;
    }
    let (l, list, r) = coll_children(e);
    l.is_some_and(has_collate) || list.into_iter().any(has_collate) || r.is_some_and(has_collate)
}

/// SQLite's sqlite3ExprCollSeq.
fn expr_coll(e: &BExpr) -> Option<Coll> {
    let mut p = e;
    loop {
        match p {
            BExpr::Col(_, _, c) => return Some(*c),
            BExpr::Outer(_, _, _, c) => return *c,
            BExpr::Collate(_, c) => return Some(*c),
            BExpr::Cast(x, _) | BExpr::Unary(UnOp::Pos, x) => p = x,
            _ if has_collate(p) => {
                let (l, list, r) = coll_children(p);
                if let Some(l) = l.filter(|l| has_collate(l)) {
                    p = l;
                } else if let Some(x) = list.into_iter().find(|x| has_collate(x)) {
                    p = x;
                } else if let Some(r) = r {
                    p = r;
                } else {
                    return None;
                }
            }
            _ => return None,
        }
    }
}

/// Collation for a binary comparison (sqlite3BinaryCompareCollSeq).
fn binary_coll(l: &BExpr, r: &BExpr) -> Result<Coll, String> {
    let c = if has_collate(l) {
        expr_coll(l)
    } else if has_collate(r) {
        expr_coll(r)
    } else {
        expr_coll(l).or_else(|| expr_coll(r))
    };
    check_coll(c)
}

fn check_coll(c: Option<Coll>) -> Result<Coll, String> {
    match c {
        Some(Coll::Unknown) => Err("no such collation sequence".into()),
        Some(c) => Ok(c),
        None => Ok(Coll::Binary),
    }
}

fn is_constant(e: &BExpr) -> bool {
    if let BExpr::Col(..)
    | BExpr::Agg(..)
    | BExpr::Win(..)
    | BExpr::Outer(..)
    | BExpr::Scalar(_)
    | BExpr::Exists(_)
    | BExpr::InSelect { .. } = e
    {
        return false;
    }
    let (l, list, r) = coll_children(e);
    l.is_none_or(is_constant) && list.into_iter().all(is_constant) && r.is_none_or(is_constant)
}

fn make_cmp(op: BinOp, l: BExpr, r: BExpr) -> Result<BExpr, String> {
    let aff = comparison_affinity(expr_affinity(&l), expr_affinity(&r));
    let coll = binary_coll(&l, &r)?;
    Ok(BExpr::Cmp(op, Box::new(l), Box::new(r), aff, coll))
}

struct Source {
    name: String,
    columns: Vec<String>,
    affinities: Vec<Affinity>,
    colls: Vec<Coll>,
    offset: usize,
    /// Absolute index of the rowid in the evaluation row.
    rowid: Option<usize>,
    /// Only reachable with a table qualifier (upsert's `excluded`).
    qualified_only: bool,
    /// Columns merged into an earlier source's column by USING/NATURAL:
    /// hidden from `*` and from unqualified lookup.
    merged: Vec<bool>,
    /// Right-hand columns of RIGHT/FULL USING joins that an unqualified
    /// reference to this column coalesces with.
    partners: Vec<Vec<(usize, Affinity, Coll)>>,
}

impl Source {
    fn width(&self) -> usize {
        self.columns.len() + self.rowid.is_some() as usize
    }

    /// Expression for column `i`; unqualified references to a USING column
    /// of a RIGHT/FULL join coalesce both sides.
    fn col_expr(&self, i: usize, unqualified: bool) -> BExpr {
        let own = BExpr::Col(self.offset + i, self.affinities[i], self.colls[i]);
        if unqualified && !self.partners[i].is_empty() {
            let mut v = vec![own];
            v.extend(
                self.partners[i]
                    .iter()
                    .map(|&(j, a, c)| BExpr::Col(j, a, c)),
            );
            BExpr::Coalesce(v)
        } else {
            own
        }
    }
}

#[derive(Default)]
struct Scope<'a> {
    db: Option<&'a Database>,
    /// The enclosing query's scope (for correlated references).
    parent: Option<&'a Scope<'a>>,
    sources: Vec<Source>,
    /// Result-column aliases visible as a fallback (ORDER BY).
    aliases: Vec<(String, BExpr)>,
    /// Aggregates collected while binding; None where aggregates are not
    /// allowed.
    agg: RefCell<Option<AggCtx>>,
    /// Set when something bound in this scope refers to an enclosing query.
    corr: Cell<bool>,
    /// Inside RETURNING: subquery results are recomputed for every row.
    volatile: bool,
    /// Result-column aliases usable in WHERE, bound in place when used.
    where_aliases: Vec<(String, Expr)>,
    alias_depth: Cell<usize>,
    /// Common table expressions visible here.
    ctes: Option<Rc<query::CteEnv>>,
    /// Window functions collected while binding; None where they are not
    /// allowed.
    win: RefCell<Option<window::WinCtx>>,
}

struct AggCtx {
    /// Environment slot of the first aggregate result.
    base: usize,
    calls: Vec<AggCall>,
    /// Nonzero while binding the arguments of an aggregate.
    depth: usize,
}

fn has_agg(e: &BExpr) -> bool {
    if let BExpr::Agg(..) = e {
        return true;
    }
    let (l, list, r) = coll_children(e);
    l.is_some_and(has_agg) || list.into_iter().any(has_agg) || r.is_some_and(has_agg)
}

/// Column references of an expression, not descending into subqueries.
fn expr_columns<'e>(e: &'e Expr, out: &mut Vec<(Option<&'e str>, &'e str)>) {
    match e {
        Expr::Lit(_) | Expr::Subquery(_) | Expr::Exists(_) => {}
        Expr::Column { table, name, .. } => out.push((table.as_deref(), name)),
        Expr::Unary(_, x)
        | Expr::IsNull(x)
        | Expr::NotNull(x)
        | Expr::Cast(x, _)
        | Expr::Collate(x, _) => expr_columns(x, out),
        Expr::InSelect { expr, .. } => expr_columns(expr, out),
        Expr::Binary(_, l, r) => {
            expr_columns(l, out);
            expr_columns(r, out);
        }
        Expr::Between { expr, lo, hi, .. } => {
            expr_columns(expr, out);
            expr_columns(lo, out);
            expr_columns(hi, out);
        }
        Expr::InList { expr, list, .. } => {
            expr_columns(expr, out);
            list.iter().for_each(|x| expr_columns(x, out));
        }
        Expr::Like {
            expr,
            pattern,
            escape,
            ..
        } => {
            expr_columns(expr, out);
            expr_columns(pattern, out);
            if let Some(x) = escape {
                expr_columns(x, out);
            }
        }
        Expr::Case {
            operand,
            whens,
            else_,
        } => {
            if let Some(x) = operand {
                expr_columns(x, out);
            }
            for (w, t) in whens {
                expr_columns(w, out);
                expr_columns(t, out);
            }
            if let Some(x) = else_ {
                expr_columns(x, out);
            }
        }
        Expr::Func {
            args,
            filter,
            order_by,
            ..
        } => {
            args.iter().for_each(|x| expr_columns(x, out));
            if let Some(x) = filter {
                expr_columns(x, out);
            }
            order_by.iter().for_each(|t| expr_columns(&t.expr, out));
        }
    }
}

/// Bind an aggregate call. It belongs to the innermost enclosing query whose
/// columns it references (the current one if it references none).
fn bind_agg(
    kind: AggKind,
    name: &str,
    args: &[Expr],
    distinct: bool,
    filter: Option<&Expr>,
    order_by: &[OrderTerm],
    scope: &Scope,
) -> Result<BExpr, String> {
    let mut cols = Vec::new();
    args.iter().for_each(|a| expr_columns(a, &mut cols));
    if let Some(f) = filter {
        expr_columns(f, &mut cols);
    }
    let levels: Vec<usize> = cols
        .iter()
        .filter_map(|(t, n)| scope.find_level(*t, n))
        .collect();
    let level = if levels.contains(&0) {
        0
    } else {
        levels.into_iter().min().unwrap_or(0)
    };
    if level == 0 {
        return bind_agg_here(kind, name, args, distinct, filter, order_by, scope);
    }
    let mut target = scope;
    for _ in 0..level {
        target = target.parent.unwrap();
    }
    let e = bind_agg_here(kind, name, args, distinct, filter, order_by, target)?;
    scope.mark_corr(level);
    match e {
        BExpr::Agg(slot, _) => Ok(BExpr::Outer(level, slot, Affinity::None, None)),
        _ => unreachable!(),
    }
}

/// Bind an aggregate call, registering it in the scope's aggregate context.
fn bind_agg_here(
    kind: AggKind,
    name: &str,
    args: &[Expr],
    distinct: bool,
    filter: Option<&Expr>,
    order_by: &[OrderTerm],
    scope: &Scope,
) -> Result<BExpr, String> {
    {
        let mut ctx = scope.agg.borrow_mut();
        match ctx.as_mut() {
            Some(c) if c.depth == 0 => c.depth += 1,
            _ => return Err(format!("misuse of aggregate function {}()", name)),
        }
    }
    let r = (|| -> Result<AggCall, String> {
        let ba = bind_all(args, scope)?;
        let filter = match filter {
            Some(f) => Some(bind(f, scope)?),
            None => None,
        };
        let mut order = Vec::new();
        for t in order_by {
            let e = bind(&t.expr, scope)?;
            let coll = check_coll(expr_coll(&e))?;
            order.push((e, t.desc, t.nulls_first, coll));
        }
        let coll = match ba.first() {
            Some(a) => check_coll(expr_coll(a))?,
            None => Coll::Binary,
        };
        Ok(AggCall {
            kind,
            args: ba,
            distinct,
            coll,
            filter,
            order,
        })
    })();
    let mut ctx = scope.agg.borrow_mut();
    let c = ctx.as_mut().unwrap();
    c.depth -= 1;
    let call = r?;
    let slot = c.base + c.calls.len();
    let args = call.args.clone();
    c.calls.push(call);
    Ok(BExpr::Agg(slot, args))
}

fn to_outer(e: BExpr, depth: usize) -> BExpr {
    match e {
        BExpr::Col(i, a, c) => BExpr::Outer(depth, i, a, Some(c)),
        BExpr::Coalesce(v) => BExpr::Coalesce(v.into_iter().map(|x| to_outer(x, depth)).collect()),
        other => other,
    }
}

impl Scope<'_> {
    /// Resolve a column name: this query's sources, then its result aliases,
    /// then the enclosing queries.
    fn resolve(&self, table: Option<&str>, name: &str) -> Result<Option<BExpr>, String> {
        if let Some(e) = self.resolve_local(table, name)? {
            return Ok(Some(e));
        }
        if table.is_none() {
            let lname = fold(name);
            if let Some((_, e)) = self.aliases.iter().find(|(a, _)| fold(a) == lname) {
                return Ok(Some(e.clone()));
            }
            if let Some((_, e)) = self.where_aliases.iter().find(|(a, _)| fold(a) == lname) {
                if self.alias_depth.get() < 8 {
                    self.alias_depth.set(self.alias_depth.get() + 1);
                    let r = bind(e, self);
                    self.alias_depth.set(self.alias_depth.get() - 1);
                    return r.map(Some);
                }
            }
        }
        let mut depth = 1;
        let mut s = self.parent;
        while let Some(p) = s {
            if let Some(e) = p.resolve_local(table, name)? {
                self.mark_corr(depth);
                return Ok(Some(to_outer(e, depth)));
            }
            s = p.parent;
            depth += 1;
        }
        Ok(None)
    }

    /// Mark this scope and the enclosing ones below `depth` as correlated.
    fn mark_corr(&self, depth: usize) {
        let mut s = Some(self);
        for _ in 0..depth {
            if let Some(x) = s {
                x.corr.set(true);
                s = x.parent;
            }
        }
    }

    /// How many levels up a column reference resolves.
    fn find_level(&self, table: Option<&str>, name: &str) -> Option<usize> {
        if matches!(self.resolve_local(table, name), Ok(Some(_))) {
            return Some(0);
        }
        if table.is_none() && self.aliases.iter().any(|(a, _)| fold(a) == fold(name)) {
            return Some(0);
        }
        let mut depth = 1;
        let mut s = self.parent;
        while let Some(p) = s {
            if matches!(p.resolve_local(table, name), Ok(Some(_))) {
                return Some(depth);
            }
            s = p.parent;
            depth += 1;
        }
        None
    }

    fn resolve_local(&self, table: Option<&str>, name: &str) -> Result<Option<BExpr>, String> {
        let lname = fold(name);
        let mut found = None;
        for s in &self.sources {
            match table {
                Some(t) if fold(t) != s.name => continue,
                None if s.qualified_only => continue,
                _ => {}
            }
            for (i, c) in s.columns.iter().enumerate() {
                if fold(c) == lname {
                    if table.is_none() && s.merged[i] {
                        continue;
                    }
                    if found.is_some() {
                        return Err(format!("ambiguous column name: {}", name));
                    }
                    found = Some(s.col_expr(i, table.is_none()));
                }
            }
        }
        if found.is_none() && is_rowid_name(name) {
            for s in &self.sources {
                match table {
                    Some(t) if fold(t) != s.name => continue,
                    None if s.qualified_only => continue,
                    _ => {}
                }
                if let Some(r) = s.rowid {
                    if found.is_some() {
                        return Err(format!("ambiguous column name: {}", name));
                    }
                    found = Some(BExpr::Col(r, Affinity::Integer, Coll::Binary));
                }
            }
        }
        Ok(found)
    }
}

fn bind_all(es: &[Expr], scope: &Scope) -> Result<Vec<BExpr>, String> {
    es.iter().map(|e| bind(e, scope)).collect()
}

fn bind(e: &Expr, scope: &Scope) -> Result<BExpr, String> {
    Ok(match e {
        Expr::Lit(v) => BExpr::Lit(v.clone()),
        Expr::Column { table, name, dq } => match scope.resolve(table.as_deref(), name)? {
            Some(c) => c,
            None => {
                if *dq && table.is_none() {
                    BExpr::Lit(Value::Text(name.clone()))
                } else if let Some(t) = table {
                    return Err(format!("no such column: {}.{}", t, name));
                } else {
                    return Err(format!("no such column: {}", name));
                }
            }
        },
        Expr::Unary(op, x) => BExpr::Unary(*op, Box::new(bind(x, scope)?)),
        Expr::Binary(op, l, r) => {
            let bl = bind(l, scope)?;
            let br = bind(r, scope)?;
            if op.is_comparison() {
                make_cmp(*op, bl, br)?
            } else {
                BExpr::Binary(*op, Box::new(bl), Box::new(br))
            }
        }
        Expr::IsNull(x) => BExpr::IsNull(Box::new(bind(x, scope)?)),
        Expr::NotNull(x) => BExpr::NotNull(Box::new(bind(x, scope)?)),
        Expr::Between { expr, lo, hi, not } => {
            let be = bind(expr, scope)?;
            let bl = bind(lo, scope)?;
            let bh = bind(hi, scope)?;
            let ea = expr_affinity(&be);
            let aff_lo = comparison_affinity(ea, expr_affinity(&bl));
            let aff_hi = comparison_affinity(ea, expr_affinity(&bh));
            let coll_lo = binary_coll(&be, &bl)?;
            let coll_hi = binary_coll(&be, &bh)?;
            BExpr::Between {
                expr: Box::new(be),
                lo: Box::new(bl),
                hi: Box::new(bh),
                not: *not,
                aff_lo,
                aff_hi,
                coll_lo,
                coll_hi,
            }
        }
        Expr::InList { expr, list, not } => {
            let be = bind(expr, scope)?;
            let bl = bind_all(list, scope)?;
            if bl.is_empty() {
                return Ok(BExpr::Lit(Value::Integer(*not as i64)));
            }
            if bl.len() == 1 && is_constant(&bl[0]) {
                // x IN (const) is rewritten as x = +const.
                let rhs = BExpr::Unary(UnOp::Pos, Box::new(bl.into_iter().next().unwrap()));
                let cmp = make_cmp(BinOp::Eq, be, rhs)?;
                return Ok(if *not {
                    BExpr::Unary(UnOp::Not, Box::new(cmp))
                } else {
                    cmp
                });
            }
            let aff = expr_affinity(&be);
            let coll = check_coll(expr_coll(&be))?;
            BExpr::InList {
                expr: Box::new(be),
                list: bl,
                not: *not,
                aff,
                coll,
            }
        }
        Expr::Like {
            op,
            expr,
            pattern,
            escape,
            not,
        } => {
            let fname = match op {
                LikeOp::Like => "like",
                LikeOp::Glob => "glob",
                LikeOp::Regexp => "regexp",
                LikeOp::Match => "match",
            };
            let mut args = vec![(**pattern).clone(), (**expr).clone()];
            if let Some(e) = escape {
                args.push((**e).clone());
            }
            let call = Expr::Func {
                name: fname.to_string(),
                args,
                distinct: false,
                star: false,
                filter: None,
                order_by: vec![],
                over: None,
            };
            let b = bind(&call, scope)?;
            if *not {
                BExpr::Unary(UnOp::Not, Box::new(b))
            } else {
                b
            }
        }
        Expr::Case {
            operand,
            whens,
            else_,
        } => {
            let operand = match operand {
                Some(o) => Some(Box::new(bind(o, scope)?)),
                None => None,
            };
            let mut bw = Vec::new();
            for (w, t) in whens {
                let bwv = bind(w, scope)?;
                let (aff, coll) = match &operand {
                    Some(o) => (
                        comparison_affinity(expr_affinity(o), expr_affinity(&bwv)),
                        binary_coll(o, &bwv)?,
                    ),
                    None => (Affinity::None, Coll::Binary),
                };
                bw.push((bwv, bind(t, scope)?, aff, coll));
            }
            let else_ = match else_ {
                Some(x) => Some(Box::new(bind(x, scope)?)),
                None => None,
            };
            BExpr::Case {
                operand,
                whens: bw,
                else_,
            }
        }
        Expr::Subquery(q) => {
            let sub = query::compile_sub(q, scope)?;
            if sub.plan.ncols != 1 {
                return Err(format!(
                    "sub-select returns {} columns - expected 1",
                    sub.plan.ncols
                ));
            }
            BExpr::Scalar(Rc::new(sub))
        }
        Expr::Exists(q) => BExpr::Exists(Rc::new(query::compile_sub(q, scope)?)),
        Expr::InSelect {
            expr,
            query: q,
            not,
        } => {
            let be = bind(expr, scope)?;
            let sub = query::compile_sub(q, scope)?;
            if sub.plan.ncols != 1 {
                return Err(format!(
                    "sub-select returns {} columns - expected 1",
                    sub.plan.ncols
                ));
            }
            let aff = comparison_affinity(expr_affinity(&be), sub.plan.affs[0]);
            let coll = match sub.plan.first_expr() {
                Some(r) => binary_coll(&be, r)?,
                None => check_coll(expr_coll(&be))?,
            };
            BExpr::InSelect {
                expr: Box::new(be),
                sub: Rc::new(sub),
                not: *not,
                aff,
                coll,
            }
        }
        Expr::Cast(x, t) => BExpr::Cast(Box::new(bind(x, scope)?), affinity_of_type(t)),
        Expr::Collate(x, c) => BExpr::Collate(
            Box::new(bind(x, scope)?),
            Coll::from_name(c).unwrap_or(Coll::Unknown),
        ),
        Expr::Func {
            name,
            args,
            distinct,
            star,
            filter,
            order_by,
            over,
        } => {
            let lname = fold(name);
            if let Some(spec) = over {
                return window::bind_window(e, spec, scope);
            }
            if window::is_window_only(&lname) {
                return Err(format!("misuse of window function {}()", name));
            }
            let wrong = || format!("wrong number of arguments to function {}()", name);
            if let Some(kind) = AggKind::from_call(&lname, args.len(), *star) {
                let (lo, hi) = kind.arg_range(&lname);
                if args.len() < lo || args.len() > hi || (*star && kind != AggKind::CountStar) {
                    return Err(wrong());
                }
                if *distinct && args.len() != 1 {
                    return Err("DISTINCT aggregates must have exactly one argument".into());
                }
                return bind_agg(
                    kind,
                    &lname,
                    args,
                    *distinct,
                    filter.as_deref(),
                    order_by,
                    scope,
                );
            }
            if filter.is_some() {
                return Err(format!(
                    "FILTER may not be used with non-aggregate {}()",
                    name
                ));
            }
            if !order_by.is_empty() {
                return Err(format!(
                    "ORDER BY may not be used with non-aggregate {}()",
                    name
                ));
            }
            match lname.as_str() {
                "coalesce" | "ifnull" => {
                    if *star || args.len() < 2 || (lname == "ifnull" && args.len() != 2) {
                        return Err(wrong());
                    }
                    return Ok(BExpr::Coalesce(bind_all(args, scope)?));
                }
                "iif" | "if" => {
                    if *star || args.len() < 2 || args.len() > 3 {
                        return Err(wrong());
                    }
                    let mut ba = bind_all(args, scope)?.into_iter();
                    let c = ba.next().unwrap();
                    let t = ba.next().unwrap();
                    let else_ = ba.next().map(Box::new);
                    return Ok(BExpr::Case {
                        operand: None,
                        whens: vec![(c, t, Affinity::None, Coll::Binary)],
                        else_,
                    });
                }
                _ => {}
            }
            let (min, max, f) =
                func::lookup(&lname).ok_or_else(|| format!("no such function: {}", name))?;
            if *star || args.len() < min || max.is_some_and(|m| args.len() > m) {
                return Err(wrong());
            }
            if *distinct {
                return Err("DISTINCT aggregates must have exactly one argument".into());
            }
            let ba = bind_all(args, scope)?;
            if lname == "likelihood" {
                let ok = match &ba[1] {
                    BExpr::Lit(v @ (Value::Integer(_) | Value::Real(_))) => {
                        (0.0..=1.0).contains(&v.to_f64())
                    }
                    _ => false,
                };
                if !ok {
                    return Err(
                        "second argument to likelihood() must be a constant between 0.0 and 1.0"
                            .into(),
                    );
                }
            }
            let coll = if func::needs_coll(&lname) {
                check_coll(ba.iter().find_map(expr_coll))?
            } else {
                Coll::Binary
            };
            BExpr::Func(f, ba, coll)
        }
    })
}

// ---------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------

fn bool_val(b: bool) -> Value {
    Value::Integer(b as i64)
}

fn arith(op: BinOp, a: &Value, b: &Value) -> Value {
    let a = a.to_numeric();
    let b = b.to_numeric();
    if a.is_null() || b.is_null() {
        return Value::Null;
    }
    if let (Value::Integer(x), Value::Integer(y)) = (&a, &b) {
        let (x, y) = (*x, *y);
        let r = match op {
            BinOp::Add => x.checked_add(y),
            BinOp::Sub => x.checked_sub(y),
            BinOp::Mul => x.checked_mul(y),
            BinOp::Div => {
                if y == 0 {
                    return Value::Null;
                }
                x.checked_div(y)
            }
            BinOp::Rem => {
                if y == 0 {
                    return Value::Null;
                }
                Some(x % if y == -1 { 1 } else { y })
            }
            _ => unreachable!(),
        };
        if let Some(r) = r {
            return Value::Integer(r);
        }
    }
    let (x, y) = (a.to_f64(), b.to_f64());
    let r = match op {
        BinOp::Add => x + y,
        BinOp::Sub => x - y,
        BinOp::Mul => x * y,
        BinOp::Div => {
            if y == 0.0 {
                return Value::Null;
            }
            x / y
        }
        BinOp::Rem => {
            let ia = a.to_i64();
            let ib = b.to_i64();
            if ib == 0 {
                return Value::Null;
            }
            (ia % if ib == -1 { 1 } else { ib }) as f64
        }
        _ => unreachable!(),
    };
    if r.is_nan() {
        Value::Null
    } else {
        Value::Real(r)
    }
}

pub(crate) fn apply_cmp_affinity(v: Value, aff: Affinity) -> Value {
    if aff.is_numeric() {
        if let Value::Text(s) = &v {
            if let Some(n) = text_numeric_affinity(s, false) {
                return n;
            }
        }
        v
    } else if aff == Affinity::Text {
        match v {
            Value::Integer(_) | Value::Real(_) => Value::Text(v.to_text().unwrap()),
            other => other,
        }
    } else {
        v
    }
}

fn compare_with_affinity(a: Value, b: Value, aff: Affinity, coll: Coll) -> Ordering {
    let a = apply_cmp_affinity(a, aff);
    let b = apply_cmp_affinity(b, aff);
    compare_values_coll(&a, &b, coll)
}

fn cast_value(v: Value, aff: Affinity) -> Value {
    if v.is_null() {
        return v;
    }
    match aff {
        Affinity::Blob | Affinity::None => match v {
            Value::Blob(_) => v,
            other => Value::Blob(other.to_text().unwrap().into_bytes()),
        },
        Affinity::Text => Value::Text(v.to_text().unwrap()),
        Affinity::Integer => Value::Integer(v.to_i64()),
        Affinity::Real => Value::Real(v.to_f64()),
        Affinity::Numeric => match v {
            Value::Integer(_) | Value::Real(_) => v,
            Value::Text(ref s) => numerify(s.as_bytes()),
            Value::Blob(ref b) => numerify(b),
            Value::Null => Value::Null,
        },
    }
}

fn numerify(z: &[u8]) -> Value {
    let (rc, r) = atof(z);
    let (irc, ix) = atoi64(z);
    if (rc == 0 || rc == 1) && irc <= 1 {
        return Value::Integer(ix);
    }
    let ix = real_to_i64(r);
    if r == ix as f64 && r.abs() < 9.2e18 {
        Value::Integer(ix)
    } else {
        Value::Real(r)
    }
}

pub fn eval(e: &BExpr, row: &[Value], cx: Cx) -> Result<Value, String> {
    Ok(match e {
        BExpr::Lit(v) => v.clone(),
        BExpr::Col(i, _, _) => row[*i].clone(),
        BExpr::Unary(op, x) => {
            let v = eval(x, row, cx)?;
            match op {
                UnOp::Pos => v,
                UnOp::Neg => arith(BinOp::Sub, &Value::Integer(0), &v),
                UnOp::Not => match v.truthy() {
                    None => Value::Null,
                    Some(b) => bool_val(!b),
                },
                UnOp::BitNot => match v.to_numeric() {
                    Value::Null => Value::Null,
                    n => Value::Integer(!n.to_i64()),
                },
            }
        }
        BExpr::Binary(op, l, r) => match op {
            BinOp::And => {
                let a = eval(l, row, cx)?.truthy();
                if a == Some(false) {
                    return Ok(bool_val(false));
                }
                let b = eval(r, row, cx)?.truthy();
                match (a, b) {
                    (_, Some(false)) => bool_val(false),
                    (Some(true), Some(true)) => bool_val(true),
                    _ => Value::Null,
                }
            }
            BinOp::Or => {
                let a = eval(l, row, cx)?.truthy();
                if a == Some(true) {
                    return Ok(bool_val(true));
                }
                let b = eval(r, row, cx)?.truthy();
                match (a, b) {
                    (_, Some(true)) => bool_val(true),
                    (Some(false), Some(false)) => bool_val(false),
                    _ => Value::Null,
                }
            }
            BinOp::Concat => {
                let a = eval(l, row, cx)?;
                let b = eval(r, row, cx)?;
                match (a.to_text(), b.to_text()) {
                    (Some(x), Some(y)) => Value::Text(x + &y),
                    _ => Value::Null,
                }
            }
            BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Rem => {
                let a = eval(l, row, cx)?;
                let b = eval(r, row, cx)?;
                arith(*op, &a, &b)
            }
            BinOp::BitAnd | BinOp::BitOr | BinOp::Shl | BinOp::Shr => {
                let a = eval(l, row, cx)?.to_numeric();
                let b = eval(r, row, cx)?.to_numeric();
                if a.is_null() || b.is_null() {
                    return Ok(Value::Null);
                }
                let (x, y) = (a.to_i64(), b.to_i64());
                Value::Integer(match op {
                    BinOp::BitAnd => x & y,
                    BinOp::BitOr => x | y,
                    BinOp::Shl => shift_left(x, y),
                    _ => shift_left(x, y.checked_neg().unwrap_or(i64::MAX)),
                })
            }
            _ => unreachable!("comparison is bound as Cmp"),
        },
        BExpr::Cmp(op, l, r, aff, coll) => {
            let a = eval(l, row, cx)?;
            let b = eval(r, row, cx)?;
            match op {
                BinOp::Is | BinOp::IsNot => {
                    let eq = match (a.is_null(), b.is_null()) {
                        (true, true) => true,
                        (true, false) | (false, true) => false,
                        _ => compare_with_affinity(a, b, *aff, *coll) == Ordering::Equal,
                    };
                    bool_val(if *op == BinOp::Is { eq } else { !eq })
                }
                _ => {
                    if a.is_null() || b.is_null() {
                        return Ok(Value::Null);
                    }
                    let o = compare_with_affinity(a, b, *aff, *coll);
                    bool_val(match op {
                        BinOp::Eq => o == Ordering::Equal,
                        BinOp::Ne => o != Ordering::Equal,
                        BinOp::Lt => o == Ordering::Less,
                        BinOp::Le => o != Ordering::Greater,
                        BinOp::Gt => o == Ordering::Greater,
                        BinOp::Ge => o != Ordering::Less,
                        _ => unreachable!(),
                    })
                }
            }
        }
        BExpr::IsNull(x) => bool_val(eval(x, row, cx)?.is_null()),
        BExpr::NotNull(x) => bool_val(!eval(x, row, cx)?.is_null()),
        BExpr::Between {
            expr,
            lo,
            hi,
            not,
            aff_lo,
            aff_hi,
            coll_lo,
            coll_hi,
        } => {
            let v = eval(expr, row, cx)?;
            let l = eval(lo, row, cx)?;
            let h = eval(hi, row, cx)?;
            let ge = if v.is_null() || l.is_null() {
                None
            } else {
                Some(compare_with_affinity(v.clone(), l, *aff_lo, *coll_lo) != Ordering::Less)
            };
            let le = if v.is_null() || h.is_null() {
                None
            } else {
                Some(compare_with_affinity(v, h, *aff_hi, *coll_hi) != Ordering::Greater)
            };
            let r = match (ge, le) {
                (Some(false), _) | (_, Some(false)) => Some(false),
                (Some(true), Some(true)) => Some(true),
                _ => None,
            };
            match r {
                None => Value::Null,
                Some(b) => bool_val(b != *not),
            }
        }
        BExpr::InList {
            expr,
            list,
            not,
            aff,
            coll,
        } => {
            let v = eval(expr, row, cx)?;
            if v.is_null() {
                return Ok(Value::Null);
            }
            let mut saw_null = false;
            let mut found = false;
            for x in list {
                let xv = eval(x, row, cx)?;
                if xv.is_null() {
                    saw_null = true;
                    continue;
                }
                if compare_with_affinity(v.clone(), xv, *aff, *coll) == Ordering::Equal {
                    found = true;
                    break;
                }
            }
            if found {
                bool_val(!*not)
            } else if saw_null {
                Value::Null
            } else {
                bool_val(*not)
            }
        }
        BExpr::Case {
            operand,
            whens,
            else_,
        } => {
            let base = match operand {
                Some(o) => Some(eval(o, row, cx)?),
                None => None,
            };
            for (w, t, aff, coll) in whens {
                let wv = eval(w, row, cx)?;
                let hit = match &base {
                    Some(b) => {
                        !b.is_null()
                            && !wv.is_null()
                            && compare_with_affinity(b.clone(), wv, *aff, *coll) == Ordering::Equal
                    }
                    None => wv.truthy() == Some(true),
                };
                if hit {
                    return eval(t, row, cx);
                }
            }
            match else_ {
                Some(x) => eval(x, row, cx)?,
                None => Value::Null,
            }
        }
        BExpr::Cast(x, aff) => cast_value(eval(x, row, cx)?, *aff),
        BExpr::Collate(x, _) => eval(x, row, cx)?,
        BExpr::Func(f, args, coll) => {
            let mut vals = Vec::with_capacity(args.len());
            for a in args {
                vals.push(eval(a, row, cx)?);
            }
            f(&vals, *coll)?
        }
        BExpr::Agg(i, _) => row[*i].clone(),
        BExpr::Win(i, base) => match row.get(base.get() + *i) {
            Some(v) => v.clone(),
            None => return Err("misuse of window function".into()),
        },
        BExpr::Outer(d, i, _, _) => {
            let mut f = cx.outer.ok_or_else(|| "no outer row".to_string())?;
            for _ in 1..*d {
                f = f.up.ok_or_else(|| "no outer row".to_string())?;
            }
            f.row.get(*i).cloned().unwrap_or(Value::Null)
        }
        BExpr::Scalar(sub) => query::eval_scalar(sub, row, cx)?,
        BExpr::Exists(sub) => query::eval_exists(sub, row, cx)?,
        BExpr::InSelect {
            expr,
            sub,
            not,
            aff,
            coll,
        } => {
            let v = eval(expr, row, cx)?;
            query::eval_in(sub, v, *not, *aff, *coll, row, cx)?
        }
        BExpr::Coalesce(args) => {
            for a in args {
                let v = eval(a, row, cx)?;
                if !v.is_null() {
                    return Ok(v);
                }
            }
            Value::Null
        }
    })
}

fn shift_left(x: i64, n: i64) -> i64 {
    if n >= 64 {
        0
    } else if n >= 0 {
        ((x as u64) << n) as i64
    } else if n <= -64 {
        if x < 0 {
            -1
        } else {
            0
        }
    } else {
        x >> (-n)
    }
}

// ---------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------

/// A statement failure; `keep` means the changes made so far stay (OR FAIL).
struct StmtErr {
    msg: String,
    keep: bool,
    /// ON CONFLICT ROLLBACK: the whole transaction is rolled back.
    txn: bool,
}

impl From<String> for StmtErr {
    fn from(msg: String) -> Self {
        StmtErr {
            msg,
            keep: false,
            txn: false,
        }
    }
}

type SResult<T> = Result<T, StmtErr>;

fn constraint_err(msg: String, action: ConflictAction) -> StmtErr {
    StmtErr {
        msg,
        keep: action == ConflictAction::Fail,
        txn: action == ConflictAction::Rollback,
    }
}

fn mismatch() -> StmtErr {
    StmtErr::from("datatype mismatch".to_string())
}

enum SortKey {
    Result(usize),
    Expr(BExpr),
}

enum BUpsertAction {
    Nothing,
    /// SET targets are column indexes (`ncols` = the rowid).
    Update {
        sets: Vec<(usize, BExpr)>,
        where_: Option<BExpr>,
    },
}

struct BUpsert {
    /// Sorted column indexes of the conflict target; None = any constraint.
    target: Option<Vec<usize>>,
    action: BUpsertAction,
}

#[derive(Clone, Copy, PartialEq)]
enum UKey {
    Rowid,
    Index(usize),
}

#[derive(Clone, Copy, PartialEq)]
enum Resolution {
    Act(ConflictAction),
    Upsert(usize),
}

enum WriteResult {
    Written(i64, Row),
    Skipped,
    /// Uniqueness conflict handled by the given DO UPDATE clause.
    Conflict(usize, i64),
}

/// Row-level writes to one table with undo logging and constraint checks.
struct Writer<'a> {
    t: &'a mut Table,
    undo: &'a mut Vec<Undo>,
    key: &'a str,
    changes: &'a mut i64,
}

impl Writer<'_> {
    fn insert_raw(&mut self, rowid: i64, row: Row) -> SResult<()> {
        self.t.insert_raw(rowid, row)?;
        self.undo.push(Undo::Inserted(self.key.to_string(), rowid));
        Ok(())
    }

    fn delete_raw(&mut self, rowid: i64) -> Option<Row> {
        let row = self.t.delete_raw(rowid)?;
        self.undo
            .push(Undo::Deleted(self.key.to_string(), rowid, row.clone()));
        Some(row)
    }

    /// AUTOINCREMENT: every rowid chosen for an insert raises the sequence,
    /// even if the row is then skipped.
    fn bump_seq(&mut self, rowid: i64) {
        if self.t.autoinc && rowid > self.t.seq {
            self.undo.push(Undo::Seq(self.key.to_string(), self.t.seq));
            self.t.seq = rowid;
        }
    }

    fn new_rowid(&self) -> SResult<i64> {
        let max = self.t.rows.keys().next_back().copied().unwrap_or(0);
        let base = if self.t.autoinc {
            max.max(self.t.seq)
        } else {
            max
        };
        if base < i64::MAX {
            return Ok(base + 1);
        }
        if self.t.autoinc {
            return Err(StmtErr::from("database or disk is full".to_string()));
        }
        (1..i64::MAX)
            .find(|r| !self.t.rows.contains_key(r))
            .ok_or_else(|| StmtErr::from("database or disk is full".to_string()))
    }

    fn resolve(
        &self,
        cols: Option<Vec<usize>>,
        own: Option<ConflictAction>,
        or_action: Option<ConflictAction>,
        upserts: &[BUpsert],
    ) -> Resolution {
        let sorted = cols.map(|mut c| {
            c.sort_unstable();
            c
        });
        for (i, u) in upserts.iter().enumerate() {
            match &u.target {
                None => return Resolution::Upsert(i),
                Some(tc) if Some(tc) == sorted.as_ref() => return Resolution::Upsert(i),
                _ => {}
            }
        }
        Resolution::Act(or_action.or(own).unwrap_or(ConflictAction::Abort))
    }

    /// Check constraints for a new version of a row and store it. `old` is
    /// the rowid of the row being updated (None for an insert).
    fn write_row(
        &mut self,
        old: Option<i64>,
        rowid: i64,
        mut row: Row,
        or_action: Option<ConflictAction>,
        upserts: &[BUpsert],
    ) -> SResult<WriteResult> {
        use ConflictAction as CA;
        // NOT NULL
        for i in 0..row.len() {
            let c = &self.t.columns[i];
            if Some(i) == self.t.ipk || !c.not_null || !row[i].is_null() {
                continue;
            }
            let msg = format!("NOT NULL constraint failed: {}", self.t.qualified(i));
            match or_action.or(c.not_null_conflict).unwrap_or(CA::Abort) {
                CA::Ignore => return Ok(WriteResult::Skipped),
                CA::Replace => {
                    if let Some(d) = &c.default {
                        let v = apply_affinity(eval(d, &[], Cx::default())?, c.affinity);
                        if !v.is_null() {
                            row[i] = v;
                            continue;
                        }
                    }
                    return Err(constraint_err(msg, CA::Abort));
                }
                a => return Err(constraint_err(msg, a)),
            }
        }
        // CHECK
        if !self.t.checks.is_empty() {
            let mut env = row.clone();
            env.push(Value::Integer(rowid));
            for (e, name) in &self.t.checks {
                if eval(e, &env, Cx::default())?.truthy() == Some(false) {
                    let msg = format!("CHECK constraint failed: {}", name);
                    match or_action.unwrap_or(CA::Abort) {
                        CA::Ignore => return Ok(WriteResult::Skipped),
                        CA::Replace => return Err(constraint_err(msg, CA::Abort)),
                        a => return Err(constraint_err(msg, a)),
                    }
                }
            }
        }
        // Uniqueness, in SQLite's order: upsert targets, then the rowid,
        // then indexes (most recently declared first), REPLACE ones last.
        let mut all: Vec<(UKey, Resolution)> = Vec::new();
        let mut deferred_rowid = None;
        if old != Some(rowid) {
            let cols: Vec<usize> = self.t.ipk.into_iter().collect();
            let res = self.resolve(Some(cols), self.t.ipk_conflict, or_action, upserts);
            let has_unique = self.t.indexes.iter().any(|i| i.unique);
            if res == Resolution::Act(CA::Replace) && or_action != Some(CA::Replace) && has_unique {
                deferred_rowid = Some((UKey::Rowid, res));
            } else {
                all.push((UKey::Rowid, res));
            }
        }
        for i in (0..self.t.indexes.len()).rev() {
            let idx = &self.t.indexes[i];
            if idx.unique {
                all.push((
                    UKey::Index(i),
                    self.resolve(idx.col_list(), idx.conflict, or_action, upserts),
                ));
            }
        }
        let mut order: Vec<(UKey, Resolution)> = Vec::new();
        for ui in 0..upserts.len() {
            if upserts[ui].target.is_some() {
                order.extend(
                    all.iter()
                        .filter(|(_, r)| *r == Resolution::Upsert(ui))
                        .copied(),
                );
            }
        }
        let targeted =
            |r: &Resolution| matches!(r, Resolution::Upsert(ui) if upserts[*ui].target.is_some());
        order.extend(
            all.iter()
                .filter(|(_, r)| !targeted(r) && *r != Resolution::Act(CA::Replace))
                .copied(),
        );
        order.extend(
            all.iter()
                .filter(|(_, r)| *r == Resolution::Act(CA::Replace))
                .copied(),
        );
        order.extend(deferred_rowid);

        for (uk, res) in order {
            let (conflicts, msg) = match uk {
                UKey::Rowid => {
                    if !self.t.rows.contains_key(&rowid) {
                        continue;
                    }
                    let name = match self.t.ipk {
                        Some(p) => self.t.qualified(p),
                        None => format!("{}.rowid", self.t.name),
                    };
                    (vec![rowid], name)
                }
                UKey::Index(i) => {
                    let idx = &self.t.indexes[i];
                    let Some(key) = idx.key(&row, rowid)? else {
                        continue;
                    };
                    if key.0.iter().any(Value::is_null) {
                        continue;
                    }
                    let found: Vec<i64> = idx
                        .find(&key)
                        .into_iter()
                        .filter(|r| Some(*r) != old)
                        .collect();
                    if found.is_empty() {
                        continue;
                    }
                    (found, index_desc(self.t, idx))
                }
            };
            let msg = format!("UNIQUE constraint failed: {}", msg);
            match res {
                Resolution::Upsert(ui) => {
                    return Ok(match upserts[ui].action {
                        BUpsertAction::Nothing => WriteResult::Skipped,
                        BUpsertAction::Update { .. } => WriteResult::Conflict(ui, conflicts[0]),
                    })
                }
                Resolution::Act(CA::Ignore) => return Ok(WriteResult::Skipped),
                Resolution::Act(CA::Replace) => {
                    for r in conflicts {
                        self.delete_raw(r);
                    }
                }
                Resolution::Act(a) => return Err(constraint_err(msg, a)),
            }
        }

        if let Some(o) = old {
            self.delete_raw(o);
        }
        self.insert_raw(rowid, row.clone())?;
        *self.changes += 1;
        Ok(WriteResult::Written(rowid, row))
    }
}

/// Rows of an UPDATE/DELETE target that may satisfy WHERE, using a rowid
/// or index lookup when the conditions allow.
fn candidate_rows<'t>(
    t: &'t Table,
    where_: Option<&BExpr>,
    cx: Cx,
) -> Result<Vec<(i64, &'t Row)>, String> {
    if let Some(w) = where_ {
        let mut conj = Vec::new();
        query::split_and(w.clone(), &mut conj);
        let conds: Vec<&BExpr> = conj.iter().collect();
        if let Some(acc) = access::choose(t, 0, &conds) {
            let mut rids = access::rowids(t, &acc, &[], cx)?;
            rids.sort_unstable();
            rids.dedup();
            return Ok(rids
                .into_iter()
                .filter_map(|r| t.rows.get(&r).map(|row| (r, row)))
                .collect());
        }
    }
    Ok(t.rows.iter().map(|(&r, row)| (r, row)).collect())
}

/// Column properties from a column definition.
fn column_info(c: &ColumnDef) -> Result<ColumnInfo, String> {
    let coll = match &c.collate {
        Some(n) => Coll::from_name(n)?,
        None => Coll::Binary,
    };
    let default = match &c.default {
        Some(e) => Some(
            bind(e, &Scope::default())
                .map_err(|_| format!("default value of column [{}] is not constant", c.name))?,
        ),
        None => None,
    };
    Ok(ColumnInfo {
        name: c.name.clone(),
        affinity: affinity_of_type(&c.type_name),
        coll,
        not_null: c.not_null,
        not_null_conflict: c.not_null_conflict,
        default,
        sz_est: size_estimate(&c.type_name),
    })
}

/// Convert a value assigned to a rowid to an integer.
fn rowid_value(v: Value) -> SResult<Option<i64>> {
    match apply_affinity(v, Affinity::Integer) {
        Value::Null => Ok(None),
        Value::Integer(i) => Ok(Some(i)),
        _ => Err(mismatch()),
    }
}

/// Bind RETURNING / result columns against a scope.
fn bind_result_cols(
    cols: &[ResultCol],
    scope: &Scope,
) -> Result<Vec<(BExpr, Option<String>)>, String> {
    let mut outs = Vec::new();
    for rc in cols {
        match rc {
            ResultCol::Star => {
                if scope.sources.is_empty() {
                    return Err("no tables specified".into());
                }
                for s in &scope.sources {
                    for i in 0..s.columns.len() {
                        if !s.merged[i] {
                            outs.push((s.col_expr(i, true), None));
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
                for (i, _) in s.columns.iter().enumerate() {
                    outs.push((BExpr::Col(s.offset + i, s.affinities[i], s.colls[i]), None));
                }
            }
            ResultCol::Expr(e, alias, _) => outs.push((bind(e, scope)?, alias.clone())),
        }
    }
    Ok(outs)
}

fn eval_row(outs: &[(BExpr, Option<String>)], env: &[Value], cx: Cx) -> Result<Row, String> {
    outs.iter().map(|(e, _)| eval(e, env, cx)).collect()
}

/// Evaluate a LIMIT/OFFSET expression to an integer.
fn eval_limit(e: &BExpr, cx: Cx) -> Result<i64, String> {
    match eval(e, &[], cx)? {
        Value::Integer(i) => Ok(i),
        Value::Real(r) if r == r.trunc() && r.abs() < 9.2e18 => Ok(r as i64),
        Value::Text(s) => match text_numeric_affinity(&s, true) {
            Some(Value::Integer(i)) => Ok(i),
            _ => Err("datatype mismatch".into()),
        },
        _ => Err("datatype mismatch".into()),
    }
}

const SCHEMA_NAMES: [&str; 4] = [
    "sqlite_schema",
    "sqlite_master",
    "sqlite_temp_schema",
    "sqlite_temp_master",
];

fn is_schema_table(name: &str) -> bool {
    SCHEMA_NAMES.iter().any(|n| n.eq_ignore_ascii_case(name))
}

fn reserved_name(name: &str) -> Result<(), String> {
    if name.len() >= 7 && name[..7].eq_ignore_ascii_case("sqlite_") {
        return Err(format!("object name reserved for internal use: {}", name));
    }
    Ok(())
}

impl Database {
    /// Load the contents of a SQLite database file.
    pub fn load_file(&mut self, data: &[u8]) -> Result<(), String> {
        if data.is_empty() {
            return Ok(());
        }
        let fr = file::FileReader::new(data)?;
        self.page_size = fr.page_size();
        self.file_header = Some(data[..100].try_into().unwrap());
        let mut sequence: Option<u64> = None;
        let mut pending_seq: Vec<(String, i64)> = Vec::new();
        for (_, rec) in fr.table_entries(1)? {
            let vals = file::decode_record(&rec)?;
            let get = |i: usize| vals.get(i).cloned().unwrap_or(Value::Null);
            let (Value::Text(kind), Value::Text(name)) = (get(0), get(1)) else {
                continue;
            };
            let root = match get(3) {
                Value::Integer(n) if n > 0 => n as u64,
                _ => 0,
            };
            let sql = match get(4) {
                Value::Text(s) => s,
                _ => continue,
            };
            if kind == "table" && name.eq_ignore_ascii_case("sqlite_sequence") {
                sequence = Some(root);
                continue;
            }
            if !matches!(kind.as_str(), "table" | "index" | "view") || reserved_name(&name).is_err()
            {
                continue;
            }
            // An object that cannot be loaded is skipped rather than
            // making the whole database unreadable.
            let _ = self.load_object(&fr, &kind, &name, &sql, root);
        }
        if let Some(root) = sequence {
            for (_, rec) in fr.table_entries(root)? {
                let vals = file::decode_record(&rec)?;
                if let (Some(Value::Text(name)), Some(Value::Integer(n))) =
                    (vals.first(), vals.get(1))
                {
                    pending_seq.push((name.clone(), *n));
                }
            }
        }
        for (name, n) in pending_seq {
            if let Some(t) = self.tables.get_mut(&fold(&name)) {
                t.seq = t.seq.max(n);
            }
        }
        Ok(())
    }

    fn load_object(
        &mut self,
        fr: &file::FileReader,
        kind: &str,
        name: &str,
        sql: &str,
        root: u64,
    ) -> Result<(), String> {
        let stmt = crate::parser::parse_statement(sql)?;
        self.undo.clear();
        let r = self.execute_ddl(&stmt);
        self.undo.clear();
        r?;
        if kind == "table" {
            let key = fold(name);
            let t = self
                .tables
                .get_mut(&key)
                .ok_or_else(|| format!("no such table: {}", name))?;
            let defaults: Vec<Value> = t
                .columns
                .iter()
                .map(|c| match &c.default {
                    Some(d) => eval(d, &[], Cx::default()).map(|v| apply_affinity(v, c.affinity)),
                    None => Ok(Value::Null),
                })
                .collect::<Result<_, _>>()?;
            for (rowid, payload) in fr.table_entries(root)? {
                let mut vals = file::decode_record(&payload)?;
                vals.truncate(t.columns.len());
                for (i, v) in vals.iter_mut().enumerate() {
                    if t.columns[i].affinity == Affinity::Real {
                        if let Value::Integer(n) = *v {
                            *v = Value::Real(n as f64);
                        }
                    }
                }
                let n = vals.len();
                vals.extend_from_slice(&defaults[n..]);
                if let Some(i) = t.ipk {
                    vals[i] = Value::Integer(rowid);
                }
                t.insert_raw(rowid, vals)?;
            }
        }
        Ok(())
    }

    pub fn execute(&mut self, stmt: &Stmt) -> Result<Vec<Row>, String> {
        match stmt {
            Stmt::Begin => {
                if self.txn.is_some() {
                    return Err("cannot start a transaction within a transaction".into());
                }
                self.txn = Some(Txn {
                    log: Vec::new(),
                    savepoints: Vec::new(),
                    explicit: true,
                });
                Ok(Vec::new())
            }
            Stmt::Commit => {
                let Some(t) = self.txn.take() else {
                    return Err("cannot commit - no transaction is active".into());
                };
                self.note_committed(&t.log);
                Ok(Vec::new())
            }
            Stmt::Rollback(None) => {
                let Some(t) = self.txn.take() else {
                    return Err("cannot rollback - no transaction is active".into());
                };
                self.undo_entries(t.log);
                Ok(Vec::new())
            }
            Stmt::Rollback(Some(name)) => {
                let lname = fold(name);
                let pos = self
                    .txn
                    .as_ref()
                    .and_then(|t| t.savepoints.iter().rposition(|(n, _)| fold(n) == lname));
                let Some(pos) = pos else {
                    return Err(format!("no such savepoint: {}", name));
                };
                let t = self.txn.as_mut().unwrap();
                t.savepoints.truncate(pos + 1);
                let at = t.savepoints[pos].1;
                let tail = t.log.split_off(at);
                self.undo_entries(tail);
                Ok(Vec::new())
            }
            Stmt::Savepoint(name) => {
                let t = self.txn.get_or_insert_with(|| Txn {
                    log: Vec::new(),
                    savepoints: Vec::new(),
                    explicit: false,
                });
                t.savepoints.push((name.clone(), t.log.len()));
                Ok(Vec::new())
            }
            Stmt::Release(name) => {
                let lname = fold(name);
                let pos = self
                    .txn
                    .as_ref()
                    .and_then(|t| t.savepoints.iter().rposition(|(n, _)| fold(n) == lname));
                let Some(pos) = pos else {
                    return Err(format!("no such savepoint: {}", name));
                };
                let t = self.txn.as_mut().unwrap();
                t.savepoints.truncate(pos);
                if t.savepoints.is_empty() && !t.explicit {
                    let t = self.txn.take().unwrap();
                    self.note_committed(&t.log);
                }
                Ok(Vec::new())
            }
            Stmt::Insert(ins) => self.run_dml(|db, ch| db.insert(ins, ch)),
            Stmt::Update(up) => self.run_dml(|db, ch| db.update(up, ch)),
            Stmt::Delete(del) => self.run_dml(|db, ch| db.delete(del, ch)),
            Stmt::Select(sel) => self.run_select(sel, None).map(|(_, rows)| rows),
            _ => {
                self.undo.clear();
                let r = self.execute_ddl(stmt);
                match r {
                    Ok(()) => {
                        if self.txn.is_none() {
                            self.dirty = true;
                            self.schema_dirty = true;
                        }
                        self.commit_stmt()
                    }
                    Err(_) => self.rollback_undo(),
                }
                r.map(|_| Vec::new())
            }
        }
    }

    fn execute_ddl(&mut self, stmt: &Stmt) -> Result<(), String> {
        match stmt {
            Stmt::CreateTable(ct) => self.create_table(ct),
            Stmt::DropTable { name, if_exists } => self.drop_table(name, *if_exists),
            Stmt::CreateIndex(ci) => self.create_index(ci),
            Stmt::DropIndex { name, if_exists } => self.drop_index(name, *if_exists),
            Stmt::CreateView(cv) => self.create_view(cv),
            Stmt::DropView { name, if_exists } => self.drop_view(name, *if_exists),
            Stmt::AlterTable { table, action } => self.alter_table(table, action),
            _ => unreachable!(),
        }
    }

    /// A statement succeeded: its undo entries join the transaction's log.
    fn commit_stmt(&mut self) {
        match &mut self.txn {
            Some(t) => t.log.append(&mut self.undo),
            None => {
                let log = std::mem::take(&mut self.undo);
                self.note_committed(&log);
            }
        }
    }

    /// Changes in `log` were committed: the file must be rewritten.
    fn note_committed(&mut self, log: &[Undo]) {
        if !log.is_empty() {
            self.dirty = true;
        }
        if log
            .iter()
            .any(|u| matches!(u, Undo::Table(..) | Undo::View(..)))
        {
            self.schema_dirty = true;
        }
    }

    /// Rows of sqlite_sequence (name, seq, rowid), if that table exists.
    pub fn sequence_rows(&self) -> Option<Vec<Row>> {
        let mut ts: Vec<&Table> = self.tables.values().filter(|t| t.autoinc).collect();
        if ts.is_empty() {
            return None;
        }
        ts.sort_by_key(|t| t.schema_id);
        Some(
            ts.into_iter()
                .filter(|t| t.seq > 0)
                .enumerate()
                .map(|(i, t)| {
                    vec![
                        Value::Text(t.name.clone()),
                        Value::Integer(t.seq),
                        Value::Integer(i as i64 + 1),
                    ]
                })
                .collect(),
        )
    }

    /// Run a data-changing statement atomically and maintain the change
    /// counters.
    fn run_dml(
        &mut self,
        f: impl FnOnce(&mut Self, &mut i64) -> SResult<Vec<Row>>,
    ) -> Result<Vec<Row>, String> {
        self.undo.clear();
        self.started.set(false);
        let mut changes = 0;
        let r = f(self, &mut changes);
        let r = match r {
            Ok(rows) => {
                self.commit_stmt();
                Ok(rows)
            }
            Err(e) => {
                if e.keep {
                    self.commit_stmt();
                } else {
                    self.rollback_undo();
                    changes = 0;
                    if e.txn {
                        if let Some(t) = self.txn.take() {
                            self.undo_entries(t.log);
                        }
                    }
                }
                if !self.started.get() {
                    // Failed while preparing: nothing ran.
                    return Err(e.msg);
                }
                Err(e.msg)
            }
        };
        self.total_changes += changes;
        func::set_changes(changes, self.total_changes);
        r
    }

    fn rollback_undo(&mut self) {
        let log = std::mem::take(&mut self.undo);
        self.undo_entries(log);
    }

    /// Apply undo entries, most recent first.
    fn undo_entries(&mut self, mut log: Vec<Undo>) {
        while let Some(u) = log.pop() {
            match u {
                Undo::Inserted(k, r) => {
                    if let Some(t) = self.tables.get_mut(&k) {
                        t.delete_raw(r);
                    }
                }
                Undo::Deleted(k, r, row) => {
                    if let Some(t) = self.tables.get_mut(&k) {
                        let _ = t.insert_raw(r, row);
                    }
                }
                Undo::Seq(k, s) => {
                    if let Some(t) = self.tables.get_mut(&k) {
                        t.seq = s;
                    }
                }
                Undo::Table(k, t) => match t {
                    Some(t) => {
                        self.tables.insert(k, *t);
                    }
                    None => {
                        self.tables.remove(&k);
                    }
                },
                Undo::View(k, v) => match v {
                    Some(v) => {
                        self.views.insert(k, *v);
                    }
                    None => {
                        self.views.remove(&k);
                    }
                },
            }
        }
    }

    /// Record a schema change for ROLLBACK (only needed inside a
    /// transaction: DDL statements validate before changing anything).
    fn log_ddl(&mut self, u: Undo) {
        if self.txn.is_some() {
            self.undo.push(u);
        }
    }

    fn table(&self, name: &str) -> Result<&Table, String> {
        self.tables
            .get(&fold(name))
            .ok_or_else(|| format!("no such table: {}", name))
    }

    /// The target of INSERT/UPDATE/DELETE.
    fn writable_table(&self, name: &str) -> Result<&Table, String> {
        if let Some(t) = self.tables.get(&fold(name)) {
            return Ok(t);
        }
        if self.views.contains_key(&fold(name)) {
            return Err(format!("cannot modify {} because it is a view", name));
        }
        if is_schema_table(name) {
            return Err("table sqlite_master may not be modified".into());
        }
        Err(format!("no such table: {}", name))
    }

    /// The index with this name and the key of its table.
    fn find_index(&self, name: &str) -> Option<(String, usize)> {
        for (k, t) in &self.tables {
            if let Some(i) = t
                .indexes
                .iter()
                .position(|x| x.name.eq_ignore_ascii_case(name))
            {
                return Some((k.clone(), i));
            }
        }
        None
    }

    /// Kind of the schema object with this name, if any.
    fn object_kind(&self, name: &str) -> Option<&'static str> {
        let k = fold(name);
        if self.tables.contains_key(&k) {
            Some("table")
        } else if self.views.contains_key(&k) {
            Some("view")
        } else if self.find_index(name).is_some() {
            Some("index")
        } else {
            None
        }
    }

    fn next_schema_id(&self) -> u64 {
        let mut m = 0;
        for t in self.tables.values() {
            m = m.max(t.schema_id);
            for i in &t.indexes {
                m = m.max(i.schema_id);
            }
        }
        for v in self.views.values() {
            m = m.max(v.schema_id);
        }
        m + 1
    }

    /// Rows of sqlite_schema: type, name, tbl_name, rootpage, sql, rowid.
    pub fn schema_rows(&self) -> Vec<Row> {
        let mut items: Vec<(u64, Row)> = Vec::new();
        let text = |s: &str| Value::Text(s.to_string());
        for t in self.tables.values() {
            items.push((
                t.schema_id,
                vec![
                    text("table"),
                    text(&t.name),
                    text(&t.name),
                    Value::Integer(0),
                    text(&t.sql),
                ],
            ));
            for i in &t.indexes {
                let sql = i.sql.as_deref().map(text).unwrap_or(Value::Null);
                items.push((
                    i.schema_id,
                    vec![
                        text("index"),
                        text(&i.name),
                        text(&t.name),
                        Value::Integer(0),
                        sql,
                    ],
                ));
            }
        }
        for v in self.views.values() {
            items.push((
                v.schema_id,
                vec![
                    text("view"),
                    text(&v.name),
                    text(&v.name),
                    Value::Integer(0),
                    text(&v.sql),
                ],
            ));
        }
        // SQLite creates sqlite_sequence along with the first AUTOINCREMENT
        // table.
        let seq_after = self
            .tables
            .values()
            .filter(|t| t.autoinc)
            .min_by_key(|t| t.schema_id)
            .map(|t| t.indexes.iter().map(|i| i.schema_id).fold(t.schema_id, u64::max));
        let mut items: Vec<(u64, Row)> = items.into_iter().map(|(id, r)| (id * 2, r)).collect();
        if let Some(id) = seq_after {
            items.push((
                id * 2 + 1,
                vec![
                    text("table"),
                    text("sqlite_sequence"),
                    text("sqlite_sequence"),
                    Value::Integer(0),
                    text("CREATE TABLE sqlite_sequence(name,seq)"),
                ],
            ));
        }
        items.sort_by_key(|(id, _)| *id);
        let mut page = 1;
        items
            .into_iter()
            .enumerate()
            .map(|(i, (_, mut r))| {
                if r[0] != text("view") {
                    page += 1;
                    r[3] = Value::Integer(page);
                }
                r.push(Value::Integer(i as i64 + 1));
                r
            })
            .collect()
    }

    fn create_table(&mut self, ct: &CreateTable) -> Result<(), String> {
        let key = fold(&ct.name);
        if let Some(kind) = self.object_kind(&ct.name) {
            if ct.if_not_exists && kind != "index" {
                return Ok(());
            }
            return Err(match kind {
                "index" => format!("there is already an index named {}", ct.name),
                k => format!("{} {} already exists", k, ct.name),
            });
        }
        reserved_name(&ct.name)?;
        let mut columns: Vec<ColumnInfo> = Vec::new();
        for c in &ct.columns {
            if columns.iter().any(|x| fold(&x.name) == fold(&c.name)) {
                return Err(format!("duplicate column name: {}", c.name));
            }
            columns.push(column_info(c)?);
        }
        let schema_id = self.next_schema_id();
        let mut table = Table {
            name: ct.name.clone(),
            columns,
            rows: BTreeMap::new(),
            ipk: None,
            ipk_conflict: None,
            autoinc: false,
            seq: 0,
            indexes: Vec::new(),
            checks: Vec::new(),
            check_defs: Vec::new(),
            version: 0,
            schema_id,
            sql: ct.sql.clone(),
        };

        let npk = ct.columns.iter().filter(|c| c.primary_key).count()
            + ct.constraints
                .iter()
                .filter(|c| matches!(c, TableConstraint::PrimaryKey(..)))
                .count();
        if npk > 1 {
            return Err(format!(
                "table \"{}\" has more than one primary key",
                ct.name
            ));
        }
        let is_int_type = |i: usize| ct.columns[i].type_name.eq_ignore_ascii_case("INTEGER");
        let col_ref = |name: &str| IndexedColumn {
            expr: Expr::Column {
                table: None,
                name: name.to_string(),
                dq: false,
            },
            collate: None,
            desc: false,
        };
        // Constraint indexes, in declaration order.
        let mut pending: Vec<(Vec<IndexedColumn>, Option<ConflictAction>)> = Vec::new();
        let mut autoinc = false;
        for (i, c) in ct.columns.iter().enumerate() {
            autoinc |= c.autoincrement;
            if c.primary_key {
                if is_int_type(i) && !c.pk_desc {
                    table.ipk = Some(i);
                    table.ipk_conflict = c.pk_conflict;
                } else {
                    pending.push((vec![col_ref(&c.name)], c.pk_conflict));
                }
            }
            if c.unique {
                pending.push((vec![col_ref(&c.name)], c.unique_conflict));
            }
        }
        for tc in &ct.constraints {
            match tc {
                TableConstraint::PrimaryKey(cols, conflict, ai) => {
                    autoinc |= *ai;
                    let single_int = match cols.as_slice() {
                        [IndexedColumn {
                            expr:
                                Expr::Column {
                                    table: None, name, ..
                                },
                            collate: None,
                            ..
                        }] => table.col_index(name).filter(|&i| is_int_type(i)),
                        _ => None,
                    };
                    if let Some(i) = single_int {
                        table.ipk = Some(i);
                        table.ipk_conflict = *conflict;
                    } else {
                        pending.push((cols.clone(), *conflict));
                    }
                }
                TableConstraint::Unique(cols, conflict) => pending.push((cols.clone(), *conflict)),
                _ => {}
            }
        }
        let mut n = 0;
        for (cols, conflict) in pending {
            for ic in &cols {
                match &ic.expr {
                    Expr::Column {
                        table: None, name, ..
                    } => {
                        table
                            .col_index(name)
                            .ok_or_else(|| format!("no such column: {}", name))?;
                    }
                    _ => {
                        return Err(
                            "expressions prohibited in PRIMARY KEY and UNIQUE constraints".into(),
                        )
                    }
                }
            }
            let (parts, _) = table.bind_index(&cols, None)?;
            let same = |x: &Index| {
                x.parts.len() == parts.len()
                    && x.parts
                        .iter()
                        .zip(&parts)
                        .all(|(a, b)| a.col == b.col && a.coll == b.coll)
            };
            if table.indexes.iter().any(same) {
                continue;
            }
            n += 1;
            table.indexes.push(Index {
                name: format!("sqlite_autoindex_{}_{}", ct.name, n),
                auto: Some(n),
                unique: true,
                parts,
                where_: None,
                conflict,
                entries: BTreeSet::new(),
                schema_id: schema_id + n as u64,
                ast: cols,
                where_ast: None,
                sql: None,
            });
        }
        if autoinc {
            if table.ipk.is_none() {
                return Err("AUTOINCREMENT is only allowed on an INTEGER PRIMARY KEY".into());
            }
            table.autoinc = true;
        }
        for c in &ct.columns {
            table.check_defs.extend(c.checks.iter().cloned());
        }
        for tc in &ct.constraints {
            if let TableConstraint::Check(ch) = tc {
                table.check_defs.push(ch.clone());
            }
        }
        table.rebind()?;
        self.log_ddl(Undo::Table(key.clone(), None));
        self.tables.insert(key, table);
        Ok(())
    }

    fn drop_table(&mut self, name: &str, if_exists: bool) -> Result<(), String> {
        let key = fold(name);
        if !self.tables.contains_key(&key) {
            if self.views.contains_key(&key) {
                return Err(format!("use DROP VIEW to delete view {}", name));
            }
            if is_schema_table(name) {
                return Err("table sqlite_master may not be dropped".into());
            }
            if if_exists {
                return Ok(());
            }
            return Err(format!("no such table: {}", name));
        }
        let t = self.tables.remove(&key).unwrap();
        self.log_ddl(Undo::Table(key, Some(Box::new(t))));
        Ok(())
    }

    fn create_index(&mut self, ci: &CreateIndex) -> Result<(), String> {
        if let Some(kind) = self.object_kind(&ci.name) {
            if ci.if_not_exists && kind == "index" {
                return Ok(());
            }
            return Err(match kind {
                "index" => format!("index {} already exists", ci.name),
                k => format!("there is already a {} named {}", k, ci.name),
            });
        }
        reserved_name(&ci.name)?;
        let key = fold(&ci.table);
        let Some(t) = self.tables.get(&key) else {
            if self.views.contains_key(&key) {
                return Err("views may not be indexed".into());
            }
            if is_schema_table(&ci.table) {
                return Err("table sqlite_master may not be indexed".into());
            }
            return Err(format!("no such table: main.{}", ci.table));
        };
        let (parts, where_) = t.bind_index(&ci.columns, ci.where_.as_ref())?;
        let mut idx = Index {
            name: ci.name.clone(),
            auto: None,
            unique: ci.unique,
            parts,
            where_,
            conflict: None,
            entries: BTreeSet::new(),
            schema_id: self.next_schema_id(),
            ast: ci.columns.clone(),
            where_ast: ci.where_.clone(),
            sql: Some(ci.sql.clone()),
        };
        idx.entries = build_entries(t, &idx)?;
        let name = idx.name.clone();
        let t = self.tables.get_mut(&key).unwrap();
        t.indexes.push(idx);
        t.version += 1;
        if self.txn.is_some() {
            // Undo by restoring the table without the index.
            let mut before = self.tables[&key].clone();
            before.indexes.retain(|i| i.name != name);
            self.undo.push(Undo::Table(key, Some(Box::new(before))));
        }
        Ok(())
    }

    fn drop_index(&mut self, name: &str, if_exists: bool) -> Result<(), String> {
        let Some((key, i)) = self.find_index(name) else {
            if if_exists {
                return Ok(());
            }
            return Err(format!("no such index: {}", name));
        };
        if self.tables[&key].indexes[i].auto.is_some() {
            return Err(
                "index associated with UNIQUE or PRIMARY KEY constraint cannot be dropped".into(),
            );
        }
        if self.txn.is_some() {
            let before = self.tables[&key].clone();
            self.undo
                .push(Undo::Table(key.clone(), Some(Box::new(before))));
        }
        let t = self.tables.get_mut(&key).unwrap();
        t.indexes.remove(i);
        t.version += 1;
        Ok(())
    }

    fn create_view(&mut self, cv: &CreateView) -> Result<(), String> {
        if let Some(kind) = self.object_kind(&cv.name) {
            if cv.if_not_exists {
                return Ok(());
            }
            return Err(match kind {
                "index" => format!("there is already an index named {}", cv.name),
                k => format!("{} {} already exists", k, cv.name),
            });
        }
        reserved_name(&cv.name)?;
        let key = fold(&cv.name);
        let v = View {
            name: cv.name.clone(),
            columns: cv.columns.clone(),
            query: cv.query.clone(),
            schema_id: self.next_schema_id(),
            sql: cv.sql.clone(),
        };
        self.log_ddl(Undo::View(key.clone(), None));
        self.views.insert(key, v);
        Ok(())
    }

    fn drop_view(&mut self, name: &str, if_exists: bool) -> Result<(), String> {
        let key = fold(name);
        match self.views.remove(&key) {
            Some(v) => {
                self.log_ddl(Undo::View(key, Some(Box::new(v))));
                Ok(())
            }
            None => {
                if self.tables.contains_key(&key) {
                    return Err(format!("use DROP TABLE to delete table {}", name));
                }
                if if_exists {
                    return Ok(());
                }
                Err(format!("no such view: {}", name))
            }
        }
    }

    fn alter_table(&mut self, name: &str, action: &AlterAction) -> Result<(), String> {
        let key = fold(name);
        if !self.tables.contains_key(&key) {
            if self.views.contains_key(&key) {
                return Err(match action {
                    AlterAction::AddColumn(_) => "Cannot add a column to a view".to_string(),
                    _ => format!("view {} may not be altered", name),
                });
            }
            if is_schema_table(name) {
                return Err(format!("table {} may not be altered", name));
            }
            return Err(format!("no such table: {}", name));
        }
        match action {
            AlterAction::RenameTable(new) => self.rename_table(&key, new),
            AlterAction::RenameColumn(old, new) => {
                let mut t = self.tables[&key].clone();
                let ci = t
                    .col_index(old)
                    .ok_or_else(|| format!("no such column: \"{}\"", old))?;
                if t.col_index(new).is_some_and(|j| j != ci) {
                    return Err(format!("duplicate column name: {}", new));
                }
                let r = schema::Rename::Column {
                    table: &t.name.clone(),
                    old,
                    new,
                };
                t.columns[ci].name = new.clone();
                let tname = t.name.clone();
                for ch in &mut t.check_defs {
                    schema::rename_in_table_expr(&mut ch.expr, &r, &tname);
                }
                for idx in &mut t.indexes {
                    for ic in &mut idx.ast {
                        schema::rename_in_table_expr(&mut ic.expr, &r, &tname);
                    }
                    if let Some(w) = &mut idx.where_ast {
                        schema::rename_in_table_expr(w, &r, &tname);
                    }
                }
                t.rebind()?;
                t.sql = sqltext::rename_column_in_table(&t.sql, &tname, old, new);
                for idx in &mut t.indexes {
                    if let Some(s) = &idx.sql {
                        idx.sql = Some(sqltext::rename_column_in_index(s, &tname, old, new));
                    }
                }
                let mut views = self.views.clone();
                for v in views.values_mut() {
                    schema::rename_in_select(&mut v.query, &r);
                    v.sql = sqltext::rename_column_elsewhere(&v.sql, true, &tname, old, new);
                }
                self.replace_views(views);
                self.replace_table(&key, t);
                self.rewrite_other_tables(&key, |s| {
                    sqltext::rename_column_elsewhere(s, false, &tname, old, new)
                });
                Ok(())
            }
            AlterAction::AddColumn(cd) => {
                let mut t = self.tables[&key].clone();
                if t.col_index(&cd.name).is_some() {
                    return Err(format!("duplicate column name: {}", cd.name));
                }
                if cd.primary_key {
                    return Err("Cannot add a PRIMARY KEY column".into());
                }
                if cd.unique {
                    return Err("Cannot add a UNIQUE column".into());
                }
                fn literal(e: &Expr) -> bool {
                    match e {
                        Expr::Lit(_) => true,
                        Expr::Unary(UnOp::Neg | UnOp::Pos, x) => literal(x),
                        _ => false,
                    }
                }
                if cd.default.as_ref().is_some_and(|d| !literal(d)) {
                    return Err("Cannot add a column with non-constant default".into());
                }
                let info = column_info(cd)?;
                let dv = match &info.default {
                    Some(d) => apply_affinity(eval(d, &[], Cx::default())?, info.affinity),
                    None => Value::Null,
                };
                if info.not_null && dv.is_null() {
                    return Err("Cannot add a NOT NULL column with default value NULL".into());
                }
                t.columns.push(info);
                t.sql = sqltext::add_column(&t.sql, &cd.text);
                t.check_defs.extend(cd.checks.iter().cloned());
                for row in t.rows.values_mut() {
                    row.push(dv.clone());
                }
                t.rebind()?;
                if !cd.checks.is_empty() {
                    for (&rid, row) in &t.rows {
                        let mut env = row.clone();
                        env.push(Value::Integer(rid));
                        for (e, name) in &t.checks[t.checks.len() - cd.checks.len()..] {
                            if eval(e, &env, Cx::default())?.truthy() == Some(false) {
                                return Err(format!("CHECK constraint failed: {}", name));
                            }
                        }
                    }
                }
                t.rebuild_indexes()?;
                t.version += 1;
                self.replace_table(&key, t);
                Ok(())
            }
            AlterAction::DropColumn(col) => {
                let mut t = self.tables[&key].clone();
                let ci = t
                    .col_index(col)
                    .ok_or_else(|| format!("no such column: \"{}\"", col))?;
                if t.ipk == Some(ci) {
                    return Err(format!("cannot drop PRIMARY KEY column: \"{}\"", col));
                }
                if let Some(idx) = t
                    .indexes
                    .iter()
                    .find(|i| i.parts.iter().any(|p| p.col == Some(ci)))
                {
                    return Err(if idx.auto.is_some() {
                        format!("cannot drop UNIQUE column: \"{}\"", col)
                    } else {
                        format!(
                            "error in index {} after drop column: no such column: {}",
                            idx.name, col
                        )
                    });
                }
                if t.columns.len() == 1 {
                    return Err(format!(
                        "cannot drop column \"{}\": no other columns exist",
                        col
                    ));
                }
                t.sql = sqltext::drop_column(&t.sql, &t.columns[ci].name);
                t.columns.remove(ci);
                if let Some(p) = t.ipk {
                    if p > ci {
                        t.ipk = Some(p - 1);
                    }
                }
                for row in t.rows.values_mut() {
                    row.remove(ci);
                }
                t.rebind()?;
                t.rebuild_indexes()?;
                t.version += 1;
                let old = self.tables[&key].clone();
                self.replace_table(&key, t);
                if let Err(e) = self.check_views() {
                    // Inside a transaction the statement's undo log restores it.
                    if self.txn.is_none() {
                        self.tables.insert(key, old);
                    }
                    return Err(e);
                }
                Ok(())
            }
        }
    }

    /// Every view must still compile after a schema change.
    fn check_views(&self) -> Result<(), String> {
        let root = Scope {
            db: Some(self),
            ..Default::default()
        };
        for v in self.views.values() {
            if let Err(e) = query::compile_sub(&v.query, &root) {
                return Err(format!("error in view {}: {}", v.name, e));
            }
        }
        Ok(())
    }

    fn replace_table(&mut self, key: &str, t: Table) {
        if let Some(old) = self.tables.insert(key.to_string(), t) {
            self.log_ddl(Undo::Table(key.to_string(), Some(Box::new(old))));
        }
    }

    /// Apply a rewrite to the CREATE statements of tables other than `key`.
    fn rewrite_other_tables(&mut self, key: &str, f: impl Fn(&str) -> String) {
        let changed: Vec<(String, String)> = self
            .tables
            .iter()
            .filter(|(k, _)| k.as_str() != key)
            .filter_map(|(k, t)| {
                let s = f(&t.sql);
                (s != t.sql).then(|| (k.clone(), s))
            })
            .collect();
        for (k, s) in changed {
            let mut t = self.tables[&k].clone();
            t.sql = s;
            self.replace_table(&k, t);
        }
    }

    fn replace_views(&mut self, views: BTreeMap<String, View>) {
        let old = std::mem::replace(&mut self.views, views);
        if self.txn.is_some() {
            for (k, v) in old {
                self.undo.push(Undo::View(k, Some(Box::new(v))));
            }
        }
    }

    fn check_new_name(&self, new: &str) -> Result<(), String> {
        if self.object_kind(new).is_some() {
            return Err(format!(
                "there is already another table or index with this name: {}",
                new
            ));
        }
        reserved_name(new)
    }

    fn rename_table(&mut self, key: &str, new: &str) -> Result<(), String> {
        let old_name = self.tables[key].name.clone();
        self.check_new_name(new)?;
        let mut t = self.tables[key].clone();
        let r = schema::Rename::Table {
            old: &old_name,
            new,
        };
        t.name = new.to_string();
        t.sql = sqltext::rename_table(&t.sql, &old_name, new);
        for ch in &mut t.check_defs {
            schema::rename_in_table_expr(&mut ch.expr, &r, &old_name);
        }
        for idx in &mut t.indexes {
            if let Some(n) = idx.auto {
                idx.name = format!("sqlite_autoindex_{}_{}", new, n);
            }
            for ic in &mut idx.ast {
                schema::rename_in_table_expr(&mut ic.expr, &r, &old_name);
            }
            if let Some(w) = &mut idx.where_ast {
                schema::rename_in_table_expr(w, &r, &old_name);
            }
            if let Some(s) = &idx.sql {
                idx.sql = Some(sqltext::rename_table(s, &old_name, new));
            }
        }
        t.rebind()?;
        let mut views = self.views.clone();
        for v in views.values_mut() {
            schema::rename_in_select(&mut v.query, &r);
            v.sql = sqltext::rename_table(&v.sql, &old_name, new);
        }
        self.replace_views(views);
        self.rewrite_other_tables(key, |s| sqltext::rename_table(s, &old_name, new));
        let old = self.tables.remove(key).unwrap();
        self.log_ddl(Undo::Table(key.to_string(), Some(Box::new(old))));
        let nk = fold(new);
        self.log_ddl(Undo::Table(nk.clone(), None));
        self.tables.insert(nk, t);
        Ok(())
    }

    /// Column index for an assignment target; `ncols` stands for the rowid.
    fn target_col(t: &Table, name: &str) -> Result<usize, String> {
        if let Some(i) = t.col_index(name) {
            return Ok(i);
        }
        if is_rowid_name(name) {
            return Ok(t.ipk.unwrap_or(t.columns.len()));
        }
        Err(format!("no such column: {}", name))
    }

    fn insert(&mut self, ins: &Insert, changes: &mut i64) -> SResult<Vec<Row>> {
        let env = ins.with.as_ref().map(|w| query::CteEnv::new(w, None));
        let key = fold(&ins.table);
        let t = self.writable_table(&ins.table)?;
        let ncols = t.columns.len();
        // Map each supplied value position to a column (ncols = rowid).
        let targets: Vec<usize> = match &ins.columns {
            None => (0..ncols).collect(),
            Some(cols) => {
                let mut v = Vec::new();
                for c in cols {
                    match Self::target_col(t, c) {
                        Ok(i) => v.push(i),
                        Err(_) => {
                            return Err(format!("table {} has no column named {}", t.name, c).into())
                        }
                    }
                }
                v
            }
        };
        let count_err = |n: usize| -> StmtErr {
            match &ins.columns {
                None => format!(
                    "table {} has {} columns but {} values were supplied",
                    t.name, ncols, n
                ),
                Some(_) => format!("{} values for {} columns", n, targets.len()),
            }
            .into()
        };
        let src_rows: Vec<Row> = match &ins.source {
            InsertSource::Values(rows) => {
                if let Some(r) = rows.iter().find(|r| r.len() != targets.len()) {
                    return Err(count_err(r.len()));
                }
                let scope = Scope {
                    db: Some(&*self),
                    ctes: env.clone(),
                    ..Default::default()
                };
                let mut bound = Vec::new();
                for r in rows {
                    bound.push(bind_all(r, &scope)?);
                }
                self.started.set(true);
                let cx = Cx {
                    db: Some(&*self),
                    outer: None,
                };
                let mut out = Vec::new();
                for r in &bound {
                    let mut vals = Vec::with_capacity(r.len());
                    for e in r {
                        vals.push(eval(e, &[], cx)?);
                    }
                    out.push(vals);
                }
                out
            }
            InsertSource::Select(sel) => {
                let (n, rows) = self.run_select(sel, env.clone())?;
                if n != targets.len() {
                    return Err(count_err(n));
                }
                rows
            }
            InsertSource::Default => vec![Vec::new()],
        };
        let targets = if matches!(ins.source, InsertSource::Default) {
            Vec::new()
        } else {
            targets
        };

        // Upsert clauses.
        let alias = ins.alias.as_deref().unwrap_or(&ins.table);
        let mut scope = Scope {
            db: Some(&*self),
            ctes: env.clone(),
            ..Default::default()
        };
        scope.sources.push(t.source(alias, 0));
        let mut ex = t.source("excluded", ncols + 1);
        ex.qualified_only = true;
        scope.sources.push(ex);
        let mut upserts = Vec::new();
        for u in &ins.upsert {
            let target = match &u.target {
                None => None,
                Some(cols) => {
                    let mut v = Vec::new();
                    for ic in cols {
                        match &ic.expr {
                            Expr::Column { table: None, name, .. } => v.push(Self::target_col(t, name)?),
                            _ => return Err(StmtErr::from("ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint".to_string())),
                        }
                    }
                    v.sort_unstable();
                    let matches_ipk = t.ipk.is_some_and(|p| v == [p]);
                    let matches_idx = t.indexes.iter().any(|idx| {
                        idx.unique
                            && idx.where_.is_none()
                            && idx.col_list().is_some_and(|mut c| {
                                c.sort_unstable();
                                c == v
                            })
                    });
                    if !matches_ipk && !matches_idx {
                        return Err(StmtErr::from("ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint".to_string()));
                    }
                    Some(v)
                }
            };
            let action = match &u.action {
                UpsertAction::Nothing => BUpsertAction::Nothing,
                UpsertAction::Update { sets, where_ } => {
                    let mut bs = Vec::new();
                    for (name, e) in sets {
                        bs.push((Self::target_col(t, name)?, bind(e, &scope)?));
                    }
                    let w = match where_ {
                        Some(w) => Some(bind(w, &scope)?),
                        None => None,
                    };
                    BUpsertAction::Update {
                        sets: bs,
                        where_: w,
                    }
                }
            };
            upserts.push(BUpsert { target, action });
        }
        let returning = match &ins.returning {
            Some(cols) => {
                let mut sc = Scope {
                    db: Some(&*self),
                    volatile: true,
                    ctes: env.clone(),
                    ..Default::default()
                };
                // RETURNING sees the table under its own name, not the alias.
                sc.sources.push(t.source(&ins.table, 0));
                Some(bind_result_cols(cols, &sc)?)
            }
            None => None,
        };

        self.started.set(true);
        let mut out = Vec::new();
        for src in src_rows {
            let mut w = self.writer(&key, changes);
            let mut row = vec![Value::Null; ncols];
            let mut given = vec![false; ncols];
            let mut explicit_rowid = Value::Null;
            for (v, &ti) in src.into_iter().zip(&targets) {
                if ti == ncols {
                    explicit_rowid = v;
                } else {
                    row[ti] = v;
                    given[ti] = true;
                }
            }
            for (i, c) in w.t.columns.iter().enumerate() {
                if !given[i] {
                    if let Some(d) = &c.default {
                        row[i] = eval(d, &[], Cx::default())?;
                    }
                }
                row[i] = apply_affinity(std::mem::replace(&mut row[i], Value::Null), c.affinity);
            }
            let rid = match w.t.ipk {
                Some(p) => rowid_value(row[p].clone())?,
                None => rowid_value(explicit_rowid)?,
            };
            let rowid = match rid {
                Some(r) => r,
                None => w.new_rowid()?,
            };
            if let Some(p) = w.t.ipk {
                row[p] = Value::Integer(rowid);
            }
            w.bump_seq(rowid);
            let excluded = if upserts.is_empty() {
                Vec::new()
            } else {
                row.clone()
            };
            let written = match w.write_row(None, rowid, row, ins.or_action, &upserts)? {
                WriteResult::Written(r, row) => {
                    func::set_last_insert_rowid(r);
                    Some((r, row))
                }
                WriteResult::Skipped => None,
                WriteResult::Conflict(ui, crow) => {
                    let BUpsertAction::Update { sets, where_ } = &upserts[ui].action else {
                        unreachable!()
                    };
                    let t = &self.tables[&key];
                    let cx = Cx {
                        db: Some(&*self),
                        outer: None,
                    };
                    let old = t.rows[&crow].clone();
                    let mut env = old.clone();
                    env.push(Value::Integer(crow));
                    env.extend(excluded);
                    env.push(Value::Integer(rowid));
                    if let Some(wh) = where_ {
                        if eval(wh, &env, cx)?.truthy() != Some(true) {
                            continue;
                        }
                    }
                    let mut new = old;
                    let mut new_rowid = Value::Integer(crow);
                    for (ci, e) in sets {
                        let v = eval(e, &env, cx)?;
                        if *ci == ncols {
                            new_rowid = v;
                        } else {
                            new[*ci] = apply_affinity(v, t.columns[*ci].affinity);
                        }
                    }
                    if let Some(p) = t.ipk {
                        new_rowid = new[p].clone();
                    }
                    let nr = rowid_value(new_rowid)?.ok_or_else(mismatch)?;
                    if let Some(p) = t.ipk {
                        new[p] = Value::Integer(nr);
                    }
                    let mut w = self.writer(&key, changes);
                    match w.write_row(Some(crow), nr, new, Some(ConflictAction::Abort), &[])? {
                        WriteResult::Written(r, row) => Some((r, row)),
                        _ => None,
                    }
                }
            };
            if let (Some((r, mut row)), Some(ret)) = (written, &returning) {
                row.push(Value::Integer(r));
                out.push(self.returning_row(ret, &row)?);
            }
        }
        Ok(out)
    }

    fn writer<'s>(&'s mut self, key: &'s str, changes: &'s mut i64) -> Writer<'s> {
        let Database { tables, undo, .. } = self;
        Writer {
            t: tables.get_mut(key).unwrap(),
            undo,
            key,
            changes,
        }
    }

    /// Evaluate RETURNING for one changed row; its subqueries see the
    /// database as it is at this point.
    fn returning_row(&self, ret: &[(BExpr, Option<String>)], row: &[Value]) -> Result<Row, String> {
        self.gen.set(self.gen.get() + 1);
        eval_row(
            ret,
            row,
            Cx {
                db: Some(self),
                outer: None,
            },
        )
    }

    fn update(&mut self, up: &Update, changes: &mut i64) -> SResult<Vec<Row>> {
        let env = up.with.as_ref().map(|w| query::CteEnv::new(w, None));
        let key = fold(&up.table);
        let t = self.writable_table(&up.table)?;
        let ncols = t.columns.len();
        let mut scope = Scope {
            db: Some(&*self),
            ctes: env.clone(),
            ..Default::default()
        };
        scope
            .sources
            .push(t.source(up.alias.as_deref().unwrap_or(&up.table), 0));
        let mut sets = Vec::new();
        for (name, e) in &up.sets {
            sets.push((Self::target_col(t, name)?, bind(e, &scope)?));
        }
        let where_ = match &up.where_ {
            Some(w) => Some(bind(w, &scope)?),
            None => None,
        };
        let returning = match &up.returning {
            Some(cols) => {
                let mut sc = Scope {
                    db: Some(&*self),
                    volatile: true,
                    ctes: env.clone(),
                    ..Default::default()
                };
                sc.sources.push(t.source(&up.table, 0));
                Some(bind_result_cols(cols, &sc)?)
            }
            None => None,
        };
        // WHERE sees the table as it was; SET values are computed row by
        // row, so correlated subqueries see earlier rows' updates.
        self.started.set(true);
        let t = self.table(&up.table)?;
        let cx = Cx {
            db: Some(&*self),
            outer: None,
        };
        let mut targets = Vec::new();
        let mut env = Vec::with_capacity(ncols + 1);
        for (rid, row) in candidate_rows(t, where_.as_ref(), cx)? {
            env.clear();
            env.extend(row.iter().cloned());
            env.push(Value::Integer(rid));
            if let Some(w) = &where_ {
                if eval(w, &env, cx)?.truthy() != Some(true) {
                    continue;
                }
            }
            targets.push(rid);
        }
        let mut out = Vec::new();
        for rid in targets {
            let t = &self.tables[&key];
            let Some(row) = t.rows.get(&rid) else {
                continue;
            };
            let cx = Cx {
                db: Some(&*self),
                outer: None,
            };
            env.clear();
            env.extend(row.iter().cloned());
            env.push(Value::Integer(rid));
            let mut new = row.clone();
            let mut new_rowid = Value::Integer(rid);
            for (ci, e) in &sets {
                let v = eval(e, &env, cx)?;
                if *ci == ncols {
                    new_rowid = v;
                } else {
                    new[*ci] = apply_affinity(v, t.columns[*ci].affinity);
                }
            }
            if let Some(p) = t.ipk {
                new_rowid = new[p].clone();
            }
            let nr = rowid_value(new_rowid)?.ok_or_else(mismatch)?;
            if let Some(p) = t.ipk {
                new[p] = Value::Integer(nr);
            }
            let res =
                self.writer(&key, changes)
                    .write_row(Some(rid), nr, new, up.or_action, &[])?;
            if let (WriteResult::Written(r, mut row), Some(ret)) = (res, &returning) {
                row.push(Value::Integer(r));
                out.push(self.returning_row(ret, &row)?);
            }
        }
        Ok(out)
    }

    fn delete(&mut self, del: &Delete, changes: &mut i64) -> SResult<Vec<Row>> {
        let env = del.with.as_ref().map(|w| query::CteEnv::new(w, None));
        let key = fold(&del.table);
        let t = self.writable_table(&del.table)?;
        let mut scope = Scope {
            db: Some(&*self),
            ctes: env.clone(),
            ..Default::default()
        };
        scope
            .sources
            .push(t.source(del.alias.as_deref().unwrap_or(&del.table), 0));
        let where_ = match &del.where_ {
            Some(w) => Some(bind(w, &scope)?),
            None => None,
        };
        let returning = match &del.returning {
            Some(cols) => {
                let mut sc = Scope {
                    db: Some(&*self),
                    volatile: true,
                    ctes: env.clone(),
                    ..Default::default()
                };
                sc.sources.push(t.source(&del.table, 0));
                Some(bind_result_cols(cols, &sc)?)
            }
            None => None,
        };
        self.started.set(true);
        let t = self.table(&del.table)?;
        let cx = Cx {
            db: Some(&*self),
            outer: None,
        };
        let mut victims = Vec::new();
        let mut env = Vec::new();
        for (rid, row) in candidate_rows(t, where_.as_ref(), cx)? {
            env.clear();
            env.extend(row.iter().cloned());
            env.push(Value::Integer(rid));
            if let Some(w) = &where_ {
                if eval(w, &env, cx)?.truthy() != Some(true) {
                    continue;
                }
            }
            victims.push((
                rid,
                if returning.is_some() {
                    env.clone()
                } else {
                    Vec::new()
                },
            ));
        }
        let mut out = Vec::new();
        for (rid, env) in victims {
            if self.writer(&key, changes).delete_raw(rid).is_some() {
                *changes += 1;
                if let Some(ret) = &returning {
                    out.push(self.returning_row(ret, &env)?);
                }
            }
        }
        Ok(out)
    }

    /// Run a query; returns the number of result columns and the rows.
    fn run_select(
        &self,
        sel: &Select,
        ctes: Option<Rc<query::CteEnv>>,
    ) -> Result<(usize, Vec<Row>), String> {
        let root = Scope {
            db: Some(self),
            ctes,
            ..Default::default()
        };
        let sub = query::compile_sub(sel, &root)?;
        let rows = query::exec_query(
            &sub.plan,
            Cx {
                db: Some(self),
                outer: None,
            },
        )?;
        Ok((sub.plan.ncols, rows))
    }
}

/// Group filtered input rows and compute the aggregates; returns one
/// evaluation environment per group (bare columns followed by aggregate
/// results) that passes HAVING, in group-key order.
fn group_rows(
    input: Vec<Row>,
    group_by: &[(BExpr, Coll)],
    calls: &[AggCall],
    width: usize,
    having: Option<&BExpr>,
    cx: Cx,
) -> Result<Vec<Row>, String> {
    struct Group {
        rep: Option<Row>,
        states: Vec<agg::AggState>,
    }
    let new_group = || Group {
        rep: None,
        states: calls.iter().map(|c| c.new_state()).collect(),
    };
    let mut groups: Vec<Group> = Vec::new();
    let mut index: BTreeMap<IdxKey, usize> = BTreeMap::new();
    for r in input {
        let mut key = Vec::with_capacity(group_by.len());
        for (e, coll) in group_by {
            key.push(coll_key(&eval(e, &r, cx)?, *coll));
        }
        let gi = *index.entry(IdxKey(key)).or_insert_with(|| {
            groups.push(new_group());
            groups.len() - 1
        });
        let g = &mut groups[gi];
        let load = agg::step_row(calls, &mut g.states, &r, cx)?;
        if load.unwrap_or(g.rep.is_none()) {
            g.rep = Some(r);
        }
    }
    let order: Vec<usize> = if group_by.is_empty() {
        if groups.is_empty() {
            groups.push(new_group());
        }
        vec![0]
    } else {
        index.into_values().collect()
    };
    let mut envs = Vec::with_capacity(order.len());
    for gi in order {
        let g = &mut groups[gi];
        let mut env = g.rep.take().unwrap_or_else(|| vec![Value::Null; width]);
        env.extend(agg::finish_all(calls, &mut g.states)?);
        if let Some(h) = having {
            if eval(h, &env, cx)?.truthy() != Some(true) {
                continue;
            }
        }
        envs.push(env);
    }
    Ok(envs)
}

fn ordinal(n: usize) -> String {
    let suffix = match (n % 10, n % 100) {
        (1, x) if x != 11 => "st",
        (2, x) if x != 12 => "nd",
        (3, x) if x != 13 => "rd",
        _ => "th",
    };
    format!("{}{}", n, suffix)
}
