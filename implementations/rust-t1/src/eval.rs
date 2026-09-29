// Name resolution (binding) and expression evaluation.

use std::cell::{Cell, RefCell};
use std::cmp::Ordering;
use std::collections::BTreeSet;
use std::rc::Rc;

use crate::agg::AggCollector;
use crate::ast::{BinOp, CmpInfo, Expr, OrderTerm, Select, SubKind, UnOp};
use crate::db::{is_rowid_name, normalize, Database, IdxKey};
use crate::error::{err, Result};
use crate::query::{exec_query, QueryPlan, SubResult};
use crate::value::{compare_coll, Affinity, Collation, Value};

/// A FROM-clause source visible to name resolution.
#[derive(Clone, Debug)]
pub struct Source {
    /// Alias, or table name if no alias.
    pub name: String,
    pub columns: Vec<(String, Affinity, Collation)>,
    /// Index of this source's first column in the row.
    pub offset: usize,
    /// Index of the rowid in the row, if the source has one.
    pub rowid: Option<usize>,
    /// Only matched by qualified references (the upsert `excluded` row).
    pub qualified_only: bool,
    /// Columns merged into an earlier source by USING/NATURAL: invisible
    /// to unqualified references and `*` (empty = none).
    pub hidden: Vec<bool>,
    /// Replacement expression for unqualified references and `*` (the
    /// coalesced USING column of a RIGHT/FULL join), per column.
    pub merged: Vec<Option<Expr>>,
}

impl Source {
    pub fn new(name: String, columns: Vec<(String, Affinity, Collation)>, offset: usize, rowid: Option<usize>) -> Source {
        Source { name, columns, offset, rowid, qualified_only: false, hidden: vec![], merged: vec![] }
    }

    pub fn is_hidden(&self, i: usize) -> bool {
        self.hidden.get(i).copied().unwrap_or(false)
    }

    /// Expression for column `i` as seen by unqualified references.
    pub fn col_expr(&self, i: usize) -> Expr {
        if let Some(Some(e)) = self.merged.get(i) {
            return e.clone();
        }
        self.raw_col(i)
    }

    pub fn raw_col(&self, i: usize) -> Expr {
        Expr::Col { idx: self.offset + i, aff: self.columns[i].1, coll: self.columns[i].2 }
    }
}

/// Name-resolution context of one query level.
#[derive(Clone, Default)]
pub struct Scope<'a> {
    pub sources: Vec<Source>,
    /// Result-column aliases (already bound), consulted when a bare name
    /// matches no column.
    pub aliases: Vec<(String, Expr)>,
    /// Aggregate function calls are allowed here.
    pub allow_agg: bool,
    /// Database for resolving subqueries (None = subqueries prohibited).
    pub db: Option<&'a Database>,
    /// Enclosing query level.
    pub parent: Option<&'a Scope<'a>>,
    /// Aggregates of this query level.
    pub aggs: Option<Rc<RefCell<AggCollector>>>,
    /// Set when this level references an enclosing level.
    pub correlated: Rc<Cell<bool>>,
    /// Common table expressions visible here.
    pub ctes: Option<Rc<crate::query::CteEnv>>,
    /// Window functions of this query level (None = not allowed here).
    pub wins: Option<Rc<RefCell<crate::window::WinCollector>>>,
}

impl<'a> Scope<'a> {
    pub fn with_sources(sources: Vec<Source>) -> Scope<'a> {
        Scope { sources, ..Default::default() }
    }

    fn resolve(&self, table: Option<&str>, name: &str) -> Result<Option<Expr>> {
        let mut found: Option<Expr> = None;
        for s in &self.sources {
            match table {
                Some(t) if !s.name.eq_ignore_ascii_case(t) => continue,
                None if s.qualified_only => continue,
                _ => {}
            }
            let hit = match s.columns.iter().position(|(c, _, _)| c.eq_ignore_ascii_case(name)) {
                Some(i) if table.is_none() && s.is_hidden(i) => None,
                Some(i) if table.is_none() => Some(s.col_expr(i)),
                Some(i) => Some(s.raw_col(i)),
                None => match s.rowid {
                    Some(r) if is_rowid_name(name) => Some(Expr::Col { idx: r, aff: Affinity::Integer, coll: Collation::Binary }),
                    _ => None,
                },
            };
            if let Some(h) = hit {
                if found.is_some() {
                    return err!("ambiguous column name: {}", name);
                }
                found = Some(h);
            }
        }
        Ok(found)
    }

    /// Resolve a column through this level and the enclosing ones.
    fn resolve_all(&self, table: Option<&str>, name: &str) -> Result<Option<Expr>> {
        let mut s = self;
        let mut up = 0;
        loop {
            if let Some(e) = s.resolve(table, name)? {
                if up == 0 {
                    return Ok(Some(e));
                }
                let mut m = self;
                for _ in 0..up {
                    m.correlated.set(true);
                    m = m.parent.unwrap();
                }
                return Ok(Some(Expr::Outer { up, inner: Box::new(e) }));
            }
            match s.parent {
                Some(p) => {
                    s = p;
                    up += 1;
                }
                None => return Ok(None),
            }
        }
    }
}

/// Evaluation context: the database and the rows of enclosing queries.
#[derive(Clone, Copy)]
pub struct Cx<'a> {
    pub db: &'a Database,
    pub outer: Option<(&'a [Value], &'a Cx<'a>)>,
}

impl<'a> Cx<'a> {
    pub fn new(db: &'a Database) -> Cx<'a> {
        Cx { db, outer: None }
    }
}

/// Smallest enclosing level referenced by a bound expression (0 = local
/// or none). Subqueries are not inspected.
fn min_level(e: &Expr) -> Option<usize> {
    match e {
        Expr::Col { .. } | Expr::AggRef { .. } => Some(0),
        Expr::Outer { up, .. } => Some(*up),
        Expr::SubPlan { .. } => None,
        _ => {
            let mut m: Option<usize> = None;
            for_each_child(e, &mut |c| {
                if let Some(x) = min_level(c) {
                    m = Some(m.map_or(x, |y: usize| y.min(x)));
                }
            });
            m
        }
    }
}

/// Re-express a bound expression relative to the level `k` levels out.
fn rebase(e: &mut Expr, k: usize) {
    if let Expr::Outer { up, inner } = e {
        if *up == k {
            let i = std::mem::replace(inner.as_mut(), Expr::Lit(Value::Null));
            *e = i;
        } else {
            *up -= k;
        }
        return;
    }
    crate::agg::for_each_child_mut(e, &mut |c| rebase(c, k));
}

/// Does an (unbound) expression contain a subquery?
pub fn contains_subquery(e: &Expr) -> bool {
    if matches!(e, Expr::Subquery(_) | Expr::Exists(_) | Expr::InSelect { .. } | Expr::SubPlan { .. }) {
        return true;
    }
    let mut found = false;
    for_each_child(e, &mut |c| found |= contains_subquery(c));
    found
}

/// Apply `f` to each direct child expression of `e`.
pub fn for_each_child(e: &Expr, f: &mut dyn FnMut(&Expr)) {
    let (l, r, list) = expr_parts(e);
    if let Some(x) = l {
        f(x);
    }
    if let Some(x) = r {
        f(x);
    }
    for x in list {
        f(x);
    }
    if let Expr::Func { filter, order_by, .. } = e {
        if let Some(x) = filter {
            f(x);
        }
        for t in order_by {
            f(&t.expr);
        }
    }
}

/// Plan a subquery nested in `scope`; returns the plan and whether it
/// references enclosing queries.
fn bind_subquery(q: &Select, scope: &Scope) -> Result<(QueryPlan, bool)> {
    let Some(db) = scope.db else { return err!("subqueries prohibited here") };
    let child = Scope { db: Some(db), parent: Some(scope), ctes: scope.ctes.clone(), ..Default::default() };
    let plan = crate::query::plan_select(q, &child)?;
    Ok((plan, child.correlated.get()))
}

fn sub_plan(kind: SubKind, plan: QueryPlan, correlated: bool) -> Expr {
    Expr::SubPlan { kind, plan: Rc::new(plan), correlated, cache: Rc::new(RefCell::new(None)) }
}

fn check_one_column(plan: &QueryPlan) -> Result<()> {
    if plan.cols.len() != 1 {
        return err!("sub-select returns {} columns - expected 1", plan.cols.len());
    }
    Ok(())
}

/// Resolve column references in `e` against `scope`, validate function
/// calls and collations, and precompute comparison affinity/collation.
pub fn bind(e: &Expr, scope: &Scope) -> Result<Expr> {
    let b = |x: &Expr| -> Result<Box<Expr>> { Ok(Box::new(bind(x, scope)?)) };
    Ok(match e {
        Expr::Column { table, name, dq } => match scope.resolve_all(table.as_deref(), name)? {
            Some(c) => c,
            None => {
                let alias = match table {
                    None => scope.aliases.iter().find(|(a, _)| a.eq_ignore_ascii_case(name)),
                    Some(_) => None,
                };
                if let Some((_, e)) = alias {
                    e.clone()
                } else if *dq && table.is_none() {
                    Expr::Lit(Value::Text(name.clone()))
                } else if let Some(t) = table {
                    return err!("no such column: {}.{}", t, name);
                } else {
                    return err!("no such column: {}", name);
                }
            }
        },
        Expr::Lit(_) | Expr::Col { .. } | Expr::AggRef { .. } | Expr::Outer { .. } | Expr::SubPlan { .. } => e.clone(),
        Expr::Window { func, over } => crate::window::bind_window(func, over, scope)?,
        Expr::Subquery(q) => {
            let (plan, corr) = bind_subquery(q, scope)?;
            check_one_column(&plan)?;
            sub_plan(SubKind::Scalar, plan, corr)
        }
        Expr::Exists(q) => {
            let (plan, corr) = bind_subquery(q, scope)?;
            sub_plan(SubKind::Exists, plan, corr)
        }
        Expr::InSelect { e, query, neg } => {
            let e = b(e)?;
            let (plan, corr) = bind_subquery(query, scope)?;
            check_one_column(&plan)?;
            let c = &plan.cols[0];
            let info = cmp_info_parts(
                (expr_affinity(&e), expr_collation(&e), has_explicit_coll(&e)),
                (c.aff, c.coll, c.explicit_coll),
            );
            sub_plan(SubKind::In { e, neg: *neg, info }, plan, corr)
        }
        Expr::Unary(op, a) => Expr::Unary(*op, b(a)?),
        Expr::Binary(op, x, y) | Expr::Compare { op, l: x, r: y, .. } => {
            let (x, y) = (b(x)?, b(y)?);
            if op.is_comparison() {
                let info = cmp_info(&x, &y);
                Expr::Compare { op: *op, l: x, r: y, info }
            } else {
                Expr::Binary(*op, x, y)
            }
        }
        Expr::IsNull(a, neg) => Expr::IsNull(b(a)?, *neg),
        Expr::Collate(a, c) => {
            if Collation::from_name(c).is_none() {
                return err!("no such collation sequence: {}", c);
            }
            Expr::Collate(b(a)?, c.clone())
        }
        Expr::Func { name, args, star, distinct, filter, order_by, .. } => {
            if crate::window::is_window_only(name) {
                return err!("misuse of window function {}()", name);
            }
            crate::func::check_function(name, args.len(), *star)?;
            if crate::func::is_aggregate(name, args.len()) {
                if *distinct && args.len() != 1 {
                    return err!("DISTINCT aggregates must have exactly one argument");
                }
                let mut inner = scope.clone();
                inner.allow_agg = false;
                inner.wins = None;
                let args = args.iter().map(|a| bind(a, &inner)).collect::<Result<Vec<_>>>()?;
                let filter = match filter {
                    Some(f) => Some(Box::new(bind(f, &inner)?)),
                    None => None,
                };
                let order_by = order_by
                    .iter()
                    .map(|t| Ok(OrderTerm { expr: bind(&t.expr, &inner)?, desc: t.desc, nulls_first: t.nulls_first }))
                    .collect::<Result<Vec<_>>>()?;
                let coll = args.iter().find_map(expr_collation).unwrap_or(Collation::Binary);
                let mut f = Expr::Func {
                    name: name.clone(),
                    args,
                    star: *star,
                    distinct: *distinct,
                    coll,
                    filter,
                    order_by,
                };
                // The aggregate belongs to the innermost level whose columns
                // it references.
                let up = min_level(&f).unwrap_or(0);
                let mut owner = scope;
                for _ in 0..up {
                    owner = owner.parent.unwrap();
                }
                let Some(aggs) = owner.aggs.as_ref().filter(|_| owner.allow_agg) else {
                    return err!("misuse of aggregate function {}()", name);
                };
                if up > 0 {
                    rebase(&mut f, up);
                }
                let coll = expr_collation(&f);
                let idx = aggs.borrow_mut().register(f);
                let r = Expr::AggRef { idx, coll };
                return Ok(if up > 0 { Expr::Outer { up, inner: Box::new(r) } } else { r });
            }
            if filter.is_some() {
                return err!("FILTER may not be used with non-aggregate {}()", name);
            }
            if !order_by.is_empty() {
                return err!("ORDER BY may not be used with non-aggregate {}()", name);
            }
            if *distinct {
                return err!("DISTINCT may not be used with non-aggregate {}()", name);
            }
            let args = args.iter().map(|a| bind(a, scope)).collect::<Result<Vec<_>>>()?;
            if name == "likelihood" {
                match &args[1] {
                    Expr::Lit(Value::Real(p)) if (0.0..=1.0).contains(p) => {}
                    _ => return err!("second argument to likelihood() must be a constant between 0.0 and 1.0"),
                }
            }
            let coll = args.iter().find_map(expr_collation).unwrap_or(Collation::Binary);
            Expr::Func { name: name.clone(), args, star: *star, distinct: *distinct, coll, filter: None, order_by: vec![] }
        }
        Expr::Cast(a, aff) => Expr::Cast(b(a)?, *aff),
        Expr::Case { base, whens, else_, .. } => {
            let base = match base {
                Some(x) => Some(b(x)?),
                None => None,
            };
            let mut bw = Vec::with_capacity(whens.len());
            for (w, t) in whens {
                bw.push((bind(w, scope)?, bind(t, scope)?));
            }
            let infos = match &base {
                Some(x) => bw.iter().map(|(w, _)| cmp_info(x, w)).collect(),
                None => vec![],
            };
            let else_ = match else_ {
                Some(x) => Some(b(x)?),
                None => None,
            };
            Expr::Case { base, whens: bw, else_, infos }
        }
        Expr::Between { e, lo, hi, neg, .. } => {
            let (e, lo, hi) = (b(e)?, b(lo)?, b(hi)?);
            let info_lo = cmp_info(&e, &lo);
            let info_hi = cmp_info(&e, &hi);
            Expr::Between { e, lo, hi, neg: *neg, info_lo, info_hi }
        }
        Expr::InList { e, list, neg, .. } => {
            let e = b(e)?;
            let list = list.iter().map(|a| bind(a, scope)).collect::<Result<Vec<_>>>()?;
            let info = CmpInfo { aff: expr_affinity(&e), coll: expr_collation(&e).unwrap_or(Collation::Binary) };
            Expr::InList { e, list, neg: *neg, info }
        }
        Expr::Like { e, pat, esc, neg, glob } => {
            let esc = match esc {
                Some(x) => Some(b(x)?),
                None => None,
            };
            Expr::Like { e: b(e)?, pat: b(pat)?, esc, neg: *neg, glob: *glob }
        }
    })
}

/// Affinity of an expression for comparison purposes (None = no affinity).
pub fn expr_affinity(e: &Expr) -> Option<Affinity> {
    match e {
        Expr::Col { aff, .. } => Some(*aff),
        Expr::Cast(_, aff) => Some(*aff),
        Expr::Collate(a, _) => expr_affinity(a),
        Expr::Outer { inner, .. } => expr_affinity(inner),
        Expr::SubPlan { kind: SubKind::Scalar, plan, .. } => plan.cols[0].aff,
        _ => None,
    }
}

/// Affinity applied to both operands of a comparison.
fn comparison_affinity(a: Option<Affinity>, b: Option<Affinity>) -> Option<Affinity> {
    match (a, b) {
        (Some(x), Some(y)) => {
            if x.is_numeric() || y.is_numeric() {
                Some(Affinity::Numeric)
            } else {
                None
            }
        }
        (Some(x), None) | (None, Some(x)) => Some(x),
        (None, None) => None,
    }
}

/// Direct children in SQLite's layout: (left operand, right operand, list).
pub fn expr_parts(e: &Expr) -> (Option<&Expr>, Option<&Expr>, Vec<&Expr>) {
    match e {
        Expr::Binary(_, a, b) | Expr::Compare { l: a, r: b, .. } => (Some(a), Some(b), vec![]),
        Expr::Unary(_, a) | Expr::IsNull(a, _) | Expr::Cast(a, _) | Expr::Collate(a, _) => (Some(a), None, vec![]),
        Expr::Func { args, .. } => (None, None, args.iter().collect()),
        Expr::Case { base, whens, else_, .. } => {
            let mut list = Vec::new();
            for (w, t) in whens {
                list.push(w);
                list.push(t);
            }
            if let Some(x) = else_ {
                list.push(x.as_ref());
            }
            (base.as_deref(), None, list)
        }
        Expr::Between { e, lo, hi, .. } => (Some(e), None, vec![lo.as_ref(), hi.as_ref()]),
        Expr::InList { e, list, .. } => (Some(e), None, list.iter().collect()),
        Expr::Like { e, pat, esc, .. } => {
            let mut list = vec![pat.as_ref(), e.as_ref()];
            if let Some(x) = esc {
                list.push(x.as_ref());
            }
            (None, None, list)
        }
        Expr::InSelect { e, .. } => (Some(e), None, vec![]),
        Expr::SubPlan { kind: SubKind::In { e, .. }, .. } => (Some(e), None, vec![]),
        Expr::Lit(_)
        | Expr::Column { .. }
        | Expr::Col { .. }
        | Expr::AggRef { .. }
        | Expr::Outer { .. }
        | Expr::Subquery(_)
        | Expr::Exists(_)
        | Expr::Window { .. }
        | Expr::SubPlan { .. } => (None, None, vec![]),
    }
}

/// Does the expression contain an explicit COLLATE (SQLite's EP_Collate)?
pub fn has_explicit_coll(e: &Expr) -> bool {
    if matches!(e, Expr::Collate(..)) {
        return true;
    }
    let (l, r, list) = expr_parts(e);
    l.is_some_and(has_explicit_coll) || r.is_some_and(has_explicit_coll) || list.into_iter().any(has_explicit_coll)
}

/// Collating sequence of an expression (sqlite3ExprCollSeq).
pub fn expr_collation(e: &Expr) -> Option<Collation> {
    let mut p = e;
    loop {
        match p {
            Expr::Cast(x, _) | Expr::Unary(UnOp::Pos, x) | Expr::Outer { inner: x, .. } => {
                p = x;
                continue;
            }
            Expr::Collate(_, c) => return Collation::from_name(c),
            Expr::Col { coll, .. } => return Some(*coll),
            Expr::AggRef { coll, .. } => return *coll,
            _ => {}
        }
        if !has_explicit_coll(p) {
            return None;
        }
        let (l, r, list) = expr_parts(p);
        if let Some(l) = l {
            if has_explicit_coll(l) {
                p = l;
                continue;
            }
        }
        let mut next = r;
        if let Some(x) = list.into_iter().find(|x| has_explicit_coll(x)) {
            next = Some(x);
        }
        p = next?;
    }
}

/// Collation for a binary comparison (sqlite3BinaryCompareCollSeq).
fn binary_collation(l: &Expr, r: &Expr) -> Collation {
    let c = if has_explicit_coll(l) {
        expr_collation(l)
    } else if has_explicit_coll(r) {
        expr_collation(r)
    } else {
        expr_collation(l).or_else(|| expr_collation(r))
    };
    c.unwrap_or(Collation::Binary)
}

pub fn cmp_info(l: &Expr, r: &Expr) -> CmpInfo {
    CmpInfo { aff: comparison_affinity(expr_affinity(l), expr_affinity(r)), coll: binary_collation(l, r) }
}

/// Comparison info from (affinity, collation, has explicit COLLATE) of
/// each operand.
pub fn cmp_info_parts(
    l: (Option<Affinity>, Option<Collation>, bool),
    r: (Option<Affinity>, Option<Collation>, bool),
) -> CmpInfo {
    let coll = if l.2 {
        l.1
    } else if r.2 {
        r.1
    } else {
        l.1.or(r.1)
    };
    CmpInfo { aff: comparison_affinity(l.0, r.0), coll: coll.unwrap_or(Collation::Binary) }
}

/// Apply a comparison affinity to one operand.
pub fn apply_cmp_affinity(v: Value, aff: Option<Affinity>) -> Value {
    match aff {
        Some(a) if a.is_numeric() => v.apply_numeric_cmp(),
        Some(Affinity::Text) => match v {
            Value::Int(_) | Value::Real(_) => Value::Text(v.to_text().unwrap()),
            v => v,
        },
        _ => v,
    }
}

/// Compare two non-NULL values under `info`.
pub fn compare_with(a: Value, b: Value, info: CmpInfo) -> Ordering {
    let a = apply_cmp_affinity(a, info.aff);
    let b = apply_cmp_affinity(b, info.aff);
    compare_coll(&a, &b, info.coll)
}

/// Three-valued comparison result: None if either side is NULL.
fn cmp3(a: &Value, b: &Value, info: CmpInfo) -> Option<Ordering> {
    if a.is_null() || b.is_null() {
        None
    } else {
        Some(compare_with(a.clone(), b.clone(), info))
    }
}

fn and3(a: Option<bool>, b: Option<bool>) -> Option<bool> {
    match (a, b) {
        (Some(false), _) | (_, Some(false)) => Some(false),
        (Some(true), Some(true)) => Some(true),
        _ => None,
    }
}

fn val3(b: Option<bool>) -> Value {
    match b {
        Some(b) => bool_val(b),
        None => Value::Null,
    }
}

fn arith(op: BinOp, a: Value, b: Value) -> Value {
    if a.is_null() || b.is_null() {
        return Value::Null;
    }
    let a = a.to_numeric();
    let b = b.to_numeric();
    if let (Value::Int(x), Value::Int(y)) = (&a, &b) {
        let (x, y) = (*x, *y);
        return match op {
            BinOp::Add => x.checked_add(y).map(Value::Int).unwrap_or(Value::Real(x as f64 + y as f64)),
            BinOp::Sub => x.checked_sub(y).map(Value::Int).unwrap_or(Value::Real(x as f64 - y as f64)),
            BinOp::Mul => x.checked_mul(y).map(Value::Int).unwrap_or(Value::Real(x as f64 * y as f64)),
            BinOp::Div => {
                if y == 0 {
                    Value::Null
                } else {
                    x.checked_div(y).map(Value::Int).unwrap_or(Value::Real(x as f64 / y as f64))
                }
            }
            BinOp::Rem => {
                if y == 0 {
                    Value::Null
                } else if y == -1 {
                    Value::Int(0)
                } else {
                    Value::Int(x % y)
                }
            }
            _ => unreachable!(),
        };
    }
    let x = a.to_f64();
    let y = b.to_f64();
    match op {
        BinOp::Add => Value::real(x + y),
        BinOp::Sub => Value::real(x - y),
        BinOp::Mul => Value::real(x * y),
        BinOp::Div => {
            if y == 0.0 {
                Value::Null
            } else {
                Value::real(x / y)
            }
        }
        BinOp::Rem => {
            let xi = crate::value::real_to_i64(x);
            let mut yi = crate::value::real_to_i64(y);
            if yi == 0 {
                return Value::Null;
            }
            if yi == -1 {
                yi = 1;
            }
            Value::Real((xi % yi) as f64)
        }
        _ => unreachable!(),
    }
}

fn bitwise(op: BinOp, a: Value, b: Value) -> Value {
    if a.is_null() || b.is_null() {
        return Value::Null;
    }
    let x = a.to_int();
    let y = b.to_int();
    Value::Int(match op {
        BinOp::BitAnd => x & y,
        BinOp::BitOr => x | y,
        BinOp::Shl => shift_left(x, y),
        BinOp::Shr => shift_left(x, y.checked_neg().unwrap_or(i64::MAX)),
        _ => unreachable!(),
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

fn bool_val(b: bool) -> Value {
    Value::Int(b as i64)
}

pub fn eval(e: &Expr, row: &[Value], cx: &Cx) -> Result<Value> {
    Ok(match e {
        Expr::Lit(v) => v.clone(),
        Expr::Col { idx, .. } | Expr::AggRef { idx, .. } => row[*idx].clone(),
        Expr::Column { name, .. } => return err!("no such column: {}", name),
        Expr::Subquery(_) | Expr::Exists(_) | Expr::InSelect { .. } => return err!("unbound subquery"),
        Expr::Window { func, .. } => match func.as_ref() {
            Expr::Func { name, .. } => return err!("misuse of window function {}()", name),
            _ => return err!("misuse of window function"),
        },
        Expr::Outer { up, inner } => {
            let mut c = cx;
            let mut r: &[Value] = row;
            for _ in 0..*up {
                let (orow, ocx) = c.outer.expect("outer row");
                r = orow;
                c = ocx;
            }
            eval(inner, r, c)?
        }
        Expr::SubPlan { kind, plan, correlated, cache } => eval_subquery(kind, plan, *correlated, cache, row, cx)?,
        Expr::Unary(op, a) => {
            let v = eval(a, row, cx)?;
            match op {
                UnOp::Pos => v,
                UnOp::Neg => match v.to_numeric() {
                    Value::Int(i) => i.checked_neg().map(Value::Int).unwrap_or(Value::Real(-(i as f64))),
                    Value::Real(f) => Value::Real(-f),
                    other => other,
                },
                UnOp::Not => match v.truthy() {
                    None => Value::Null,
                    Some(b) => bool_val(!b),
                },
                UnOp::BitNot => match v {
                    Value::Null => Value::Null,
                    v => Value::Int(!v.to_int()),
                },
            }
        }
        Expr::Binary(op, a, b) => match op {
            BinOp::And => {
                let l = eval(a, row, cx)?.truthy();
                if l == Some(false) {
                    return Ok(bool_val(false));
                }
                let r = eval(b, row, cx)?.truthy();
                match (l, r) {
                    (_, Some(false)) => bool_val(false),
                    (Some(true), Some(true)) => bool_val(true),
                    _ => Value::Null,
                }
            }
            BinOp::Or => {
                let l = eval(a, row, cx)?.truthy();
                if l == Some(true) {
                    return Ok(bool_val(true));
                }
                let r = eval(b, row, cx)?.truthy();
                match (l, r) {
                    (_, Some(true)) => bool_val(true),
                    (Some(false), Some(false)) => bool_val(false),
                    _ => Value::Null,
                }
            }
            BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Rem => {
                arith(*op, eval(a, row, cx)?, eval(b, row, cx)?)
            }
            BinOp::BitAnd | BinOp::BitOr | BinOp::Shl | BinOp::Shr => bitwise(*op, eval(a, row, cx)?, eval(b, row, cx)?),
            BinOp::Concat => {
                let l = eval(a, row, cx)?;
                let r = eval(b, row, cx)?;
                match (l.to_text(), r.to_text()) {
                    (Some(mut x), Some(y)) => {
                        x.push_str(&y);
                        Value::Text(x)
                    }
                    _ => Value::Null,
                }
            }
            _ => {
                // Unbound comparison: compute the comparison info on the fly.
                let info = cmp_info(a, b);
                eval_compare(*op, a, b, info, row, cx)?
            }
        },
        Expr::Compare { op, l, r, info } => eval_compare(*op, l, r, *info, row, cx)?,
        Expr::IsNull(a, neg) => {
            let v = eval(a, row, cx)?;
            bool_val(v.is_null() != *neg)
        }
        Expr::Collate(a, _) => eval(a, row, cx)?,
        Expr::Cast(a, aff) => eval(a, row, cx)?.cast(*aff),
        Expr::Case { base, whens, else_, infos } => {
            match base {
                Some(bx) => {
                    let bv = eval(bx, row, cx)?;
                    for (i, (w, t)) in whens.iter().enumerate() {
                        let wv = eval(w, row, cx)?;
                        let info = infos.get(i).copied().unwrap_or_default();
                        if cmp3(&bv, &wv, info) == Some(Ordering::Equal) {
                            return eval(t, row, cx);
                        }
                    }
                }
                None => {
                    for (w, t) in whens {
                        if eval(w, row, cx)?.truthy() == Some(true) {
                            return eval(t, row, cx);
                        }
                    }
                }
            }
            match else_ {
                Some(x) => eval(x, row, cx)?,
                None => Value::Null,
            }
        }
        Expr::Between { e, lo, hi, neg, info_lo, info_hi } => {
            let x = eval(e, row, cx)?;
            let l = eval(lo, row, cx)?;
            let h = eval(hi, row, cx)?;
            let ge = cmp3(&x, &l, *info_lo).map(|c| c != Ordering::Less);
            let le = cmp3(&x, &h, *info_hi).map(|c| c != Ordering::Greater);
            let r = and3(ge, le);
            val3(if *neg { r.map(|b| !b) } else { r })
        }
        Expr::InList { e, list, neg, info } => {
            if list.is_empty() {
                return Ok(bool_val(*neg));
            }
            let x = eval(e, row, cx)?;
            if x.is_null() {
                return Ok(Value::Null);
            }
            let mut saw_null = false;
            for item in list {
                let v = eval(item, row, cx)?;
                if v.is_null() {
                    saw_null = true;
                } else if compare_with(x.clone(), v, *info) == Ordering::Equal {
                    return Ok(bool_val(!*neg));
                }
            }
            if saw_null {
                Value::Null
            } else {
                bool_val(*neg)
            }
        }
        Expr::Like { e, pat, esc, neg, glob } => {
            let x = eval(e, row, cx)?;
            let p = eval(pat, row, cx)?;
            let esc = match esc {
                Some(x) => Some(eval(x, row, cx)?),
                None => None,
            };
            match crate::func::like_values(&p, &x, esc.as_ref(), *glob)? {
                Some(m) => bool_val(m != *neg),
                None => Value::Null,
            }
        }
        Expr::Func { name, args, coll, .. } => eval_func(name, args, *coll, row, cx)?,
    })
}

fn eval_compare(op: BinOp, a: &Expr, b: &Expr, info: CmpInfo, row: &[Value], cx: &Cx) -> Result<Value> {
    let l = eval(a, row, cx)?;
    let r = eval(b, row, cx)?;
    if l.is_null() || r.is_null() {
        return Ok(match op {
            BinOp::Is => bool_val(l.is_null() && r.is_null()),
            BinOp::IsNot => bool_val(!(l.is_null() && r.is_null())),
            _ => Value::Null,
        });
    }
    let c = compare_with(l, r, info);
    Ok(bool_val(match op {
        BinOp::Eq | BinOp::Is => c == Ordering::Equal,
        BinOp::Ne | BinOp::IsNot => c != Ordering::Equal,
        BinOp::Lt => c == Ordering::Less,
        BinOp::Le => c != Ordering::Greater,
        BinOp::Gt => c == Ordering::Greater,
        BinOp::Ge => c != Ordering::Less,
        _ => unreachable!(),
    }))
}

/// Function call; functions that evaluate their arguments lazily are
/// handled here, the rest in `func::call`.
fn eval_func(name: &str, args: &[Expr], coll: Collation, row: &[Value], cx: &Cx) -> Result<Value> {
    match name {
        "coalesce" | "ifnull" => {
            for a in args {
                let v = eval(a, row, cx)?;
                if !v.is_null() {
                    return Ok(v);
                }
            }
            Ok(Value::Null)
        }
        "iif" | "if" => {
            if eval(&args[0], row, cx)?.truthy() == Some(true) {
                eval(&args[1], row, cx)
            } else if args.len() > 2 {
                eval(&args[2], row, cx)
            } else {
                Ok(Value::Null)
            }
        }
        "likely" | "unlikely" | "likelihood" => eval(&args[0], row, cx),
        _ => {
            let vals = args.iter().map(|a| eval(a, row, cx)).collect::<Result<Vec<_>>>()?;
            crate::func::call(name, vals, coll)
        }
    }
}

/// Result of running a subquery for its expression kind.
fn run_subquery(kind: &SubKind, plan: &QueryPlan, row: &[Value], cx: &Cx) -> Result<SubResult> {
    let sub = Cx { db: cx.db, outer: Some((row, cx)) };
    Ok(match kind {
        SubKind::Scalar => {
            let rows = exec_query(plan, &sub, Some(1))?;
            SubResult::Value(rows.into_iter().next().map(|mut r| r.swap_remove(0)).unwrap_or(Value::Null))
        }
        SubKind::Exists => SubResult::Bool(!exec_query(plan, &sub, Some(1))?.is_empty()),
        SubKind::In { info, .. } => {
            let rows = exec_query(plan, &sub, None)?;
            let mut keys = BTreeSet::new();
            let mut has_null = false;
            let empty = rows.is_empty();
            for mut r in rows {
                let v = r.swap_remove(0);
                if v.is_null() {
                    has_null = true;
                } else {
                    keys.insert(IdxKey(vec![normalize(&apply_cmp_affinity(v, info.aff), info.coll)]));
                }
            }
            SubResult::Set { keys, has_null, empty }
        }
    })
}

fn eval_subquery(
    kind: &SubKind,
    plan: &QueryPlan,
    correlated: bool,
    cache: &RefCell<Option<SubResult>>,
    row: &[Value],
    cx: &Cx,
) -> Result<Value> {
    // The left operand of IN is evaluated first.
    let lhs = match kind {
        SubKind::In { e, .. } => Some(eval(e, row, cx)?),
        _ => None,
    };
    let fresh;
    let guard;
    let res: &SubResult = if correlated {
        fresh = run_subquery(kind, plan, row, cx)?;
        &fresh
    } else {
        if cache.borrow().is_none() {
            let r = run_subquery(kind, plan, row, cx)?;
            *cache.borrow_mut() = Some(r);
        }
        guard = cache.borrow();
        guard.as_ref().unwrap()
    };
    Ok(match (res, kind) {
        (SubResult::Value(v), _) => v.clone(),
        (SubResult::Bool(b), _) => bool_val(*b),
        (SubResult::Set { keys, has_null, empty }, SubKind::In { neg, info, .. }) => {
            if *empty {
                return Ok(bool_val(*neg));
            }
            let x = lhs.unwrap();
            if x.is_null() {
                return Ok(Value::Null);
            }
            let k = IdxKey(vec![normalize(&apply_cmp_affinity(x, info.aff), info.coll)]);
            if keys.contains(&k) {
                bool_val(!*neg)
            } else if *has_null {
                Value::Null
            } else {
                bool_val(*neg)
            }
        }
        _ => Value::Null,
    })
}
