// Aggregate functions: detection, AST rewriting and accumulator state.

use std::cell::RefCell;
use std::cmp::Ordering;
use std::collections::BTreeSet;

use crate::ast::{Expr, Frame, FrameBound, FuncCall, OrderTerm, WindowSpec};
use crate::db::{key_val, KeyVal};
use crate::eval::{eval, BExpr, Env};
use crate::value::{compare_coll, Coll, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AggKind {
    Count,
    CountStar,
    Sum,
    Total,
    Avg,
    Min,
    Max,
    GroupConcat,
}

/// Whether a call with this name and argument count is an aggregate.
pub fn is_agg_call(name: &str, nargs: usize) -> bool {
    let n = name.to_ascii_lowercase();
    match n.as_str() {
        "count" | "sum" | "total" | "avg" | "group_concat" | "string_agg" => true,
        "min" | "max" => nargs <= 1,
        _ => false,
    }
}

/// The aggregate kind of a call, checking the argument count.
pub fn agg_kind(fc: &FuncCall) -> Result<AggKind, String> {
    let n = fc.name.to_ascii_lowercase();
    let nargs = fc.args.len();
    let (kind, ok) = match n.as_str() {
        "count" => {
            if fc.star || nargs == 0 {
                (AggKind::CountStar, true)
            } else {
                (AggKind::Count, nargs == 1)
            }
        }
        "sum" => (AggKind::Sum, nargs == 1),
        "total" => (AggKind::Total, nargs == 1),
        "avg" => (AggKind::Avg, nargs == 1),
        "min" => (AggKind::Min, nargs == 1),
        "max" => (AggKind::Max, nargs == 1),
        "group_concat" => (AggKind::GroupConcat, nargs == 1 || nargs == 2),
        "string_agg" => (AggKind::GroupConcat, nargs == 2),
        _ => return Err(format!("no such function: {}", fc.name)),
    };
    if !ok || (fc.star && kind != AggKind::CountStar) {
        return Err(format!("wrong number of arguments to function {}()", fc.name));
    }
    if fc.distinct && nargs != 1 {
        return Err("DISTINCT aggregates must have exactly one argument".to_string());
    }
    Ok(kind)
}

/// Rebuilds an expression, letting `f` replace any subexpression (pre-order).
pub fn map_expr(e: &Expr, f: &mut dyn FnMut(&Expr) -> Result<Option<Expr>, String>) -> Result<Expr, String> {
    if let Some(r) = f(e)? {
        return Ok(r);
    }
    let mut m = |x: &Expr| map_expr(x, f);
    Ok(match e {
        Expr::Literal(_)
        | Expr::Column { .. }
        | Expr::AggRef(_)
        | Expr::WinRef(_)
        | Expr::SourceCol { .. }
        | Expr::Subquery(_)
        | Expr::Exists(_) => e.clone(),
        Expr::InSelect { e, query, not } => Expr::InSelect { e: Box::new(m(e)?), query: query.clone(), not: *not },
        Expr::Unary(op, x) => Expr::Unary(*op, Box::new(m(x)?)),
        Expr::Binary(op, l, r) => Expr::Binary(*op, Box::new(m(l)?), Box::new(m(r)?)),
        Expr::IsNull(x, n) => Expr::IsNull(Box::new(m(x)?), *n),
        Expr::Function(fc) => {
            let mut args = Vec::with_capacity(fc.args.len());
            for a in &fc.args {
                args.push(m(a)?);
            }
            let mut order_by = Vec::with_capacity(fc.order_by.len());
            for t in &fc.order_by {
                order_by.push(OrderTerm { expr: m(&t.expr)?, desc: t.desc, nulls_first: t.nulls_first });
            }
            let filter = match &fc.filter {
                Some(x) => Some(m(x)?),
                None => None,
            };
            let over = match &fc.over {
                Some(w) => Some(Box::new(map_window(w, f)?)),
                None => None,
            };
            Expr::Function(Box::new(FuncCall {
                name: fc.name.clone(),
                args,
                star: fc.star,
                distinct: fc.distinct,
                order_by,
                filter,
                over,
            }))
        }
        Expr::Case { base, whens, else_ } => {
            let base = match base {
                Some(b) => Some(Box::new(m(b)?)),
                None => None,
            };
            let mut ws = Vec::with_capacity(whens.len());
            for (w, t) in whens {
                ws.push((m(w)?, m(t)?));
            }
            let else_ = match else_ {
                Some(x) => Some(Box::new(m(x)?)),
                None => None,
            };
            Expr::Case { base, whens: ws, else_ }
        }
        Expr::Cast(x, t) => Expr::Cast(Box::new(m(x)?), t.clone()),
        Expr::Collate(x, c) => Expr::Collate(Box::new(m(x)?), c.clone()),
        Expr::Between { e, lo, hi, not } => {
            Expr::Between { e: Box::new(m(e)?), lo: Box::new(m(lo)?), hi: Box::new(m(hi)?), not: *not }
        }
        Expr::InList { e, list, not } => {
            let mut l = Vec::with_capacity(list.len());
            for x in list {
                l.push(m(x)?);
            }
            Expr::InList { e: Box::new(m(e)?), list: l, not: *not }
        }
        Expr::Like { op, e, pattern, escape, not } => Expr::Like {
            op: op.clone(),
            e: Box::new(m(e)?),
            pattern: Box::new(m(pattern)?),
            escape: match escape {
                Some(x) => Some(Box::new(m(x)?)),
                None => None,
            },
            not: *not,
        },
    })
}

/// Rebuilds the expressions of a window definition with `map_expr`.
pub fn map_window(w: &WindowSpec, f: &mut dyn FnMut(&Expr) -> Result<Option<Expr>, String>) -> Result<WindowSpec, String> {
    let mut partition = Vec::with_capacity(w.partition.len());
    for e in &w.partition {
        partition.push(map_expr(e, f)?);
    }
    let mut order = Vec::with_capacity(w.order.len());
    for t in &w.order {
        order.push(OrderTerm { expr: map_expr(&t.expr, f)?, desc: t.desc, nulls_first: t.nulls_first });
    }
    let frame = match &w.frame {
        Some(fr) => {
            let mut bound = |b: &FrameBound| -> Result<FrameBound, String> {
                Ok(match b {
                    FrameBound::Preceding(e) => FrameBound::Preceding(Box::new(map_expr(e, f)?)),
                    FrameBound::Following(e) => FrameBound::Following(Box::new(map_expr(e, f)?)),
                    other => other.clone(),
                })
            };
            let start = bound(&fr.start)?;
            let end = bound(&fr.end)?;
            Some(Frame { unit: fr.unit, start, end, exclude: fr.exclude })
        }
        None => None,
    };
    Ok(WindowSpec { base: w.base.clone(), paren: w.paren, partition, order, frame })
}

/// Whether the expression contains a window function call (outside
/// subqueries).
pub fn contains_window(e: &Expr) -> bool {
    let mut found = false;
    let _ = map_expr(e, &mut |x| {
        if let Expr::Function(fc) = x {
            if fc.over.is_some() {
                found = true;
                return Ok(Some(x.clone()));
            }
        }
        Ok(None)
    });
    found
}

/// Whether the expression contains an aggregate call of the current query
/// (`is_local` tells whether a call belongs to it).
pub fn contains_agg(e: &Expr, is_local: &dyn Fn(&FuncCall) -> bool) -> bool {
    let mut found = false;
    let _ = map_expr(e, &mut |x| {
        if let Expr::Function(fc) = x {
            if fc.over.is_none() && is_agg_call(&fc.name, fc.args.len()) && is_local(fc) {
                found = true;
                return Ok(Some(x.clone()));
            }
        }
        Ok(None)
    });
    found
}

/// Replaces aggregate calls of the current query with `AggRef`s,
/// collecting the calls.
pub fn extract(e: &Expr, aggs: &RefCell<Vec<FuncCall>>, is_local: &dyn Fn(&FuncCall) -> bool) -> Result<Expr, String> {
    map_expr(e, &mut |x| {
        if let Expr::Function(fc) = x {
            if fc.over.is_none() && is_agg_call(&fc.name, fc.args.len()) && is_local(fc) {
                agg_kind(fc)?;
                let mut aggs = aggs.borrow_mut();
                aggs.push((**fc).clone());
                return Ok(Some(Expr::AggRef(aggs.len() - 1)));
            }
        }
        Ok(None)
    })
}

/// A bound aggregate call.
#[derive(Debug)]
pub struct AggSpec {
    pub kind: AggKind,
    pub args: Vec<BExpr>,
    pub distinct: bool,
    pub filter: Option<BExpr>,
    /// ORDER BY terms: expression, descending, nulls first, collation.
    pub order: Vec<(BExpr, bool, bool, Coll)>,
    /// Collation for comparisons (min/max, DISTINCT).
    pub coll: Coll,
}

impl AggSpec {
    pub fn is_minmax(&self) -> bool {
        matches!(self.kind, AggKind::Min | AggKind::Max)
    }
}

#[derive(Default)]
pub struct AggState {
    count: i64,
    isum: i64,
    rsum: f64,
    rerr: f64,
    approx: bool,
    ovrfl: bool,
    best: Option<Value>,
    text: Option<String>,
    seen: BTreeSet<KeyVal>,
    buffered: Vec<(Vec<Value>, Vec<Value>)>,
}

const BIG: i64 = 4503599627370496;

impl AggState {
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

    fn kbn_init(&mut self, v: i64) {
        if v <= -BIG || v >= BIG {
            let sm = v % 16384;
            self.rsum = (v - sm) as f64;
            self.rerr = sm as f64;
        } else {
            self.rsum = v as f64;
            self.rerr = 0.0;
        }
    }

    fn sum_step(&mut self, v: &Value) {
        let v = v.numeric();
        if v.is_null() {
            return;
        }
        self.count += 1;
        let int = match v {
            Value::Integer(i) => Some(i),
            _ => None,
        };
        if !self.approx {
            match int {
                Some(i) => match self.isum.checked_add(i) {
                    Some(x) => self.isum = x,
                    None => {
                        self.ovrfl = true;
                        self.kbn_init(self.isum);
                        self.approx = true;
                        self.kbn_int(i);
                    }
                },
                None => {
                    self.kbn_init(self.isum);
                    self.approx = true;
                    self.kbn(v.to_real());
                }
            }
        } else {
            match int {
                Some(i) => self.kbn_int(i),
                None => {
                    self.ovrfl = false;
                    self.kbn(v.to_real());
                }
            }
        }
    }

    fn approx_value(&self) -> f64 {
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

    /// Feeds one row of argument values. Returns true if a min()/max()
    /// did not take this row as its new extreme.
    pub fn step(&mut self, spec: &AggSpec, args: &[Value]) -> bool {
        if spec.distinct {
            if args[0].is_null() {
                return false;
            }
            if !self.seen.insert(key_val(&args[0], spec.coll)) {
                return false;
            }
        }
        match spec.kind {
            AggKind::CountStar => self.count += 1,
            AggKind::Count => {
                if !args[0].is_null() {
                    self.count += 1;
                }
            }
            AggKind::Sum | AggKind::Total | AggKind::Avg => self.sum_step(&args[0]),
            AggKind::Min | AggKind::Max => {
                let v = &args[0];
                match &self.best {
                    None => {
                        if !v.is_null() {
                            self.best = Some(v.clone());
                        }
                    }
                    Some(b) => {
                        if v.is_null() {
                            return true;
                        }
                        let c = compare_coll(b, v, spec.coll);
                        let better = if spec.kind == AggKind::Max { c == Ordering::Less } else { c == Ordering::Greater };
                        if better {
                            self.best = Some(v.clone());
                        } else {
                            return true;
                        }
                    }
                }
            }
            AggKind::GroupConcat => {
                let v = &args[0];
                if v.is_null() {
                    return false;
                }
                let s = text_of(v);
                match &mut self.text {
                    None => self.text = Some(s),
                    Some(t) => {
                        if args.len() > 1 {
                            if !args[1].is_null() {
                                t.push_str(&text_of(&args[1]));
                            }
                        } else {
                            t.push(',');
                        }
                        t.push_str(&s);
                    }
                }
            }
        }
        false
    }

    /// Whether rows can be removed with `inverse`.
    pub fn has_inverse(kind: AggKind) -> bool {
        matches!(kind, AggKind::Count | AggKind::CountStar | AggKind::Sum | AggKind::Total | AggKind::Avg)
    }

    /// Removes a row fed earlier by `step` (window frames).
    pub fn inverse(&mut self, spec: &AggSpec, args: &[Value]) {
        match spec.kind {
            AggKind::CountStar => self.count -= 1,
            AggKind::Count => {
                if !args[0].is_null() {
                    self.count -= 1;
                }
            }
            AggKind::Sum | AggKind::Total | AggKind::Avg => {
                let v = args[0].numeric();
                if v.is_null() {
                    return;
                }
                self.count -= 1;
                if !self.approx {
                    match self.isum.checked_sub(v.to_int()) {
                        Some(x) => self.isum = x,
                        None => {
                            self.ovrfl = true;
                            self.approx = true;
                        }
                    }
                } else if let Value::Integer(i) = v {
                    if i != i64::MIN {
                        self.kbn_int(-i);
                    } else {
                        self.kbn_int(i64::MAX);
                        self.kbn_int(1);
                    }
                } else {
                    self.kbn(-v.to_real());
                }
            }
            _ => {}
        }
    }

    pub fn result(&self, spec: &AggSpec) -> Result<Value, String> {
        Ok(match spec.kind {
            AggKind::Count | AggKind::CountStar => Value::Integer(self.count),
            AggKind::Sum => {
                if self.count == 0 {
                    Value::Null
                } else if self.approx {
                    if self.ovrfl {
                        return Err("integer overflow".to_string());
                    }
                    Value::Real(self.approx_value())
                } else {
                    Value::Integer(self.isum)
                }
            }
            AggKind::Total => Value::Real(self.approx_value()),
            AggKind::Avg => {
                if self.count == 0 {
                    Value::Null
                } else {
                    Value::Real(self.approx_value() / self.count as f64)
                }
            }
            AggKind::Min | AggKind::Max => self.best.clone().unwrap_or(Value::Null),
            AggKind::GroupConcat => match &self.text {
                Some(t) => Value::Text(t.clone()),
                None => Value::Null,
            },
        })
    }
}

fn text_of(v: &Value) -> String {
    match v {
        Value::Blob(b) => String::from_utf8_lossy(b).into_owned(),
        _ => v.to_text().unwrap_or_default(),
    }
}

/// Compares two sort-key rows under ORDER BY terms (desc, nulls first, collation).
pub fn cmp_order(a: &[Value], b: &[Value], terms: &[(bool, bool, Coll)]) -> Ordering {
    for (i, &(desc, nulls_first, coll)) in terms.iter().enumerate() {
        let (x, y) = (&a[i], &b[i]);
        let o = match (x.is_null(), y.is_null()) {
            (true, true) => Ordering::Equal,
            (true, false) => {
                if nulls_first {
                    Ordering::Less
                } else {
                    Ordering::Greater
                }
            }
            (false, true) => {
                if nulls_first {
                    Ordering::Greater
                } else {
                    Ordering::Less
                }
            }
            (false, false) => {
                let o = compare_coll(x, y, coll);
                if desc {
                    o.reverse()
                } else {
                    o
                }
            }
        };
        if o != Ordering::Equal {
            return o;
        }
    }
    Ordering::Equal
}

/// Accumulators for one group.
pub struct Group {
    pub rep: Option<Vec<Value>>,
    rows: u64,
    hit: bool,
    states: Vec<AggState>,
}

impl Group {
    pub fn new(n: usize) -> Group {
        Group { rep: None, rows: 0, hit: false, states: (0..n).map(|_| AggState::default()).collect() }
    }

    /// Feeds a source row to every aggregate and updates the row that bare
    /// columns are read from (SQLite's min/max "magnet" rule: the first row
    /// of the group, or the row that set the last min()/max()).
    pub fn step(&mut self, specs: &[AggSpec], row: &[Value], env: &Env) -> Result<(), String> {
        let first = self.rows == 0;
        self.rows += 1;
        let streamed_minmax = |s: &AggSpec| s.is_minmax() && s.order.is_empty();
        let magnet = specs.iter().any(streamed_minmax);
        let unfiltered_minmax = specs.iter().any(|s| streamed_minmax(s) && s.filter.is_none());
        let mut hit = self.hit;
        for (spec, st) in specs.iter().zip(self.states.iter_mut()) {
            if let Some(f) = &spec.filter {
                if streamed_minmax(spec) && !unfiltered_minmax {
                    hit = !first;
                }
                if eval(f, row, env)?.truth() != Some(true) {
                    continue;
                }
            }
            let mut args = Vec::with_capacity(spec.args.len());
            for a in &spec.args {
                args.push(eval(a, row, env)?);
            }
            if !spec.order.is_empty() {
                let mut keys = Vec::with_capacity(spec.order.len());
                for (e, ..) in &spec.order {
                    keys.push(eval(e, row, env)?);
                }
                st.buffered.push((keys, args));
                continue;
            }
            if streamed_minmax(spec) {
                if spec.distinct && !args[0].is_null() && st.seen.contains(&key_val(&args[0], spec.coll)) {
                    continue;
                }
                hit = st.step(spec, &args);
            } else {
                st.step(spec, &args);
            }
        }
        self.hit = hit;
        let load = if magnet { !hit } else { first };
        if load {
            self.rep = Some(row.to_vec());
        }
        Ok(())
    }

    /// Final values of all aggregates.
    pub fn finish(&mut self, specs: &[AggSpec]) -> Result<Vec<Value>, String> {
        let mut out = Vec::with_capacity(specs.len());
        for (spec, st) in specs.iter().zip(self.states.iter_mut()) {
            if !spec.order.is_empty() {
                let mut buf = std::mem::take(&mut st.buffered);
                let terms: Vec<(bool, bool, Coll)> = spec.order.iter().map(|(_, d, n, c)| (*d, *n, *c)).collect();
                buf.sort_by(|a, b| cmp_order(&a.0, &b.0, &terms));
                for (_, args) in &buf {
                    st.step(spec, args);
                }
            }
            out.push(st.result(spec)?);
        }
        Ok(out)
    }
}
