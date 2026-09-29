// Aggregate functions: extraction from bound expressions and accumulators.

use std::cmp::Ordering;
use std::collections::BTreeSet;

use crate::ast::Expr;
use crate::db::{normalize, IdxKey};
use crate::error::{err, Result};
use crate::eval::{eval, expr_collation, expr_parts, Cx};
use crate::func::is_aggregate;
use crate::value::{compare_coll, Collation, Value};

/// Sort specification of one ORDER BY key: (desc, nulls_first, collation).
pub type SortSpec = (bool, Option<bool>, Collation);

/// Compare two key tuples under SQLite's ORDER BY rules.
pub fn cmp_keys(a: &[Value], b: &[Value], spec: &[SortSpec]) -> Ordering {
    for (i, (desc, nulls_first, coll)) in spec.iter().enumerate() {
        let (x, y) = (&a[i], &b[i]);
        let c = match (x.is_null(), y.is_null(), nulls_first) {
            (true, true, _) => Ordering::Equal,
            (true, false, Some(nf)) => {
                if *nf {
                    Ordering::Less
                } else {
                    Ordering::Greater
                }
            }
            (false, true, Some(nf)) => {
                if *nf {
                    Ordering::Greater
                } else {
                    Ordering::Less
                }
            }
            _ => {
                let c = compare_coll(x, y, *coll);
                if *desc {
                    c.reverse()
                } else {
                    c
                }
            }
        };
        if c != Ordering::Equal {
            return c;
        }
    }
    Ordering::Equal
}

/// One aggregate call of a query.
#[derive(Debug)]
pub struct AggSpec {
    pub name: String,
    pub args: Vec<Expr>,
    pub star: bool,
    pub distinct: bool,
    /// Collation of the (first) argument.
    pub coll: Collation,
    pub filter: Option<Expr>,
    pub order_by: Vec<Expr>,
    pub order_spec: Vec<SortSpec>,
}

impl AggSpec {
    pub fn is_minmax(&self) -> bool {
        self.name == "min" || self.name == "max"
    }
}

/// Is `e` an aggregate function call (after binding)?
fn is_agg_call(e: &Expr) -> bool {
    matches!(e, Expr::Func { name, args, .. } if is_aggregate(name, args.len()))
}

/// Does the expression contain an aggregate call?
pub fn contains_agg(e: &Expr) -> bool {
    if is_agg_call(e) {
        return true;
    }
    let (l, r, list) = expr_parts(e);
    l.is_some_and(contains_agg) || r.is_some_and(contains_agg) || list.into_iter().any(contains_agg)
}

/// Apply `f` to each direct child of `e`.
pub fn for_each_child_mut(e: &mut Expr, f: &mut dyn FnMut(&mut Expr)) {
    match e {
        Expr::Lit(_)
        | Expr::Column { .. }
        | Expr::Col { .. }
        | Expr::AggRef { .. }
        | Expr::Outer { .. }
        | Expr::Subquery(_)
        | Expr::Exists(_) => {}
        Expr::InSelect { e, .. } => f(e),
        Expr::Window { func, over } => {
            f(func);
            if let crate::ast::Over::Spec(d) = over.as_mut() {
                for x in d.partition.iter_mut() {
                    f(x);
                }
                for t in d.order.iter_mut() {
                    f(&mut t.expr);
                }
            }
        }
        Expr::SubPlan { kind, .. } => {
            if let crate::ast::SubKind::In { e, .. } = kind {
                f(e);
            }
        }
        Expr::Unary(_, a) | Expr::IsNull(a, _) | Expr::Collate(a, _) | Expr::Cast(a, _) => f(a),
        Expr::Binary(_, a, b) | Expr::Compare { l: a, r: b, .. } => {
            f(a);
            f(b);
        }
        Expr::Func { args, filter, order_by, .. } => {
            for a in args {
                f(a);
            }
            if let Some(x) = filter {
                f(x);
            }
            for t in order_by {
                f(&mut t.expr);
            }
        }
        Expr::Case { base, whens, else_, .. } => {
            if let Some(b) = base {
                f(b);
            }
            for (w, t) in whens {
                f(w);
                f(t);
            }
            if let Some(x) = else_ {
                f(x);
            }
        }
        Expr::Between { e, lo, hi, .. } => {
            f(e);
            f(lo);
            f(hi);
        }
        Expr::InList { e, list, .. } => {
            f(e);
            for x in list {
                f(x);
            }
        }
        Expr::Like { e, pat, esc, .. } => {
            f(e);
            f(pat);
            if let Some(x) = esc {
                f(x);
            }
        }
    }
}

/// Collects the aggregate calls of a query, deduplicating identical ones.
#[derive(Default, Debug)]
pub struct AggCollector {
    pub specs: Vec<AggSpec>,
    keys: Vec<String>,
    /// Row index of the first aggregate result.
    pub base: usize,
}

impl AggCollector {
    pub fn new(base: usize) -> Self {
        AggCollector { specs: vec![], keys: vec![], base }
    }

    /// Add a bound aggregate call (deduplicated); returns the row index of
    /// its result.
    pub fn register(&mut self, e: Expr) -> usize {
        let key = format!("{:?}", e);
        if let Some(i) = self.keys.iter().position(|k| *k == key) {
            return self.base + i;
        }
        let Expr::Func { name, args, star, distinct, coll, filter, order_by } = e else { unreachable!() };
        let order_spec = order_by
            .iter()
            .map(|t| (t.desc, t.nulls_first, expr_collation(&t.expr).unwrap_or(Collation::Binary)))
            .collect();
        self.specs.push(AggSpec {
            name,
            args,
            star,
            distinct,
            coll,
            filter: filter.map(|f| *f),
            order_by: order_by.into_iter().map(|t| t.expr).collect(),
            order_spec,
        });
        self.keys.push(key);
        self.base + self.specs.len() - 1
    }

    /// Replace every aggregate call in `e` by an `AggRef`.
    pub fn extract(&mut self, e: &mut Expr) {
        if is_agg_call(e) {
            let key = format!("{:?}", e);
            let coll = expr_collation(e);
            let i = match self.keys.iter().position(|k| *k == key) {
                Some(i) => i,
                None => {
                    let old = std::mem::replace(e, Expr::Lit(Value::Null));
                    let Expr::Func { name, args, star, distinct, coll: fcoll, filter, order_by } = old else {
                        unreachable!()
                    };
                    let order_spec = order_by
                        .iter()
                        .map(|t| (t.desc, t.nulls_first, expr_collation(&t.expr).unwrap_or(Collation::Binary)))
                        .collect();
                    self.specs.push(AggSpec {
                        name,
                        args,
                        star,
                        distinct,
                        coll: fcoll,
                        filter: filter.map(|f| *f),
                        order_by: order_by.into_iter().map(|t| t.expr).collect(),
                        order_spec,
                    });
                    self.keys.push(key);
                    self.specs.len() - 1
                }
            };
            *e = Expr::AggRef { idx: self.base + i, coll };
            return;
        }
        for_each_child_mut(e, &mut |c| self.extract(c));
    }
}

/// sum()/total()/avg() state, following SQLite's SumCtx (Kahan-Babuska-
/// Neumaier summation once the sum becomes approximate).
#[derive(Clone, Debug, Default)]
struct SumCtx {
    r_sum: f64,
    r_err: f64,
    i_sum: i64,
    cnt: i64,
    approx: bool,
    ovrfl: bool,
}

impl SumCtx {
    fn kbn_step(&mut self, r: f64) {
        let s = self.r_sum;
        let t = s + r;
        if s.abs() > r.abs() {
            self.r_err += (s - t) + r;
        } else {
            self.r_err += (r - t) + s;
        }
        self.r_sum = t;
    }

    fn kbn_step_int(&mut self, v: i64) {
        if v <= -4503599627370496 || v >= 4503599627370496 {
            let sm = v % 16384;
            let big = v - sm;
            self.kbn_step(big as f64);
            self.kbn_step(sm as f64);
        } else {
            self.kbn_step(v as f64);
        }
    }

    fn kbn_init(&mut self, v: i64) {
        if v <= -4503599627370496 || v >= 4503599627370496 {
            let sm = v % 16384;
            self.r_sum = (v - sm) as f64;
            self.r_err = sm as f64;
        } else {
            self.r_sum = v as f64;
            self.r_err = 0.0;
        }
    }

    fn step(&mut self, v: &Value) {
        if v.is_null() {
            return;
        }
        // sqlite3_value_numeric_type: Some(Int) means an integer.
        let int = match v.as_strict_number() {
            Some(Value::Int(i)) => Some(i),
            _ => None,
        };
        self.cnt += 1;
        if !self.approx {
            match int {
                None => {
                    self.kbn_init(self.i_sum);
                    self.approx = true;
                    self.kbn_step(v.to_f64());
                }
                Some(i) => match self.i_sum.checked_add(i) {
                    Some(x) => self.i_sum = x,
                    None => {
                        self.ovrfl = true;
                        self.kbn_init(self.i_sum);
                        self.approx = true;
                        self.kbn_step_int(i);
                    }
                },
            }
        } else {
            match int {
                Some(i) => self.kbn_step_int(i),
                None => {
                    self.ovrfl = false;
                    self.kbn_step(v.to_f64());
                }
            }
        }
    }

    /// SQLite's sumInverse.
    fn inverse(&mut self, v: &Value) {
        if v.is_null() {
            return;
        }
        self.cnt -= 1;
        let int = match v.as_strict_number() {
            Some(Value::Int(i)) => Some(i),
            _ => None,
        };
        if !self.approx {
            let iv = int.unwrap_or_else(|| v.to_int());
            match self.i_sum.checked_sub(iv) {
                Some(x) => self.i_sum = x,
                None => {
                    self.ovrfl = true;
                    self.approx = true;
                }
            }
        } else if let Some(i) = int {
            if i != i64::MIN {
                self.kbn_step_int(-i);
            } else {
                self.kbn_step_int(i64::MAX);
                self.kbn_step_int(1);
            }
        } else {
            self.kbn_step(-v.to_f64());
        }
    }

    fn approx_value(&self) -> f64 {
        if !self.r_err.is_finite() {
            self.r_sum
        } else {
            self.r_sum + self.r_err
        }
    }
}

#[derive(Clone, Debug)]
enum Acc {
    Count(i64),
    Sum(SumCtx),
    MinMax(Option<Value>),
    Concat(Option<String>),
}

/// Running state of one aggregate within one group.
#[derive(Clone, Debug)]
pub struct AggState {
    seen: BTreeSet<IdxKey>,
    /// Buffered (arguments, order keys) for aggregates with ORDER BY.
    buf: Vec<(Vec<Value>, Vec<Value>)>,
    acc: Acc,
}

impl AggState {
    pub fn new(spec: &AggSpec) -> AggState {
        let acc = match spec.name.as_str() {
            "count" => Acc::Count(0),
            "sum" | "total" | "avg" => Acc::Sum(SumCtx::default()),
            "min" | "max" => Acc::MinMax(None),
            _ => Acc::Concat(None),
        };
        AggState { seen: BTreeSet::new(), buf: vec![], acc }
    }

    /// Process one input row. Returns Some(skip) for min/max (skip = the
    /// row did not become the new extremum), None otherwise or if the row
    /// was not fed to the aggregate.
    pub fn update(&mut self, spec: &AggSpec, row: &[Value], cx: &Cx) -> Result<Option<bool>> {
        if let Some(f) = &spec.filter {
            if eval(f, row, cx)?.truthy() != Some(true) {
                return Ok(None);
            }
        }
        let args = spec.args.iter().map(|a| eval(a, row, cx)).collect::<Result<Vec<_>>>()?;
        if spec.distinct && !self.seen.insert(IdxKey(vec![normalize(&args[0], spec.coll)])) {
            return Ok(None);
        }
        if !spec.order_by.is_empty() {
            let keys = spec.order_by.iter().map(|k| eval(k, row, cx)).collect::<Result<Vec<_>>>()?;
            self.buf.push((args, keys));
            return Ok(None);
        }
        Ok(self.step(spec, &args))
    }

    /// Remove one input row from the aggregate (sliding window frames);
    /// only for aggregates where `has_inverse` holds.
    pub fn inverse(&mut self, spec: &AggSpec, args: &[Value]) {
        match &mut self.acc {
            Acc::Count(n) => {
                if spec.star || !args[0].is_null() {
                    *n -= 1;
                }
            }
            Acc::Sum(s) => s.inverse(&args[0]),
            _ => {}
        }
    }

    pub fn step(&mut self, spec: &AggSpec, args: &[Value]) -> Option<bool> {
        match &mut self.acc {
            Acc::Count(n) => {
                if spec.star || !args[0].is_null() {
                    *n += 1;
                }
                None
            }
            Acc::Sum(s) => {
                s.step(&args[0]);
                None
            }
            Acc::MinMax(best) => {
                let v = &args[0];
                if v.is_null() {
                    return Some(best.is_some());
                }
                let better = match best {
                    None => true,
                    Some(b) => {
                        let c = compare_coll(b, v, spec.coll);
                        if spec.name == "max" {
                            c == Ordering::Less
                        } else {
                            c == Ordering::Greater
                        }
                    }
                };
                if better {
                    *best = Some(v.clone());
                }
                Some(!better)
            }
            Acc::Concat(acc) => {
                let Some(t) = args[0].to_text() else { return None };
                match acc {
                    None => *acc = Some(t),
                    Some(s) => {
                        let sep = match args.get(1) {
                            Some(v) => v.to_text().unwrap_or_default(),
                            None => ",".to_string(),
                        };
                        s.push_str(&sep);
                        s.push_str(&t);
                    }
                }
                None
            }
        }
    }

    /// Final value of the aggregate.
    pub fn finish(mut self, spec: &AggSpec) -> Result<Value> {
        if !self.buf.is_empty() {
            let mut buf = std::mem::take(&mut self.buf);
            buf.sort_by(|a, b| cmp_keys(&a.1, &b.1, &spec.order_spec));
            for (args, _) in buf {
                self.step(spec, &args);
            }
        }
        Ok(match self.acc {
            Acc::Count(n) => Value::Int(n),
            Acc::Sum(s) => match spec.name.as_str() {
                "sum" => {
                    if s.cnt == 0 {
                        Value::Null
                    } else if s.approx {
                        if s.ovrfl {
                            return err!("integer overflow");
                        }
                        Value::real(s.approx_value())
                    } else {
                        Value::Int(s.i_sum)
                    }
                }
                "total" => Value::real(if s.approx { s.approx_value() } else { s.i_sum as f64 }),
                _ => {
                    if s.cnt == 0 {
                        Value::Null
                    } else {
                        let r = if s.approx { s.approx_value() } else { s.i_sum as f64 };
                        Value::real(r / s.cnt as f64)
                    }
                }
            },
            Acc::MinMax(b) => b.unwrap_or(Value::Null),
            Acc::Concat(s) => s.map(Value::Text).unwrap_or(Value::Null),
        })
    }
}
