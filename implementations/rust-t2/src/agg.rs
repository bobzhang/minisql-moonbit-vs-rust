// Aggregate functions: accumulators and per-group evaluation.

use std::cmp::Ordering;
use std::collections::BTreeSet;

use crate::engine::{coll_key, eval, BExpr, Cx, IdxKey};
use crate::value::*;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum AggKind {
    CountStar,
    Count,
    Sum,
    Total,
    Avg,
    Min,
    Max,
    GroupConcat,
}

impl AggKind {
    /// Classify an aggregate call by name and argument count; None if the
    /// call is not an aggregate.
    pub fn from_call(name: &str, nargs: usize, star: bool) -> Option<AggKind> {
        Some(match name {
            "count" if star || nargs == 0 => AggKind::CountStar,
            "count" => AggKind::Count,
            "sum" => AggKind::Sum,
            "total" => AggKind::Total,
            "avg" => AggKind::Avg,
            "min" if nargs <= 1 => AggKind::Min,
            "max" if nargs <= 1 => AggKind::Max,
            "group_concat" | "string_agg" => AggKind::GroupConcat,
            _ => return None,
        })
    }

    /// Allowed argument counts (min, max).
    pub fn arg_range(self, name: &str) -> (usize, usize) {
        match self {
            AggKind::CountStar => (0, 0),
            AggKind::GroupConcat if name == "string_agg" => (2, 2),
            AggKind::GroupConcat => (1, 2),
            _ => (1, 1),
        }
    }

    fn is_minmax(self) -> bool {
        matches!(self, AggKind::Min | AggKind::Max)
    }
}

/// One ORDER BY term: expression, DESC, NULLS FIRST/LAST, collation.
pub type OrderSpec = (BExpr, bool, Option<bool>, Coll);

#[derive(Debug, Clone)]
pub struct AggCall {
    pub kind: AggKind,
    pub args: Vec<BExpr>,
    pub distinct: bool,
    pub coll: Coll,
    pub filter: Option<BExpr>,
    pub order: Vec<OrderSpec>,
}

/// Compare two sort-key values under one ORDER BY term.
pub fn order_cmp(
    x: &Value,
    y: &Value,
    desc: bool,
    nulls_first: Option<bool>,
    coll: Coll,
) -> Ordering {
    match (x.is_null(), y.is_null(), nulls_first) {
        (true, false, Some(nf)) => {
            if nf {
                Ordering::Less
            } else {
                Ordering::Greater
            }
        }
        (false, true, Some(nf)) => {
            if nf {
                Ordering::Greater
            } else {
                Ordering::Less
            }
        }
        _ => {
            let o = compare_values_coll(x, y, coll);
            if desc {
                o.reverse()
            } else {
                o
            }
        }
    }
}

#[derive(Debug, Default, Clone)]
struct SumCtx {
    cnt: i64,
    isum: i64,
    rsum: f64,
    rerr: f64,
    approx: bool,
    ovrfl: bool,
}

const BIG: i64 = 4503599627370496;

impl SumCtx {
    /// Kahan-Babuska-Neumaier summation step.
    fn kbn(&mut self, r: f64) {
        let s = self.rsum;
        let t = s + r;
        if s.abs() > r.abs() {
            self.rerr += (s - t) + r;
        } else {
            self.rerr += (r - t) + s;
        }
        self.rsum = t;
    }

    fn kbn_int(&mut self, v: i64) {
        if v <= -BIG || v >= BIG {
            let sm = v % 16384;
            self.kbn((v - sm) as f64);
            self.kbn(sm as f64);
        } else {
            self.kbn(v as f64);
        }
    }

    fn init(&mut self, v: i64) {
        if v <= -BIG || v >= BIG {
            let sm = v % 16384;
            self.rsum = (v - sm) as f64;
            self.rerr = sm as f64;
        } else {
            self.rsum = v as f64;
            self.rerr = 0.0;
        }
    }

    fn step(&mut self, v: &Value) {
        let nv = match v {
            Value::Null => return,
            Value::Integer(i) => Value::Integer(*i),
            Value::Real(r) => Value::Real(*r),
            Value::Text(s) => text_numeric_affinity(s, false).unwrap_or(Value::Real(v.to_f64())),
            Value::Blob(_) => Value::Real(v.to_f64()),
        };
        self.cnt += 1;
        match nv {
            Value::Integer(i) => {
                if !self.approx {
                    match self.isum.checked_add(i) {
                        Some(x) => self.isum = x,
                        None => {
                            self.ovrfl = true;
                            self.init(self.isum);
                            self.approx = true;
                            self.kbn_int(i);
                        }
                    }
                } else {
                    self.kbn_int(i);
                }
            }
            Value::Real(r) => {
                if !self.approx {
                    self.init(self.isum);
                    self.approx = true;
                } else {
                    self.ovrfl = false;
                }
                self.kbn(r);
            }
            _ => unreachable!(),
        }
    }

    /// Remove a value added by `step` (window frames; sumInverse).
    fn inverse(&mut self, v: &Value) {
        let nv = match v {
            Value::Null => return,
            Value::Integer(i) => Value::Integer(*i),
            Value::Real(r) => Value::Real(*r),
            Value::Text(s) => text_numeric_affinity(s, false).unwrap_or(Value::Real(v.to_f64())),
            Value::Blob(_) => Value::Real(v.to_f64()),
        };
        self.cnt -= 1;
        if !self.approx {
            match self.isum.checked_sub(nv.to_i64()) {
                Some(x) => self.isum = x,
                None => {
                    self.ovrfl = true;
                    self.approx = true;
                }
            }
        } else if let Value::Integer(i) = nv {
            if i != i64::MIN {
                self.kbn_int(-i);
            } else {
                self.kbn_int(i64::MAX);
                self.kbn_int(1);
            }
        } else {
            self.kbn(-nv.to_f64());
        }
    }

    fn real_value(&self) -> f64 {
        if self.approx {
            if self.rerr.is_finite() {
                self.rsum + self.rerr
            } else {
                self.rsum
            }
        } else {
            self.isum as f64
        }
    }
}

#[derive(Debug, Clone)]
enum Acc {
    Count(i64),
    Sum(SumCtx),
    MinMax(Option<Value>),
    Concat(Option<String>),
}

#[derive(Debug, Clone)]
pub struct AggState {
    acc: Acc,
    seen: BTreeSet<IdxKey>,
    /// Buffered (arguments, sort keys) for aggregates with ORDER BY.
    buf: Vec<(Vec<Value>, Vec<Value>)>,
}

impl AggCall {
    pub fn new_state(&self) -> AggState {
        let acc = match self.kind {
            AggKind::CountStar | AggKind::Count => Acc::Count(0),
            AggKind::Sum | AggKind::Total | AggKind::Avg => Acc::Sum(SumCtx::default()),
            AggKind::Min | AggKind::Max => Acc::MinMax(None),
            AggKind::GroupConcat => Acc::Concat(None),
        };
        AggState {
            acc,
            seen: BTreeSet::new(),
            buf: Vec::new(),
        }
    }

    /// Feed one set of argument values. For min/max, returns whether the
    /// row should become the source of bare columns.
    fn feed(&self, st: &mut AggState, args: &[Value]) -> bool {
        if self.distinct && !st.seen.insert(IdxKey(vec![coll_key(&args[0], self.coll)])) {
            return false;
        }
        match &mut st.acc {
            Acc::Count(n) => {
                if self.kind == AggKind::CountStar || !args[0].is_null() {
                    *n += 1;
                }
                false
            }
            Acc::Sum(s) => {
                s.step(&args[0]);
                false
            }
            Acc::MinMax(best) => {
                let v = &args[0];
                match best {
                    None => {
                        if !v.is_null() {
                            *best = Some(v.clone());
                        }
                        true
                    }
                    Some(b) => {
                        if v.is_null() {
                            return false;
                        }
                        let c = compare_values_coll(b, v, self.coll);
                        let better = if self.kind == AggKind::Max {
                            c == Ordering::Less
                        } else {
                            c == Ordering::Greater
                        };
                        if better {
                            *best = Some(v.clone());
                        }
                        better
                    }
                }
            }
            Acc::Concat(s) => {
                let Some(t) = args[0].to_text() else {
                    return false;
                };
                match s {
                    None => *s = Some(t),
                    Some(acc) => {
                        match args.get(1) {
                            Some(sep) => acc.push_str(&sep.to_text().unwrap_or_default()),
                            None => acc.push(','),
                        }
                        acc.push_str(&t);
                    }
                }
                false
            }
        }
    }

    fn finish(&self, st: &mut AggState) -> Result<Value, String> {
        if !st.buf.is_empty() {
            let mut buf = std::mem::take(&mut st.buf);
            buf.sort_by(|a, b| {
                for (i, (_, desc, nf, coll)) in self.order.iter().enumerate() {
                    let o = order_cmp(&a.1[i], &b.1[i], *desc, *nf, *coll);
                    if o != Ordering::Equal {
                        return o;
                    }
                }
                Ordering::Equal
            });
            for (args, _) in buf {
                self.feed(st, &args);
            }
        }
        Ok(match &st.acc {
            Acc::Count(n) => Value::Integer(*n),
            Acc::Sum(s) => match self.kind {
                AggKind::Total => Value::Real(s.real_value()),
                _ if s.cnt == 0 => Value::Null,
                AggKind::Avg => Value::Real(s.real_value() / s.cnt as f64),
                _ => {
                    if s.approx {
                        if s.ovrfl {
                            return Err("integer overflow".into());
                        }
                        Value::Real(s.real_value())
                    } else {
                        Value::Integer(s.isum)
                    }
                }
            },
            Acc::MinMax(b) => b.clone().unwrap_or(Value::Null),
            Acc::Concat(s) => s.clone().map(Value::Text).unwrap_or(Value::Null),
        })
    }
}

impl AggCall {
    /// Whether frame rows can be removed from the state (window use).
    pub fn has_inverse(&self) -> bool {
        matches!(
            self.kind,
            AggKind::CountStar | AggKind::Count | AggKind::Sum | AggKind::Total | AggKind::Avg
        )
    }

    pub fn win_step(&self, st: &mut AggState, args: &[Value]) {
        self.feed(st, args);
    }

    /// Remove one row's arguments (only if `has_inverse`).
    pub fn win_inverse(&self, st: &mut AggState, args: &[Value]) {
        match &mut st.acc {
            Acc::Count(n) => {
                if self.kind == AggKind::CountStar || !args[0].is_null() {
                    *n -= 1;
                }
            }
            Acc::Sum(s) => s.inverse(&args[0]),
            _ => {}
        }
    }

    /// Current value of the aggregate.
    pub fn win_value(&self, st: &mut AggState) -> Result<Value, String> {
        self.finish(st)
    }
}

/// Feed one input row to every aggregate of a group. Returns Some(load)
/// when the query has min()/max() aggregates: whether this row should
/// supply the bare columns.
pub fn step_row(
    calls: &[AggCall],
    states: &mut [AggState],
    row: &[Value],
    cx: Cx,
) -> Result<Option<bool>, String> {
    let mut load = None;
    for (c, st) in calls.iter().zip(states.iter_mut()) {
        let mm = c.kind.is_minmax();
        if let Some(f) = &c.filter {
            if eval(f, row, cx)?.truthy() != Some(true) {
                if mm {
                    load = Some(false);
                }
                continue;
            }
        }
        let mut args = Vec::with_capacity(c.args.len());
        for a in &c.args {
            args.push(eval(a, row, cx)?);
        }
        if !c.order.is_empty() && !mm {
            let mut keys = Vec::with_capacity(c.order.len());
            for (e, ..) in &c.order {
                keys.push(eval(e, row, cx)?);
            }
            st.buf.push((args, keys));
            continue;
        }
        let hit = c.feed(st, &args);
        if mm {
            load = Some(hit);
        }
    }
    Ok(load)
}

/// Final values of every aggregate of a group.
pub fn finish_all(calls: &[AggCall], states: &mut [AggState]) -> Result<Vec<Value>, String> {
    calls
        .iter()
        .zip(states.iter_mut())
        .map(|(c, st)| c.finish(st))
        .collect()
}
