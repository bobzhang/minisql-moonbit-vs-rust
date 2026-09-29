// Access paths and join planning.
//
// For each table of a query the planner picks how to read it (full scan,
// rowid lookup, index lookup or index scan) and, for inner joins, the
// nesting order of the tables. Choices follow SQLite's cost model (LogEst
// arithmetic, default row estimates) so that rows come out in the order
// SQLite would produce them.
//
// A lookup only narrows the rows visited: every condition is still checked
// on each candidate row, so an access path yields a superset of the
// matching rows.

use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap};
use std::ops::Bound;

use crate::ast::BinOp;
use crate::db::{key_val, Database, IKey, IdxCol, Index, KeyVal, Table};
use crate::eval::{affinity, bind, children, eval, sub_values, BExpr, Env, Scope, SubKind};
use crate::query::table_source;
use crate::value::{apply_cmp_affinity, Affinity, Coll, Value};

/// Where the values of an equality constraint come from.
#[derive(Debug, Clone)]
pub enum Probe {
    One(BExpr),
    List(Vec<BExpr>),
    /// An uncorrelated `IN (SELECT ...)` (the Sub node).
    Sub(BExpr),
    Null,
}

#[derive(Debug, Clone)]
pub struct EqTerm {
    probe: Probe,
    aff: Affinity,
    /// `IS`: a NULL probe matches NULL.
    null_ok: bool,
}

#[derive(Debug, Clone)]
pub struct RangeTerm {
    e: BExpr,
    incl: bool,
    aff: Affinity,
    /// `x IS NOT NULL` as `x > NULL`.
    vnull: bool,
}

#[derive(Debug, Clone)]
pub enum Access {
    Scan { reverse: bool },
    Rowid { eq: Option<EqTerm>, lo: Option<RangeTerm>, hi: Option<RangeTerm>, reverse: bool },
    /// Index lookup; with no constraints, a full scan of the index.
    Index { idx: usize, eq: Vec<EqTerm>, lo: Option<RangeTerm>, hi: Option<RangeTerm>, reverse: bool },
    /// One lookup per term of an OR, each row once (SQLite's MULTI-INDEX
    /// OR).
    MultiOr(Vec<Access>),
}

impl Access {
    pub fn is_scan(&self) -> bool {
        matches!(self, Access::Scan { reverse: false })
    }

    fn set_reverse(&mut self, r: bool) {
        match self {
            Access::Scan { reverse } | Access::Rowid { reverse, .. } | Access::Index { reverse, .. } => *reverse = r,
            Access::MultiOr(_) => {}
        }
    }
}

/// Equality lookup through a transient index built on first use.
#[derive(Debug, Clone)]
pub struct AutoKey {
    pub key: BExpr,
    pub probe: BExpr,
    pub aff: Affinity,
    pub coll: Coll,
    /// `IS`: NULL matches NULL.
    pub null_ok: bool,
    /// Columns (relative to the level) that order rows with equal keys,
    /// before the rowid: SQLite's automatic indexes cover the columns the
    /// query uses. Empty when the index only speeds up a scan.
    pub sort_cols: Vec<usize>,
}

/// Whether a WHERE term can only be true when the row of the level at
/// positions `lo..hi` is not all NULL (sqlite3ExprImpliesNonNullRow).
pub fn implies_non_null(e: &BExpr, lo: usize, hi: usize) -> bool {
    match skip_collate(e) {
        BExpr::And(a, b) => implies_non_null(a, lo, hi) || implies_non_null(b, lo, hi),
        BExpr::IsNull(x, true) => non_null_walk(x, lo, hi),
        e => non_null_walk(e, lo, hi),
    }
}

fn non_null_walk(e: &BExpr, lo: usize, hi: usize) -> bool {
    match e {
        BExpr::IsNull(..)
        | BExpr::Cmp(BinOp::Is | BinOp::IsNot, ..)
        | BExpr::Func(..)
        | BExpr::Coalesce(_)
        | BExpr::Case { .. }
        | BExpr::Sub(_)
        | BExpr::Outer { .. }
        | BExpr::Const(_) => false,
        BExpr::Col { idx, .. } => *idx >= lo && *idx < hi,
        BExpr::And(a, b) | BExpr::Or(a, b) => non_null_walk(a, lo, hi) && non_null_walk(b, lo, hi),
        BExpr::InList { e, list, .. } => !list.is_empty() && non_null_walk(e, lo, hi),
        e => children(e).into_iter().any(|c| non_null_walk(c, lo, hi)),
    }
}

// ---------- expression analysis ----------

/// Splits an AND tree into its terms.
pub fn conjuncts(e: BExpr, out: &mut Vec<BExpr>) {
    match e {
        BExpr::And(l, r) => {
            conjuncts(*l, out);
            conjuncts(*r, out);
        }
        e => out.push(e),
    }
}


fn same(a: &BExpr, b: &BExpr) -> bool {
    format!("{:?}", a) == format!("{:?}", b)
}

fn flip(op: BinOp) -> BinOp {
    match op {
        BinOp::Lt => BinOp::Gt,
        BinOp::Le => BinOp::Ge,
        BinOp::Gt => BinOp::Lt,
        BinOp::Ge => BinOp::Le,
        o => o,
    }
}

fn skip_collate(e: &BExpr) -> &BExpr {
    match e {
        BExpr::Collate(x, _) => skip_collate(x),
        e => e,
    }
}

/// Whether a comparison with affinity `cmp` can use an index column with
/// affinity `col` (sqlite3IndexAffinityOk).
fn aff_ok(cmp: Affinity, col: Affinity) -> bool {
    match cmp {
        Affinity::None | Affinity::Blob => true,
        Affinity::Text => col == Affinity::Text,
        _ => col.is_numeric(),
    }
}

/// A join level as seen by the planner.
#[derive(Clone)]
pub struct Level<'a> {
    pub table: Option<&'a Table>,
    pub offset: usize,
    pub width: usize,
    /// Columns of the table read by the query.
    pub used: Vec<bool>,
    /// The right side of a LEFT JOIN (its columns may be NULL).
    pub nullable: bool,
    /// Written as the right side of a LEFT JOIN (even if planned as an
    /// inner join).
    pub was_outer: bool,
    /// Levels that must be outer to this one.
    pub prereq: u64,
    /// Estimated rows (LogEst) of a subquery level.
    pub rows: i32,
    /// The level is a view (not merged into the query).
    pub is_view: bool,
}

/// Bitmask of the levels an expression reads (all bits for a correlated
/// subquery).
pub fn mask_of(e: &BExpr, levels: &[Level]) -> u64 {
    match e {
        BExpr::Col { idx, .. } => levels
            .iter()
            .position(|l| *idx >= l.offset && *idx < l.offset + l.width)
            .map(|i| 1u64 << i)
            .unwrap_or(0),
        BExpr::Sub(sq) if sq.correlated => u64::MAX,
        _ => children(e).into_iter().fold(0, |m, c| m | mask_of(c, levels)),
    }
}

enum Kind {
    Eq(Probe, bool),
    Lo(BExpr, bool),
    Hi(BExpr, bool),
}

/// A constraint `key op value` found in a term.
struct Cons<'a> {
    key: &'a BExpr,
    kind: Kind,
    aff: Affinity,
    /// Collation of the comparison (None = any, as for IS NULL).
    coll: Option<Coll>,
    /// Levels the value side reads.
    prereq: u64,
    term: usize,
    /// The virtual `x > NULL` of `x IS NOT NULL`.
    vnull: bool,
}

/// Constraints on level `l` in a term, with value sides reading only
/// levels in `avail`.
fn constraints<'a>(term: &'a BExpr, ti: usize, l: usize, avail: u64, levels: &[Level]) -> Vec<Cons<'a>> {
    let me = 1u64 << l;
    let local = |e: &BExpr| mask_of(e, levels) == me;
    let value = |e: &BExpr| {
        let m = mask_of(e, levels);
        (m & !avail == 0).then_some(m)
    };
    match term {
        BExpr::Cmp(op, l, r, aff, coll) => {
            let (key, val, op, prereq) = if let (true, Some(m)) = (local(l), value(r)) {
                (&**l, &**r, *op, m)
            } else if let (true, Some(m)) = (local(r), value(l)) {
                (&**r, &**l, flip(*op), m)
            } else {
                return Vec::new();
            };
            let kind = match op {
                BinOp::Eq => Kind::Eq(Probe::One(val.clone()), false),
                BinOp::Is => Kind::Eq(Probe::One(val.clone()), true),
                BinOp::Gt => Kind::Lo(val.clone(), false),
                BinOp::Ge => Kind::Lo(val.clone(), true),
                BinOp::Lt => Kind::Hi(val.clone(), false),
                BinOp::Le => Kind::Hi(val.clone(), true),
                _ => return Vec::new(),
            };
            vec![Cons { key: skip_collate(key), kind, aff: *aff, coll: Some(*coll), prereq, term: ti, vnull: false }]
        }
        BExpr::IsNull(x, false) if local(x) => vec![Cons {
            key: skip_collate(x),
            kind: Kind::Eq(Probe::Null, true),
            aff: Affinity::None,
            coll: None,
            prereq: 0,
            term: ti,
            vnull: false,
        }],
        BExpr::IsNull(x, true) if local(x) && matches!(skip_collate(x), BExpr::Col { .. }) => vec![Cons {
            key: skip_collate(x),
            kind: Kind::Lo(BExpr::Const(Value::Null), false),
            aff: Affinity::None,
            coll: None,
            prereq: 0,
            term: ti,
            vnull: true,
        }],
        BExpr::InList { e, list, not: false, aff, coll } if !list.is_empty() && local(e) => {
            let mut prereq = 0;
            for x in list {
                match value(x) {
                    Some(m) => prereq |= m,
                    None => return Vec::new(),
                }
            }
            vec![Cons {
                key: skip_collate(e),
                kind: Kind::Eq(Probe::List(list.clone()), false),
                aff: *aff,
                coll: Some(*coll),
                prereq,
                term: ti,
                vnull: false,
            }]
        }
        BExpr::Sub(sq) if !sq.correlated => match &sq.kind {
            SubKind::In { e, not: false, aff, coll } if local(e) => vec![Cons {
                key: skip_collate(e),
                kind: Kind::Eq(Probe::Sub(term.clone()), false),
                aff: *aff,
                coll: Some(*coll),
                prereq: 0,
                term: ti,
                vnull: false,
            }],
            _ => Vec::new(),
        },
        _ => Vec::new(),
    }
}

/// Whether the partial-index predicate term `p` is implied by the terms.
fn implied(p: &BExpr, terms: &[&BExpr]) -> bool {
    if terms.iter().any(|t| same(t, p)) {
        return true;
    }
    // x IS NOT NULL follows from a comparison that uses x
    if let BExpr::IsNull(x, true) = p {
        return terms.iter().any(|t| match t {
            BExpr::Cmp(op, l, r, _, _) if !matches!(op, BinOp::Is | BinOp::IsNot) => same(l, x) || same(r, x),
            BExpr::InList { e, not: false, .. } => same(e, x),
            _ => false,
        });
    }
    false
}

// ---------- cost model ----------

/// sqlite3LogEst: 10*log2(x), roughly.
pub fn log_est(x: u64) -> i32 {
    const A: [i32; 8] = [0, 2, 3, 5, 6, 7, 8, 9];
    let mut x = x;
    let mut y: i32 = 40;
    if x < 8 {
        if x < 2 {
            return 0;
        }
        while x < 8 {
            y -= 10;
            x <<= 1;
        }
    } else {
        let i = 60 - x.leading_zeros() as i32;
        y += i * 10;
        x >>= i;
    }
    A[(x & 7) as usize] + y - 10
}

/// sqlite3LogEstAdd: the LogEst of the sum of two LogEst values.
pub fn log_add(a: i32, b: i32) -> i32 {
    const X: [i32; 32] = [10, 10, 9, 9, 8, 8, 7, 7, 7, 6, 6, 6, 5, 5, 5, 4, 4, 4, 4, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2];
    let (hi, lo) = if a >= b { (a, b) } else { (b, a) };
    if hi > lo + 49 {
        hi
    } else if hi > lo + 31 {
        hi + 1
    } else {
        hi + X[(hi - lo) as usize]
    }
}

fn est_log(n: i32) -> i32 {
    if n <= 10 {
        0
    } else {
        log_est(n as u64) - 33
    }
}

/// Estimated size of a column from its declared type (sqlite3AffinityType).
fn col_size(decl: Option<&str>) -> u32 {
    let Some(t) = decl else { return 1 };
    let b = t.as_bytes();
    let word = |s: &[u8; 4]| u32::from_be_bytes(*s);
    let mut h: u32 = 0;
    let mut aff = Affinity::Numeric;
    let mut zchar: Option<usize> = None;
    let mut i = 0;
    while i < b.len() {
        h = (h << 8).wrapping_add(b[i].to_ascii_lowercase() as u32);
        i += 1;
        if h == word(b"char") {
            aff = Affinity::Text;
            zchar = Some(i);
        } else if h == word(b"clob") || h == word(b"text") {
            aff = Affinity::Text;
        } else if h == word(b"blob") && matches!(aff, Affinity::Numeric | Affinity::Real) {
            aff = Affinity::Blob;
            if b.get(i) == Some(&b'(') {
                zchar = Some(i);
            }
        } else if (h == word(b"real") || h == word(b"floa") || h == word(b"doub")) && aff == Affinity::Numeric {
            aff = Affinity::Real;
        } else if h & 0x00FF_FFFF == 0x0069_6e74 {
            aff = Affinity::Integer;
            break;
        }
    }
    let mut v: u32 = 0;
    if matches!(aff, Affinity::Blob | Affinity::Text) {
        match zchar {
            Some(p) => {
                if let Some(d) = b[p..].iter().position(|c| c.is_ascii_digit()) {
                    let digits: String = b[p + d..].iter().take_while(|c| c.is_ascii_digit()).map(|&c| c as char).collect();
                    v = digits.parse().unwrap_or(u32::MAX / 8);
                }
            }
            None => v = 16,
        }
    }
    (v / 4 + 1).min(255)
}

fn table_width(t: &Table) -> i32 {
    let mut w: u64 = t.columns.iter().map(|c| col_size(c.decl_type.as_deref()) as u64).sum();
    if t.ipk.is_none() {
        w += 1;
    }
    log_est(w * 4)
}

fn index_width(t: &Table, idx: &Index) -> i32 {
    let mut w: u64 = 1; // the rowid
    for c in &idx.cols {
        w += match c {
            IdxCol::Col(i) if Some(*i) != t.ipk => col_size(t.columns[*i].decl_type.as_deref()) as u64,
            _ => 1,
        };
    }
    log_est(w * 4)
}

/// Default estimated rows for an equality on the first n index columns.
fn index_rows(idx: &Index, n: usize, r_size: i32) -> i32 {
    const VAL: [i32; 5] = [33, 32, 30, 28, 26];
    if n == 0 {
        return r_size;
    }
    if idx.unique && n == idx.cols.len() {
        return 0;
    }
    if n <= VAL.len() {
        VAL[n - 1]
    } else {
        23
    }
}

/// LogEst of SQLite's default table size.
pub const TABLE_ROWS: i32 = 200;

fn in_count(p: &Probe) -> i32 {
    match p {
        Probe::List(l) => log_est(l.len() as u64),
        Probe::Sub(_) => 46,
        _ => 0,
    }
}

/// Rows left after range bounds (whereRangeScanEst without statistics).
fn range_rows(n_out: i32, lo: Option<&Cons>, hi: Option<&Cons>) -> i32 {
    let mut n_new = n_out;
    for c in lo.iter().chain(hi.iter()) {
        if !c.vnull {
            n_new -= 20;
        }
    }
    let (lo, hi) = (lo.is_some(), hi.is_some());
    if lo && hi {
        n_new -= 20;
    }
    let mut n_out = n_out - lo as i32 - hi as i32;
    if n_new < 10 {
        n_new = 10;
    }
    if n_new < n_out {
        n_out = n_new;
    }
    n_out
}

/// The order in which a loop produces rows.
#[derive(Debug, Clone)]
enum OrdInfo {
    None,
    Rowid,
    /// Index scan/lookup: the index and, per equality column, whether it
    /// has a single value.
    Index(usize, Vec<bool>),
    OneRow,
}

#[derive(Debug, Clone)]
struct Cand {
    access: Access,
    auto: Option<AutoKey>,
    setup: i32,
    run: i32,
    n_out: i32,
    ord: OrdInfo,
    /// Levels the loop's constraints read.
    prereq: u64,
    /// Full scans that may help ORDER BY are compared only among
    /// themselves (SQLite's iSortIdx).
    sort_idx: usize,
    /// Index lookup with an equality constraint.
    eq_lookup: bool,
}

/// whereLoopInsert: adds a loop unless an existing one is at least as
/// good; a new loop that is at least as good replaces existing ones.
fn insert_cand(list: &mut Vec<Cand>, t: Cand) {
    let mut replace: Option<usize> = None;
    let mut i = 0;
    while i < list.len() {
        let p = &list[i];
        if p.sort_idx != t.sort_idx {
            i += 1;
            continue;
        }
        if p.auto.is_some() && t.eq_lookup && (p.prereq & t.prereq) == t.prereq {
            if replace.is_none() {
                replace = Some(i);
                i += 1;
            } else {
                list.remove(i);
            }
            continue;
        }
        if replace.is_none()
            && (p.prereq & t.prereq) == p.prereq
            && p.setup <= t.setup
            && p.run <= t.run
            && p.n_out <= t.n_out
        {
            return;
        }
        if (p.prereq & t.prereq) == t.prereq && p.run >= t.run && p.n_out >= t.n_out {
            if replace.is_none() {
                replace = Some(i);
                i += 1;
            } else {
                list.remove(i);
            }
            continue;
        }
        i += 1;
    }
    match replace {
        Some(i) => list[i] = t,
        None => list.push(t),
    }
}

/// What the order requirement comes from.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum OrderMode {
    /// ORDER BY: terms in order, directions matter.
    Order,
    /// GROUP BY: any term order, any direction.
    Group,
    /// DISTINCT: any term order.
    Distinct,
}

/// An ORDER BY term the planner tries to satisfy.
pub struct OrderReq {
    pub e: BExpr,
    pub desc: bool,
    pub nulls_first: bool,
    pub coll: Coll,
}

/// A WHERE (or ON) term as seen by the planner.
pub struct Term {
    pub e: BExpr,
    /// Levels the term reads.
    pub mask: u64,
    /// Terms of one BETWEEN share a group (they count once in estimates).
    pub group: usize,
    /// The LEFT JOIN level whose ON clause the term belongs to.
    pub owner: Option<usize>,
    /// A term derived for planning only (not evaluated).
    pub virt: bool,
}

/// Planner terms of a WHERE term: a BETWEEN yields its two comparisons.
pub fn plan_terms(e: &BExpr, levels: &[Level], owner: Option<usize>, out: &mut Vec<Term>) {
    let group = out.len();
    // `x IS NOT NULL` on a column that cannot be NULL is always true
    if let BExpr::IsNull(x, true) = e {
        if let BExpr::Col { idx, .. } = skip_collate(x) {
            if let Some(l) = levels.iter().find(|l| *idx >= l.offset && *idx < l.offset + l.width) {
                if let (Some(t), false) = (l.table, l.nullable || l.was_outer) {
                    let c = idx - l.offset;
                    if c == t.columns.len() || Some(c) == t.ipk || t.columns[c].not_null.is_some() {
                        return;
                    }
                }
            }
        }
    }
    match e {
        BExpr::Between(inner) => {
            let mut parts = Vec::new();
            conjuncts((**inner).clone(), &mut parts);
            for p in parts {
                let mask = mask_of(&p, levels);
                out.push(Term { e: p, mask, group, owner, virt: false });
            }
        }
        e => {
            let mask = mask_of(e, levels);
            out.push(Term { e: e.clone(), mask, group, owner, virt: false });
            // `x = a OR x = b ...` also gives `x IN (a, b, ...)`
            if let Some(inl) = or_to_in(e, levels) {
                out.push(Term { e: inl, mask, group, owner, virt: true });
            }
        }
    }
}

/// The IN form of an OR of equalities on one column (exprAnalyzeOrTerm).
fn or_to_in(e: &BExpr, levels: &[Level]) -> Option<BExpr> {
    fn disjuncts<'e>(e: &'e BExpr, out: &mut Vec<&'e BExpr>) {
        match e {
            BExpr::Or(l, r) => {
                disjuncts(l, out);
                disjuncts(r, out);
            }
            e => out.push(e),
        }
    }
    if !matches!(e, BExpr::Or(..)) {
        return None;
    }
    let mut parts = Vec::new();
    disjuncts(e, &mut parts);
    let mut col: Option<&BExpr> = None;
    let mut values = Vec::new();
    for p in parts {
        let BExpr::Cmp(BinOp::Eq, l, r, _, _) = p else { return None };
        let side = |c: &BExpr, v: &BExpr, col: Option<&BExpr>| -> bool {
            matches!(c, BExpr::Col { .. })
                && col.is_none_or(|x| same(x, c))
                && mask_of(v, levels) & mask_of(c, levels) == 0
                && (affinity(v) == Affinity::None || affinity(v) == affinity(c))
        };
        if side(l, r, col) {
            col = Some(l);
            values.push((**r).clone());
        } else if side(r, l, col) {
            col = Some(r);
            values.push((**l).clone());
        } else {
            return None;
        }
    }
    let x = col?.clone();
    let aff = affinity(&x);
    let coll = crate::eval::expr_coll(&x).unwrap_or(Coll::Binary);
    Some(BExpr::InList { e: Box::new(x), list: values, not: false, aff, coll })
}

pub struct Planner<'a> {
    pub db: &'a Database,
    pub levels: Vec<Level<'a>>,
    pub terms: Vec<Term>,
    pub order_by: Vec<OrderReq>,
    pub mode: OrderMode,
    pub n_cols: usize,
    pub limit: Option<i64>,
    /// Full scans of covering indexes are allowed.
    pub covering_scans: bool,
}

/// The chosen plan: loop order and per-level access.
pub struct Plan {
    pub order: Vec<usize>,
    pub loops: Vec<(Access, Option<AutoKey>)>,
    /// The rows come out in the required order.
    pub ordered: bool,
    /// Estimated output rows (LogEst).
    pub n_row: i32,
}

#[derive(Clone)]
struct Path {
    mask: u64,
    order: Vec<usize>,
    loops: Vec<usize>,
    n_row: i32,
    cost: i32,
    unsorted: i32,
    is_ordered: i32,
    rev: Vec<bool>,
}

impl<'a> Planner<'a> {
    /// Terms a loop on level `l` may use.
    fn usable_terms(&self, l: usize) -> Vec<usize> {
        let me = 1u64 << l;
        (0..self.terms.len())
            .filter(|&i| {
                let t = &self.terms[i];
                if self.levels[l].nullable {
                    t.owner == Some(l)
                } else {
                    t.owner.is_none() && t.mask & me != 0
                }
            })
            .collect()
    }

    /// whereLoopOutputAdjust: reduces a loop's row estimate for the terms
    /// it does not use itself.
    fn adjust(&self, n_out: i32, l: usize, prereq: u64, consumed: &[usize], usable: &[usize], r_size: i32) -> i32 {
        let me = 1u64 << l;
        let mut n = n_out;
        let mut reduce = 0;
        let mut seen: Vec<usize> = Vec::new();
        for &ti in usable {
            let t = &self.terms[ti];
            if consumed.iter().any(|&c| self.terms[c].group == t.group) || seen.contains(&t.group) {
                continue;
            }
            if t.mask & me == 0 || t.mask & !(prereq | me) != 0 {
                continue;
            }
            seen.push(t.group);
            n -= 1;
            if let BExpr::Cmp(BinOp::Eq | BinOp::Is, x, y, _, _) = &t.e {
                let col = |e: &BExpr| matches!(skip_collate(e), BExpr::Col { .. });
                if col(x) || col(y) {
                    let small = |e: &BExpr| -> bool {
                        let mut e = e;
                        let mut neg = false;
                        loop {
                            match e {
                                BExpr::Pos(x) => e = x,
                                BExpr::Neg(x) => {
                                    neg = !neg;
                                    e = x
                                }
                                BExpr::Const(Value::Integer(v)) => {
                                    let v = if neg { v.wrapping_neg() } else { *v };
                                    return (-1..=1).contains(&v);
                                }
                                _ => return false,
                            }
                        }
                    };
                    let k = if small(y) { 10 } else { 20 };
                    reduce = reduce.max(k);
                }
            }
        }
        n.min(r_size - reduce)
    }

    fn is_rowid(&self, l: usize, e: &BExpr) -> bool {
        let lv = &self.levels[l];
        let Some(t) = lv.table else { return false };
        match e {
            BExpr::Col { idx, .. } => *idx == lv.offset + t.columns.len() || t.ipk.is_some_and(|p| *idx == lv.offset + p),
            _ => false,
        }
    }

    /// An automatic index a term can drive on level `l` (with the levels
    /// its other side reads). `strict` applies SQLite's conditions for
    /// choosing one; otherwise it only has to give the same rows.
    fn auto_for_term(&self, ti: usize, l: usize, strict: bool) -> Option<(AutoKey, u64)> {
        let me = 1u64 << l;
        let BExpr::Cmp(op @ (BinOp::Eq | BinOp::Is), x, y, aff, coll) = &self.terms[ti].e else { return None };
        let mx = mask_of(x, &self.levels);
        let my = mask_of(y, &self.levels);
        let (key, probe, prereq) = if mx == me && my & me == 0 {
            (x, y, my)
        } else if my == me && mx & me == 0 {
            (y, x, mx)
        } else {
            return None;
        };
        let key_aff = affinity(key);
        if *aff == Affinity::Text && key_aff != Affinity::Text {
            return None;
        }
        let lv = &self.levels[l];
        let key_col = match skip_collate(key) {
            BExpr::Col { idx, .. } => Some(idx - lv.offset),
            _ => None,
        };
        if strict {
            let c = key_col?;
            if let Some(t) = lv.table {
                if c >= t.columns.len() || Some(c) == t.ipk || !aff_ok(*aff, t.columns[c].affinity) {
                    return None;
                }
                // not a column that already leads an index
                if t.indexes.iter().any(|i| matches!(i.cols.first(), Some(IdxCol::Col(x)) if *x == c)) {
                    return None;
                }
            }
        }
        // rows with equal keys come out ordered by the other columns the
        // query uses (the automatic index covers them)
        let sort_cols = if strict {
            lv.used
                .iter()
                .enumerate()
                .filter(|(c, u)| (**u || lv.is_view) && Some(*c) != key_col && lv.table.is_none_or(|t| Some(*c) != t.ipk))
                .map(|(c, _)| c)
                .collect()
        } else {
            Vec::new()
        };
        let ak = AutoKey {
            key: (**key).clone(),
            probe: (**probe).clone(),
            aff: *aff,
            coll: *coll,
            null_ok: *op == BinOp::Is,
            sort_cols,
        };
        Some((ak, prereq))
    }

    /// A transient index usable to execute a full scan of level `l`.
    pub fn exec_auto(&self, l: usize, avail: u64) -> Option<AutoKey> {
        for ti in self.usable_terms(l) {
            if let Some((ak, prereq)) = self.auto_for_term(ti, l, false) {
                if prereq & !avail == 0 && prereq != 0 {
                    return Some(ak);
                }
            }
        }
        None
    }

    /// Constraints on columns of level `l` that follow from terms on
    /// other columns known to be equal to them (`a = b AND b > 5` gives
    /// `a > 5`; SQLite's WO_EQUIV).
    fn equiv_constraints(&self, l: usize) -> Vec<Cons<'_>> {
        let me = 1u64 << l;
        // column pairs equated by a term
        let mut pairs: Vec<(&BExpr, &BExpr)> = Vec::new();
        for t in self.terms.iter().filter(|t| t.owner.is_none()) {
            if let BExpr::Cmp(BinOp::Eq, x, y, _, Coll::Binary) = &t.e {
                if matches!(**x, BExpr::Col { .. }) && matches!(**y, BExpr::Col { .. }) {
                    let (ax, ay) = (affinity(x), affinity(y));
                    if ax == ay || (ax.is_numeric() && ay.is_numeric()) {
                        pairs.push((x, y));
                    }
                }
            }
        }
        let mut out = Vec::new();
        if pairs.is_empty() {
            return out;
        }
        let mut keys: Vec<&BExpr> = Vec::new();
        for (x, y) in &pairs {
            for k in [*x, *y] {
                if mask_of(k, &self.levels) == me && !keys.iter().any(|q| same(q, k)) {
                    keys.push(k);
                }
            }
        }
        for key in keys {
            // the columns equal to `key`
            let mut class: Vec<&BExpr> = vec![key];
            let mut i = 0;
            while i < class.len() && class.len() < 11 {
                let c = class[i];
                for (x, y) in &pairs {
                    for (a, b) in [(*x, *y), (*y, *x)] {
                        if same(a, c) && !class.iter().any(|q| same(q, b)) {
                            class.push(b);
                        }
                    }
                }
                i += 1;
            }
            for other in class.iter().skip(1) {
                let lo = mask_of(other, &self.levels).trailing_zeros() as usize;
                for (ti, t) in self.terms.iter().enumerate() {
                    if t.owner.is_some() {
                        continue;
                    }
                    for mut c in constraints(&t.e, ti, lo, !(1u64 << lo), &self.levels) {
                        if !same(c.key, other) || c.prereq & me != 0 {
                            continue;
                        }
                        c.key = key;
                        out.push(c);
                    }
                }
            }
        }
        out
    }

    /// All candidate loops for level `l` (SQLite's whereLoopAddBtree).
    fn candidates(&self, l: usize) -> Vec<Cand> {
        let lv = &self.levels[l];
        let me = 1u64 << l;
        let usable = self.usable_terms(l);
        let mut cons: Vec<Cons> =
            usable.iter().flat_map(|&ti| constraints(&self.terms[ti].e, ti, l, !me, &self.levels)).collect();
        if !lv.nullable {
            cons.extend(self.equiv_constraints(l));
        }
        let mut out = Vec::new();
        let r_size = if lv.table.is_some() { TABLE_ROWS } else { lv.rows };
        let r_log = est_log(r_size);
        // automatic indexes
        for &ti in &usable {
            if let Some((ak, prereq)) = self.auto_for_term(ti, l, true) {
                let setup = if lv.table.is_some() { r_log + r_size + 28 } else { (r_log + r_size - 25).max(0) };
                insert_cand(
                    &mut out,
                    Cand {
                        access: Access::Scan { reverse: false },
                        auto: Some(ak),
                        setup,
                        run: log_add(r_log, 43),
                        n_out: 43,
                        ord: OrdInfo::None,
                        prereq,
                        sort_idx: 0,
                        eq_lookup: false,
                    },
                );
            }
        }
        let Some(t) = lv.table else {
            insert_cand(
                &mut out,
                Cand {
                    access: Access::Scan { reverse: false },
                    auto: None,
                    setup: 0,
                    run: r_size + 16,
                    n_out: self.adjust(r_size, l, 0, &[], &usable, r_size),
                    ord: OrdInfo::None,
                    prereq: 0,
                    sort_idx: 0,
                    eq_lookup: false,
                },
            );
            return out;
        };
        let sz_tab = table_width(t);
        let covered = |idx: &Index| {
            lv.used.iter().enumerate().all(|(c, &u)| {
                !u || Some(c) == t.ipk || idx.cols.iter().any(|x| matches!(x, IdxCol::Col(i) if *i == c))
            })
        };

        // full table scan
        let helps = self.order_by.iter().any(|o| self.is_rowid(l, skip_collate(&o.e)));
        let scan_sort = if helps { 1 } else { 0 };
        insert_cand(
            &mut out,
            Cand {
                access: Access::Scan { reverse: false },
                auto: None,
                setup: 0,
                run: r_size + 16,
                n_out: self.adjust(r_size, l, 0, &[], &usable, r_size),
                ord: OrdInfo::Rowid,
                prereq: 0,
                sort_idx: scan_sort,
                eq_lookup: false,
            },
        );

        // rowid lookups
        let rt = |c: &Cons| match &c.kind {
            Kind::Lo(e, incl) | Kind::Hi(e, incl) => RangeTerm { e: e.clone(), incl: *incl, aff: c.aff, vnull: c.vnull },
            Kind::Eq(..) => unreachable!(),
        };
        let rowid_cons: Vec<&Cons> =
            cons.iter().filter(|c| self.is_rowid(l, c.key) && !c.vnull && aff_ok(c.aff, Affinity::Integer)).collect();
        for c in &rowid_cons {
            match &c.kind {
                Kind::Eq(p, null_ok) => {
                    let n_in = in_count(p);
                    let one = matches!(p, Probe::One(_) | Probe::Null);
                    let e = EqTerm { probe: p.clone(), aff: c.aff, null_ok: *null_ok };
                    insert_cand(
                        &mut out,
                        Cand {
                            access: Access::Rowid { eq: Some(e), lo: None, hi: None, reverse: false },
                            auto: None,
                            setup: 0,
                            run: log_add(r_log, 16) + n_in,
                            n_out: self.adjust(n_in, l, c.prereq, &[c.term], &usable, r_size),
                            ord: if one { OrdInfo::OneRow } else { OrdInfo::Rowid },
                            prereq: c.prereq,
                            sort_idx: scan_sort,
                            eq_lookup: true,
                        },
                    );
                }
                Kind::Lo(..) => {
                    let his: Vec<Option<&Cons>> = std::iter::once(None)
                        .chain(rowid_cons.iter().filter(|h| matches!(h.kind, Kind::Hi(..))).map(|h| Some(*h)))
                        .collect();
                    for hi in his {
                        self.push_rowid_range(&mut out, l, Some(c), hi, &usable, r_size, scan_sort, &rt);
                    }
                }
                Kind::Hi(..) => self.push_rowid_range(&mut out, l, None, Some(c), &usable, r_size, scan_sort, &rt),
            }
        }

        // indexes, most recently created first
        let mut order: Vec<usize> = (0..t.indexes.len()).collect();
        order.sort_by_key(|&i| std::cmp::Reverse(t.indexes[i].order));
        let usable_exprs: Vec<&BExpr> = usable.iter().map(|&i| &self.terms[i].e).collect();
        let mut probe_no = 1;
        for n in order {
            let idx = &t.indexes[n];
            probe_no += 1;
            if let Some(def) = idx.def.as_ref().filter(|_| idx.pred.is_some()) {
                let mut scope = Scope::empty();
                scope.sources.push(table_source(t, &t.name, lv.offset, false));
                let Some(w) = &def.where_ else { continue };
                let Ok(p) = bind(w, &scope, self.db) else { continue };
                let mut parts = Vec::new();
                conjuncts(p, &mut parts);
                if !parts.iter().all(|p| implied(p, &usable_exprs)) {
                    continue;
                }
            }
            let exprs = self.index_exprs(t, idx, lv.offset);
            let partial = idx.pred.is_some();
            let r_size_i = if partial { r_size - 10 } else { r_size };
            let sz_idx = index_width(t, idx);
            let is_covering = covered(idx);
            let matches_col = |j: usize, k: &BExpr| match &idx.cols[j] {
                IdxCol::Col(c) => matches!(k, BExpr::Col { idx: i, .. } if *i == lv.offset + c),
                IdxCol::Expr(_) => exprs[j].as_ref().is_some_and(|e| same(e, k)),
            };
            let helps_order = self.order_by.iter().any(|o| {
                let e = skip_collate(&o.e);
                self.is_rowid(l, e) || (0..idx.cols.len()).any(|j| matches_col(j, e))
            });
            let sort_idx = if helps_order { probe_no } else { 0 };

            // full scan of the index
            if helps_order || partial || (is_covering && sz_idx < sz_tab && self.covering_scans) {
                let mut run = r_size_i + 1 + (15 * sz_idx) / sz_tab;
                if !is_covering {
                    run = log_add(run, r_size_i + 16);
                }
                insert_cand(
                    &mut out,
                    Cand {
                        access: Access::Index { idx: n, eq: Vec::new(), lo: None, hi: None, reverse: false },
                        auto: None,
                        setup: 0,
                        run,
                        n_out: self.adjust(r_size_i, l, 0, &[], &usable, r_size_i),
                        ord: OrdInfo::Index(n, Vec::new()),
                        prereq: 0,
                        sort_idx,
                        eq_lookup: false,
                    },
                );
            }

            // lookups: every choice of equality terms for a prefix of the
            // columns, optionally with a range on the next column
            let usable_c = |j: usize, c: &Cons| {
                let col_aff = match idx.affs[j] {
                    Affinity::None => Affinity::Blob,
                    a => a,
                };
                matches_col(j, c.key) && aff_ok(c.aff, col_aff) && c.coll.is_none_or(|x| x == idx.colls[j])
            };
            let ctx = IdxCtx {
                l,
                n,
                idx,
                cons: &cons,
                usable: &usable,
                usable_c: &usable_c,
                r_size_i,
                sz_idx,
                sz_tab,
                is_covering,
                sort_idx,
            };
            let mut eqs: Vec<usize> = Vec::new();
            self.index_loops(&mut out, &ctx, &mut eqs, &rt);
        }

        // OR terms whose every branch can use a lookup
        for &ti in &usable {
            let t = &self.terms[ti];
            if t.virt || !matches!(t.e, BExpr::Or(..)) {
                continue;
            }
            if let Some(c) = self.multi_or(l, &t.e) {
                insert_cand(&mut out, c);
            }
        }
        out
    }

    /// whereLoopAddOr: a loop doing one lookup per branch of an OR.
    fn multi_or(&self, l: usize, e: &BExpr) -> Option<Cand> {
        fn disjuncts<'e>(e: &'e BExpr, out: &mut Vec<&'e BExpr>) {
            match e {
                BExpr::Or(a, b) => {
                    disjuncts(a, out);
                    disjuncts(b, out);
                }
                e => out.push(e),
            }
        }
        let mut parts = Vec::new();
        disjuncts(e, &mut parts);
        let me = 1u64 << l;
        let mut subs = Vec::new();
        let mut run: Option<i32> = None;
        let mut n_out: Option<i32> = None;
        let mut prereq = 0u64;
        for p in parts {
            let mut conj = Vec::new();
            conjuncts(p.clone(), &mut conj);
            let mut terms = Vec::new();
            for c in &conj {
                plan_terms(c, &self.levels, None, &mut terms);
            }
            if !terms.iter().any(|t| t.mask & me != 0) {
                return None;
            }
            let sub = Planner {
                db: self.db,
                levels: self.levels.clone(),
                terms,
                order_by: Vec::new(),
                mode: OrderMode::Order,
                n_cols: self.n_cols,
                limit: None,
                covering_scans: false,
            };
            let best = sub.candidates(l).into_iter().filter(|c| c.auto.is_none()).min_by_key(|c| c.run)?;
            if matches!(best.access, Access::Scan { .. }) {
                return None;
            }
            run = Some(run.map_or(best.run, |r| log_add(r, best.run)));
            n_out = Some(n_out.map_or(best.n_out, |n| log_add(n, best.n_out)));
            prereq |= best.prereq;
            subs.push(best.access);
        }
        Some(Cand {
            access: Access::MultiOr(subs),
            auto: None,
            setup: 0,
            run: run? + 1,
            n_out: n_out?,
            ord: OrdInfo::None,
            prereq,
            sort_idx: 0,
            eq_lookup: false,
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn push_rowid_range(
        &self,
        out: &mut Vec<Cand>,
        l: usize,
        lo: Option<&Cons>,
        hi: Option<&Cons>,
        usable: &[usize],
        r_size: i32,
        sort_idx: usize,
        rt: &dyn Fn(&Cons) -> RangeTerm,
    ) {
        let r_log = est_log(r_size);
        let n_out = range_rows(r_size, lo, hi);
        let consumed: Vec<usize> = lo.iter().chain(hi.iter()).map(|c| c.term).collect();
        let prereq = lo.iter().chain(hi.iter()).fold(0, |m, c| m | c.prereq);
        insert_cand(
            out,
            Cand {
                access: Access::Rowid { eq: None, lo: lo.map(rt), hi: hi.map(rt), reverse: false },
                auto: None,
                setup: 0,
                run: log_add(r_log, n_out + 16),
                n_out: self.adjust(n_out, l, prereq, &consumed, usable, r_size),
                ord: OrdInfo::Rowid,
                prereq,
                sort_idx,
                eq_lookup: false,
            },
        );
    }

    /// whereLoopAddBtreeIndex: loops for the equality terms chosen so far
    /// (`eqs`, one per leading column) extended by one more column.
    fn index_loops(&self, out: &mut Vec<Cand>, ctx: &IdxCtx, eqs: &mut Vec<usize>, rt: &dyn Fn(&Cons) -> RangeTerm) {
        let j = eqs.len();
        if j == ctx.idx.cols.len() {
            // a range on the rowid that ends each index entry (only narrows
            // the estimate: the rows it skips fail the term anyway)
            let rowid = |c: &Cons| self.is_rowid(ctx.l, c.key) && !c.vnull && aff_ok(c.aff, Affinity::Integer);
            for c in ctx.cons.iter().filter(|c| rowid(c)) {
                match &c.kind {
                    Kind::Lo(..) => {
                        self.push_index_loop(out, ctx, eqs, Some(c), None, rt);
                        for h in ctx.cons.iter().filter(|h| matches!(h.kind, Kind::Hi(..)) && rowid(h)) {
                            self.push_index_loop(out, ctx, eqs, Some(c), Some(h), rt);
                        }
                    }
                    Kind::Hi(..) => self.push_index_loop(out, ctx, eqs, None, Some(c), rt),
                    Kind::Eq(..) => {}
                }
            }
            return;
        }
        if j > ctx.idx.cols.len() {
            return;
        }
        for (ci, c) in ctx.cons.iter().enumerate() {
            if !(ctx.usable_c)(j, c) {
                continue;
            }
            match &c.kind {
                Kind::Eq(..) => {
                    eqs.push(ci);
                    self.push_index_loop(out, ctx, eqs, None, None, rt);
                    self.index_loops(out, ctx, eqs, rt);
                    eqs.pop();
                }
                Kind::Lo(..) => {
                    self.push_index_loop(out, ctx, eqs, Some(c), None, rt);
                    for h in ctx.cons.iter().filter(|h| matches!(h.kind, Kind::Hi(..)) && (ctx.usable_c)(j, h)) {
                        self.push_index_loop(out, ctx, eqs, Some(c), Some(h), rt);
                    }
                }
                Kind::Hi(..) => self.push_index_loop(out, ctx, eqs, None, Some(c), rt),
            }
        }
    }

    fn push_index_loop(
        &self,
        out: &mut Vec<Cand>,
        ctx: &IdxCtx,
        eqs: &[usize],
        lo: Option<&Cons>,
        hi: Option<&Cons>,
        rt: &dyn Fn(&Cons) -> RangeTerm,
    ) {
        let idx = ctx.idx;
        let mut terms = Vec::new();
        let mut singles = Vec::new();
        let mut consumed = Vec::new();
        let mut prereq = 0u64;
        let mut n_in = 0;
        let mut null_eq = false;
        for &ci in eqs {
            let c = &ctx.cons[ci];
            let Kind::Eq(p, null_ok) = &c.kind else { unreachable!() };
            n_in += in_count(p);
            singles.push(matches!(p, Probe::One(_) | Probe::Null));
            null_eq |= *null_ok;
            terms.push(EqTerm { probe: p.clone(), aff: c.aff, null_ok: *null_ok });
            consumed.push(c.term);
            prereq |= c.prereq;
        }
        let mut n_out = index_rows(idx, eqs.len(), ctx.r_size_i);
        if null_eq && n_out == 0 {
            n_out = 1;
        }
        if lo.is_some() || hi.is_some() {
            n_out = range_rows(n_out, lo, hi);
        }
        for c in lo.iter().chain(hi.iter()) {
            consumed.push(c.term);
            prereq |= c.prereq;
        }
        let r_log_i = est_log(ctx.r_size_i);
        let mut run = log_add(r_log_i, n_out + 1 + (15 * ctx.sz_idx) / ctx.sz_tab);
        if !ctx.is_covering {
            run = log_add(run, n_out + 16);
        }
        run += n_in;
        let one = idx.unique && eqs.len() == idx.cols.len() && !null_eq && singles.iter().all(|s| *s);
        let n_out = self.adjust(n_out + n_in, ctx.l, prereq, &consumed, ctx.usable, ctx.r_size_i);
        // bounds on the trailing rowid are not applied to the lookup
        let (lo, hi) = if eqs.len() == idx.cols.len() { (None, None) } else { (lo, hi) };
        insert_cand(
            out,
            Cand {
                access: Access::Index { idx: ctx.n, eq: terms, lo: lo.map(rt), hi: hi.map(rt), reverse: false },
                auto: None,
                setup: 0,
                run,
                n_out,
                ord: if one { OrdInfo::OneRow } else { OrdInfo::Index(ctx.n, singles) },
                prereq,
                sort_idx: ctx.sort_idx,
                eq_lookup: !eqs.is_empty(),
            },
        );
    }

    /// wherePathSatisfiesOrderBy: how many leading ORDER BY terms the
    /// loops (in nesting order) deliver in order (-1: not known yet), and
    /// which loops must run in reverse.
    fn order_sat(&self, path: &[usize], cands: &[&Cand]) -> (i32, Vec<bool>) {
        let obs = &self.order_by;
        let n_ob = obs.len();
        let mut rev_mask = vec![false; path.len()];
        if n_ob == 0 {
            return (0, rev_mask);
        }
        let mut sat = vec![false; n_ob];
        let group = self.mode == OrderMode::Group;
        let any_order = self.mode != OrderMode::Order;
        let mut ready = 0u64;
        let mut distinct_mask = 0u64;
        let mut is_distinct = true;
        for (pos, (&l, c)) in path.iter().zip(cands).enumerate() {
            if !is_distinct || sat.iter().all(|s| *s) {
                break;
            }
            let lv = &self.levels[l];
            let me = 1u64 << l;
            ready |= me;
            // terms constrained to a single value by == are in order
            for (i, o) in obs.iter().enumerate() {
                if sat[i] {
                    continue;
                }
                let e = skip_collate(&o.e);
                if !matches!(e, BExpr::Col { .. }) || mask_of(e, &self.levels) != me {
                    continue;
                }
                let eq = self.terms.iter().any(|t| match &t.e {
                    BExpr::Cmp(BinOp::Eq | BinOp::Is, x, y, _, coll) => {
                        let fits =
                            |k: &BExpr, v: &BExpr| same(skip_collate(k), e) && mask_of(v, &self.levels) & !ready == 0;
                        (fits(x, y) || fits(y, x)) && (*coll == o.coll || self.is_rowid(l, e))
                    }
                    _ => false,
                });
                if eq {
                    sat[i] = true;
                }
            }
            let Some(t) = lv.table else {
                is_distinct = false;
                break;
            };
            // the columns the loop delivers in order: (index column or
            // rowid, single-valued equality)
            let mut cols: Vec<(Option<usize>, bool)> = Vec::new();
            let mut n_key = 0;
            let mut idx_ref: Option<&Index> = None;
            let mut exprs: Vec<Option<BExpr>> = Vec::new();
            match &c.ord {
                OrdInfo::None => {
                    is_distinct = false;
                    break;
                }
                OrdInfo::OneRow => {}
                OrdInfo::Rowid => cols.push((None, false)),
                OrdInfo::Index(n, singles) => {
                    let idx = &t.indexes[*n];
                    idx_ref = Some(idx);
                    exprs = self.index_exprs(t, idx, lv.offset);
                    n_key = idx.cols.len();
                    for j in 0..n_key {
                        cols.push((Some(j), singles.get(j).copied().unwrap_or(false)));
                    }
                    cols.push((None, false));
                }
            }
            let mut rev: Option<bool> = None;
            let mut distinct_cols = false;
            let n_eq = match &c.access {
                Access::Index { eq, .. } => eq.len(),
                _ => 0,
            };
            for (j, &(col, single)) in cols.iter().enumerate() {
                if single {
                    continue;
                }
                if let (Some(jc), Some(idx)) = (col, idx_ref) {
                    match &idx.cols[jc] {
                        IdxCol::Col(ci) => {
                            if j >= n_eq && Some(*ci) != t.ipk && t.columns[*ci].not_null.is_none() {
                                is_distinct = false;
                            }
                        }
                        IdxCol::Expr(_) => is_distinct = false,
                    }
                }
                let matches = |e: &BExpr, coll: Coll| -> bool {
                    match col {
                        None => self.is_rowid(l, e),
                        Some(jc) => {
                            let idx = idx_ref.unwrap();
                            let m = match &idx.cols[jc] {
                                IdxCol::Col(ci) => matches!(e, BExpr::Col { idx: i, .. } if *i == lv.offset + ci),
                                IdxCol::Expr(_) => exprs[jc].as_ref().is_some_and(|x| same(x, e)),
                            };
                            m && coll == idx.colls[jc]
                        }
                    }
                };
                let mut found: Option<usize> = None;
                for (i, o) in obs.iter().enumerate() {
                    if sat[i] {
                        continue;
                    }
                    let hit = matches(skip_collate(&o.e), o.coll);
                    if hit {
                        found = Some(i);
                    }
                    if hit || !any_order {
                        break;
                    }
                }
                let mut ok = found.is_some();
                if let Some(i) = found {
                    let o = &obs[i];
                    if o.nulls_first == o.desc {
                        ok = false;
                    } else if !group {
                        let idx_desc = match (col, idx_ref) {
                            (Some(jc), Some(idx)) => idx.desc[jc],
                            _ => false,
                        };
                        let r = idx_desc != o.desc;
                        match rev {
                            Some(x) if x != r => ok = false,
                            _ => rev = Some(r),
                        }
                    }
                }
                if ok {
                    if col.is_none() {
                        distinct_cols = true;
                    }
                    sat[found.unwrap()] = true;
                } else {
                    if j == 0 || j < n_key {
                        is_distinct = false;
                    }
                    break;
                }
            }
            if distinct_cols {
                is_distinct = true;
            }
            rev_mask[pos] = rev.unwrap_or(false);
            if is_distinct {
                distinct_mask |= me;
                for (i, o) in obs.iter().enumerate() {
                    if !sat[i] && mask_of(&o.e, &self.levels) & !distinct_mask == 0 {
                        sat[i] = true;
                    }
                }
            }
        }
        if sat.iter().all(|s| *s) {
            return (n_ob as i32, rev_mask);
        }
        if !is_distinct {
            return (sat.iter().take_while(|s| **s).count() as i32, rev_mask);
        }
        (-1, rev_mask)
    }

    fn index_exprs(&self, t: &Table, idx: &Index, offset: usize) -> Vec<Option<BExpr>> {
        let mut exprs: Vec<Option<BExpr>> = vec![None; idx.cols.len()];
        if let Some(def) = &idx.def {
            if idx.cols.iter().any(|c| matches!(c, IdxCol::Expr(_))) {
                let mut scope = Scope::empty();
                scope.sources.push(table_source(t, &t.name, offset, false));
                for (j, c) in idx.cols.iter().enumerate() {
                    if matches!(c, IdxCol::Expr(_)) {
                        exprs[j] = bind(&def.columns[j].expr, &scope, self.db).ok();
                    }
                }
            }
        }
        exprs
    }

    fn sort_cost(&self, n_row: i32, n_sorted: usize) -> i32 {
        let n_ob = self.order_by.len();
        let n_col = log_est(((self.n_cols + 59) / 30) as u64);
        let mut cost = n_row + n_col;
        let mut n_row = n_row;
        if n_sorted > 0 {
            cost += log_est(((n_ob - n_sorted) * 100 / n_ob) as u64) - 66;
        }
        if let Some(lim) = self.limit {
            cost += 10;
            if n_sorted > 0 {
                cost += 6;
            }
            let l = log_est(lim.max(0) as u64);
            if l < n_row {
                n_row = l;
            }
        } else if self.mode == OrderMode::Distinct && n_row > 10 {
            n_row -= 10;
        }
        cost + est_log(n_row)
    }

    /// wherePathSolver: the cheapest nesting of the loops. `n_ob` is 0 on
    /// the first pass (sorting ignored).
    fn solve(&self, cands: &[Vec<Cand>], n_ob: usize, n_row_est: i32) -> Path {
        let n = self.levels.len();
        let mx_choice = match n {
            0 | 1 => 1,
            2 => 5,
            _ => 10,
        };
        let mut from = vec![Path {
            mask: 0,
            order: Vec::new(),
            loops: Vec::new(),
            n_row: 0,
            cost: 0,
            unsorted: 0,
            is_ordered: if n > 0 { -1 } else { n_ob as i32 },
            rev: Vec::new(),
        }];
        let mut sort_costs: HashMap<i32, i32> = HashMap::new();
        for _ in 0..n {
            let mut to: Vec<Path> = Vec::new();
            let mut mx_i = 0;
            let mut mx_cost = 0;
            let mut mx_unsorted = 0;
            for pf in &from {
                for l in 0..n {
                    let me = 1u64 << l;
                    if pf.mask & me != 0 || self.levels[l].prereq & !pf.mask != 0 {
                        continue;
                    }
                    for (ci, c) in cands[l].iter().enumerate() {
                        if c.prereq & !pf.mask != 0 {
                            continue;
                        }
                        if c.auto.is_some() && pf.n_row < 3 {
                            continue;
                        }
                        let mut unsorted = log_add(c.setup, c.run + pf.n_row);
                        unsorted = log_add(unsorted, pf.unsorted);
                        let n_out = pf.n_row + c.n_out;
                        let mask = pf.mask | me;
                        let mut order = pf.order.clone();
                        order.push(l);
                        let mut loops = pf.loops.clone();
                        loops.push(ci);
                        let (is_ordered, rev) = if pf.is_ordered < 0 {
                            let refs: Vec<&Cand> = order.iter().zip(&loops).map(|(&l, &ci)| &cands[l][ci]).collect();
                            self.order_sat(&order, &refs)
                        } else {
                            let mut r = pf.rev.clone();
                            r.push(false);
                            (pf.is_ordered, r)
                        };
                        let cost;
                        if is_ordered >= 0 && (is_ordered as usize) < n_ob {
                            let sc = *sort_costs
                                .entry(is_ordered)
                                .or_insert_with(|| self.sort_cost(n_row_est, is_ordered as usize));
                            cost = log_add(unsorted, sc) + 3;
                        } else {
                            cost = unsorted;
                            unsorted -= 2;
                        }
                        let cand = Path { mask, order, loops, n_row: n_out, cost, unsorted, is_ordered, rev };
                        let existing =
                            to.iter().position(|p| p.mask == mask && (p.is_ordered < 0) == (is_ordered < 0));
                        match existing {
                            None => {
                                if to.len() >= mx_choice
                                    && (cost > mx_cost || (cost == mx_cost && unsorted >= mx_unsorted))
                                {
                                    continue;
                                }
                                if to.len() < mx_choice {
                                    to.push(cand);
                                } else {
                                    to[mx_i] = cand;
                                }
                            }
                            Some(j) => {
                                let p = &to[j];
                                if p.cost < cost
                                    || (p.cost == cost && (p.n_row < n_out || (p.n_row == n_out && p.unsorted <= unsorted)))
                                {
                                    continue;
                                }
                                to[j] = cand;
                            }
                        }
                        if to.len() >= mx_choice {
                            mx_i = 0;
                            mx_cost = to[0].cost;
                            mx_unsorted = to[0].unsorted;
                            for (jj, p) in to.iter().enumerate().skip(1) {
                                if p.cost > mx_cost || (p.cost == mx_cost && p.unsorted > mx_unsorted) {
                                    mx_cost = p.cost;
                                    mx_unsorted = p.unsorted;
                                    mx_i = jj;
                                }
                            }
                        }
                    }
                }
            }
            from = to;
        }
        let mut best = 0;
        for i in 1..from.len() {
            if from[best].cost > from[i].cost {
                best = i;
            }
        }
        from.swap_remove(best)
    }

    pub fn plan(&self) -> Plan {
        let n = self.levels.len();
        let cands: Vec<Vec<Cand>> = (0..n).map(|l| self.candidates(l)).collect();
        let mut p = self.solve(&cands, 0, 0);
        if !self.order_by.is_empty() {
            p = self.solve(&cands, self.order_by.len(), p.n_row + 1);
        }
        let ordered = !self.order_by.is_empty() && p.is_ordered == self.order_by.len() as i32;
        let mut loops: Vec<(Access, Option<AutoKey>)> = vec![(Access::Scan { reverse: false }, None); n];
        let mut avail = 0u64;
        for (i, (&l, &ci)) in p.order.iter().zip(&p.loops).enumerate() {
            let mut c = cands[l][ci].clone();
            if p.is_ordered > 0 && p.rev.get(i).copied().unwrap_or(false) && self.mode == OrderMode::Order {
                c.access.set_reverse(true);
            }
            // an inner full scan with an equality on outer values visits the
            // same rows in the same order through a transient index
            if i > 0 && c.auto.is_none() && c.access.is_scan() {
                c.auto = self.exec_auto(l, avail);
            }
            avail |= 1u64 << l;
            loops[l] = (c.access, c.auto);
        }
        Plan { order: p.order, loops, ordered, n_row: p.n_row }
    }
}

struct IdxCtx<'c> {
    l: usize,
    n: usize,
    idx: &'c Index,
    cons: &'c [Cons<'c>],
    usable: &'c [usize],
    usable_c: &'c dyn Fn(usize, &Cons) -> bool,
    r_size_i: i32,
    sz_idx: i32,
    sz_tab: i32,
    is_covering: bool,
    sort_idx: usize,
}

/// Plans access to a single table (UPDATE and DELETE).
pub fn plan_single(db: &Database, t: &Table, terms: &[BExpr]) -> Access {
    let levels = vec![Level {
        table: Some(t),
        offset: 0,
        width: t.columns.len() + 1,
        used: vec![true; t.columns.len()],
        nullable: false,
        was_outer: false,
        prereq: 0,
        rows: TABLE_ROWS,
        is_view: false,
    }];
    let mut pt = Vec::new();
    for e in terms {
        plan_terms(e, &levels, None, &mut pt);
    }
    let p = Planner {
        db,
        levels,
        terms: pt,
        order_by: Vec::new(),
        mode: OrderMode::Order,
        n_cols: 1,
        limit: None,
        covering_scans: false,
    };
    p.plan().loops.swap_remove(0).0
}

// ---------- execution ----------

fn conv(v: Value, aff: Affinity) -> Value {
    match apply_cmp_affinity(&v, aff) {
        Some(x) => x,
        None => v,
    }
}

/// Key of a value for a transient index (None for NULL unless `null_ok`).
pub fn auto_key(v: Value, aff: Affinity, coll: Coll, null_ok: bool) -> Option<KeyVal> {
    if v.is_null() && !null_ok {
        return None;
    }
    Some(key_val(&conv(v, aff), coll))
}

fn probe_values(p: &Probe, row: &[Value], env: &Env) -> Result<Vec<Value>, String> {
    Ok(match p {
        Probe::One(e) => vec![eval(e, row, env)?],
        Probe::List(l) => {
            let mut v = Vec::with_capacity(l.len());
            for e in l {
                v.push(eval(e, row, env)?);
            }
            v
        }
        Probe::Sub(e) => match e {
            BExpr::Sub(sq) => sub_values(sq, row, env)?,
            _ => Vec::new(),
        },
        Probe::Null => vec![Value::Null],
    })
}

fn rowid_of(v: &Value) -> Option<i64> {
    match v {
        Value::Integer(i) => Some(*i),
        Value::Real(r) if r.fract() == 0.0 && *r >= -9.2e18 && *r <= 9.2e18 => Some(*r as i64),
        _ => None,
    }
}

/// Lower rowid bound: Err(()) = nothing matches, Ok(None) = unbounded.
fn rowid_lo(v: &Value, incl: bool) -> Result<Option<i64>, ()> {
    match v {
        Value::Null => Err(()),
        Value::Integer(i) => {
            if incl {
                Ok(Some(*i))
            } else {
                i.checked_add(1).map(Some).ok_or(())
            }
        }
        Value::Real(r) => {
            if *r < -9.2e18 {
                Ok(None)
            } else if *r > 9.2e18 {
                Err(())
            } else {
                let c = r.ceil();
                Ok(Some(if !incl && c == *r { c as i64 + 1 } else { c as i64 }))
            }
        }
        _ => Err(()),
    }
}

fn rowid_hi(v: &Value, incl: bool) -> Result<Option<i64>, ()> {
    match v {
        Value::Null => Err(()),
        Value::Integer(i) => {
            if incl {
                Ok(Some(*i))
            } else {
                i.checked_sub(1).map(Some).ok_or(())
            }
        }
        Value::Real(r) => {
            if *r > 9.2e18 {
                Ok(None)
            } else if *r < -9.2e18 {
                Err(())
            } else {
                let f = r.floor();
                Ok(Some(if !incl && f == *r { f as i64 - 1 } else { f as i64 }))
            }
        }
        _ => Ok(None),
    }
}

/// Candidate rowids for an access path, in visiting order.
pub fn rowids(t: &Table, acc: &Access, row: &[Value], env: &Env) -> Result<Vec<i64>, String> {
    match acc {
        Access::Scan { reverse } => {
            if *reverse {
                Ok(t.rows.keys().rev().copied().collect())
            } else {
                Ok(t.rows.keys().copied().collect())
            }
        }
        Access::Rowid { eq: Some(e), reverse, .. } => {
            let mut ids: Vec<i64> = probe_values(&e.probe, row, env)?
                .into_iter()
                .filter(|v| !v.is_null())
                .filter_map(|v| rowid_of(&conv(v, e.aff)))
                .filter(|id| t.rows.contains_key(id))
                .collect();
            ids.sort_unstable();
            ids.dedup();
            if *reverse {
                ids.reverse();
            }
            Ok(ids)
        }
        Access::Rowid { eq: None, lo, hi, reverse } => {
            let lo = match lo {
                Some(r) => match rowid_lo(&conv(eval(&r.e, row, env)?, r.aff), r.incl) {
                    Ok(b) => b,
                    Err(()) => return Ok(Vec::new()),
                },
                None => None,
            };
            let hi = match hi {
                Some(r) => match rowid_hi(&conv(eval(&r.e, row, env)?, r.aff), r.incl) {
                    Ok(b) => b,
                    Err(()) => return Ok(Vec::new()),
                },
                None => None,
            };
            let lo = lo.unwrap_or(i64::MIN);
            let hi = hi.unwrap_or(i64::MAX);
            if lo > hi {
                return Ok(Vec::new());
            }
            let it = t.rows.range(lo..=hi).map(|(k, _)| *k);
            Ok(if *reverse { it.rev().collect() } else { it.collect() })
        }
        Access::MultiOr(subs) => {
            let mut seen = std::collections::HashSet::new();
            let mut out = Vec::new();
            for sub in subs {
                for id in rowids(t, sub, row, env)? {
                    if seen.insert(id) {
                        out.push(id);
                    }
                }
            }
            Ok(out)
        }
        Access::Index { idx, eq, lo, hi, reverse } => {
            let index = &t.indexes[*idx];
            // equality prefixes, in index order
            let mut prefixes: Vec<Vec<IKey>> = vec![Vec::new()];
            for (j, e) in eq.iter().enumerate() {
                let mut keys: Vec<IKey> = Vec::new();
                for v in probe_values(&e.probe, row, env)? {
                    if v.is_null() && !e.null_ok {
                        continue;
                    }
                    keys.push(IKey::Val(key_val(&conv(v, e.aff), index.colls[j]), index.desc[j]));
                }
                keys.sort();
                keys.dedup();
                if keys.is_empty() {
                    return Ok(Vec::new());
                }
                let mut next = Vec::with_capacity(prefixes.len() * keys.len());
                for p in &prefixes {
                    for k in &keys {
                        let mut q = p.clone();
                        q.push(k.clone());
                        next.push(q);
                    }
                }
                prefixes = next;
            }
            let j = eq.len();
            let bound = |r: &Option<RangeTerm>| -> Result<Option<Option<(IKey, bool)>>, String> {
                match r {
                    None => Ok(Some(None)),
                    Some(r) if r.vnull => Ok(Some(Some((IKey::Val(KeyVal(Value::Null), index.desc[j]), false)))),
                    Some(r) => {
                        let v = conv(eval(&r.e, row, env)?, r.aff);
                        if v.is_null() {
                            return Ok(None);
                        }
                        Ok(Some(Some((IKey::Val(key_val(&v, index.colls[j]), index.desc[j]), r.incl))))
                    }
                }
            };
            let (Some(mut vlo), Some(mut vhi)) = (bound(lo)?, bound(hi)?) else { return Ok(Vec::new()) };
            // a range excludes NULLs
            if vlo.is_none() && vhi.is_some() {
                vlo = Some((IKey::Val(KeyVal(Value::Null), index.desc[j]), false));
            }
            if j < index.desc.len() && index.desc[j] {
                std::mem::swap(&mut vlo, &mut vhi);
            }
            let mut out = Vec::new();
            for p in prefixes {
                let with = |extra: &[IKey]| {
                    let mut k = p.clone();
                    k.extend_from_slice(extra);
                    k
                };
                let start = match &vlo {
                    None => (with(&[]), i64::MIN),
                    Some((v, true)) => (with(std::slice::from_ref(v)), i64::MIN),
                    Some((v, false)) => (with(&[v.clone(), IKey::Max]), i64::MIN),
                };
                let (end, end_incl) = match &vhi {
                    None => ((with(&[IKey::Max]), i64::MAX), true),
                    Some((v, true)) => ((with(&[v.clone(), IKey::Max]), i64::MAX), true),
                    Some((v, false)) => ((with(std::slice::from_ref(v)), i64::MIN), false),
                };
                match start.cmp(&end) {
                    Ordering::Greater => continue,
                    Ordering::Equal if !end_incl => continue,
                    _ => {}
                }
                let hi_b = if end_incl { Bound::Included(end) } else { Bound::Excluded(end) };
                out.extend(index.entries.range((Bound::Included(start), hi_b)).map(|(_, r)| *r));
            }
            if *reverse {
                out.reverse();
            }
            Ok(out)
        }
    }
}

/// A transient index: key -> positions of the rows with that key.
pub type AutoIndex = BTreeMap<KeyVal, Vec<usize>>;
