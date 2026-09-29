// Index access paths: choosing a rowid or index lookup for a table from the
// conditions on it, and producing the candidate rowids. Every condition is
// still checked on the candidates, so a lookup only has to return a
// superset of the matching rows.

use std::ops::Bound as RBound;

use super::query::{refs, split_and};
use super::*;

#[derive(Clone, Copy)]
enum Target {
    Rowid,
    Index(usize),
}

/// A value to look up, with the comparison's affinity and collation.
struct Probe {
    exprs: Vec<BExpr>,
    /// Values from an uncorrelated `IN (SELECT ...)`.
    sub: Option<Rc<SubExpr>>,
    aff: Affinity,
    coll: Coll,
}

struct RangeBound {
    probe: Probe,
    incl: bool,
}

pub struct Access {
    target: Target,
    /// Equality (or IN) probes for the leading key parts.
    eq: Vec<Probe>,
    lo: Option<RangeBound>,
    hi: Option<RangeBound>,
}

impl Access {
    /// Uses an equality, or a range bounded on both sides.
    pub fn has_eq(&self) -> bool {
        !self.eq.is_empty() || (self.lo.is_some() && self.hi.is_some())
    }
}

enum TermKind {
    Eq(Vec<BExpr>),
    EqSub(Rc<SubExpr>),
    Lo(BExpr, bool),
    Hi(BExpr, bool),
}

/// A usable condition: `col <op> value` where `col` is over this table only
/// and `value` can be computed before the table is read.
struct Term<'a> {
    col: &'a BExpr,
    kind: TermKind,
    aff: Affinity,
    coll: Coll,
    is_in: bool,
}

/// Whether a lookup value can be computed from earlier sources, the
/// enclosing queries and uncorrelated subqueries.
fn probe_ok(e: &BExpr, off: usize) -> bool {
    match e {
        BExpr::Col(i, _, _) => *i < off,
        BExpr::Agg(..) | BExpr::Win(..) => false,
        BExpr::Scalar(s) | BExpr::Exists(s) => !s.plan.correlated,
        BExpr::InSelect { expr, sub, .. } => !sub.plan.correlated && probe_ok(expr, off),
        _ => {
            let (l, list, r) = coll_children(e);
            l.is_none_or(|x| probe_ok(x, off))
                && list.into_iter().all(|x| probe_ok(x, off))
                && r.is_none_or(|x| probe_ok(x, off))
        }
    }
}

fn terms<'a>(conds: &[&'a BExpr], off: usize, width: usize) -> Vec<Term<'a>> {
    let colside = |e: &BExpr| {
        let r = refs(e);
        !r.opaque
            && !r.outer
            && r.min.is_some_and(|m| m >= off)
            && r.max.is_some_and(|m| m < off + width)
    };
    let mut out = Vec::new();
    for c in conds {
        match c {
            BExpr::Cmp(op, a, b, aff, coll) => {
                let (col, val, op) = if colside(a) && probe_ok(b, off) {
                    (&**a, &**b, *op)
                } else if colside(b) && probe_ok(a, off) {
                    let flipped = match op {
                        BinOp::Lt => BinOp::Gt,
                        BinOp::Le => BinOp::Ge,
                        BinOp::Gt => BinOp::Lt,
                        BinOp::Ge => BinOp::Le,
                        o => *o,
                    };
                    (&**b, &**a, flipped)
                } else {
                    continue;
                };
                let v = val.clone();
                let kind = match op {
                    BinOp::Eq => TermKind::Eq(vec![v]),
                    BinOp::Gt => TermKind::Lo(v, false),
                    BinOp::Ge => TermKind::Lo(v, true),
                    BinOp::Lt => TermKind::Hi(v, false),
                    BinOp::Le => TermKind::Hi(v, true),
                    _ => continue,
                };
                out.push(Term {
                    col,
                    kind,
                    aff: *aff,
                    coll: *coll,
                    is_in: false,
                });
            }
            BExpr::Between {
                expr,
                lo,
                hi,
                not: false,
                aff_lo,
                aff_hi,
                coll_lo,
                coll_hi,
            } => {
                if colside(expr) && probe_ok(lo, off) && probe_ok(hi, off) {
                    out.push(Term {
                        col: expr,
                        kind: TermKind::Lo((**lo).clone(), true),
                        aff: *aff_lo,
                        coll: *coll_lo,
                        is_in: false,
                    });
                    out.push(Term {
                        col: expr,
                        kind: TermKind::Hi((**hi).clone(), true),
                        aff: *aff_hi,
                        coll: *coll_hi,
                        is_in: false,
                    });
                }
            }
            BExpr::InSelect {
                expr,
                sub,
                not: false,
                aff,
                coll,
            } => {
                if colside(expr) && !sub.plan.correlated {
                    out.push(Term {
                        col: expr,
                        kind: TermKind::EqSub(sub.clone()),
                        aff: *aff,
                        coll: *coll,
                        is_in: true,
                    });
                }
            }
            BExpr::InList {
                expr,
                list,
                not: false,
                aff,
                coll,
            } => {
                if colside(expr) && list.iter().all(|x| probe_ok(x, off)) {
                    out.push(Term {
                        col: expr,
                        kind: TermKind::Eq(list.clone()),
                        aff: *aff,
                        coll: *coll,
                        is_in: true,
                    });
                }
            }
            _ => {}
        }
    }
    out
}

/// Whether comparing under `cond` leaves stored values of a key part with
/// affinity `col` unchanged (so the index order applies).
fn aff_ok(cond: Affinity, col: Affinity) -> bool {
    match cond {
        Affinity::None | Affinity::Blob => true,
        Affinity::Text => col == Affinity::Text,
        _ => col.is_numeric(),
    }
}

fn dbg(e: &BExpr) -> String {
    format!("{:?}", e)
}

/// Choose the best lookup for table `t` placed at `off` in the evaluation
/// row, given the conditions that apply to it.
pub fn choose(t: &Table, off: usize, conds: &[&BExpr]) -> Option<Access> {
    let ncols = t.columns.len();
    let ts = terms(conds, off, ncols + 1);
    if ts.is_empty() {
        return None;
    }
    let term_dbg: Vec<String> = ts.iter().map(|x| dbg(x.col)).collect();
    let mut best: Option<(i32, Access)> = None;
    let consider = |score: i32, acc: Access, best: &mut Option<(i32, Access)>| {
        if score > 0 && best.as_ref().is_none_or(|(s, _)| score > *s) {
            *best = Some((score, acc));
        }
    };

    // Rowid (or INTEGER PRIMARY KEY).
    let is_rowid = |e: &BExpr| match e {
        BExpr::Col(i, _, _) => *i == off + ncols || t.ipk.is_some_and(|p| *i == off + p),
        _ => false,
    };
    let make = |x: &Term, v: Vec<BExpr>| Probe {
        exprs: v,
        sub: None,
        aff: x.aff,
        coll: x.coll,
    };
    let make_eq = |x: &Term| match &x.kind {
        TermKind::Eq(v) => Some(make(x, v.clone())),
        TermKind::EqSub(s) => Some(Probe {
            exprs: Vec::new(),
            sub: Some(s.clone()),
            aff: x.aff,
            coll: x.coll,
        }),
        _ => None,
    };
    let is_eq = |x: &Term| matches!(x.kind, TermKind::Eq(_) | TermKind::EqSub(_));
    {
        let mut acc = Access {
            target: Target::Rowid,
            eq: Vec::new(),
            lo: None,
            hi: None,
        };
        for x in ts.iter().filter(|x| is_rowid(x.col)) {
            match &x.kind {
                TermKind::Eq(_) | TermKind::EqSub(_) if acc.eq.is_empty() => {
                    acc.eq.extend(make_eq(x))
                }
                TermKind::Lo(v, incl) if acc.lo.is_none() => {
                    acc.lo = Some(RangeBound {
                        probe: make(x, vec![v.clone()]),
                        incl: *incl,
                    })
                }
                TermKind::Hi(v, incl) if acc.hi.is_none() => {
                    acc.hi = Some(RangeBound {
                        probe: make(x, vec![v.clone()]),
                        incl: *incl,
                    })
                }
                _ => {}
            }
        }
        let score = if !acc.eq.is_empty() {
            acc.lo = None;
            acc.hi = None;
            200
        } else {
            2 * (acc.lo.is_some() as i32 + acc.hi.is_some() as i32)
                + (acc.lo.is_some() || acc.hi.is_some()) as i32
        };
        consider(score, acc, &mut best);
    }

    let cond_dbg: Vec<String> = conds.iter().map(|c| dbg(c)).collect();
    for (ii, idx) in t.indexes.iter().enumerate() {
        // Bind the index at this table's offset to compare expressions.
        let mut scope = Scope::default();
        scope.sources.push(t.source(&t.name, off));
        let parts: Option<Vec<BExpr>> = idx
            .ast
            .iter()
            .map(|ic| bind(&ic.expr, &scope).ok())
            .collect();
        let Some(parts) = parts else { continue };
        if let Some(w) = &idx.where_ast {
            let Ok(bw) = bind(w, &scope) else { continue };
            let mut conj = Vec::new();
            split_and(bw, &mut conj);
            if !conj.iter().all(|c| cond_dbg.contains(&dbg(c))) {
                continue;
            }
        }
        let usable = |j: usize, x: &Term| {
            x.coll == idx.parts[j].coll && aff_ok(x.aff, expr_affinity(&parts[j]))
        };
        let part_dbg: Vec<String> = parts.iter().map(dbg).collect();
        let mut acc = Access {
            target: Target::Index(ii),
            eq: Vec::new(),
            lo: None,
            hi: None,
        };
        let mut score = 0;
        let mut all_plain_eq = true;
        for j in 0..parts.len() {
            let cands = || {
                ts.iter()
                    .enumerate()
                    .filter(|(k, x)| term_dbg[*k] == part_dbg[j] && usable(j, x))
            };
            let found = cands()
                .find(|(_, x)| is_eq(x) && !x.is_in)
                .or_else(|| cands().find(|(_, x)| is_eq(x)));
            match found {
                Some((_, x)) => {
                    all_plain_eq &= !x.is_in;
                    score += if x.is_in { 3 } else { 4 };
                    acc.eq.extend(make_eq(x));
                }
                None => break,
            }
        }
        let j = acc.eq.len();
        if j < parts.len() {
            for (k, x) in ts.iter().enumerate() {
                if term_dbg[k] != part_dbg[j] || !usable(j, x) {
                    continue;
                }
                match &x.kind {
                    TermKind::Lo(v, incl) if acc.lo.is_none() => {
                        acc.lo = Some(RangeBound {
                            probe: make(x, vec![v.clone()]),
                            incl: *incl,
                        });
                        score += 2;
                    }
                    TermKind::Hi(v, incl) if acc.hi.is_none() => {
                        acc.hi = Some(RangeBound {
                            probe: make(x, vec![v.clone()]),
                            incl: *incl,
                        });
                        score += 2;
                    }
                    _ => {}
                }
            }
        } else if idx.unique && all_plain_eq {
            score += 100;
        }
        consider(score, acc, &mut best);
    }
    best.map(|(_, a)| a)
}

/// Lookup key value for a probe: the comparison's affinity and collation
/// applied. None for NULL (matches nothing).
fn probe_value(e: &BExpr, p: &Probe, env: &[Value], cx: Cx) -> Result<Option<Value>, String> {
    let v = eval(e, env, cx)?;
    if v.is_null() {
        return Ok(None);
    }
    Ok(Some(coll_key(&apply_cmp_affinity(v, p.aff), p.coll)))
}

/// Distinct lookup values of an equality/IN probe, in key order.
fn probe_values(p: &Probe, env: &[Value], cx: Cx) -> Result<Vec<Value>, String> {
    if let Some(sub) = &p.sub {
        return query::in_values(sub, p.aff, p.coll, env, cx);
    }
    let mut vals = Vec::with_capacity(p.exprs.len());
    for e in &p.exprs {
        if let Some(v) = probe_value(e, p, env, cx)? {
            vals.push(v);
        }
    }
    vals.sort_by(compare_values);
    vals.dedup_by(|a, b| compare_values(a, b) == Ordering::Equal);
    Ok(vals)
}

/// Candidate rowids, in the order of the index used.
pub fn rowids(t: &Table, acc: &Access, env: &[Value], cx: Cx) -> Result<Vec<i64>, String> {
    let mut eqs: Vec<Vec<Value>> = Vec::with_capacity(acc.eq.len());
    for p in &acc.eq {
        let v = probe_values(p, env, cx)?;
        if v.is_empty() {
            return Ok(Vec::new());
        }
        eqs.push(v);
    }
    let bound = |b: &Option<RangeBound>| -> Result<Option<Option<(Value, bool)>>, String> {
        match b {
            None => Ok(Some(None)),
            Some(rb) => match probe_value(&rb.probe.exprs[0], &rb.probe, env, cx)? {
                None => Ok(None),
                Some(v) => Ok(Some(Some((v, rb.incl)))),
            },
        }
    };
    // A NULL bound matches nothing.
    let Some(lo) = bound(&acc.lo)? else {
        return Ok(Vec::new());
    };
    let Some(hi) = bound(&acc.hi)? else {
        return Ok(Vec::new());
    };
    let mut out = Vec::new();
    match acc.target {
        Target::Rowid => rowid_lookup(t, eqs.first(), lo, hi, &mut out),
        Target::Index(i) => {
            let idx = &t.indexes[i];
            // Cartesian product of the equality values.
            let mut prefixes: Vec<Vec<Value>> = vec![Vec::new()];
            for vals in &eqs {
                let mut next = Vec::with_capacity(prefixes.len() * vals.len());
                for p in &prefixes {
                    for v in vals {
                        let mut q = p.clone();
                        q.push(v.clone());
                        next.push(q);
                    }
                }
                prefixes = next;
            }
            let mut found = Vec::new();
            for p in prefixes {
                index_scan(idx, p, lo.as_ref(), hi.as_ref(), &mut found);
            }
            if idx.parts.iter().any(|p| p.desc) {
                // Follow the index's declared order.
                found.sort_by(|a, b| {
                    for (i, p) in idx.parts.iter().enumerate() {
                        let o = compare_values(&a.0 .0[i], &b.0 .0[i]);
                        if o != Ordering::Equal {
                            return if p.desc { o.reverse() } else { o };
                        }
                    }
                    a.1.cmp(&b.1)
                });
            }
            out.extend(found.into_iter().map(|(_, r)| r));
        }
    }
    Ok(out)
}

fn index_scan<'i>(
    idx: &'i Index,
    prefix: Vec<Value>,
    lo: Option<&(Value, bool)>,
    hi: Option<&(Value, bool)>,
    out: &mut Vec<(&'i IdxKey, i64)>,
) {
    let k = prefix.len();
    let mut start = prefix.clone();
    if let Some((v, _)) = lo {
        start.push(v.clone());
    }
    let from = (IdxKey(start), i64::MIN);
    for (key, rid) in idx
        .entries
        .range((RBound::Included(from), RBound::Unbounded))
    {
        if key.0[..k]
            .iter()
            .zip(&prefix)
            .any(|(a, b)| compare_values(a, b) != Ordering::Equal)
        {
            break;
        }
        if k < key.0.len() {
            let v = &key.0[k];
            if let Some((l, false)) = lo {
                if compare_values(v, l) == Ordering::Equal {
                    continue;
                }
            }
            if let Some((h, incl)) = hi {
                match compare_values(v, h) {
                    Ordering::Greater => break,
                    Ordering::Equal if !incl => break,
                    _ => {}
                }
            }
        }
        out.push((key, *rid));
    }
}

/// Integer range [lo, hi] of rowids matching bounds under numeric
/// comparison; None if nothing can match.
fn rowid_lookup(
    t: &Table,
    eq: Option<&Vec<Value>>,
    lo: Option<(Value, bool)>,
    hi: Option<(Value, bool)>,
    out: &mut Vec<i64>,
) {
    if let Some(vals) = eq {
        for v in vals {
            let r = match v {
                Value::Integer(i) => Some(*i),
                Value::Real(f) if f.fract() == 0.0 && *f >= -9.2e18 && *f <= 9.2e18 => {
                    Some(*f as i64)
                }
                _ => None,
            };
            if let Some(r) = r {
                if t.rows.contains_key(&r) {
                    out.push(r);
                }
            }
        }
        return;
    }
    let mut a = i64::MIN;
    let mut b = i64::MAX;
    if let Some((v, incl)) = lo {
        match v {
            Value::Integer(i) => {
                if incl {
                    a = i;
                } else if i == i64::MAX {
                    return;
                } else {
                    a = i + 1;
                }
            }
            Value::Real(f) => {
                if f > 9.2e18 {
                    return;
                }
                if f >= -9.2e18 {
                    let c = f.ceil();
                    a = if c == f && !incl {
                        c as i64 + 1
                    } else {
                        c as i64
                    };
                }
            }
            // Text and blobs sort after every number.
            _ => return,
        }
    }
    if let Some((v, incl)) = hi {
        match v {
            Value::Integer(i) => {
                if incl {
                    b = i;
                } else if i == i64::MIN {
                    return;
                } else {
                    b = i - 1;
                }
            }
            Value::Real(f) => {
                if f < -9.2e18 {
                    return;
                }
                if f <= 9.2e18 {
                    let c = f.floor();
                    b = if c == f && !incl {
                        c as i64 - 1
                    } else {
                        c as i64
                    };
                }
            }
            _ => {}
        }
    }
    if a > b {
        return;
    }
    out.extend(t.rows.range(a..=b).map(|(r, _)| *r));
}

/// The index SQLite would scan instead of the table for a full scan: one
/// that covers every used column and has narrower rows (by SQLite's width
/// estimates); ties go to the most recently created index.
pub fn covering_index(t: &Table, used: &[bool]) -> Option<usize> {
    let tab_w: u64 =
        t.columns.iter().map(|c| c.sz_est as u64).sum::<u64>() + t.ipk.is_none() as u64;
    let sz_tab = log_est(tab_w * 4);
    let mut best: Option<(i32, u64, usize)> = None;
    for (i, idx) in t.indexes.iter().enumerate() {
        if idx.where_.is_some() {
            continue;
        }
        let covers = (0..t.columns.len()).all(|c| {
            !used.get(c).copied().unwrap_or(false)
                || Some(c) == t.ipk
                || idx.parts.iter().any(|p| p.col == Some(c))
        });
        if !covers {
            continue;
        }
        let w: u64 = idx
            .parts
            .iter()
            .map(|p| p.col.map_or(1, |c| t.columns[c].sz_est as u64))
            .sum::<u64>()
            + 1;
        let sz = log_est(w * 4);
        if sz >= sz_tab {
            continue;
        }
        let cost = 15 * sz / sz_tab;
        if best.is_none_or(|(bc, bid, _)| cost < bc || (cost == bc && idx.schema_id > bid)) {
            best = Some((cost, idx.schema_id, i));
        }
    }
    best.map(|(_, _, i)| i)
}

/// An index whose leading parts give the order of the leading ORDER BY
/// terms (column, descending, collation), scanned forwards or backwards.
/// Longer matches win, then covering indexes, then newer ones.
pub fn order_index(
    t: &Table,
    order: &[(usize, bool, Coll)],
    used: &[bool],
) -> Option<(usize, bool)> {
    let mut best: Option<((usize, bool, u64), usize, bool)> = None;
    for (i, idx) in t.indexes.iter().enumerate() {
        if idx.where_.is_some() {
            continue;
        }
        let mut n = 0;
        let mut rev = None;
        for ((c, desc, coll), p) in order.iter().zip(&idx.parts) {
            let r = *desc != p.desc;
            if p.col != Some(*c) || p.coll != *coll || rev.is_some_and(|x| x != r) {
                break;
            }
            rev = Some(r);
            n += 1;
        }
        let Some(rev) = rev else { continue };
        let covering = (0..t.columns.len()).all(|c| {
            !used.get(c).copied().unwrap_or(false)
                || Some(c) == t.ipk
                || idx.parts.iter().any(|p| p.col == Some(c))
        });
        let rank = (n, covering, idx.schema_id);
        if best.as_ref().is_none_or(|(b, _, _)| rank > *b) {
            best = Some((rank, i, rev));
        }
    }
    best.map(|(_, i, rev)| (i, rev))
}

/// Every rowid of the table in the order of index `i`.
pub fn index_order(t: &Table, i: usize) -> Vec<i64> {
    let idx = &t.indexes[i];
    if !idx.parts.iter().any(|p| p.desc) {
        return idx.entries.iter().map(|(_, r)| *r).collect();
    }
    let mut v: Vec<&(IdxKey, i64)> = idx.entries.iter().collect();
    v.sort_by(|a, b| {
        for (i, p) in idx.parts.iter().enumerate() {
            let o = compare_values(&a.0 .0[i], &b.0 .0[i]);
            if o != Ordering::Equal {
                return if p.desc { o.reverse() } else { o };
            }
        }
        a.1.cmp(&b.1)
    });
    v.into_iter().map(|(_, r)| *r).collect()
}
