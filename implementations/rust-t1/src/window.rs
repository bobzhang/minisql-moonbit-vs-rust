// Window functions: binding of `OVER` calls and evaluation over the rows
// of a query level (after WHERE / GROUP BY / HAVING, before DISTINCT,
// ORDER BY and LIMIT).

use std::cmp::Ordering;
use std::collections::BTreeMap;

use crate::agg::{cmp_keys, AggSpec, AggState, SortSpec};
use crate::ast::*;
use crate::db::{normalize, IdxKey};
use crate::error::{err, Result};
use crate::eval::{bind, eval, expr_collation, Cx, Scope};
use crate::query::Row;
use crate::value::{Collation, Value};

/// Window results are bound as `AggRef { idx: WIN_BASE + slot }` and moved
/// to their real row position once the query level is planned.
pub const WIN_BASE: usize = 1 << 40;

#[derive(Clone, Debug)]
pub enum Bound {
    UnboundedPreceding,
    Preceding(Expr),
    CurrentRow,
    Following(Expr),
    UnboundedFollowing,
}

#[derive(Clone, Debug)]
pub struct BoundFrame {
    pub unit: FrameUnit,
    pub start: Bound,
    pub end: Bound,
    pub exclude: Exclude,
}

#[derive(Debug)]
pub struct WinFunc {
    pub slot: usize,
    pub name: String,
    pub args: Vec<Expr>,
    pub star: bool,
    pub coll: Collation,
    pub filter: Option<Expr>,
    pub frame: BoundFrame,
    pub is_agg: bool,
}

/// Window functions sharing one window (partition, order and frame): they
/// are computed in one pass over the rows sorted for that window.
#[derive(Debug)]
pub struct WinGroup {
    key: String,
    pub partition: Vec<Expr>,
    pub order: Vec<Expr>,
    /// Sort specification: partition keys then order keys.
    pub spec: Vec<SortSpec>,
    pub funcs: Vec<WinFunc>,
}

#[derive(Default, Debug)]
pub struct WinCollector {
    /// Named windows of the WINDOW clause.
    pub defs: Vec<(String, WindowDef)>,
    pub groups: Vec<WinGroup>,
    pub nslots: usize,
}

fn window_only_arity(name: &str) -> Option<(usize, usize)> {
    Some(match name {
        "row_number" | "rank" | "dense_rank" | "percent_rank" | "cume_dist" => (0, 0),
        "ntile" => (1, 1),
        "lag" | "lead" => (1, 3),
        "first_value" | "last_value" => (1, 1),
        "nth_value" => (2, 2),
        _ => return None,
    })
}

pub fn is_window_only(name: &str) -> bool {
    window_only_arity(name).is_some()
}

/// Resolve a window reference against the named windows.
pub fn resolve_def(over: &Over, defs: &[(String, WindowDef)], depth: usize) -> Result<WindowDef> {
    if depth > 64 {
        return err!("window definition too deep");
    }
    let named = |n: &str| -> Result<WindowDef> {
        match defs.iter().find(|(d, _)| d.eq_ignore_ascii_case(n)) {
            Some((_, d)) => resolve_def(&Over::Spec(d.clone()), defs, depth + 1),
            None => err!("no such window: {}", n),
        }
    };
    match over {
        Over::Named(n) => named(n),
        Over::Spec(d) => {
            let Some(b) = &d.base else { return Ok(d.clone()) };
            let base = named(b)?;
            if !d.partition.is_empty() {
                return err!("cannot override PARTITION clause of window: {}", b);
            }
            if !base.order.is_empty() && !d.order.is_empty() {
                return err!("cannot override ORDER BY clause of window: {}", b);
            }
            if base.frame.is_some() {
                return err!("cannot override frame specification of window: {}", b);
            }
            Ok(WindowDef {
                base: None,
                partition: base.partition,
                order: if d.order.is_empty() { base.order } else { d.order.clone() },
                frame: d.frame.clone(),
            })
        }
    }
}

/// Bind a window function call; returns a placeholder reference to its
/// result.
pub fn bind_window(func: &Expr, over: &Over, scope: &Scope) -> Result<Expr> {
    let Expr::Func { name, args, star, distinct, filter, order_by, .. } = func else {
        return err!("syntax error");
    };
    let nargs = args.len();
    let is_agg = crate::func::is_aggregate(name, nargs);
    if !is_agg {
        match window_only_arity(name) {
            None => {
                crate::func::check_function(name, nargs, *star)?;
                return err!("{}() may not be used as a window function", name);
            }
            Some((lo, hi)) => {
                if *star || nargs < lo || nargs > hi {
                    return err!("wrong number of arguments to function {}()", name);
                }
            }
        }
    } else {
        crate::func::check_function(name, nargs, *star)?;
    }
    let Some(wc) = scope.wins.clone() else {
        return err!("misuse of window function {}()", name);
    };
    if *distinct {
        return err!("DISTINCT is not supported for window functions");
    }
    if !order_by.is_empty() {
        return err!("ORDER BY may not be used with non-aggregate {}()", name);
    }
    if filter.is_some() && !is_agg {
        return err!("FILTER clause may only be used with aggregate window functions");
    }
    let mut inner = scope.clone();
    inner.wins = None;
    let args = args.iter().map(|a| bind(a, &inner)).collect::<Result<Vec<_>>>()?;
    let filter = filter.as_ref().map(|f| bind(f, &inner)).transpose()?;
    let defs = wc.borrow().defs.clone();
    let def = resolve_def(over, &defs, 0)?;
    let partition = def.partition.iter().map(|e| bind(e, &inner)).collect::<Result<Vec<_>>>()?;
    let mut order = Vec::new();
    let mut spec: Vec<SortSpec> = Vec::new();
    for e in &partition {
        spec.push((false, None, expr_collation(e).unwrap_or(Collation::Binary)));
    }
    for t in &def.order {
        let e = bind(&t.expr, &inner)?;
        spec.push((t.desc, t.nulls_first, expr_collation(&e).unwrap_or(Collation::Binary)));
        order.push(e);
    }
    let bind_bound = |b: &FrameBound| -> Result<Bound> {
        Ok(match b {
            FrameBound::UnboundedPreceding => Bound::UnboundedPreceding,
            FrameBound::Preceding(e) => Bound::Preceding(bind(e, &inner)?),
            FrameBound::CurrentRow => Bound::CurrentRow,
            FrameBound::Following(e) => Bound::Following(bind(e, &inner)?),
            FrameBound::UnboundedFollowing => Bound::UnboundedFollowing,
        })
    };
    let mut frame = match &def.frame {
        Some(f) => BoundFrame { unit: f.unit, start: bind_bound(&f.start)?, end: bind_bound(&f.end)?, exclude: f.exclude },
        None => BoundFrame {
            unit: FrameUnit::Range,
            start: Bound::UnboundedPreceding,
            end: Bound::CurrentRow,
            exclude: Exclude::NoOthers,
        },
    };
    if frame.unit == FrameUnit::Range
        && (matches!(frame.start, Bound::Preceding(_) | Bound::Following(_))
            || matches!(frame.end, Bound::Preceding(_) | Bound::Following(_)))
        && order.len() != 1
    {
        return err!("RANGE with offset PRECEDING/FOLLOWING requires one ORDER BY expression");
    }
    // Functions that ignore the frame get a fixed one (as in SQLite, this
    // decides which windows are computed together).
    use Bound::*;
    let fixed = match name.as_str() {
        "row_number" => Some((FrameUnit::Rows, UnboundedPreceding, CurrentRow)),
        "rank" | "dense_rank" => Some((FrameUnit::Range, UnboundedPreceding, CurrentRow)),
        "percent_rank" => Some((FrameUnit::Groups, CurrentRow, UnboundedFollowing)),
        "cume_dist" => Some((FrameUnit::Groups, Following(Expr::Lit(Value::Int(1))), UnboundedFollowing)),
        "ntile" => Some((FrameUnit::Rows, CurrentRow, UnboundedFollowing)),
        "lead" => Some((FrameUnit::Rows, UnboundedPreceding, UnboundedFollowing)),
        "lag" => Some((FrameUnit::Rows, UnboundedPreceding, CurrentRow)),
        _ => None,
    };
    if let Some((unit, start, end)) = fixed {
        frame = BoundFrame { unit, start, end, exclude: Exclude::NoOthers };
    }
    let key = format!("{:?}|{:?}|{:?}|{:?}", partition, order, spec, frame);
    let coll = match name.as_str() {
        "first_value" | "last_value" | "nth_value" | "lag" | "lead" | "min" | "max" => {
            args.first().and_then(expr_collation)
        }
        _ => None,
    };
    let fcoll = args.iter().find_map(expr_collation).unwrap_or(Collation::Binary);
    let mut c = wc.borrow_mut();
    let slot = c.nslots;
    c.nslots += 1;
    let f = WinFunc { slot, name: name.clone(), args, star: *star, coll: fcoll, filter, frame, is_agg };
    match c.groups.iter_mut().find(|g| g.key == key) {
        Some(g) => g.funcs.push(f),
        None => c.groups.push(WinGroup { key, partition, order, spec, funcs: vec![f] }),
    }
    Ok(Expr::AggRef { idx: WIN_BASE + slot, coll })
}

/// Does a bound expression reference a window function result?
pub fn has_win_ref(e: &Expr) -> bool {
    if let Expr::AggRef { idx, .. } = e {
        return *idx >= WIN_BASE;
    }
    let mut found = false;
    crate::eval::for_each_child(e, &mut |c| found |= has_win_ref(c));
    found
}

/// Move window result references to row position `base + slot`.
pub fn place_refs(e: &mut Expr, base: usize) {
    if let Expr::AggRef { idx, .. } = e {
        if *idx >= WIN_BASE {
            *idx = *idx - WIN_BASE + base;
        }
        return;
    }
    crate::agg::for_each_child_mut(e, &mut |c| place_refs(c, base));
}

/// Compute all window functions over `rows`, storing each result at
/// `base + slot`. Returns the rows in the order of the first window.
pub fn compute(groups: &[WinGroup], mut rows: Vec<Row>, base: usize, nslots: usize, cx: &Cx) -> Result<Vec<Row>> {
    for r in rows.iter_mut() {
        r.resize(base + nslots, Value::Null);
    }
    // As in SQLite, the last window is computed first and each window pass
    // re-sorts (stably) the output of the previous one.
    for g in groups.iter().rev() {
        rows = run_group(g, rows, base, cx)?;
    }
    Ok(rows)
}

fn run_group(g: &WinGroup, rows: Vec<Row>, base: usize, cx: &Cx) -> Result<Vec<Row>> {
    let np = g.partition.len();
    let mut keyed: Vec<(Vec<Value>, Row)> = Vec::with_capacity(rows.len());
    for r in rows {
        let mut k = Vec::with_capacity(np + g.order.len());
        for e in g.partition.iter().chain(&g.order) {
            k.push(eval(e, &r, cx)?);
        }
        keyed.push((k, r));
    }
    if !g.spec.is_empty() {
        keyed.sort_by(|a, b| cmp_keys(&a.0, &b.0, &g.spec));
    }
    let (keys, mut rows): (Vec<Vec<Value>>, Vec<Row>) = keyed.into_iter().unzip();
    let pspec = &g.spec[..np];
    let ospec = &g.spec[np..];
    let n = rows.len();
    let mut ps = 0;
    while ps < n {
        let mut pe = ps + 1;
        while pe < n && cmp_keys(&keys[ps][..np], &keys[pe][..np], pspec) == Ordering::Equal {
            pe += 1;
        }
        let okeys: Vec<&[Value]> = keys[ps..pe].iter().map(|k| &k[np..]).collect();
        let part = Partition::new(&okeys, ospec);
        for f in &g.funcs {
            let vals = eval_func(f, &part, &rows[ps..pe], cx)?;
            for (r, v) in rows[ps..pe].iter_mut().zip(vals) {
                r[base + f.slot] = v;
            }
        }
        ps = pe;
    }
    Ok(rows)
}

/// One partition: peer groups by ORDER BY key.
struct Partition<'a> {
    m: usize,
    okeys: &'a [&'a [Value]],
    ospec: &'a [SortSpec],
    /// Peer group index of each row.
    gidx: Vec<usize>,
    /// First row and end (exclusive) of each peer group.
    gfirst: Vec<usize>,
    gend: Vec<usize>,
}

impl<'a> Partition<'a> {
    fn new(okeys: &'a [&'a [Value]], ospec: &'a [SortSpec]) -> Partition<'a> {
        let m = okeys.len();
        let mut gidx = Vec::with_capacity(m);
        let mut gfirst = Vec::new();
        let mut gend = Vec::new();
        for i in 0..m {
            let new_group = i == 0 || cmp_keys(okeys[i - 1], okeys[i], ospec) != Ordering::Equal;
            if new_group {
                if i > 0 {
                    gend.push(i);
                }
                gfirst.push(i);
            }
            gidx.push(gfirst.len() - 1);
        }
        if m > 0 {
            gend.push(m);
        }
        Partition { m, okeys, ospec, gidx, gfirst, gend }
    }

    fn peers(&self, i: usize) -> (usize, usize) {
        let g = self.gidx[i];
        (self.gfirst[g], self.gend[g])
    }
}

/// Evaluated frame bound.
enum BVal {
    UnbP,
    Prec(Value),
    Cur,
    Foll(Value),
    UnbF,
}

fn eval_bound(b: &Bound, unit: FrameUnit, is_start: bool, row: &[Value], cx: &Cx) -> Result<BVal> {
    let off = |e: &Expr| -> Result<Value> {
        let v = eval(e, row, cx)?;
        let which = if is_start { "starting" } else { "ending" };
        match unit {
            FrameUnit::Range => match v {
                Value::Int(i) if i >= 0 => Ok(v),
                Value::Real(r) if r >= 0.0 => Ok(v),
                _ => err!("frame {} offset must be a non-negative number", which),
            },
            _ => match v {
                Value::Int(i) if i >= 0 => Ok(v),
                Value::Real(r) if r >= 0.0 && r.fract() == 0.0 && r < 9.2e18 => Ok(Value::Int(r as i64)),
                _ => err!("frame {} offset must be a non-negative integer", which),
            },
        }
    };
    Ok(match b {
        Bound::UnboundedPreceding => BVal::UnbP,
        Bound::Preceding(e) => BVal::Prec(off(e)?),
        Bound::CurrentRow => BVal::Cur,
        Bound::Following(e) => BVal::Foll(off(e)?),
        Bound::UnboundedFollowing => BVal::UnbF,
    })
}

fn as_count(v: &Value) -> usize {
    match v {
        Value::Int(i) => (*i).clamp(0, i64::MAX >> 2) as usize,
        _ => 0,
    }
}

impl Partition<'_> {
    /// Position of a frame bound for row `i`: the first row of the frame
    /// (start) or one past the last (end).
    fn bound(&self, b: &BVal, unit: FrameUnit, is_start: bool, i: usize) -> usize {
        let m = self.m;
        match b {
            BVal::UnbP => 0,
            BVal::UnbF => m,
            BVal::Cur => match unit {
                FrameUnit::Rows => {
                    if is_start {
                        i
                    } else {
                        i + 1
                    }
                }
                _ => {
                    let (a, e) = self.peers(i);
                    if is_start {
                        a
                    } else {
                        e
                    }
                }
            },
            BVal::Prec(v) | BVal::Foll(v) => {
                let prec = matches!(b, BVal::Prec(_));
                match unit {
                    FrameUnit::Rows => {
                        let k = as_count(v);
                        let p = if prec { i as i64 - k as i64 } else { (i + k).min(m) as i64 };
                        let p = if is_start { p } else { p + 1 };
                        p.clamp(0, m as i64) as usize
                    }
                    FrameUnit::Groups => {
                        let k = as_count(v);
                        let g = self.gidx[i];
                        let ng = self.gfirst.len();
                        let tg = if prec { g as i64 - k as i64 } else { g as i64 + k as i64 };
                        if is_start {
                            if tg < 0 {
                                0
                            } else if tg as usize >= ng {
                                m
                            } else {
                                self.gfirst[tg as usize]
                            }
                        } else if tg < 0 {
                            0
                        } else {
                            self.gend[(tg as usize).min(ng - 1)]
                        }
                    }
                    FrameUnit::Range => {
                        let cur = &self.okeys[i][0];
                        if cur.is_null() {
                            let (a, e) = self.peers(i);
                            return if is_start { a } else { e };
                        }
                        let desc = self.ospec[0].0;
                        let add = prec == desc;
                        let target = if matches!(cur, Value::Int(_) | Value::Real(_)) {
                            let op = if add { BinOp::Add } else { BinOp::Sub };
                            let e = Expr::Binary(op, Box::new(Expr::Lit(cur.clone())), Box::new(Expr::Lit(v.clone())));
                            eval(&e, &[], &Cx::new(crate::db::empty_db())).unwrap_or(Value::Null)
                        } else {
                            cur.clone()
                        };
                        let spec = &self.ospec[..1];
                        let t = [target];
                        let ord = |j: usize| cmp_keys(&self.okeys[j][..1], &t, spec);
                        if is_start {
                            partition_point(m, |j| ord(j) == Ordering::Less)
                        } else {
                            partition_point(m, |j| ord(j) != Ordering::Greater)
                        }
                    }
                }
            }
        }
    }
}

/// First index in 0..m for which `pred` is false (pred is monotone).
fn partition_point(m: usize, pred: impl Fn(usize) -> bool) -> usize {
    let (mut lo, mut hi) = (0, m);
    while lo < hi {
        let mid = (lo + hi) / 2;
        if pred(mid) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    lo
}

/// The frame [s, e) of row `i` minus its excluded rows, as intervals.
fn frame_parts(s: usize, e: usize, i: usize, excl: Exclude, part: &Partition) -> Vec<(usize, usize)> {
    if s >= e {
        return vec![];
    }
    let cut: Vec<(usize, usize)> = match excl {
        Exclude::NoOthers => vec![],
        Exclude::CurrentRow => vec![(i, i + 1)],
        Exclude::Group => vec![part.peers(i)],
        Exclude::Ties => {
            let (a, b) = part.peers(i);
            vec![(a, i), (i + 1, b)]
        }
    };
    let mut out = vec![(s, e)];
    for (ca, cb) in cut {
        if ca >= cb {
            continue;
        }
        let mut next = Vec::new();
        for (a, b) in out {
            if cb <= a || ca >= b {
                next.push((a, b));
                continue;
            }
            if a < ca {
                next.push((a, ca));
            }
            if cb < b {
                next.push((cb, b));
            }
        }
        out = next;
    }
    out
}

fn positive_int(v: &Value) -> Option<i64> {
    match v {
        Value::Int(i) if *i > 0 => Some(*i),
        Value::Real(r) if *r > 0.0 && r.fract() == 0.0 && *r < 9.2e18 => Some(*r as i64),
        _ => None,
    }
}

fn eval_func(f: &WinFunc, part: &Partition, rows: &[Row], cx: &Cx) -> Result<Vec<Value>> {
    let m = part.m;
    let mut out = Vec::with_capacity(m);
    match f.name.as_str() {
        "row_number" => {
            for i in 0..m {
                out.push(Value::Int(i as i64 + 1));
            }
            return Ok(out);
        }
        "rank" => {
            for i in 0..m {
                out.push(Value::Int(part.peers(i).0 as i64 + 1));
            }
            return Ok(out);
        }
        "dense_rank" => {
            for i in 0..m {
                out.push(Value::Int(part.gidx[i] as i64 + 1));
            }
            return Ok(out);
        }
        "percent_rank" => {
            for i in 0..m {
                let r = if m <= 1 { 0.0 } else { part.peers(i).0 as f64 / (m - 1) as f64 };
                out.push(Value::Real(r));
            }
            return Ok(out);
        }
        "cume_dist" => {
            for i in 0..m {
                out.push(Value::Real(part.peers(i).1 as f64 / m as f64));
            }
            return Ok(out);
        }
        "ntile" => {
            for (i, r) in rows.iter().enumerate() {
                let v = eval(&f.args[0], r, cx)?;
                let np = match v {
                    Value::Null => 0,
                    v => v.to_int(),
                };
                if np <= 0 {
                    return err!("argument of ntile must be a positive integer");
                }
                let total = m as i64;
                let size = total / np;
                let iv = i as i64;
                let t = if size == 0 {
                    iv + 1
                } else {
                    let large = total - np * size;
                    let small = large * (size + 1);
                    if iv < small {
                        1 + iv / (size + 1)
                    } else {
                        1 + large + (iv - small) / size
                    }
                };
                out.push(Value::Int(t));
            }
            return Ok(out);
        }
        "lag" | "lead" => {
            let vals = rows.iter().map(|r| eval(&f.args[0], r, cx)).collect::<Result<Vec<_>>>()?;
            for (i, r) in rows.iter().enumerate() {
                let off = match f.args.get(1) {
                    Some(e) => match eval(e, r, cx)? {
                        Value::Null => None,
                        v => Some(v.to_int()),
                    },
                    None => Some(1),
                };
                let target = off.and_then(|o| {
                    let t = if f.name == "lag" { (i as i64).checked_sub(o) } else { (i as i64).checked_add(o) };
                    t.filter(|t| *t >= 0 && (*t as usize) < m)
                });
                out.push(match target {
                    Some(t) => vals[t as usize].clone(),
                    None => match f.args.get(2) {
                        Some(d) => eval(d, r, cx)?,
                        None => Value::Null,
                    },
                });
            }
            return Ok(out);
        }
        _ => {}
    }

    // Frame-based functions.
    let first = &rows[0];
    let unit = f.frame.unit;
    let bs = eval_bound(&f.frame.start, unit, true, first, cx)?;
    let be = eval_bound(&f.frame.end, unit, false, first, cx)?;
    let excl = f.frame.exclude;
    let bounds: Vec<(usize, usize)> = (0..m)
        .map(|i| {
            let s = part.bound(&bs, unit, true, i);
            let e = part.bound(&be, unit, false, i);
            (s, e.max(s))
        })
        .collect();

    if !f.is_agg {
        let vals = rows.iter().map(|r| eval(&f.args[0], r, cx)).collect::<Result<Vec<_>>>()?;
        for (i, r) in rows.iter().enumerate() {
            let (s, e) = bounds[i];
            let parts = frame_parts(s, e, i, excl, part);
            let v = match f.name.as_str() {
                "first_value" => parts.first().map(|(a, _)| vals[*a].clone()),
                "last_value" => parts.last().map(|(_, b)| vals[*b - 1].clone()),
                _ => {
                    let nv = eval(&f.args[1], r, cx)?;
                    let Some(mut k) = positive_int(&nv) else {
                        return err!("second argument to nth_value must be a positive integer");
                    };
                    let mut found = None;
                    for (a, b) in &parts {
                        let len = (b - a) as i64;
                        if k <= len {
                            found = Some(vals[a + k as usize - 1].clone());
                            break;
                        }
                        k -= len;
                    }
                    found
                }
            };
            out.push(v.unwrap_or(Value::Null));
        }
        return Ok(out);
    }

    // Aggregates over the frame.
    let spec = AggSpec {
        name: f.name.clone(),
        args: vec![],
        star: f.star,
        distinct: false,
        coll: f.coll,
        filter: None,
        order_by: vec![],
        order_spec: vec![],
    };
    let mut args: Vec<Vec<Value>> = Vec::with_capacity(m);
    let mut pass: Vec<bool> = Vec::with_capacity(m);
    for r in rows {
        let ok = match &f.filter {
            Some(fl) => eval(fl, r, cx)?.truthy() == Some(true),
            None => true,
        };
        pass.push(ok);
        args.push(if ok { f.args.iter().map(|a| eval(a, r, cx)).collect::<Result<Vec<_>>>()? } else { vec![] });
    }
    let has_inverse = matches!(f.name.as_str(), "count" | "sum" | "total" | "avg");
    let running = excl == Exclude::NoOthers && matches!(f.frame.start, Bound::UnboundedPreceding);
    let minmax = matches!(f.name.as_str(), "min" | "max");
    if running || has_inverse {
        let mut st = AggState::new(&spec);
        let (mut lo, mut hi) = (0usize, 0usize);
        for i in 0..m {
            let (s, e) = bounds[i];
            while lo < s {
                if lo < hi && pass[lo] {
                    st.inverse(&spec, &args[lo]);
                }
                lo += 1;
            }
            if hi < lo {
                hi = lo;
            }
            while hi < e {
                if pass[hi] {
                    st.step(&spec, &args[hi]);
                }
                hi += 1;
            }
            let mut cur = st.clone();
            if excl != Exclude::NoOthers && s < e {
                let kept = frame_parts(s, e, i, excl, part);
                // Remove the frame rows not kept.
                let mut j = s;
                for (a, b) in kept.iter().copied().chain(std::iter::once((e, e))) {
                    while j < a {
                        if pass[j] {
                            cur.inverse(&spec, &args[j]);
                        }
                        j += 1;
                    }
                    j = b.max(j);
                }
            }
            out.push(cur.finish(&spec)?);
        }
        return Ok(out);
    }
    if minmax && excl == Exclude::NoOthers {
        let mut set: BTreeMap<IdxKey, (Value, usize)> = BTreeMap::new();
        let (mut lo, mut hi) = (0usize, 0usize);
        let keyof = |v: &Value| IdxKey(vec![normalize(v, f.coll)]);
        for i in 0..m {
            let (s, e) = bounds[i];
            while lo < s {
                if lo < hi && pass[lo] && !args[lo][0].is_null() {
                    let k = keyof(&args[lo][0]);
                    if let Some(ent) = set.get_mut(&k) {
                        ent.1 -= 1;
                        if ent.1 == 0 {
                            set.remove(&k);
                        }
                    }
                }
                lo += 1;
            }
            if hi < lo {
                hi = lo;
            }
            while hi < e {
                if pass[hi] && !args[hi][0].is_null() {
                    set.entry(keyof(&args[hi][0])).or_insert_with(|| (args[hi][0].clone(), 0)).1 += 1;
                }
                hi += 1;
            }
            let v = if f.name == "min" { set.values().next() } else { set.values().next_back() };
            out.push(v.map(|(v, _)| v.clone()).unwrap_or(Value::Null));
        }
        return Ok(out);
    }
    // General case: aggregate each frame from scratch.
    for i in 0..m {
        let (s, e) = bounds[i];
        let mut st = AggState::new(&spec);
        for (a, b) in frame_parts(s, e, i, excl, part) {
            for j in a..b {
                if pass[j] {
                    st.step(&spec, &args[j]);
                }
            }
        }
        out.push(st.finish(&spec)?);
    }
    Ok(out)
}
