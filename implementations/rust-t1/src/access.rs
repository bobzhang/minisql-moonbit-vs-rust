// Access paths: choosing rowid / index lookups for a table from the
// conditions of a query, and producing the candidate rows.
//
// A lookup only narrows the rows considered: every condition is still
// evaluated on each candidate, so a lookup must return a superset of the
// matching rows.

use std::collections::BTreeMap;

use crate::ast::{BinOp, Expr, SubKind};
use crate::db::{normalize, IdxColKind, IdxKey, IxKey, Table};
use crate::error::Result;
use crate::eval::{apply_cmp_affinity, eval, expr_affinity, for_each_child, Cx};
use crate::value::{compare, Affinity, Collation, Value};

/// A key expression evaluated before the lookup.
#[derive(Clone, Debug)]
pub struct KeyExpr {
    pub e: Expr,
    pub aff: Option<Affinity>,
    pub coll: Collation,
    /// `IS` comparison: a NULL key matches NULL.
    pub allow_null: bool,
}

#[derive(Clone, Debug, Default)]
pub struct Lookup {
    /// Equality keys for the leading columns.
    pub eq: Vec<KeyExpr>,
    /// IN-list keys for the column after the equality prefix.
    pub in_list: Option<Vec<KeyExpr>>,
    /// Range on the column after the equality prefix: (key, inclusive).
    pub lo: Option<(KeyExpr, bool)>,
    pub hi: Option<(KeyExpr, bool)>,
}

#[derive(Clone, Debug)]
pub enum Access {
    Full,
    Rowid(Lookup),
    /// Index at this position of the table's index list.
    Index(usize, Lookup),
    /// Equality on a column without a usable index: a temporary key map is
    /// built once per scan.
    Auto { col: usize, key: KeyExpr },
}

/// Local columns referenced by a bound expression.
#[derive(Default)]
pub struct Refs {
    pub min: Option<usize>,
    pub max: Option<usize>,
    /// References something whose columns cannot be determined
    /// (aggregates, correlated subqueries).
    pub poison: bool,
}

pub fn refs(e: &Expr, r: &mut Refs) {
    match e {
        Expr::Col { idx, .. } => {
            r.min = Some(r.min.map_or(*idx, |m| m.min(*idx)));
            r.max = Some(r.max.map_or(*idx, |m| m.max(*idx)));
        }
        Expr::AggRef { .. } => r.poison = true,
        Expr::Outer { .. } => {}
        Expr::SubPlan { correlated, kind, .. } => {
            if *correlated {
                r.poison = true;
            }
            if let SubKind::In { e, .. } = kind {
                refs(e, r);
            }
        }
        _ => for_each_child(e, &mut |c| refs(c, r)),
    }
}

pub fn refs_of(e: &Expr) -> Refs {
    let mut r = Refs::default();
    refs(e, &mut r);
    r
}

/// Split an expression into its AND-ed conjuncts.
pub fn conjuncts<'a>(e: &'a Expr, out: &mut Vec<&'a Expr>) {
    match e {
        Expr::Binary(BinOp::And, a, b) => {
            conjuncts(a, out);
            conjuncts(b, out);
        }
        _ => out.push(e),
    }
}

/// Add `k` to every local column index of an expression bound at offset 0.
pub fn shift_cols(e: &mut Expr, k: usize) {
    if let Expr::Col { idx, .. } = e {
        *idx += k;
        return;
    }
    crate::agg::for_each_child_mut(e, &mut |c| shift_cols(c, k));
}

fn same_expr(a: &Expr, b: &Expr) -> bool {
    format!("{:?}", a) == format!("{:?}", b)
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Op {
    Eq,
    Lo(bool),
    Hi(bool),
    In,
}

enum Target {
    /// Column relative to the source (ncols = rowid).
    Col(usize),
    Expr(Expr),
}

struct Cons {
    target: Target,
    op: Op,
    keys: Vec<KeyExpr>,
    target_aff: Option<Affinity>,
}

/// Can comparison affinity `cmp` be applied to the stored values of a
/// target with affinity `target` without changing them?
fn aff_ok(target: Option<Affinity>, cmp: Option<Affinity>) -> bool {
    match cmp {
        None | Some(Affinity::Blob) => true,
        Some(a) if a.is_numeric() => target.is_some_and(|t| t.is_numeric()),
        Some(_) => target == Some(Affinity::Text),
    }
}

struct Ctx {
    offset: usize,
    ncols: usize,
}

impl Ctx {
    fn available(&self, e: &Expr) -> bool {
        let r = refs_of(e);
        !r.poison && r.max.is_none_or(|m| m < self.offset)
    }

    fn target(&self, e: &Expr) -> Option<(Target, Option<Affinity>)> {
        if let Expr::Col { idx, aff, .. } = e {
            if *idx >= self.offset && *idx <= self.offset + self.ncols {
                return Some((Target::Col(idx - self.offset), Some(*aff)));
            }
            return None;
        }
        let r = refs_of(e);
        if r.poison || r.min.is_none_or(|m| m < self.offset) || r.max.is_none_or(|m| m > self.offset + self.ncols) {
            return None;
        }
        Some((Target::Expr(e.clone()), expr_affinity(e)))
    }
}

fn collect(cx: &Ctx, e: &Expr, out: &mut Vec<Cons>) {
    match e {
        Expr::Compare { op, l, r, info } => {
            let base = match op {
                BinOp::Eq | BinOp::Is => Op::Eq,
                BinOp::Gt => Op::Lo(false),
                BinOp::Ge => Op::Lo(true),
                BinOp::Lt => Op::Hi(false),
                BinOp::Le => Op::Hi(true),
                _ => return,
            };
            let allow_null = *op == BinOp::Is;
            for (t, o, flip) in [(l, r, false), (r, l, true)] {
                let Some((target, taff)) = cx.target(t) else { continue };
                if !cx.available(o) || !aff_ok(taff, info.aff) {
                    continue;
                }
                let op = match (base, flip) {
                    (Op::Lo(i), true) => Op::Hi(i),
                    (Op::Hi(i), true) => Op::Lo(i),
                    (b, _) => b,
                };
                let key = KeyExpr { e: (**o).clone(), aff: info.aff, coll: info.coll, allow_null };
                out.push(Cons { target, op, keys: vec![key], target_aff: taff });
            }
        }
        Expr::Between { e, lo, hi, neg: false, info_lo, info_hi } => {
            let Some((_, taff)) = cx.target(e) else { return };
            if cx.available(lo) && aff_ok(taff, info_lo.aff) {
                let (target, _) = cx.target(e).unwrap();
                let key = KeyExpr { e: (**lo).clone(), aff: info_lo.aff, coll: info_lo.coll, allow_null: false };
                out.push(Cons { target, op: Op::Lo(true), keys: vec![key], target_aff: taff });
            }
            if cx.available(hi) && aff_ok(taff, info_hi.aff) {
                let (target, _) = cx.target(e).unwrap();
                let key = KeyExpr { e: (**hi).clone(), aff: info_hi.aff, coll: info_hi.coll, allow_null: false };
                out.push(Cons { target, op: Op::Hi(true), keys: vec![key], target_aff: taff });
            }
        }
        Expr::Binary(BinOp::Or, ..) => {
            // x = a OR x = b ... on one target acts as x IN (a, b, ...).
            let mut parts = Vec::new();
            disjuncts(e, &mut parts);
            let mut all: Vec<Cons> = Vec::new();
            for p in parts {
                let mut one = Vec::new();
                collect(cx, p, &mut one);
                match one.into_iter().find(|c| c.op == Op::Eq && !c.keys[0].allow_null) {
                    Some(c) => all.push(c),
                    None => return,
                }
            }
            let first = &all[0];
            let same = all.iter().all(|c| {
                let t = match (&c.target, &first.target) {
                    (Target::Col(a), Target::Col(b)) => a == b,
                    (Target::Expr(a), Target::Expr(b)) => same_expr(a, b),
                    _ => false,
                };
                t && c.keys[0].aff == first.keys[0].aff && c.keys[0].coll == first.keys[0].coll
            });
            if !same {
                return;
            }
            let target_aff = first.target_aff;
            let target = match &first.target {
                Target::Col(i) => Target::Col(*i),
                Target::Expr(x) => Target::Expr(x.clone()),
            };
            let keys = all.into_iter().map(|c| c.keys.into_iter().next().unwrap()).collect();
            out.push(Cons { target, op: Op::In, keys, target_aff });
        }
        Expr::InList { e, list, neg: false, info } if !list.is_empty() => {
            let Some((target, taff)) = cx.target(e) else { return };
            if !list.iter().all(|x| cx.available(x)) || !aff_ok(taff, info.aff) {
                return;
            }
            let keys =
                list.iter().map(|x| KeyExpr { e: x.clone(), aff: info.aff, coll: info.coll, allow_null: false }).collect();
            out.push(Cons { target, op: Op::In, keys, target_aff: taff });
        }
        _ => {}
    }
}

fn disjuncts<'a>(e: &'a Expr, out: &mut Vec<&'a Expr>) {
    match e {
        Expr::Binary(BinOp::Or, a, b) => {
            disjuncts(a, out);
            disjuncts(b, out);
        }
        _ => out.push(e),
    }
}

/// Does the query (its conjuncts) imply the partial-index predicate?
fn implies(conjs: &[&Expr], pred: &Expr) -> bool {
    let mut parts = Vec::new();
    conjuncts(pred, &mut parts);
    parts.into_iter().all(|p| {
        if conjs.iter().any(|c| same_expr(c, p)) {
            return true;
        }
        // `x IS NOT NULL` follows from a comparison that constrains x.
        if let Expr::IsNull(x, true) = p {
            return conjs.iter().any(|c| match c {
                Expr::Compare { op, l, r, .. } if *op != BinOp::Is && *op != BinOp::IsNot => {
                    same_expr(l, x) || same_expr(r, x)
                }
                Expr::Between { e, neg: false, .. } | Expr::InList { e, neg: false, .. } => same_expr(e, x),
                _ => false,
            });
        }
        false
    })
}

/// Choose how to read table `t`, laid out at `offset` in the row, given
/// the conditions that hold for the rows wanted.
pub fn plan_access(t: &Table, offset: usize, conjs: &[&Expr], allow_auto: bool) -> Access {
    let ncols = t.columns.len();
    let cx = Ctx { offset, ncols };
    let mut cons: Vec<Cons> = Vec::new();
    for c in conjs {
        collect(&cx, c, &mut cons);
    }
    if cons.is_empty() {
        return Access::Full;
    }
    let is_rowid = |c: &Cons| match c.target {
        Target::Col(i) => i == ncols || Some(i) == t.rowid_alias,
        _ => false,
    };
    // Rowid lookups.
    let mut best: Option<(u32, Access)> = None;
    {
        let rc: Vec<&Cons> = cons.iter().filter(|c| is_rowid(c)).collect();
        if let Some(c) = rc.iter().find(|c| c.op == Op::Eq) {
            return Access::Rowid(Lookup { eq: c.keys.clone(), ..Default::default() });
        }
        if let Some(c) = rc.iter().find(|c| c.op == Op::In) {
            best = Some((100, Access::Rowid(Lookup { in_list: Some(c.keys.clone()), ..Default::default() })));
        } else {
            let lo = rc.iter().find_map(|c| match c.op {
                Op::Lo(i) => Some((c.keys[0].clone(), i)),
                _ => None,
            });
            let hi = rc.iter().find_map(|c| match c.op {
                Op::Hi(i) => Some((c.keys[0].clone(), i)),
                _ => None,
            });
            let score = lo.is_some() as u32 + hi.is_some() as u32;
            if score > 0 {
                best = Some((score, Access::Rowid(Lookup { lo, hi, ..Default::default() })));
            }
        }
    }
    // Indexes.
    for (pos, ix) in t.indexes.iter().enumerate() {
        if let Some(w) = &ix.where_ {
            let mut w = w.clone();
            shift_cols(&mut w, offset);
            if !implies(conjs, &w) {
                continue;
            }
        }
        let matches = |c: &Cons, k: usize| -> bool {
            let icol = &ix.cols[k];
            let hit = match (&c.target, &icol.kind) {
                (Target::Col(i), IdxColKind::Col(j)) => i == j,
                (Target::Expr(e), IdxColKind::Expr { bound, .. }) => {
                    let mut b = bound.clone();
                    shift_cols(&mut b, offset);
                    same_expr(e, &b)
                }
                _ => false,
            };
            hit && c.keys.iter().all(|k| k.coll == icol.coll) && aff_ok(icol.aff.or(c.target_aff), c.keys[0].aff)
        };
        let mut lk = Lookup::default();
        let mut score = 0;
        for k in 0..ix.cols.len() {
            if let Some(c) = cons.iter().find(|c| c.op == Op::Eq && matches(c, k)) {
                lk.eq.push(c.keys[0].clone());
                score += 10;
                continue;
            }
            if let Some(c) = cons.iter().find(|c| c.op == Op::In && matches(c, k)) {
                lk.in_list = Some(c.keys.clone());
                score += 8;
                break;
            }
            lk.lo = cons.iter().find_map(|c| match c.op {
                Op::Lo(i) if matches(c, k) => Some((c.keys[0].clone(), i)),
                _ => None,
            });
            lk.hi = cons.iter().find_map(|c| match c.op {
                Op::Hi(i) if matches(c, k) => Some((c.keys[0].clone(), i)),
                _ => None,
            });
            score += lk.lo.is_some() as u32 + lk.hi.is_some() as u32;
            break;
        }
        if score == 0 {
            continue;
        }
        if ix.unique && lk.eq.len() == ix.cols.len() {
            score = 90;
        }
        if best.as_ref().is_none_or(|(s, _)| score > *s) {
            best = Some((score, Access::Index(pos, lk)));
        }
    }
    if let Some((_, a)) = best {
        return a;
    }
    if allow_auto {
        if let Some(c) = cons.iter().find(|c| c.op == Op::Eq && matches!(c.target, Target::Col(_))) {
            if let Target::Col(i) = c.target {
                return Access::Auto { col: i, key: c.keys[0].clone() };
            }
        }
    }
    Access::Full
}

/// Evaluate a key; None if it cannot match anything (NULL).
pub fn key_value(k: &KeyExpr, buf: &[Value], cx: &Cx) -> Result<Option<Value>> {
    let v = apply_cmp_affinity(eval(&k.e, buf, cx)?, k.aff);
    if v.is_null() && !k.allow_null {
        return Ok(None);
    }
    Ok(Some(normalize(&v, k.coll)))
}

/// Normalized key of a stored value for an automatic index.
pub fn auto_key(v: &Value, k: &KeyExpr) -> Option<IdxKey> {
    let v = apply_cmp_affinity(v.clone(), k.aff);
    if v.is_null() && !k.allow_null {
        return None;
    }
    Some(IdxKey(vec![normalize(&v, k.coll)]))
}

pub type AutoMap = BTreeMap<IdxKey, Vec<usize>>;

fn rowid_exact(v: &Value) -> Option<i64> {
    match v {
        Value::Int(i) => Some(*i),
        Value::Real(f) => crate::value::real_as_exact_int(*f),
        _ => None,
    }
}

/// Rowids of the candidate rows of a Rowid or Index access, in lookup order.
pub fn lookup_rowids(t: &Table, access: &Access, buf: &[Value], cx: &Cx) -> Result<Vec<i64>> {
    let mut out = Vec::new();
    match access {
        Access::Rowid(lk) => {
            if let Some(k) = lk.eq.first() {
                if let Some(r) = key_value(k, buf, cx)?.as_ref().and_then(rowid_exact) {
                    if t.rows.contains_key(&r) {
                        out.push(r);
                    }
                }
            } else if let Some(list) = &lk.in_list {
                let mut ids = Vec::new();
                for k in list {
                    if let Some(r) = key_value(k, buf, cx)?.as_ref().and_then(rowid_exact) {
                        ids.push(r);
                    }
                }
                ids.sort_unstable();
                ids.dedup();
                out.extend(ids.into_iter().filter(|r| t.rows.contains_key(r)));
            } else {
                let mut lo = i64::MIN;
                let mut hi = i64::MAX;
                if let Some((k, _)) = &lk.lo {
                    match key_value(k, buf, cx)? {
                        Some(Value::Int(i)) => lo = i,
                        Some(Value::Real(f)) => {
                            if f.is_nan() || f > 9.3e18 {
                                return Ok(out);
                            }
                            if f > -9.3e18 {
                                lo = f.floor().max(i64::MIN as f64) as i64;
                            }
                        }
                        // Integers are below all text and blobs.
                        _ => return Ok(out),
                    }
                }
                if let Some((k, _)) = &lk.hi {
                    match key_value(k, buf, cx)? {
                        Some(Value::Int(i)) => hi = i,
                        Some(Value::Real(f)) => {
                            if f.is_nan() || f < -9.3e18 {
                                return Ok(out);
                            }
                            if f < 9.3e18 {
                                hi = f.ceil().min(i64::MAX as f64) as i64;
                            }
                        }
                        Some(_) => {}
                        None => return Ok(out),
                    }
                }
                if lo <= hi {
                    out.extend(t.rows.range(lo..=hi).map(|(r, _)| *r));
                }
            }
        }
        Access::Index(pos, lk) => {
            let ix = &t.indexes[*pos];
            let mut prefix = Vec::with_capacity(lk.eq.len() + 1);
            for k in &lk.eq {
                match key_value(k, buf, cx)? {
                    Some(v) => prefix.push(v),
                    None => return Ok(out),
                }
            }
            if let Some(list) = &lk.in_list {
                let mut vals = Vec::new();
                for k in list {
                    if let Some(v) = key_value(k, buf, cx)? {
                        vals.push(IdxKey(vec![v]));
                    }
                }
                vals.sort();
                vals.dedup();
                if ix.cols.get(prefix.len()).is_some_and(|c| c.desc) {
                    vals.reverse();
                }
                for v in vals {
                    let mut p = prefix.clone();
                    p.extend(v.0);
                    scan_index(ix, &p, None, None, &mut out);
                }
            } else {
                let lo = match &lk.lo {
                    Some((k, incl)) => match key_value(k, buf, cx)? {
                        Some(v) => Some((v, *incl)),
                        None => return Ok(out),
                    },
                    None => None,
                };
                let hi = match &lk.hi {
                    Some((k, incl)) => match key_value(k, buf, cx)? {
                        Some(v) => Some((v, *incl)),
                        None => return Ok(out),
                    },
                    None => None,
                };
                scan_index(ix, &prefix, lo, hi, &mut out);
            }
        }
        Access::Full | Access::Auto { .. } => out.extend(t.rows.keys().copied()),
    }
    Ok(out)
}

/// Rowids of index entries starting with `prefix` whose next component is
/// within the bounds.
fn scan_index(
    ix: &crate::db::Index,
    prefix: &[Value],
    lo: Option<(Value, bool)>,
    hi: Option<(Value, bool)>,
    out: &mut Vec<i64>,
) {
    use std::cmp::Ordering;
    let p = prefix.len();
    let desc = ix.cols.get(p).is_some_and(|c| c.desc);
    // Scan from the bound that comes first in index order.
    let (first, last, stop) = if desc { (hi, lo, Ordering::Less) } else { (lo, hi, Ordering::Greater) };
    let mut start = prefix.to_vec();
    if let Some((v, _)) = &first {
        start.push(v.clone());
    }
    for key in ix.entries.range(IxKey(start, ix.desc_mask())..) {
        let k = &key.0;
        if (0..p).any(|i| compare(&k[i], &prefix[i]) != Ordering::Equal) {
            break;
        }
        if let Some((v, incl)) = &first {
            if !incl && compare(&k[p], v) == Ordering::Equal {
                continue;
            }
        }
        if let Some((v, incl)) = &last {
            match compare(&k[p], v) {
                o if o == stop => break,
                Ordering::Equal if !incl => break,
                _ => {}
            }
        }
        if let Some(Value::Int(r)) = k.last() {
            out.push(*r);
        }
    }
}

/// Automatic index for a materialized source of `width` columns at
/// `offset`: an equality on one of its columns, if any.
pub fn plan_auto(offset: usize, width: usize, conjs: &[&Expr]) -> Access {
    if width == 0 {
        return Access::Full;
    }
    let cx = Ctx { offset, ncols: width - 1 };
    let mut cons: Vec<Cons> = Vec::new();
    for c in conjs {
        collect(&cx, c, &mut cons);
    }
    for c in cons {
        if let (Op::Eq, Target::Col(i)) = (c.op, &c.target) {
            return Access::Auto { col: *i, key: c.keys[0].clone() };
        }
    }
    Access::Full
}
