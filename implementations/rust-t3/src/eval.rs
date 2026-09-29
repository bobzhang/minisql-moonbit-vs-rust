// Name binding and expression evaluation.

use std::cell::{Cell, OnceCell, RefCell};
use std::cmp::Ordering;
use std::collections::BTreeSet;
use std::rc::Rc;

use crate::ast::{BinOp, Expr, FuncCall, UnOp};
use crate::db::{key_val, Database, KeyVal};
use crate::functions::{self, ScalarFn};
use crate::query::{self, QueryPlan};
use crate::value::{apply_cmp_affinity, cast, compare_coll, Affinity, Coll, Num, Value};

/// A column visible through a FROM source.
#[derive(Debug, Clone)]
pub struct SrcCol {
    pub name: String,
    pub aff: Affinity,
    pub coll: Option<Coll>,
    /// Merged into an earlier column by USING/NATURAL: not visible to
    /// unqualified names or `*`.
    pub hidden: bool,
    /// Row positions of USING columns merged into this one; an unqualified
    /// reference means coalesce(this, merged...) (RIGHT/FULL joins).
    pub merged: Vec<usize>,
}

impl SrcCol {
    pub fn new(name: &str, aff: Affinity, coll: Option<Coll>) -> SrcCol {
        SrcCol { name: name.to_string(), aff, coll, hidden: false, merged: Vec::new() }
    }
}

/// Evaluation environment: the database and the rows of enclosing queries.
#[derive(Clone, Copy)]
pub struct Env<'a> {
    pub db: &'a Database,
    pub outer: Option<(&'a [Value], &'a Env<'a>)>,
}

impl<'a> Env<'a> {
    pub fn new(db: &'a Database) -> Env<'a> {
        Env { db, outer: None }
    }

    fn outer_row(&self, depth: usize) -> &'a [Value] {
        let mut e = self;
        let mut d = depth;
        loop {
            let (row, up) = e.outer.expect("outer row");
            if d == 1 {
                return row;
            }
            d -= 1;
            e = up;
        }
    }
}

/// One FROM source visible to expressions: its columns occupy
/// `offset .. offset + columns.len()` in the row, followed by the rowid.
#[derive(Debug, Clone)]
pub struct Source {
    pub name: String,
    pub columns: Vec<SrcCol>,
    pub offset: usize,
    /// Only reachable through a qualified name (like `excluded` in an upsert).
    pub qualified_only: bool,
    /// Whether the slot after the columns holds a rowid.
    pub has_rowid: bool,
}

#[derive(Debug, Clone, Default)]
pub struct Scope {
    pub sources: Vec<Source>,
    /// In an aggregate query, the row position of the first aggregate result.
    pub agg_base: Option<usize>,
    /// In a query with window functions, the row position of the first
    /// window function result.
    pub win_base: Option<usize>,
    /// Aggregate calls of this (aggregate) query, including those found in
    /// subqueries that only reference this query's columns.
    pub aggs: Option<Rc<RefCell<Vec<FuncCall>>>>,
    /// Set when a subquery finds an aggregate of this non-aggregate query
    /// (the query is then planned again as an aggregate query).
    pub agg_request: Option<Rc<Cell<bool>>>,
    /// Enclosing query's scope.
    pub parent: Option<Rc<Scope>>,
    /// Largest number of levels up that any name bound at this level (or in
    /// its subqueries) reached; > 0 means the query is correlated.
    pub corr: Rc<Cell<usize>>,
}

impl Scope {
    pub fn empty() -> Self {
        Scope::default()
    }

    /// A new query level nested in `parent`, sharing the correlation cell.
    pub fn child(parent: Option<Rc<Scope>>, corr: Rc<Cell<usize>>) -> Self {
        Scope { sources: Vec::new(), agg_base: None, win_base: None, aggs: None, agg_request: None, parent, corr }
    }

    fn level(&self, d: usize) -> &Scope {
        let mut s = self;
        for _ in 0..d {
            s = s.parent.as_deref().expect("scope level");
        }
        s
    }

    fn mark_outer(&self, d: usize) {
        for k in 0..d {
            let c = &self.level(k).corr;
            c.set(c.get().max(d - k));
        }
    }

    pub fn find_source(&self, name: &str) -> Option<&Source> {
        self.sources.iter().find(|s| s.name.eq_ignore_ascii_case(name))
    }
}

#[derive(Debug, Clone)]
pub struct When {
    pub cond: BExpr,
    pub then: BExpr,
    /// Comparison affinity and collation for simple CASE.
    pub aff: Affinity,
    pub coll: Coll,
}

#[derive(Debug, Clone)]
pub enum SubKind {
    Scalar,
    Exists,
    In { e: Box<BExpr>, not: bool, aff: Affinity, coll: Coll },
}

/// Cached result of an uncorrelated subquery.
#[derive(Debug)]
pub enum SubCache {
    Value(Value),
    /// IN: values of the column, a lookup set when usable, and whether a
    /// NULL was seen.
    List(Vec<Value>, Option<BTreeSet<KeyVal>>, bool),
}

#[derive(Debug, Clone)]
pub struct Subquery {
    pub plan: Rc<QueryPlan>,
    pub kind: SubKind,
    pub correlated: bool,
    pub cache: Rc<OnceCell<SubCache>>,
}

#[derive(Debug, Clone)]
pub enum BExpr {
    Const(Value),
    Col { idx: usize, aff: Affinity, coll: Option<Coll> },
    /// Column of the row of an enclosing query `depth` levels up.
    Outer { depth: usize, idx: usize, aff: Affinity, coll: Option<Coll> },
    Sub(Box<Subquery>),
    Neg(Box<BExpr>),
    Pos(Box<BExpr>),
    Not(Box<BExpr>),
    BitNot(Box<BExpr>),
    Arith(BinOp, Box<BExpr>, Box<BExpr>),
    Bit(BinOp, Box<BExpr>, Box<BExpr>),
    Concat(Box<BExpr>, Box<BExpr>),
    Cmp(BinOp, Box<BExpr>, Box<BExpr>, Affinity, Coll),
    And(Box<BExpr>, Box<BExpr>),
    Or(Box<BExpr>, Box<BExpr>),
    IsNull(Box<BExpr>, bool),
    Func(ScalarFn, Vec<BExpr>, Coll),
    /// coalesce/ifnull: first non-NULL argument, evaluated lazily.
    Coalesce(Vec<BExpr>),
    Case { base: Option<Box<BExpr>>, whens: Vec<When>, else_: Option<Box<BExpr>> },
    Cast(Box<BExpr>, Affinity),
    Collate(Box<BExpr>, Coll),
    InList { e: Box<BExpr>, list: Vec<BExpr>, not: bool, aff: Affinity, coll: Coll },
    /// `x BETWEEN lo AND hi`, as `x >= lo AND x <= hi`.
    Between(Box<BExpr>),
}

fn is_rowid_name(n: &str) -> bool {
    n.eq_ignore_ascii_case("rowid") || n.eq_ignore_ascii_case("oid") || n.eq_ignore_ascii_case("_rowid_")
}

fn bx(e: BExpr) -> Box<BExpr> {
    Box::new(e)
}

/// Builds a comparison node with SQLite's affinity and collation rules.
pub fn make_cmp(op: BinOp, l: BExpr, r: BExpr) -> Result<BExpr, String> {
    let aff = comparison_affinity(affinity(&l), affinity(&r));
    let coll = check_coll(binary_coll(&l, &r))?;
    Ok(BExpr::Cmp(op, bx(l), bx(r), aff, coll))
}

/// Fails if a collation that is actually needed is unknown.
pub fn check_coll(c: Coll) -> Result<Coll, String> {
    if c == Coll::Invalid {
        Err("no such collation sequence".to_string())
    } else {
        Ok(c)
    }
}

pub fn bind(e: &Expr, scope: &Scope, db: &Database) -> Result<BExpr, String> {
    Ok(match e {
        Expr::Literal(v) => BExpr::Const(v.clone()),
        Expr::Column { table, name, dq } => bind_column(table.as_deref(), name, *dq, scope)?,
        Expr::Unary(op, x) => {
            let x = bx(bind(x, scope, db)?);
            match op {
                UnOp::Neg => BExpr::Neg(x),
                UnOp::Pos => BExpr::Pos(x),
                UnOp::Not => BExpr::Not(x),
                UnOp::BitNot => BExpr::BitNot(x),
            }
        }
        Expr::Binary(op, l, r) => {
            let l = bind(l, scope, db)?;
            let r = bind(r, scope, db)?;
            match op {
                BinOp::And => BExpr::And(bx(l), bx(r)),
                BinOp::Or => BExpr::Or(bx(l), bx(r)),
                BinOp::Concat => BExpr::Concat(bx(l), bx(r)),
                BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Rem => BExpr::Arith(*op, bx(l), bx(r)),
                BinOp::BitAnd | BinOp::BitOr | BinOp::Shl | BinOp::Shr => BExpr::Bit(*op, bx(l), bx(r)),
                BinOp::Eq
                | BinOp::Ne
                | BinOp::Lt
                | BinOp::Le
                | BinOp::Gt
                | BinOp::Ge
                | BinOp::Is
                | BinOp::IsNot => match (op, &r) {
                    // x IS [NOT] NULL
                    (BinOp::Is | BinOp::IsNot, BExpr::Const(Value::Null)) => BExpr::IsNull(bx(l), *op == BinOp::IsNot),
                    _ => make_cmp(*op, l, r)?,
                },
            }
        }
        Expr::IsNull(x, neg) => BExpr::IsNull(bx(bind(x, scope, db)?), *neg),
        Expr::Function(fc) => {
            if fc.over.is_some() || crate::window::is_window_only(&fc.name) {
                return Err(format!("misuse of window function {}()", fc.name));
            }
            if crate::agg::is_agg_call(&fc.name, fc.args.len()) {
                if let Some(b) = bind_outer_agg(fc, scope)? {
                    return Ok(b);
                }
                return Err(format!("misuse of aggregate function {}()", fc.name));
            }
            if fc.filter.is_some() {
                return Err(format!("FILTER may not be used with non-aggregate {}()", fc.name));
            }
            if !fc.order_by.is_empty() {
                return Err(format!("ORDER BY may not be used with non-aggregate {}()", fc.name));
            }
            if fc.distinct {
                return Err(format!("DISTINCT may not be used with non-aggregate {}()", fc.name));
            }
            bind_function(&fc.name, &fc.args, fc.star, scope, db)?
        }
        Expr::SourceCol { src, col } => source_col(scope, 0, &scope.sources[*src], *col),
        Expr::Subquery(q) => bind_subquery(q, SubKind::Scalar, scope, db)?,
        Expr::Exists(q) => bind_subquery(q, SubKind::Exists, scope, db)?,
        Expr::InSelect { e, query, not } => {
            let x = bind(e, scope, db)?;
            let kind = SubKind::In { e: bx(x), not: *not, aff: Affinity::None, coll: Coll::Binary };
            bind_subquery(query, kind, scope, db)?
        }
        Expr::WinRef(i) => match scope.win_base {
            Some(b) => BExpr::Col { idx: b + i, aff: Affinity::None, coll: None },
            None => return Err("misuse of window function".to_string()),
        },
        Expr::AggRef(i) => match scope.agg_base {
            Some(b) => BExpr::Col { idx: b + i, aff: Affinity::None, coll: None },
            None => return Err("misuse of aggregate".to_string()),
        },
        Expr::Case { base, whens, else_ } => {
            let base = match base {
                Some(b) => Some(bind(b, scope, db)?),
                None => None,
            };
            let mut bw = Vec::with_capacity(whens.len());
            for (w, t) in whens {
                let cond = bind(w, scope, db)?;
                let then = bind(t, scope, db)?;
                let (aff, coll) = match &base {
                    Some(b) => (comparison_affinity(affinity(b), affinity(&cond)), check_coll(binary_coll(b, &cond))?),
                    None => (Affinity::None, Coll::Binary),
                };
                bw.push(When { cond, then, aff, coll });
            }
            let else_ = match else_ {
                Some(e) => Some(bx(bind(e, scope, db)?)),
                None => None,
            };
            BExpr::Case { base: base.map(bx), whens: bw, else_ }
        }
        Expr::Cast(x, t) => {
            let aff = if t.trim().is_empty() { Affinity::Numeric } else { Affinity::from_type(Some(t)) };
            BExpr::Cast(bx(bind(x, scope, db)?), aff)
        }
        Expr::Collate(x, c) => BExpr::Collate(bx(bind(x, scope, db)?), Coll::from_name(c).unwrap_or(Coll::Invalid)),
        Expr::Between { e, lo, hi, not } => {
            let x = bind(e, scope, db)?;
            let lo = bind(lo, scope, db)?;
            let hi = bind(hi, scope, db)?;
            let both =
                BExpr::Between(bx(BExpr::And(bx(make_cmp(BinOp::Ge, x.clone(), lo)?), bx(make_cmp(BinOp::Le, x, hi)?))));
            if *not {
                BExpr::Not(bx(both))
            } else {
                both
            }
        }
        Expr::InList { e, list, not } => {
            let x = bind(e, scope, db)?;
            let mut bl = Vec::with_capacity(list.len());
            for i in list {
                bl.push(bind(i, scope, db)?);
            }
            // `x IN (c)` with one constant is `x = +c` (as SQLite parses it)
            if bl.len() == 1 && is_constant(&bl[0]) {
                let c = bl.pop().unwrap();
                let eq = make_cmp(BinOp::Eq, x, BExpr::Pos(bx(c)))?;
                return Ok(if *not { BExpr::Not(bx(eq)) } else { eq });
            }
            let aff = affinity(&x);
            let coll = check_coll(expr_coll(&x).unwrap_or(Coll::Binary))?;
            BExpr::InList { e: bx(x), list: bl, not: *not, aff, coll }
        }
        Expr::Like { op, e, pattern, escape, not } => {
            let mut args = vec![(**pattern).clone(), (**e).clone()];
            if let Some(esc) = escape {
                args.push((**esc).clone());
            }
            let f = bind_function(op, &args, false, scope, db)?;
            if *not {
                BExpr::Not(bx(f))
            } else {
                f
            }
        }
    })
}

fn bind_function(name: &str, args: &[Expr], star: bool, scope: &Scope, db: &Database) -> Result<BExpr, String> {
    let f = functions::lookup(name, if star { 0 } else { args.len() })?;
    let mut bargs = Vec::with_capacity(args.len());
    for a in args {
        bargs.push(bind(a, scope, db)?);
    }
    let lname = name.to_ascii_lowercase();
    match lname.as_str() {
        "coalesce" | "ifnull" => return Ok(BExpr::Coalesce(bargs)),
        "iif" | "if" => {
            let mut it = bargs.into_iter();
            let cond = it.next().unwrap();
            let then = it.next().unwrap();
            let else_ = it.next().map(bx);
            return Ok(BExpr::Case {
                base: None,
                whens: vec![When { cond, then, aff: Affinity::None, coll: Coll::Binary }],
                else_,
            });
        }
        "likelihood" => {
            let ok = matches!(&bargs[1], BExpr::Const(Value::Real(p)) if (0.0..=1.0).contains(p));
            if !ok {
                return Err("second argument to likelihood() must be a constant between 0.0 and 1.0".to_string());
            }
        }
        _ => {}
    }
    // functions that compare values use the collation of the leftmost
    // argument that has one
    let mut coll = bargs.iter().find_map(expr_coll).unwrap_or(Coll::Binary);
    if matches!(lname.as_str(), "min" | "max" | "nullif") {
        coll = check_coll(coll)?;
    }
    Ok(BExpr::Func(f, bargs, coll))
}

/// Whether an unqualified name refers to a column (or rowid) of the
/// current query level.
pub fn resolves_column(name: &str, scope: &Scope) -> bool {
    matches!(resolve_at(None, name, scope, 0), Ok(Some(_)))
}

/// Reference to column `i` of `src` from `depth` levels below it.
fn col_ref(depth: usize, idx: usize, aff: Affinity, coll: Option<Coll>) -> BExpr {
    if depth == 0 {
        BExpr::Col { idx, aff, coll }
    } else {
        BExpr::Outer { depth, idx, aff, coll }
    }
}

/// Unqualified reference to a source column (coalescing USING columns of
/// RIGHT/FULL joins).
pub fn source_col(scope: &Scope, depth: usize, src: &Source, i: usize) -> BExpr {
    let c = &src.columns[i];
    let own = col_ref(depth, src.offset + i, c.aff, c.coll);
    if c.merged.is_empty() {
        return own;
    }
    let mut args = vec![own];
    for &m in &c.merged {
        let (aff, coll) = scope
            .sources
            .iter()
            .find(|s| m >= s.offset && m < s.offset + s.columns.len())
            .map(|s| (s.columns[m - s.offset].aff, s.columns[m - s.offset].coll))
            .unwrap_or((Affinity::None, None));
        args.push(col_ref(depth, m, aff, coll));
    }
    BExpr::Coalesce(args)
}

/// Resolves a name against the sources of one scope level (`depth` levels
/// up from where it is used). Ok(None) = not found at this level.
fn resolve_at(table: Option<&str>, name: &str, level: &Scope, depth: usize) -> Result<Option<BExpr>, String> {
    let rowid = |src: &Source| col_ref(depth, src.offset + src.columns.len(), Affinity::Integer, None);
    if let Some(t) = table {
        let mut matches = level.sources.iter().filter(|s| s.name.eq_ignore_ascii_case(t));
        let Some(src) = matches.next() else { return Ok(None) };
        if let Some(i) = src.columns.iter().position(|c| c.name.eq_ignore_ascii_case(name)) {
            if matches.next().is_some() {
                return Err(format!("ambiguous column name: {}.{}", t, name));
            }
            let c = &src.columns[i];
            return Ok(Some(col_ref(depth, src.offset + i, c.aff, c.coll)));
        }
        if is_rowid_name(name) && src.has_rowid {
            return Ok(Some(rowid(src)));
        }
        return Ok(None);
    }
    let mut found: Option<BExpr> = None;
    for src in level.sources.iter().filter(|s| !s.qualified_only) {
        if let Some(i) = src.columns.iter().position(|c| !c.hidden && c.name.eq_ignore_ascii_case(name)) {
            if found.is_some() {
                return Err(format!("ambiguous column name: {}", name));
            }
            found = Some(source_col(level, depth, src, i));
        }
    }
    if found.is_some() {
        return Ok(found);
    }
    let mut visible = level.sources.iter().filter(|s| !s.qualified_only);
    if let (Some(src), None) = (visible.next(), visible.next()) {
        if is_rowid_name(name) && src.has_rowid {
            return Ok(Some(rowid(src)));
        }
    }
    Ok(None)
}

fn bind_column(table: Option<&str>, name: &str, dq: bool, scope: &Scope) -> Result<BExpr, String> {
    let mut level = Some(scope);
    let mut depth = 0;
    while let Some(l) = level {
        if let Some(b) = resolve_at(table, name, l, depth)? {
            scope.mark_outer(depth);
            return Ok(b);
        }
        level = l.parent.as_deref();
        depth += 1;
    }
    if let Some(t) = table {
        return Err(format!("no such column: {}.{}", t, name));
    }
    if dq {
        return Ok(BExpr::Const(Value::Text(name.to_string())));
    }
    if name.eq_ignore_ascii_case("true") {
        return Ok(BExpr::Const(Value::Integer(1)));
    }
    if name.eq_ignore_ascii_case("false") {
        return Ok(BExpr::Const(Value::Integer(0)));
    }
    Err(format!("no such column: {}", name))
}

/// Scope level (0 = current) that a column reference resolves to.
fn column_level(table: Option<&str>, name: &str, scope: &Scope) -> Option<usize> {
    let mut level = Some(scope);
    let mut depth = 0;
    while let Some(l) = level {
        match resolve_at(table, name, l, depth) {
            Ok(Some(_)) | Err(_) => return Some(depth),
            Ok(None) => {}
        }
        level = l.parent.as_deref();
        depth += 1;
    }
    None
}

/// If every column referenced by an aggregate call's arguments belongs to
/// the same enclosing aggregate query, the call is an aggregate of that
/// query: returns its level.
pub fn outer_agg_level(fc: &FuncCall, scope: &Scope) -> Option<usize> {
    let mut refs: Vec<(Option<String>, String)> = Vec::new();
    let mut exprs: Vec<&Expr> = fc.args.iter().collect();
    if let Some(f) = &fc.filter {
        exprs.push(f);
    }
    for e in exprs {
        let _ = crate::agg::map_expr(e, &mut |x| {
            if let Expr::Column { table, name, .. } = x {
                refs.push((table.clone(), name.clone()));
            }
            Ok(None)
        });
    }
    if refs.is_empty() {
        return None;
    }
    // the aggregate belongs to the innermost query whose columns it uses
    let mut level = usize::MAX;
    for (t, n) in &refs {
        let l = column_level(t.as_deref(), n, scope)?;
        if l == 0 {
            return None;
        }
        level = level.min(l);
    }
    let l = level;
    let target = scope.level(l);
    if target.aggs.is_some() && target.agg_base.is_some() {
        Some(l)
    } else {
        if let Some(r) = &target.agg_request {
            r.set(true);
        }
        None
    }
}

/// Binds an aggregate call that belongs to an enclosing query.
fn bind_outer_agg(fc: &FuncCall, scope: &Scope) -> Result<Option<BExpr>, String> {
    let Some(l) = outer_agg_level(fc, scope) else { return Ok(None) };
    crate::agg::agg_kind(fc)?;
    let target = scope.level(l);
    let aggs = target.aggs.as_ref().unwrap();
    let n = {
        let mut v = aggs.borrow_mut();
        v.push(fc.clone());
        v.len() - 1
    };
    scope.mark_outer(l);
    Ok(Some(BExpr::Outer { depth: l, idx: target.agg_base.unwrap() + n, aff: Affinity::None, coll: None }))
}

fn bind_subquery(q: &crate::ast::Select, kind: SubKind, scope: &Scope, db: &Database) -> Result<BExpr, String> {
    let corr = Rc::new(Cell::new(0));
    let plan = query::plan_query(db, q, Some(Rc::new(scope.clone())), corr.clone())?;
    let ncols = plan.columns.len();
    let kind = match kind {
        SubKind::In { e, not, .. } => {
            if ncols != 1 {
                return Err(format!("sub-select returns {} columns - expected 1", ncols));
            }
            let col = &plan.columns[0];
            let raff = col.aff;
            let aff = comparison_affinity(affinity(&e), raff);
            let coll = match expr_coll(&e) {
                Some(c) => c,
                None => col.coll.unwrap_or(Coll::Binary),
            };
            SubKind::In { e, not, aff, coll: check_coll(coll)? }
        }
        SubKind::Scalar => {
            if ncols != 1 {
                return Err(format!("sub-select returns {} columns - expected 1", ncols));
            }
            SubKind::Scalar
        }
        k => k,
    };
    // references beyond the subquery's own level make it correlated
    let depth = corr.get();
    if depth > 1 {
        scope.mark_outer(depth - 1);
    }
    Ok(BExpr::Sub(Box::new(Subquery { plan: Rc::new(plan), kind, correlated: depth > 0, cache: Rc::new(OnceCell::new()) })))
}

/// Whether an expression reads no row (sqlite3ExprIsConstant).
pub fn is_constant(e: &BExpr) -> bool {
    match e {
        BExpr::Col { .. } | BExpr::Outer { .. } | BExpr::Sub(_) => false,
        e => children(e).into_iter().all(is_constant),
    }
}

/// Affinity of an expression (sqlite3ExprAffinity).
pub fn affinity(e: &BExpr) -> Affinity {
    match e {
        BExpr::Col { aff, .. } | BExpr::Outer { aff, .. } => *aff,
        BExpr::Cast(_, aff) => *aff,
        BExpr::Sub(sq) if matches!(sq.kind, SubKind::Scalar) => sq.plan.columns[0].aff,
        BExpr::Collate(x, _) => affinity(x),
        _ => Affinity::None,
    }
}

/// Direct subexpressions, in SQLite's left / right / list order.
pub fn children(e: &BExpr) -> Vec<&BExpr> {
    match e {
        BExpr::Const(_) | BExpr::Col { .. } | BExpr::Outer { .. } => vec![],
        BExpr::Sub(sq) => match &sq.kind {
            SubKind::In { e, .. } => vec![e],
            _ => vec![],
        },
        BExpr::Neg(x) | BExpr::Pos(x) | BExpr::Not(x) | BExpr::BitNot(x) | BExpr::IsNull(x, _) => vec![x],
        BExpr::Cast(x, _) | BExpr::Collate(x, _) | BExpr::Between(x) => vec![x],
        BExpr::Arith(_, l, r)
        | BExpr::Bit(_, l, r)
        | BExpr::Concat(l, r)
        | BExpr::Cmp(_, l, r, _, _)
        | BExpr::And(l, r)
        | BExpr::Or(l, r) => vec![l, r],
        BExpr::Func(_, args, _) | BExpr::Coalesce(args) => args.iter().collect(),
        BExpr::Case { base, whens, else_ } => {
            let mut v: Vec<&BExpr> = Vec::new();
            if let Some(b) = base {
                v.push(b);
            }
            for w in whens {
                v.push(&w.cond);
                v.push(&w.then);
            }
            if let Some(e) = else_ {
                v.push(e);
            }
            v
        }
        BExpr::InList { e, list, .. } => {
            let mut v: Vec<&BExpr> = vec![e];
            v.extend(list.iter());
            v
        }
    }
}

/// Whether the expression contains an explicit COLLATE (EP_Collate).
fn has_explicit_coll(e: &BExpr) -> bool {
    matches!(e, BExpr::Collate(..)) || children(e).into_iter().any(has_explicit_coll)
}

/// Collation of an expression, if any (sqlite3ExprCollSeq).
pub fn expr_coll(e: &BExpr) -> Option<Coll> {
    let mut p = e;
    loop {
        match p {
            BExpr::Col { coll, .. } | BExpr::Outer { coll, .. } => return *coll,
            BExpr::Collate(_, c) => return Some(*c),
            BExpr::Cast(x, _) | BExpr::Pos(x) => p = x,
            _ => {
                if !has_explicit_coll(p) {
                    return None;
                }
                p = children(p).into_iter().find(|c| has_explicit_coll(c))?;
            }
        }
    }
}

/// Collation used to compare two operands (sqlite3BinaryCompareCollSeq).
pub fn binary_coll(l: &BExpr, r: &BExpr) -> Coll {
    let c = if has_explicit_coll(l) {
        expr_coll(l)
    } else if has_explicit_coll(r) {
        expr_coll(r)
    } else {
        expr_coll(l).or_else(|| expr_coll(r))
    };
    c.unwrap_or(Coll::Binary)
}

/// Affinity applied to both operands of a comparison (sqlite3CompareAffinity).
pub fn comparison_affinity(a: Affinity, b: Affinity) -> Affinity {
    if a != Affinity::None && b != Affinity::None {
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

/// Compares two non-NULL values as a comparison operator would.
pub fn compare_values(a: &Value, b: &Value, aff: Affinity, coll: Coll) -> Ordering {
    if aff == Affinity::Text && !matches!(a, Value::Text(_)) && !matches!(b, Value::Text(_)) {
        return compare_coll(a, b, coll);
    }
    let ca = apply_cmp_affinity(a, aff);
    let cb = apply_cmp_affinity(b, aff);
    compare_coll(ca.as_ref().unwrap_or(a), cb.as_ref().unwrap_or(b), coll)
}

pub fn eval(e: &BExpr, row: &[Value], env: &Env) -> Result<Value, String> {
    Ok(match e {
        BExpr::Const(v) => v.clone(),
        BExpr::Col { idx, .. } => row[*idx].clone(),
        BExpr::Outer { depth, idx, .. } => env.outer_row(*depth)[*idx].clone(),
        BExpr::Sub(sq) => eval_subquery(sq, row, env)?,
        BExpr::Neg(x) => {
            let v = eval(x, row, env)?;
            arith(BinOp::Sub, &Value::Integer(0), &v)
        }
        BExpr::Pos(x) | BExpr::Collate(x, _) | BExpr::Between(x) => eval(x, row, env)?,
        BExpr::Not(x) => match eval(x, row, env)?.truth() {
            None => Value::Null,
            Some(b) => Value::from_bool(!b),
        },
        BExpr::BitNot(x) => match eval(x, row, env)? {
            Value::Null => Value::Null,
            v => Value::Integer(!v.to_int()),
        },
        BExpr::Arith(op, l, r) => {
            let a = eval(l, row, env)?;
            let b = eval(r, row, env)?;
            arith(*op, &a, &b)
        }
        BExpr::Bit(op, l, r) => {
            let a = eval(l, row, env)?;
            let b = eval(r, row, env)?;
            if a.is_null() || b.is_null() {
                return Ok(Value::Null);
            }
            Value::Integer(bitop(*op, a.to_int(), b.to_int()))
        }
        BExpr::Concat(l, r) => {
            let a = eval(l, row, env)?;
            let b = eval(r, row, env)?;
            match (a.to_text(), b.to_text()) {
                (Some(mut x), Some(y)) => {
                    x.push_str(&y);
                    Value::Text(x)
                }
                _ => Value::Null,
            }
        }
        BExpr::Cmp(op, l, r, aff, coll) => {
            let a = eval(l, row, env)?;
            let b = eval(r, row, env)?;
            if a.is_null() || b.is_null() {
                return Ok(match op {
                    BinOp::Is => Value::from_bool(a.is_null() && b.is_null()),
                    BinOp::IsNot => Value::from_bool(a.is_null() != b.is_null()),
                    _ => Value::Null,
                });
            }
            let ord = compare_values(&a, &b, *aff, *coll);
            let res = match op {
                BinOp::Eq | BinOp::Is => ord == Ordering::Equal,
                BinOp::Ne | BinOp::IsNot => ord != Ordering::Equal,
                BinOp::Lt => ord == Ordering::Less,
                BinOp::Le => ord != Ordering::Greater,
                BinOp::Gt => ord == Ordering::Greater,
                BinOp::Ge => ord != Ordering::Less,
                _ => unreachable!(),
            };
            Value::from_bool(res)
        }
        BExpr::And(l, r) => {
            let a = eval(l, row, env)?.truth();
            if a == Some(false) {
                return Ok(Value::Integer(0));
            }
            let b = eval(r, row, env)?.truth();
            match (a, b) {
                (_, Some(false)) => Value::Integer(0),
                (Some(true), Some(true)) => Value::Integer(1),
                _ => Value::Null,
            }
        }
        BExpr::Or(l, r) => {
            let a = eval(l, row, env)?.truth();
            if a == Some(true) {
                return Ok(Value::Integer(1));
            }
            let b = eval(r, row, env)?.truth();
            match (a, b) {
                (_, Some(true)) => Value::Integer(1),
                (Some(false), Some(false)) => Value::Integer(0),
                _ => Value::Null,
            }
        }
        BExpr::IsNull(x, neg) => {
            let v = eval(x, row, env)?;
            Value::from_bool(v.is_null() != *neg)
        }
        BExpr::Func(f, args, coll) => {
            let mut vals = Vec::with_capacity(args.len());
            for a in args {
                vals.push(eval(a, row, env)?);
            }
            f(&vals, *coll)?
        }
        BExpr::Coalesce(args) => {
            for a in args {
                let v = eval(a, row, env)?;
                if !v.is_null() {
                    return Ok(v);
                }
            }
            Value::Null
        }
        BExpr::Case { base, whens, else_ } => {
            let bv = match base {
                Some(b) => Some(eval(b, row, env)?),
                None => None,
            };
            for w in whens {
                let c = eval(&w.cond, row, env)?;
                let hit = match &bv {
                    Some(b) => {
                        !b.is_null() && !c.is_null() && compare_values(b, &c, w.aff, w.coll) == Ordering::Equal
                    }
                    None => c.truth() == Some(true),
                };
                if hit {
                    return eval(&w.then, row, env);
                }
            }
            match else_ {
                Some(e) => eval(e, row, env)?,
                None => Value::Null,
            }
        }
        BExpr::Cast(x, aff) => cast(eval(x, row, env)?, *aff),
        BExpr::InList { e, list, not, aff, coll } => {
            if list.is_empty() {
                return Ok(Value::from_bool(*not));
            }
            let v = eval(e, row, env)?;
            if v.is_null() {
                return Ok(Value::Null);
            }
            let mut saw_null = false;
            for item in list {
                let iv = eval(item, row, env)?;
                if iv.is_null() {
                    saw_null = true;
                    continue;
                }
                if compare_values(&v, &iv, *aff, *coll) == Ordering::Equal {
                    return Ok(Value::from_bool(!*not));
                }
            }
            if saw_null {
                Value::Null
            } else {
                Value::from_bool(*not)
            }
        }
    })
}

fn run_sub(sq: &Subquery, row: &[Value], env: &Env) -> Result<Vec<Vec<Value>>, String> {
    let sub_env = Env { db: env.db, outer: Some((row, env)) };
    let limit = match sq.kind {
        SubKind::In { .. } => None,
        _ => Some(1),
    };
    query::run_query(&sq.plan, &sub_env, limit)
}

fn sub_result(sq: &Subquery, row: &[Value], env: &Env) -> Result<SubCache, String> {
    let rows = run_sub(sq, row, env)?;
    Ok(match &sq.kind {
        SubKind::Scalar => SubCache::Value(rows.into_iter().next().map(|mut r| r.swap_remove(0)).unwrap_or(Value::Null)),
        SubKind::Exists => SubCache::Value(Value::from_bool(!rows.is_empty())),
        SubKind::In { aff, coll, .. } => {
            let mut has_null = false;
            let mut vals = Vec::with_capacity(rows.len());
            for mut r in rows {
                let v = r.swap_remove(0);
                if v.is_null() {
                    has_null = true;
                } else {
                    vals.push(v);
                }
            }
            // a lookup set (built only for cached results) is exact unless
            // TEXT affinity compares two non-text values without conversion
            let set = if *aff != Affinity::Text && !sq.correlated {
                Some(vals.iter().map(|v| key_val(apply_cmp_affinity(v, *aff).as_ref().unwrap_or(v), *coll)).collect())
            } else {
                None
            };
            SubCache::List(vals, set, has_null)
        }
    })
}

/// Values (without NULLs) produced by an uncorrelated IN subquery.
pub fn sub_values(sq: &Subquery, row: &[Value], env: &Env) -> Result<Vec<Value>, String> {
    if sq.cache.get().is_none() {
        let r = sub_result(sq, row, env)?;
        if sq.correlated {
            return Ok(match r {
                SubCache::List(vals, _, _) => vals,
                SubCache::Value(v) => vec![v],
            });
        }
        let _ = sq.cache.set(r);
    }
    Ok(match sq.cache.get().unwrap() {
        SubCache::List(vals, _, _) => vals.clone(),
        SubCache::Value(v) => vec![v.clone()],
    })
}

fn eval_subquery(sq: &Subquery, row: &[Value], env: &Env) -> Result<Value, String> {
    // the left operand of IN is evaluated first
    let lhs = match &sq.kind {
        SubKind::In { e, .. } => Some(eval(e, row, env)?),
        _ => None,
    };
    let owned;
    let res: &SubCache = if sq.correlated {
        owned = sub_result(sq, row, env)?;
        &owned
    } else {
        if sq.cache.get().is_none() {
            let r = sub_result(sq, row, env)?;
            let _ = sq.cache.set(r);
        }
        sq.cache.get().unwrap()
    };
    match (res, &sq.kind) {
        (SubCache::Value(v), _) => Ok(v.clone()),
        (SubCache::List(vals, set, has_null), SubKind::In { not, aff, coll, .. }) => {
            let v = lhs.unwrap();
            if vals.is_empty() && !has_null {
                return Ok(Value::from_bool(*not));
            }
            if v.is_null() {
                return Ok(Value::Null);
            }
            let found = match set {
                Some(set) => set.contains(&key_val(apply_cmp_affinity(&v, *aff).as_ref().unwrap_or(&v), *coll)),
                None => vals.iter().any(|x| compare_values(&v, x, *aff, *coll) == Ordering::Equal),
            };
            if found {
                Ok(Value::from_bool(!*not))
            } else if *has_null {
                Ok(Value::Null)
            } else {
                Ok(Value::from_bool(*not))
            }
        }
        _ => unreachable!(),
    }
}

fn bitop(op: BinOp, a: i64, b: i64) -> i64 {
    match op {
        BinOp::BitAnd => a & b,
        BinOp::BitOr => a | b,
        BinOp::Shl | BinOp::Shr => {
            if b == 0 {
                return a;
            }
            let mut left = op == BinOp::Shl;
            let mut n = b;
            if n < 0 {
                left = !left;
                n = if n > -64 { -n } else { 64 };
            }
            if n >= 64 {
                if a >= 0 || left {
                    0
                } else {
                    -1
                }
            } else if left {
                ((a as u64) << n) as i64
            } else {
                a >> n
            }
        }
        _ => unreachable!(),
    }
}

pub fn arith(op: BinOp, a: &Value, b: &Value) -> Value {
    if a.is_null() || b.is_null() {
        return Value::Null;
    }
    let (x, y) = (a.to_num(), b.to_num());
    if let (Num::Int(x), Num::Int(y)) = (x, y) {
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
                Some(if y == -1 { 0 } else { x % y })
            }
            _ => unreachable!(),
        };
        if let Some(r) = r {
            return Value::Integer(r);
        }
    }
    let fx = match x {
        Num::Int(i) => i as f64,
        Num::Real(r) => r,
    };
    let fy = match y {
        Num::Int(i) => i as f64,
        Num::Real(r) => r,
    };
    let r = match op {
        BinOp::Add => fx + fy,
        BinOp::Sub => fx - fy,
        BinOp::Mul => fx * fy,
        BinOp::Div => {
            if fy == 0.0 {
                return Value::Null;
            }
            fx / fy
        }
        BinOp::Rem => {
            let ix = fx as i64;
            let mut iy = fy as i64;
            if iy == 0 {
                return Value::Null;
            }
            if iy == -1 {
                iy = 1;
            }
            (ix % iy) as f64
        }
        _ => unreachable!(),
    };
    if r.is_nan() {
        Value::Null
    } else {
        Value::Real(r)
    }
}
