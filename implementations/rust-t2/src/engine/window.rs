// Window functions: binding, partitioning, frames and evaluation.

use super::*;

/// Functions that exist only as window functions.
pub fn is_window_only(name: &str) -> bool {
    matches!(
        name,
        "row_number"
            | "rank"
            | "dense_rank"
            | "percent_rank"
            | "cume_dist"
            | "ntile"
            | "lag"
            | "lead"
            | "first_value"
            | "last_value"
            | "nth_value"
    )
}

#[derive(Debug, Clone)]
pub(super) enum WinFunc {
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
    Agg(AggCall),
}

#[derive(Debug, Clone)]
pub(super) enum Bound {
    UnbPre,
    Pre(BExpr),
    Cur,
    Fol(BExpr),
    UnbFol,
}

impl Bound {
    fn rank(&self) -> u8 {
        match self {
            Bound::UnbPre => 0,
            Bound::Pre(_) => 1,
            Bound::Cur => 2,
            Bound::Fol(_) => 3,
            Bound::UnbFol => 4,
        }
    }

    fn offset(&self) -> Option<&BExpr> {
        match self {
            Bound::Pre(e) | Bound::Fol(e) => Some(e),
            _ => None,
        }
    }
}

type WinOrder = (BExpr, bool, Option<bool>, Coll);

/// One window function call of a SELECT.
#[derive(Debug, Clone)]
pub(super) struct WinCall {
    func: WinFunc,
    args: Vec<BExpr>,
    filter: Option<BExpr>,
    partition: Vec<(BExpr, Coll)>,
    order: Vec<WinOrder>,
    unit: FrameUnit,
    start: Bound,
    end: Bound,
    exclude: FrameExclude,
    /// Identifies calls that share partitioning and ordering.
    sort_key: String,
}

impl WinCall {
    /// Every expression the call evaluates against the input rows.
    pub(super) fn exprs(&self) -> Vec<&BExpr> {
        let mut v: Vec<&BExpr> = self.args.iter().collect();
        v.extend(self.filter.iter());
        v.extend(self.partition.iter().map(|(e, _)| e));
        v.extend(self.order.iter().map(|(e, ..)| e));
        v
    }
}

/// Window functions collected while binding a SELECT.
pub(super) struct WinCtx {
    pub calls: Vec<WinCall>,
    pub base: Rc<Cell<usize>>,
    /// Nonzero while binding the arguments of a window function.
    pub depth: usize,
    /// WINDOW clause definitions.
    pub defs: Vec<(String, WindowSpec)>,
}

impl WinCtx {
    pub fn new(defs: Vec<(String, WindowSpec)>) -> WinCtx {
        WinCtx {
            calls: Vec::new(),
            base: Rc::new(Cell::new(0)),
            depth: 0,
            defs,
        }
    }
}

/// Resolve references to named windows into a complete definition.
fn resolve_spec(
    spec: &WindowSpec,
    defs: &[(String, WindowSpec)],
    depth: usize,
) -> Result<WindowSpec, String> {
    let Some(b) = &spec.base else {
        return Ok(spec.clone());
    };
    let def = defs
        .iter()
        .rev()
        .find(|(n, _)| fold(n) == fold(b))
        .filter(|_| depth < 16)
        .ok_or_else(|| format!("no such window: {}", b))?;
    let base = resolve_spec(&def.1, defs, depth + 1)?;
    if spec.bare {
        return Ok(base);
    }
    if !spec.partition.is_empty() {
        return Err(format!("cannot override PARTITION clause of window: {}", b));
    }
    if !spec.order.is_empty() && !base.order.is_empty() {
        return Err(format!("cannot override ORDER BY clause of window: {}", b));
    }
    if base.frame.is_some() {
        return Err(format!(
            "cannot override frame specification of window: {}",
            b
        ));
    }
    Ok(WindowSpec {
        base: None,
        bare: false,
        partition: base.partition,
        order: if spec.order.is_empty() {
            base.order
        } else {
            spec.order.clone()
        },
        frame: spec.frame.clone(),
    })
}

/// Bind a function call with an OVER clause.
pub(super) fn bind_window(e: &Expr, spec: &WindowSpec, scope: &Scope) -> Result<BExpr, String> {
    let Expr::Func {
        name,
        args,
        distinct,
        star,
        filter,
        order_by,
        ..
    } = e
    else {
        unreachable!()
    };
    let lname = fold(name);
    let wrong = || format!("wrong number of arguments to function {}()", name);
    let n = args.len();
    let pure = |lo: usize, hi: usize, f: WinFunc| -> Result<WinFunc, String> {
        if *star || n < lo || n > hi {
            return Err(wrong());
        }
        if filter.is_some() {
            return Err("FILTER clause may only be used with aggregate window functions".into());
        }
        if *distinct {
            return Err("DISTINCT is not supported for window functions".into());
        }
        Ok(f)
    };
    let func = match lname.as_str() {
        "row_number" => pure(0, 0, WinFunc::RowNumber)?,
        "rank" => pure(0, 0, WinFunc::Rank)?,
        "dense_rank" => pure(0, 0, WinFunc::DenseRank)?,
        "percent_rank" => pure(0, 0, WinFunc::PercentRank)?,
        "cume_dist" => pure(0, 0, WinFunc::CumeDist)?,
        "ntile" => pure(1, 1, WinFunc::Ntile)?,
        "lag" => pure(1, 3, WinFunc::Lag)?,
        "lead" => pure(1, 3, WinFunc::Lead)?,
        "first_value" => pure(1, 1, WinFunc::FirstValue)?,
        "last_value" => pure(1, 1, WinFunc::LastValue)?,
        "nth_value" => pure(2, 2, WinFunc::NthValue)?,
        _ => match AggKind::from_call(&lname, n, *star) {
            Some(kind) => {
                let (lo, hi) = kind.arg_range(&lname);
                if n < lo || n > hi || (*star && kind != AggKind::CountStar) {
                    return Err(wrong());
                }
                if *distinct {
                    return Err("DISTINCT is not supported for window functions".into());
                }
                if !order_by.is_empty() {
                    return Err(format!(
                        "ORDER BY may not be used with non-aggregate {}()",
                        name
                    ));
                }
                WinFunc::Agg(AggCall {
                    kind,
                    args: Vec::new(),
                    distinct: false,
                    coll: Coll::Binary,
                    filter: None,
                    order: Vec::new(),
                })
            }
            None => {
                let scalar = func::lookup(&lname).is_some()
                    || matches!(lname.as_str(), "coalesce" | "ifnull" | "iif" | "if");
                return Err(if scalar {
                    format!("{}() may not be used as a window function", name)
                } else {
                    format!("no such function: {}", name)
                });
            }
        },
    };
    let misuse = || format!("misuse of window function {}()", name);
    let rs = {
        let agg_busy = scope.agg.borrow().as_ref().is_some_and(|c| c.depth > 0);
        let mut w = scope.win.borrow_mut();
        match w.as_mut() {
            Some(c) if c.depth == 0 && !agg_busy => {
                let rs = resolve_spec(spec, &c.defs, 0)?;
                c.depth += 1;
                rs
            }
            _ => return Err(misuse()),
        }
    };
    let r = (|| -> Result<WinCall, String> {
        let bargs = bind_all(args, scope)?;
        let bfilter = match filter {
            Some(f) => Some(bind(f, scope)?),
            None => None,
        };
        let mut partition = Vec::new();
        for p in &rs.partition {
            let b = bind(p, scope)?;
            let c = check_coll(expr_coll(&b))?;
            partition.push((b, c));
        }
        let mut order = Vec::new();
        for t in &rs.order {
            let b = bind(&t.expr, scope)?;
            let c = check_coll(expr_coll(&b))?;
            order.push((b, t.desc, t.nulls_first, c));
        }
        let cscope = Scope {
            db: scope.db,
            ..Default::default()
        };
        let bound = |b: &FrameBound| -> Result<Bound, String> {
            Ok(match b {
                FrameBound::UnboundedPreceding => Bound::UnbPre,
                FrameBound::Preceding(e) => Bound::Pre(bind(e, &cscope)?),
                FrameBound::CurrentRow => Bound::Cur,
                FrameBound::Following(e) => Bound::Fol(bind(e, &cscope)?),
                FrameBound::UnboundedFollowing => Bound::UnbFol,
            })
        };
        let (unit, start, end, exclude) = match &rs.frame {
            None => (
                FrameUnit::Range,
                Bound::UnbPre,
                Bound::Cur,
                FrameExclude::NoOthers,
            ),
            Some(f) => (f.unit, bound(&f.start)?, bound(&f.end)?, f.exclude),
        };
        let (sr, er) = (start.rank(), end.rank());
        if sr == 4 || er == 0 || (sr == 2 && er == 1) || (sr == 3 && er <= 2) {
            return Err("unsupported frame specification".into());
        }
        if unit == FrameUnit::Range
            && (start.offset().is_some() || end.offset().is_some())
            && order.len() != 1
        {
            return Err(
                "RANGE with offset PRECEDING/FOLLOWING requires one ORDER BY expression".into(),
            );
        }
        let func = match func {
            WinFunc::Agg(mut a) => {
                a.coll = match bargs.first() {
                    Some(x) => check_coll(expr_coll(x))?,
                    None => Coll::Binary,
                };
                a.args = bargs.clone();
                WinFunc::Agg(a)
            }
            f => f,
        };
        let sort_key = format!("{:?}", (&partition, &order));
        Ok(WinCall {
            func,
            args: bargs,
            filter: bfilter,
            partition,
            order,
            unit,
            start,
            end,
            exclude,
            sort_key,
        })
    })();
    let mut w = scope.win.borrow_mut();
    let c = w.as_mut().unwrap();
    c.depth -= 1;
    let call = r?;
    c.calls.push(call);
    Ok(BExpr::Win(c.calls.len() - 1, c.base.clone()))
}

// ---------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------

fn cmp_list(a: &[Value], b: &[Value]) -> Ordering {
    for (x, y) in a.iter().zip(b) {
        let o = compare_values(x, y);
        if o != Ordering::Equal {
            return o;
        }
    }
    Ordering::Equal
}

fn cmp_order(a: &[Value], b: &[Value], order: &[WinOrder]) -> Ordering {
    for (i, (_, desc, nf, coll)) in order.iter().enumerate() {
        let o = agg::order_cmp(&a[i], &b[i], *desc, *nf, *coll);
        if o != Ordering::Equal {
            return o;
        }
    }
    Ordering::Equal
}

/// Compute every window function of a SELECT over its input rows. Each
/// row gets one extra value per call, starting at `base`. Calls sharing a
/// window order are computed together; like SQLite, the rows end up in the
/// order of the first window.
pub(super) fn compute(
    calls: &[WinCall],
    base: usize,
    envs: &mut Vec<Row>,
    cx: Cx,
) -> Result<(), String> {
    for r in envs.iter_mut() {
        r.resize(base + calls.len(), Value::Null);
    }
    let mut groups: Vec<(&str, Vec<usize>)> = Vec::new();
    for (i, c) in calls.iter().enumerate() {
        match groups.iter_mut().find(|g| g.0 == c.sort_key) {
            Some(g) => g.1.push(i),
            None => groups.push((&c.sort_key, vec![i])),
        }
    }
    for (_, members) in groups.iter().rev() {
        let spec = &calls[members[0]];
        let mut keyed = Vec::with_capacity(envs.len());
        for r in envs.drain(..) {
            let mut pk = Vec::with_capacity(spec.partition.len());
            for (e, c) in &spec.partition {
                pk.push(coll_key(&eval(e, &r, cx)?, *c));
            }
            let mut ok = Vec::with_capacity(spec.order.len());
            for (e, ..) in &spec.order {
                ok.push(eval(e, &r, cx)?);
            }
            keyed.push((pk, ok, r));
        }
        keyed.sort_by(|a, b| cmp_list(&a.0, &b.0).then_with(|| cmp_order(&a.1, &b.1, &spec.order)));
        let n = keyed.len();
        let mut pkeys = Vec::with_capacity(n);
        let mut okeys = Vec::with_capacity(n);
        let mut rows = Vec::with_capacity(n);
        for (p, o, r) in keyed {
            pkeys.push(p);
            okeys.push(o);
            rows.push(r);
        }
        let mut p0 = 0;
        while p0 < n {
            let mut p1 = p0 + 1;
            while p1 < n && cmp_list(&pkeys[p1], &pkeys[p0]) == Ordering::Equal {
                p1 += 1;
            }
            for &ci in members {
                partition_values(&calls[ci], &mut rows[p0..p1], &okeys[p0..p1], base + ci, cx)?;
            }
            p0 = p1;
        }
        *envs = rows;
    }
    Ok(())
}

/// Validate a frame offset.
fn frame_offset(e: &BExpr, unit: FrameUnit, start: bool, cx: Cx) -> Result<Value, String> {
    let v = eval(e, &[], cx)?;
    let which = if start { "starting" } else { "ending" };
    let n = match &v {
        Value::Text(s) => text_numeric_affinity(s, true).unwrap_or(Value::Null),
        Value::Blob(_) => Value::Null,
        x => x.clone(),
    };
    if unit == FrameUnit::Range {
        return match n {
            Value::Integer(k) if k >= 0 => Ok(Value::Integer(k)),
            Value::Real(r) if r >= 0.0 => Ok(Value::Real(r)),
            _ => Err(format!(
                "frame {} offset must be a non-negative number",
                which
            )),
        };
    }
    match n {
        Value::Integer(k) if k >= 0 => Ok(Value::Integer(k)),
        Value::Real(r) if r >= 0.0 && r.fract() == 0.0 && r < 9.2e18 => {
            Ok(Value::Integer(r as i64))
        }
        _ => Err(format!(
            "frame {} offset must be a non-negative integer",
            which
        )),
    }
}

/// A positive integer argument (nth_value's N).
fn positive_int(v: &Value) -> Option<i64> {
    let n = match v {
        Value::Text(s) => text_numeric_affinity(s, true)?,
        x => x.clone(),
    };
    match n {
        Value::Integer(k) if k > 0 => Some(k),
        Value::Real(r) if r > 0.0 && r.fract() == 0.0 && r < 9.2e18 => Some(r as i64),
        _ => None,
    }
}

/// Frame geometry of one partition.
struct Frames<'a> {
    call: &'a WinCall,
    n: usize,
    grp: Vec<usize>,
    gstart: Vec<usize>,
    gend: Vec<usize>,
    okeys: &'a [Vec<Value>],
    /// Rows whose (single) ORDER BY key is not NULL.
    nn: (usize, usize),
    desc: bool,
    start_off: Option<Value>,
    end_off: Option<Value>,
}

fn to_usize(v: &Value) -> usize {
    usize::try_from(v.to_i64()).unwrap_or(usize::MAX)
}

impl Frames<'_> {
    fn range_target(&self, i: usize, k: &Value, preceding: bool) -> Value {
        let sub = preceding != self.desc;
        arith(
            if sub { BinOp::Sub } else { BinOp::Add },
            &self.okeys[i][0],
            k,
        )
    }

    /// First row (within the non-NULL keys) at or after `target`.
    fn range_first(&self, target: &Value) -> usize {
        let (a, b) = self.nn;
        a + self.okeys[a..b].partition_point(|r| {
            let c = compare_values(&r[0], target);
            if self.desc {
                c == Ordering::Greater
            } else {
                c == Ordering::Less
            }
        })
    }

    /// First row (within the non-NULL keys) strictly after `target`.
    fn range_after(&self, target: &Value) -> usize {
        let (a, b) = self.nn;
        a + self.okeys[a..b].partition_point(|r| {
            let c = compare_values(&r[0], target);
            if self.desc {
                c != Ordering::Less
            } else {
                c != Ordering::Greater
            }
        })
    }

    /// Frame of row `i` as a half-open range [s, t) with s <= t.
    fn bounds(&self, i: usize) -> (usize, usize) {
        let n = self.n;
        let g = self.grp[i];
        let ng = self.gstart.len();
        let unit = self.call.unit;
        let null_key = || unit == FrameUnit::Range && self.okeys[i][0].is_null();
        let s = match &self.call.start {
            Bound::UnbPre => 0,
            Bound::Cur => {
                if unit == FrameUnit::Rows {
                    i
                } else {
                    self.gstart[g]
                }
            }
            Bound::Pre(_) | Bound::Fol(_) => {
                let k = self.start_off.as_ref().unwrap();
                let pre = matches!(self.call.start, Bound::Pre(_));
                match unit {
                    FrameUnit::Rows => {
                        let k = to_usize(k);
                        if pre {
                            i.saturating_sub(k)
                        } else {
                            i.saturating_add(k).min(n)
                        }
                    }
                    FrameUnit::Groups => {
                        let k = to_usize(k);
                        if pre {
                            if g >= k {
                                self.gstart[g - k]
                            } else {
                                0
                            }
                        } else if g.saturating_add(k) < ng {
                            self.gstart[g + k]
                        } else {
                            n
                        }
                    }
                    FrameUnit::Range => {
                        if null_key() {
                            self.gstart[g]
                        } else {
                            self.range_first(&self.range_target(i, k, pre))
                        }
                    }
                }
            }
            Bound::UnbFol => n,
        };
        let t = match &self.call.end {
            Bound::UnbPre => 0,
            Bound::Cur => {
                if unit == FrameUnit::Rows {
                    i + 1
                } else {
                    self.gend[g]
                }
            }
            Bound::Pre(_) | Bound::Fol(_) => {
                let k = self.end_off.as_ref().unwrap();
                let pre = matches!(self.call.end, Bound::Pre(_));
                match unit {
                    FrameUnit::Rows => {
                        let k = to_usize(k);
                        if pre {
                            (i + 1).saturating_sub(k)
                        } else {
                            i.saturating_add(k).saturating_add(1).min(n)
                        }
                    }
                    FrameUnit::Groups => {
                        let k = to_usize(k);
                        if pre {
                            if g >= k {
                                self.gend[g - k]
                            } else {
                                0
                            }
                        } else {
                            self.gend[g.saturating_add(k).min(ng - 1)]
                        }
                    }
                    FrameUnit::Range => {
                        if null_key() {
                            self.gend[g]
                        } else {
                            self.range_after(&self.range_target(i, k, pre))
                        }
                    }
                }
            }
            Bound::UnbFol => n,
        };
        (s, t.max(s))
    }

    /// Rows of the frame [s, t) of row `i` after EXCLUDE, as ordered
    /// contiguous segments.
    fn segments(&self, i: usize, s: usize, t: usize) -> Vec<(usize, usize)> {
        let g = self.grp[i];
        let (a, b, keep) = match self.call.exclude {
            FrameExclude::NoOthers => return if s < t { vec![(s, t)] } else { Vec::new() },
            FrameExclude::CurrentRow => (i, i + 1, false),
            FrameExclude::Group => (self.gstart[g], self.gend[g], false),
            FrameExclude::Ties => (self.gstart[g], self.gend[g], true),
        };
        let a = a.clamp(s, t);
        let b = b.clamp(s, t);
        let mut v = vec![(s, a)];
        if keep && a <= i && i < b {
            v.push((i, i + 1));
        }
        v.push((b, t));
        v.retain(|(x, y)| x < y);
        v
    }
}

/// Compute one window function over one partition (rows in window order)
/// and store the results at `slot`.
fn partition_values(
    call: &WinCall,
    rows: &mut [Row],
    okeys: &[Vec<Value>],
    slot: usize,
    cx: Cx,
) -> Result<(), String> {
    let n = rows.len();
    let mut grp = vec![0; n];
    let mut gstart = Vec::new();
    let mut gend = Vec::new();
    for i in 0..n {
        if i == 0 || cmp_order(&okeys[i - 1], &okeys[i], &call.order) != Ordering::Equal {
            if i > 0 {
                gend.push(i);
            }
            gstart.push(i);
        }
        grp[i] = gstart.len() - 1;
    }
    gend.push(n);
    let mut out: Vec<Value> = Vec::with_capacity(n);
    match &call.func {
        WinFunc::RowNumber => out.extend((0..n).map(|i| Value::Integer(i as i64 + 1))),
        WinFunc::Rank => out.extend((0..n).map(|i| Value::Integer(gstart[grp[i]] as i64 + 1))),
        WinFunc::DenseRank => out.extend((0..n).map(|i| Value::Integer(grp[i] as i64 + 1))),
        WinFunc::PercentRank => out.extend((0..n).map(|i| {
            Value::Real(if n > 1 {
                gstart[grp[i]] as f64 / (n - 1) as f64
            } else {
                0.0
            })
        })),
        WinFunc::CumeDist => {
            out.extend((0..n).map(|i| Value::Real(gend[grp[i]] as f64 / n as f64)))
        }
        WinFunc::Ntile => {
            let np = eval(&call.args[0], &rows[0], cx)?.to_i64();
            if np <= 0 {
                return Err("argument of ntile must be a positive integer".into());
            }
            let total = n as i64;
            let size = total / np;
            for i in 0..n {
                let row = i as i64;
                out.push(Value::Integer(if size == 0 {
                    row + 1
                } else {
                    let large = total - np * size;
                    let small = large * (size + 1);
                    if row < small {
                        1 + row / (size + 1)
                    } else {
                        1 + large + (row - small) / size
                    }
                }));
            }
        }
        WinFunc::Lag | WinFunc::Lead => {
            let lag = matches!(call.func, WinFunc::Lag);
            let mut vals = Vec::with_capacity(n);
            for r in rows.iter() {
                vals.push(eval(&call.args[0], r, cx)?);
            }
            for (i, r) in rows.iter().enumerate() {
                let off = match call.args.get(1) {
                    Some(e) => match eval(e, r, cx)?.to_numeric() {
                        Value::Integer(k) => Some(k),
                        Value::Real(x) if x.fract() == 0.0 && x.abs() < 9.2e18 => Some(x as i64),
                        _ => None,
                    },
                    None => Some(1),
                };
                let target = off.and_then(|k| {
                    if lag {
                        (i as i64).checked_sub(k)
                    } else {
                        (i as i64).checked_add(k)
                    }
                });
                match target {
                    Some(t) if t >= 0 && (t as usize) < n => out.push(vals[t as usize].clone()),
                    _ => out.push(match call.args.get(2) {
                        Some(e) => eval(e, r, cx)?,
                        None => Value::Null,
                    }),
                }
            }
        }
        _ => {
            let eval_off = |b: &Bound, start: bool| -> Result<Option<Value>, String> {
                match b.offset() {
                    Some(e) => Ok(Some(frame_offset(e, call.unit, start, cx)?)),
                    None => Ok(None),
                }
            };
            let (nn, desc) = if call.unit == FrameUnit::Range && call.order.len() == 1 {
                let a = okeys.iter().position(|k| !k[0].is_null()).unwrap_or(n);
                let b = okeys
                    .iter()
                    .rposition(|k| !k[0].is_null())
                    .map_or(a, |x| x + 1);
                ((a, b), call.order[0].1)
            } else {
                ((0, n), false)
            };
            let fr = Frames {
                call,
                n,
                grp,
                gstart,
                gend,
                okeys,
                nn,
                desc,
                start_off: eval_off(&call.start, true)?,
                end_off: eval_off(&call.end, false)?,
            };
            frame_values(call, &fr, rows, &mut out, cx)?;
        }
    }
    for (r, v) in rows.iter_mut().zip(out) {
        r[slot] = v;
    }
    Ok(())
}

/// Values of frame-based functions (first/last/nth_value, aggregates).
fn frame_values(
    call: &WinCall,
    fr: &Frames,
    rows: &[Row],
    out: &mut Vec<Value>,
    cx: Cx,
) -> Result<(), String> {
    let n = rows.len();
    let a = match &call.func {
        WinFunc::Agg(a) => a,
        _ => {
            let mut vals = Vec::with_capacity(n);
            for r in rows {
                vals.push(eval(&call.args[0], r, cx)?);
            }
            for i in 0..n {
                let (s, t) = fr.bounds(i);
                let segs = fr.segments(i, s, t);
                let pick = match call.func {
                    WinFunc::FirstValue => segs.first().map(|x| x.0),
                    WinFunc::LastValue => segs.last().map(|x| x.1 - 1),
                    _ => {
                        let v = eval(&call.args[1], &rows[i], cx)?;
                        let Some(k) = positive_int(&v) else {
                            return Err(
                                "second argument to nth_value must be a positive integer".into()
                            );
                        };
                        let mut k = (k - 1) as u64;
                        let mut found = None;
                        for (x, y) in &segs {
                            let len = (y - x) as u64;
                            if k < len {
                                found = Some(x + k as usize);
                                break;
                            }
                            k -= len;
                        }
                        found
                    }
                };
                out.push(pick.map_or(Value::Null, |j| vals[j].clone()));
            }
            return Ok(());
        }
    };
    let mut argv = Vec::with_capacity(n);
    let mut pass = Vec::with_capacity(n);
    for r in rows {
        let mut v = Vec::with_capacity(call.args.len());
        for e in &call.args {
            v.push(eval(e, r, cx)?);
        }
        argv.push(v);
        pass.push(match &call.filter {
            Some(f) => eval(f, r, cx)?.truthy() == Some(true),
            None => true,
        });
    }
    let inv = a.has_inverse();
    let add = |st: &mut agg::AggState, lo: usize, hi: usize| {
        for j in lo..hi {
            if pass[j] {
                a.win_step(st, &argv[j]);
            }
        }
    };
    let remove = |st: &mut agg::AggState, lo: usize, hi: usize| {
        for j in lo..hi {
            if pass[j] {
                a.win_inverse(st, &argv[j]);
            }
        }
    };
    let mut st = a.new_state();
    let (mut cs, mut ct) = (0usize, 0usize);
    for i in 0..n {
        let (s, t) = fr.bounds(i);
        if inv {
            if s >= ct || s < cs || t < ct {
                st = a.new_state();
                add(&mut st, s, t);
            } else {
                remove(&mut st, cs, s);
                add(&mut st, ct, t);
            }
        } else if s == cs && t >= ct {
            add(&mut st, ct, t);
        } else {
            st = a.new_state();
            add(&mut st, s, t);
        }
        cs = s;
        ct = t;
        let segs = fr.segments(i, s, t);
        let whole = (segs.len() == 1 && segs[0] == (s, t)) || s == t;
        if whole {
            out.push(a.win_value(&mut st)?);
        } else if inv {
            let mut st2 = st.clone();
            let mut prev = s;
            for &(x, y) in &segs {
                remove(&mut st2, prev, x);
                prev = y;
            }
            remove(&mut st2, prev, t);
            out.push(a.win_value(&mut st2)?);
        } else {
            let mut st2 = a.new_state();
            for &(x, y) in &segs {
                add(&mut st2, x, y);
            }
            out.push(a.win_value(&mut st2)?);
        }
    }
    Ok(())
}
