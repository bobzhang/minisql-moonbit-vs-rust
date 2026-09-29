// Window functions: extraction from the AST, binding and evaluation over
// the rows of a query (after WHERE / GROUP BY / HAVING, before DISTINCT,
// ORDER BY and LIMIT).

use std::cmp::Ordering;

use crate::agg::{self, AggKind, AggSpec, AggState};
use crate::ast::{BinOp, Exclude, Expr, FrameBound, FrameUnit, FuncCall, WindowSpec};
use crate::eval::{arith, check_coll, eval, expr_coll, BExpr, Env};
use crate::value::{apply_affinity, Affinity, Coll, Value};

/// Functions that exist only as window functions.
pub fn is_window_only(name: &str) -> bool {
    matches!(
        name.to_ascii_lowercase().as_str(),
        "row_number" | "rank" | "dense_rank" | "percent_rank" | "cume_dist" | "ntile" | "lag" | "lead" | "first_value"
            | "last_value" | "nth_value"
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WinKind {
    RowNumber,
    Rank,
    DenseRank,
    PercentRank,
    CumeDist,
    Ntile,
    Lag,
    Lead,
    FirstValue,
    LastValue,
    NthValue,
    Agg(AggKind),
}

/// Resolves named windows: the result has no base.
fn resolve_spec(spec: &WindowSpec, named: &[(String, WindowSpec)], depth: usize) -> Result<WindowSpec, String> {
    let Some(b) = &spec.base else { return Ok(spec.clone()) };
    let base = named
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case(b))
        .map(|(_, w)| w)
        .ok_or_else(|| format!("no such window: {}", b))?;
    if depth > 32 {
        return Err(format!("no such window: {}", b));
    }
    let base = resolve_spec(base, named, depth + 1)?;
    if !spec.paren {
        return Ok(base);
    }
    if !spec.partition.is_empty() {
        return Err(format!("cannot override PARTITION clause of window: {}", b));
    }
    if !spec.order.is_empty() && !base.order.is_empty() {
        return Err(format!("cannot override ORDER BY clause of window: {}", b));
    }
    if base.frame.is_some() {
        return Err(format!("cannot override frame specification of window: {}", b));
    }
    Ok(WindowSpec {
        base: None,
        paren: true,
        partition: base.partition,
        order: if spec.order.is_empty() { base.order } else { spec.order.clone() },
        frame: spec.frame.clone(),
    })
}

/// The kind of a window function call, checking its arguments.
fn win_kind(fc: &FuncCall) -> Result<WinKind, String> {
    let n = fc.args.len();
    let lname = fc.name.to_ascii_lowercase();
    let (kind, ok) = match lname.as_str() {
        "row_number" => (WinKind::RowNumber, n == 0),
        "rank" => (WinKind::Rank, n == 0),
        "dense_rank" => (WinKind::DenseRank, n == 0),
        "percent_rank" => (WinKind::PercentRank, n == 0),
        "cume_dist" => (WinKind::CumeDist, n == 0),
        "ntile" => (WinKind::Ntile, n == 1),
        "lag" => (WinKind::Lag, (1..=3).contains(&n)),
        "lead" => (WinKind::Lead, (1..=3).contains(&n)),
        "first_value" => (WinKind::FirstValue, n == 1),
        "last_value" => (WinKind::LastValue, n == 1),
        "nth_value" => (WinKind::NthValue, n == 2),
        _ => {
            if agg::is_agg_call(&fc.name, n) || matches!(lname.as_str(), "min" | "max") {
                if !fc.order_by.is_empty() {
                    return Err(format!("ORDER BY may not be used with non-aggregate {}()", fc.name));
                }
                if fc.distinct {
                    return Err("DISTINCT is not supported for window functions".to_string());
                }
                return Ok(WinKind::Agg(agg::agg_kind(fc)?));
            }
            crate::functions::lookup(&fc.name, n)?;
            return Err(format!("{}() may not be used as a window function", fc.name));
        }
    };
    if !ok || (fc.star && n > 0) {
        return Err(format!("wrong number of arguments to function {}()", fc.name));
    }
    if fc.distinct {
        return Err("DISTINCT is not supported for window functions".to_string());
    }
    if !fc.order_by.is_empty() {
        return Err(format!("ORDER BY may not be used with non-aggregate {}()", fc.name));
    }
    if fc.filter.is_some() {
        return Err("FILTER clause may only be used with aggregate window functions".to_string());
    }
    Ok(kind)
}

/// Replaces the window function calls of an expression with `WinRef`s,
/// collecting the calls (with named windows resolved).
pub fn extract(e: &Expr, named: &[(String, WindowSpec)], calls: &mut Vec<FuncCall>) -> Result<Expr, String> {
    agg::map_expr(e, &mut |x| {
        if let Expr::Function(fc) = x {
            if let Some(w) = &fc.over {
                win_kind(fc)?;
                let mut c = (**fc).clone();
                c.over = Some(Box::new(resolve_spec(w, named, 0)?));
                calls.push(c);
                return Ok(Some(Expr::WinRef(calls.len() - 1)));
            }
        }
        Ok(None)
    })
}

#[derive(Debug)]
pub enum Bound {
    UnboundedPreceding,
    Preceding(BExpr),
    CurrentRow,
    Following(BExpr),
    UnboundedFollowing,
}

#[derive(Debug)]
pub struct SpecPlan {
    pub partition: Vec<(BExpr, Coll)>,
    /// Expression, descending, nulls first, collation.
    pub order: Vec<(BExpr, bool, bool, Coll)>,
}

#[derive(Debug)]
pub struct CallPlan {
    kind: WinKind,
    args: Vec<BExpr>,
    filter: Option<BExpr>,
    spec: usize,
    unit: FrameUnit,
    start: Bound,
    end: Bound,
    exclude: Exclude,
    agg: Option<AggSpec>,
}

#[derive(Debug)]
pub struct WinPlan {
    pub specs: Vec<SpecPlan>,
    pub calls: Vec<CallPlan>,
    /// Row position of the first window function result.
    pub base: usize,
}

impl WinPlan {
    /// All expressions of the plan (for column usage analysis).
    pub fn exprs(&self) -> Vec<&BExpr> {
        let mut v: Vec<&BExpr> = Vec::new();
        for s in &self.specs {
            v.extend(s.partition.iter().map(|p| &p.0));
            v.extend(s.order.iter().map(|o| &o.0));
        }
        for c in &self.calls {
            v.extend(c.args.iter());
            v.extend(c.filter.iter());
            for b in [&c.start, &c.end] {
                if let Bound::Preceding(e) | Bound::Following(e) = b {
                    v.push(e);
                }
            }
        }
        v
    }
}

/// Binds the collected window calls; `bind` binds an expression against
/// the rows the windows run over.
pub fn plan(calls: &[FuncCall], base: usize, bind: &dyn Fn(&Expr) -> Result<BExpr, String>) -> Result<WinPlan, String> {
    let mut specs: Vec<SpecPlan> = Vec::new();
    let mut spec_keys: Vec<String> = Vec::new();
    let mut out = Vec::new();
    for fc in calls {
        let kind = win_kind(fc)?;
        let w = fc.over.as_deref().unwrap();
        let key = format!("{:?}|{:?}", w.partition, w.order);
        let spec = match spec_keys.iter().position(|k| *k == key) {
            Some(i) => i,
            None => {
                let mut partition = Vec::new();
                for e in &w.partition {
                    let b = bind(e)?;
                    let coll = check_coll(expr_coll(&b).unwrap_or(Coll::Binary))?;
                    partition.push((b, coll));
                }
                let mut order = Vec::new();
                for t in &w.order {
                    let b = bind(&t.expr)?;
                    let coll = check_coll(expr_coll(&b).unwrap_or(Coll::Binary))?;
                    order.push((b, t.desc, t.nulls_first.unwrap_or(!t.desc), coll));
                }
                specs.push(SpecPlan { partition, order });
                spec_keys.push(key);
                specs.len() - 1
            }
        };
        let mut args = Vec::new();
        for a in &fc.args {
            args.push(bind(a)?);
        }
        let filter = match &fc.filter {
            Some(f) => Some(bind(f)?),
            None => None,
        };
        let (unit, start, end, exclude) = match &w.frame {
            None => (FrameUnit::Range, Bound::UnboundedPreceding, Bound::CurrentRow, Exclude::NoOthers),
            Some(fr) => {
                let b = |x: &FrameBound| -> Result<Bound, String> {
                    Ok(match x {
                        FrameBound::UnboundedPreceding => Bound::UnboundedPreceding,
                        FrameBound::Preceding(e) => Bound::Preceding(bind(e)?),
                        FrameBound::CurrentRow => Bound::CurrentRow,
                        FrameBound::Following(e) => Bound::Following(bind(e)?),
                        FrameBound::UnboundedFollowing => Bound::UnboundedFollowing,
                    })
                };
                let s = b(&fr.start)?;
                let e = b(&fr.end)?;
                (fr.unit, s, e, fr.exclude)
            }
        };
        let has_offset = |x: &Bound| matches!(x, Bound::Preceding(_) | Bound::Following(_));
        if unit == FrameUnit::Range && (has_offset(&start) || has_offset(&end)) && w.order.len() != 1 {
            return Err("RANGE with offset PRECEDING/FOLLOWING requires one ORDER BY expression".to_string());
        }
        let agg = match kind {
            WinKind::Agg(k) => {
                let coll = args.first().and_then(expr_coll).unwrap_or(Coll::Binary);
                let coll = if matches!(k, AggKind::Min | AggKind::Max) { check_coll(coll)? } else { coll };
                Some(AggSpec { kind: k, args: Vec::new(), distinct: false, filter: None, order: Vec::new(), coll })
            }
            _ => None,
        };
        out.push(CallPlan { kind, args, filter, spec, unit, start, end, exclude, agg });
    }
    Ok(WinPlan { specs, calls: out, base })
}

fn cmp_keys(a: &[Value], b: &[Value], terms: &[(bool, bool, Coll)]) -> Ordering {
    agg::cmp_order(a, b, terms)
}

/// A frame offset: a non-negative integer (ROWS, GROUPS) or number (RANGE).
fn offset_value(e: &BExpr, row: &[Value], env: &Env, unit: FrameUnit, start: bool) -> Result<Value, String> {
    let which = if start { "starting" } else { "ending" };
    let v = eval(e, row, env)?;
    if unit == FrameUnit::Range {
        let n = v.numeric();
        let ok = match &n {
            Value::Integer(i) => *i >= 0,
            Value::Real(r) => *r >= 0.0,
            _ => false,
        };
        if !ok {
            return Err(format!("frame {} offset must be a non-negative number", which));
        }
        return Ok(n);
    }
    match apply_affinity(v, Affinity::Integer) {
        Value::Integer(i) if i >= 0 => Ok(Value::Integer(i)),
        _ => Err(format!("frame {} offset must be a non-negative integer", which)),
    }
}

fn int_of(v: &Value) -> i64 {
    match v {
        Value::Integer(i) => *i,
        _ => 0,
    }
}

/// The k-th (0-based) position of `segs`, if any.
fn nth_pos(segs: &[(usize, usize)], mut k: usize) -> Option<usize> {
    for &(a, b) in segs {
        if k < b - a {
            return Some(a + k);
        }
        k -= b - a;
    }
    None
}

/// `[s, e)` minus the excluded ranges.
fn subtract(s: usize, e: usize, excl: &[(usize, usize)]) -> Vec<(usize, usize)> {
    let mut segs = vec![(s, e)];
    for &(xa, xb) in excl {
        let mut next = Vec::new();
        for (a, b) in segs {
            if xb <= a || xa >= b {
                next.push((a, b));
                continue;
            }
            if a < xa {
                next.push((a, xa));
            }
            if xb < b {
                next.push((xb, b));
            }
        }
        segs = next;
    }
    segs.retain(|(a, b)| a < b);
    segs
}

/// Computes all window functions over `rows` (each has the result slots
/// at `plan.base ..`); leaves the rows in the order of the first window.
pub fn compute(plan: &WinPlan, rows: &mut Vec<Vec<Value>>, env: &Env) -> Result<(), String> {
    let n = rows.len();
    let mut order: Vec<usize> = (0..n).collect();
    if n == 0 {
        return Ok(());
    }
    // later windows first; each sort keeps the previous order among ties
    for si in (0..plan.specs.len()).rev() {
        let spec = &plan.specs[si];
        let mut pkeys: Vec<Vec<Value>> = Vec::with_capacity(n);
        let mut okeys: Vec<Vec<Value>> = Vec::with_capacity(n);
        for r in rows.iter() {
            let mut pk = Vec::with_capacity(spec.partition.len());
            for (e, _) in &spec.partition {
                pk.push(eval(e, r, env)?);
            }
            let mut ok = Vec::with_capacity(spec.order.len());
            for (e, ..) in &spec.order {
                ok.push(eval(e, r, env)?);
            }
            pkeys.push(pk);
            okeys.push(ok);
        }
        let pterms: Vec<(bool, bool, Coll)> = spec.partition.iter().map(|(_, c)| (false, true, *c)).collect();
        let oterms: Vec<(bool, bool, Coll)> = spec.order.iter().map(|&(_, d, nf, c)| (d, nf, c)).collect();
        order.sort_by(|&a, &b| {
            cmp_keys(&pkeys[a], &pkeys[b], &pterms).then_with(|| cmp_keys(&okeys[a], &okeys[b], &oterms))
        });
        let calls: Vec<(usize, &CallPlan)> = plan.calls.iter().enumerate().filter(|(_, c)| c.spec == si).collect();
        let mut results: Vec<Vec<Value>> = vec![vec![Value::Null; n]; calls.len()];
        let mut a = 0;
        while a < n {
            let mut b = a + 1;
            while b < n && cmp_keys(&pkeys[order[a]], &pkeys[order[b]], &pterms) == Ordering::Equal {
                b += 1;
            }
            let part = &order[a..b];
            // peer groups
            let m = part.len();
            let mut group_of = vec![0usize; m];
            let mut gstart: Vec<usize> = vec![0];
            for j in 1..m {
                if cmp_keys(&okeys[part[j - 1]], &okeys[part[j]], &oterms) != Ordering::Equal {
                    gstart.push(j);
                }
                group_of[j] = gstart.len() - 1;
            }
            let mut gend: Vec<usize> = gstart[1..].to_vec();
            gend.push(m);
            let ctx = Part { part, rows, okeys: &okeys, oterms: &oterms, group_of: &group_of, gstart: &gstart, gend: &gend };
            for (ci, (_, call)) in calls.iter().enumerate() {
                let vals = ctx.eval_call(call, env)?;
                for (j, v) in vals.into_iter().enumerate() {
                    results[ci][part[j]] = v;
                }
            }
            a = b;
        }
        for (ci, (idx, _)) in calls.iter().enumerate() {
            for (r, v) in rows.iter_mut().zip(std::mem::take(&mut results[ci])) {
                r[plan.base + idx] = v;
            }
        }
    }
    let mut taken: Vec<Option<Vec<Value>>> = std::mem::take(rows).into_iter().map(Some).collect();
    *rows = order.iter().map(|&i| taken[i].take().unwrap()).collect();
    Ok(())
}

/// One partition, in window order.
struct Part<'a> {
    part: &'a [usize],
    rows: &'a [Vec<Value>],
    okeys: &'a [Vec<Value>],
    oterms: &'a [(bool, bool, Coll)],
    group_of: &'a [usize],
    gstart: &'a [usize],
    gend: &'a [usize],
}

impl Part<'_> {
    fn row(&self, j: usize) -> &[Value] {
        &self.rows[self.part[j]]
    }

    /// Frame bound position for row `j` (a start position, or an exclusive
    /// end position).
    fn bound(&self, b: &Bound, off: &Option<Value>, j: usize, unit: FrameUnit, is_start: bool) -> usize {
        let m = self.part.len();
        let g = self.group_of[j];
        let ng = self.gstart.len();
        match b {
            Bound::UnboundedPreceding => 0,
            Bound::UnboundedFollowing => m,
            Bound::CurrentRow => match unit {
                FrameUnit::Rows => {
                    if is_start {
                        j
                    } else {
                        j + 1
                    }
                }
                _ => {
                    if is_start {
                        self.gstart[g]
                    } else {
                        self.gend[g]
                    }
                }
            },
            Bound::Preceding(_) | Bound::Following(_) => {
                let preceding = matches!(b, Bound::Preceding(_));
                let v = off.as_ref().unwrap();
                match unit {
                    FrameUnit::Rows => {
                        let k = int_of(v) as i128;
                        let pos = if preceding { j as i128 - k } else { j as i128 + k };
                        let pos = if is_start { pos } else { pos + 1 };
                        pos.clamp(0, m as i128) as usize
                    }
                    FrameUnit::Groups => {
                        let k = int_of(v) as i128;
                        let tg = if preceding { g as i128 - k } else { g as i128 + k };
                        if tg < 0 {
                            0
                        } else if tg >= ng as i128 {
                            m
                        } else if is_start {
                            self.gstart[tg as usize]
                        } else {
                            self.gend[tg as usize]
                        }
                    }
                    FrameUnit::Range => {
                        let cur = &self.okeys[self.part[j]][0];
                        let (desc, _, _) = self.oterms[0];
                        let target = if matches!(cur, Value::Integer(_) | Value::Real(_)) {
                            let add = preceding == desc;
                            arith(if add { BinOp::Add } else { BinOp::Sub }, cur, v)
                        } else {
                            cur.clone()
                        };
                        let t = [target];
                        let key = |k: usize| &self.okeys[self.part[k]][..1];
                        if is_start {
                            partition_point(m, |k| cmp_keys(key(k), &t, &self.oterms[..1]) == Ordering::Less)
                        } else {
                            partition_point(m, |k| cmp_keys(key(k), &t, &self.oterms[..1]) != Ordering::Greater)
                        }
                    }
                }
            }
        }
    }

    fn eval_call(&self, c: &CallPlan, env: &Env) -> Result<Vec<Value>, String> {
        let m = self.part.len();
        let mut out = Vec::with_capacity(m);
        match c.kind {
            WinKind::RowNumber => out.extend((0..m).map(|j| Value::Integer(j as i64 + 1))),
            WinKind::Rank => out.extend((0..m).map(|j| Value::Integer(self.gstart[self.group_of[j]] as i64 + 1))),
            WinKind::DenseRank => out.extend((0..m).map(|j| Value::Integer(self.group_of[j] as i64 + 1))),
            WinKind::PercentRank => out.extend((0..m).map(|j| {
                if m > 1 {
                    Value::Real(self.gstart[self.group_of[j]] as f64 / (m - 1) as f64)
                } else {
                    Value::Real(0.0)
                }
            })),
            WinKind::CumeDist => {
                out.extend((0..m).map(|j| Value::Real(self.gend[self.group_of[j]] as f64 / m as f64)))
            }
            WinKind::Ntile => {
                for j in 0..m {
                    let v = eval(&c.args[0], self.row(j), env)?;
                    let np = match v.numeric() {
                        Value::Integer(i) => i,
                        Value::Real(r) => r as i64,
                        _ => 0,
                    };
                    if np <= 0 {
                        return Err("argument of ntile must be a positive integer".to_string());
                    }
                    let (n, i) = (m as i64, j as i64);
                    let small = n / np;
                    let large = n - np * small;
                    let r = if small == 0 {
                        i + 1
                    } else if i < large * (small + 1) {
                        1 + i / (small + 1)
                    } else {
                        1 + large + (i - large * (small + 1)) / small
                    };
                    out.push(Value::Integer(r));
                }
            }
            WinKind::Lag | WinKind::Lead => {
                for j in 0..m {
                    let row = self.row(j);
                    // the target is the 1-based position plus/minus the
                    // offset; a non-integer position matches no row
                    let off = match c.args.get(1) {
                        Some(e) => eval(e, row, env)?,
                        None => Value::Integer(1),
                    };
                    let op = if c.kind == WinKind::Lag { BinOp::Sub } else { BinOp::Add };
                    let t = match arith(op, &Value::Integer(j as i64 + 1), &off) {
                        Value::Integer(i) => Some(i),
                        Value::Real(r) if r.fract() == 0.0 && r.abs() < 9.0e18 => Some(r as i64),
                        _ => None,
                    };
                    if let Some(t) = t.filter(|&t| t >= 1 && t <= m as i64) {
                        out.push(eval(&c.args[0], self.row(t as usize - 1), env)?);
                    } else {
                        out.push(match c.args.get(2) {
                            Some(d) => eval(d, row, env)?,
                            None => Value::Null,
                        });
                    }
                }
            }
            _ => return self.eval_framed(c, env),
        }
        Ok(out)
    }

    /// Functions computed over the frame.
    fn eval_framed(&self, c: &CallPlan, env: &Env) -> Result<Vec<Value>, String> {
        let m = self.part.len();
        let first = self.row(0);
        let offset = |b: &Bound, start: bool| -> Result<Option<Value>, String> {
            match b {
                Bound::Preceding(e) | Bound::Following(e) => Ok(Some(offset_value(e, first, env, c.unit, start)?)),
                _ => Ok(None),
            }
        };
        let soff = offset(&c.start, true)?;
        let eoff = offset(&c.end, false)?;
        let frame = |j: usize| -> Vec<(usize, usize)> {
            let s = self.bound(&c.start, &soff, j, c.unit, true).min(m);
            let e = self.bound(&c.end, &eoff, j, c.unit, false).min(m).max(s);
            let g = self.group_of[j];
            match c.exclude {
                Exclude::NoOthers => vec![(s, e)],
                Exclude::CurrentRow => subtract(s, e, &[(j, j + 1)]),
                Exclude::Group => subtract(s, e, &[(self.gstart[g], self.gend[g])]),
                Exclude::Ties => subtract(s, e, &[(self.gstart[g], j), (j + 1, self.gend[g])]),
            }
        };
        let mut out = Vec::with_capacity(m);
        match c.kind {
            WinKind::FirstValue | WinKind::LastValue | WinKind::NthValue => {
                for j in 0..m {
                    let segs = frame(j);
                    let total: usize = segs.iter().map(|(a, b)| b - a).sum();
                    let k = match c.kind {
                        WinKind::FirstValue => Some(0),
                        WinKind::LastValue => total.checked_sub(1),
                        _ => {
                            let v = eval(&c.args[1], self.row(j), env)?.numeric();
                            let nth = match v {
                                Value::Integer(i) if i > 0 => i as u64,
                                Value::Real(r) if r > 0.0 && r.fract() == 0.0 => r as u64,
                                _ => return Err("second argument to nth_value must be a positive integer".to_string()),
                            };
                            usize::try_from(nth - 1).ok()
                        }
                    };
                    out.push(match k.and_then(|k| nth_pos(&segs, k)) {
                        Some(p) => eval(&c.args[0], self.row(p), env)?,
                        None => Value::Null,
                    });
                }
            }
            WinKind::Agg(_) => {
                let spec = c.agg.as_ref().unwrap();
                // argument values and FILTER results by position
                let mut argv: Vec<Vec<Value>> = Vec::with_capacity(m);
                let mut pass: Vec<bool> = Vec::with_capacity(m);
                for j in 0..m {
                    let row = self.row(j);
                    let ok = match &c.filter {
                        Some(f) => eval(f, row, env)?.truth() == Some(true),
                        None => true,
                    };
                    pass.push(ok);
                    let mut a = Vec::with_capacity(c.args.len());
                    if ok {
                        for e in &c.args {
                            a.push(eval(e, row, env)?);
                        }
                    }
                    argv.push(a);
                }
                let inv = AggState::has_inverse(spec.kind);
                let mut st = AggState::default();
                let (mut cs, mut ce) = (0usize, 0usize);
                for j in 0..m {
                    let segs = frame(j);
                    if c.exclude != Exclude::NoOthers {
                        st = AggState::default();
                        for (a, b) in segs {
                            for k in a..b {
                                if pass[k] {
                                    st.step(spec, &argv[k]);
                                }
                            }
                        }
                        out.push(st.result(spec)?);
                        continue;
                    }
                    let (s, e) = segs.first().copied().unwrap_or_else(|| {
                        let s = self.bound(&c.start, &soff, j, c.unit, true).min(m);
                        (s, s)
                    });
                    if s == cs && e >= ce {
                        // grows at the end
                    } else if inv && s >= cs && s <= ce && e >= ce {
                        for k in cs..s {
                            if pass[k] {
                                st.inverse(spec, &argv[k]);
                            }
                        }
                    } else {
                        st = AggState::default();
                        ce = s;
                    }
                    for k in ce..e {
                        if pass[k] {
                            st.step(spec, &argv[k]);
                        }
                    }
                    cs = s;
                    ce = e;
                    out.push(st.result(spec)?);
                }
            }
            _ => unreachable!(),
        }
        Ok(out)
    }
}

/// First index in 0..n for which `pred` is false (pred is monotone).
fn partition_point(n: usize, pred: impl Fn(usize) -> bool) -> usize {
    let (mut lo, mut hi) = (0, n);
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
