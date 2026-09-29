// Aggregate functions: binding and accumulation.

///|
priv struct AggOrder {
  key : Expr
  desc : Bool
  nulls_first : Bool
  coll : Coll
}

///|
priv struct AggSpec {
  name : String
  args : Array[Expr]
  star : Bool // count(*) / count()
  distinct : Bool
  filter : Expr?
  order : Array[AggOrder]
  coll : Coll
}

///|
priv struct AggCtx {
  specs : Array[AggSpec]
  base : Int // slot of the first aggregate result in the group row
  mut inside : Bool
}

///|
fn is_aggregate_call(name : String, nargs : Int) -> Bool {
  match name {
    "COUNT" | "SUM" | "TOTAL" | "AVG" | "GROUP_CONCAT" | "STRING_AGG" => true
    "MIN" | "MAX" => nargs == 1
    _ => false
  }
}

///|
fn Scope::bind_aggregate(
  self : Scope,
  name : String,
  args : Array[Expr],
  star : Bool,
  distinct : Bool,
  filter : Expr?,
  order : Array[OrderTerm],
) -> Expr raise SqlError {
  // Like SQLite, an aggregate belongs to the innermost query whose columns
  // its arguments reference; probe the arguments to find it.
  if self.outer is Some(_) {
    let tr : Ref[Int] = { val: -1, }
    agg_trackers.push((self.level, tr))
    let probe : Scope = { ..self, agg: None, }
    for a in args {
      ignore(probe.bind(a)) catch {
        _ => ()
      }
    }
    ignore(agg_trackers.pop())
    if tr.val >= 0 && tr.val < self.level {
      let mut cur = self.outer
      while cur is Some(sc) {
        if sc.level == tr.val {
          let inner = sc.bind_aggregate_here(
            name, args, star, distinct, filter, order,
          )
          self.mark_corr(sc.level)
          if self.agg is None && self.wflag is Some(f) {
            f.val = name.to_lower()
          }
          return Outer(self.level - sc.level, inner)
        }
        cur = sc.outer
      }
    }
  }
  self.bind_aggregate_here(name, args, star, distinct, filter, order)
}

///|
fn Scope::bind_aggregate_here(
  self : Scope,
  name : String,
  args : Array[Expr],
  star : Bool,
  distinct : Bool,
  filter : Expr?,
  order : Array[OrderTerm],
) -> Expr raise SqlError {
  let lname = name.to_lower()
  guard self.agg is Some(ctx) else {
    raise sql_err("misuse of aggregate: \{lname}()")
  }
  if ctx.inside {
    raise sql_err("misuse of aggregate function \{lname}()")
  }
  let n = args.length()
  let (lo, hi) = match name {
    "COUNT" => (0, 1)
    "GROUP_CONCAT" => (1, 2)
    "STRING_AGG" => (2, 2)
    _ => (1, 1)
  }
  if (star && name != "COUNT") || (star && n > 0) || n < lo || n > hi {
    raise sql_err("wrong number of arguments to function \{lname}()")
  }
  if distinct && n != 1 {
    raise sql_err("DISTINCT aggregates must have exactly one argument")
  }
  ctx.inside = true
  let self = { ..self, win: None, }
  let bargs = args.map(a => self.bind(a))
  let bfilter = match filter {
    Some(f) => Some(self.bind(f))
    None => None
  }
  let border : Array[AggOrder] = []
  for t in order {
    let k = self.bind(t.expr)
    border.push({
      key: k,
      desc: t.desc,
      nulls_first: t.nulls_first.unwrap_or(!t.desc),
      coll: expr_coll(k).unwrap_or(CBinary),
    })
  }
  ctx.inside = false
  let coll = if bargs.length() > 0 {
    expr_coll(bargs[0]).unwrap_or(CBinary)
  } else {
    CBinary
  }
  let idx = ctx.specs.length()
  ctx.specs.push({
    name,
    args: bargs,
    star: star || n == 0,
    distinct,
    filter: bfilter,
    order: border,
    coll,
  })
  AggRef(ctx.base + idx)
}

///|
fn contains_agg(e : Expr) -> Bool {
  match e {
    AggRef(_) => true
    _ => expr_children(e).any(contains_agg)
  }
}

///|
/// Running state of one aggregate within one group.
priv struct Acc {
  spec : AggSpec
  mut cnt : Int64
  mut isum : Int64
  mut approx : Bool
  mut ovrfl : Bool
  mut rsum : Double
  mut rerr : Double
  mut best : Value
  sb : StringBuilder
  mut started : Bool
  mut seen : PMap[Value, Unit]
  buffered : Array[(Array[Value], Array[Value])]
}

///|
fn new_acc(spec : AggSpec) -> Acc {
  let coll = spec.coll
  {
    spec,
    cnt: 0L,
    isum: 0L,
    approx: false,
    ovrfl: false,
    rsum: 0.0,
    rerr: 0.0,
    best: Null,
    sb: StringBuilder(),
    started: false,
    seen: PMap::empty((a, b) => compare_coll(a, b, coll)),
    buffered: [],
  }
}

///|
fn Acc::kbn_step(self : Acc, r : Double) -> Unit {
  let s = self.rsum
  let t = s + r
  if s.abs() > r.abs() {
    self.rerr += s - t + r
  } else {
    self.rerr += r - t + s
  }
  self.rsum = t
}

///|
fn Acc::kbn_step_int(self : Acc, v : Int64) -> Unit {
  if v <= -4503599627370496L || v >= 4503599627370496L {
    let sm = v % 16384L
    self.kbn_step((v - sm).to_double())
    self.kbn_step(sm.to_double())
  } else {
    self.kbn_step(v.to_double())
  }
}

///|
fn Acc::kbn_init(self : Acc, v : Int64) -> Unit {
  if v <= -4503599627370496L || v >= 4503599627370496L {
    let sm = v % 16384L
    self.rsum = (v - sm).to_double()
    self.rerr = sm.to_double()
  } else {
    self.rsum = v.to_double()
    self.rerr = 0.0
  }
}

///|
fn Acc::sum_step(self : Acc, v0 : Value) -> Unit {
  let v = match v0 {
    Text(_) => apply_affinity(v0, AffNumeric)
    _ => v0
  }
  if v is Null {
    return
  }
  self.cnt += 1L
  match v {
    Int(i) =>
      if !self.approx {
        let r = self.isum + i
        if ((self.isum ^ r) & (i ^ r)) < 0L {
          self.ovrfl = true
          self.kbn_init(self.isum)
          self.approx = true
          self.kbn_step_int(i)
        } else {
          self.isum = r
        }
      } else {
        self.kbn_step_int(i)
      }
    _ =>
      if !self.approx {
        self.kbn_init(self.isum)
        self.approx = true
        self.kbn_step(v.to_double())
      } else {
        self.ovrfl = false
        self.kbn_step(v.to_double())
      }
  }
}

///|
fn Acc::real_sum(self : Acc) -> Double {
  if self.approx {
    if self.rerr.is_inf() || self.rerr.is_nan() {
      self.rsum
    } else {
      self.rsum + self.rerr
    }
  } else {
    self.isum.to_double()
  }
}

///|
/// Feed one row's argument values. For min/max returns whether this row
/// became the new extremum (drives the bare-column rule).
fn Acc::step(self : Acc, vals : Array[Value]) -> Bool? {
  match self.spec.name {
    "COUNT" => {
      if !(vals[0] is Null) {
        self.cnt += 1L
      }
      None
    }
    "SUM" | "TOTAL" | "AVG" => {
      self.sum_step(vals[0])
      None
    }
    "MIN" | "MAX" => {
      let v = vals[0]
      if v is Null {
        return Some(self.best is Null)
      }
      if self.best is Null {
        self.best = v
        return Some(true)
      }
      let c = compare_coll(self.best, v, self.spec.coll)
      let replace = if self.spec.name == "MAX" { c < 0 } else { c > 0 }
      if replace {
        self.best = v
      }
      Some(replace)
    }
    _ => {
      // GROUP_CONCAT / STRING_AGG
      let v = vals[0]
      if v is Null {
        return None
      }
      if self.started {
        let sep = if vals.length() > 1 {
          vals[1].to_text().unwrap_or("")
        } else {
          ","
        }
        self.sb.write_string(sep)
      }
      self.started = true
      self.sb.write_string(v.to_text().unwrap_or(""))
      None
    }
  }
}

///|
fn order_sensitive(name : String) -> Bool {
  name == "GROUP_CONCAT" || name == "STRING_AGG"
}

///|
/// Process one input row; returns the min/max hit flag (see `step`).
fn Acc::add_row(self : Acc, row : Array[Value]) -> Bool? raise SqlError {
  let spec = self.spec
  if spec.filter is Some(f) && !(eval(f, row).truth() is Some(true)) {
    return None
  }
  if spec.star {
    self.cnt += 1L
    return None
  }
  let vals = spec.args.map(a => eval(a, row))
  if spec.distinct {
    let v = vals[0]
    if v is Null {
      return None
    }
    if self.seen.find(v) is Some(_) {
      return None
    }
    self.seen = self.seen.add(v, ())
  }
  if spec.order.length() > 0 && order_sensitive(spec.name) {
    self.buffered.push((vals, spec.order.map(o => eval(o.key, row))))
    return None
  }
  self.step(vals)
}

///|
fn Acc::finish(self : Acc) -> Value raise SqlError {
  let spec = self.spec
  if self.buffered.length() > 0 {
    let order = spec.order
    stable_sort(self.buffered, (a, b) => {
      for i, o in order {
        let x = a.1[i]
        let y = b.1[i]
        match (x, y) {
          (Null, Null) => continue
          (Null, _) => return if o.nulls_first { -1 } else { 1 }
          (_, Null) => return if o.nulls_first { 1 } else { -1 }
          _ => ()
        }
        let c = compare_coll(x, y, o.coll)
        if c != 0 {
          return if o.desc { -c } else { c }
        }
      }
      0
    })
    for b in self.buffered {
      ignore(self.step(b.0))
    }
    self.buffered.clear()
  }
  match spec.name {
    "COUNT" => Int(self.cnt)
    "SUM" =>
      if self.cnt == 0L {
        Null
      } else if self.approx {
        if self.ovrfl {
          raise int_overflow()
        }
        Real(self.real_sum())
      } else {
        Int(self.isum)
      }
    "TOTAL" => Real(self.real_sum())
    "AVG" =>
      if self.cnt == 0L {
        Null
      } else {
        Real(self.real_sum() / self.cnt.to_double())
      }
    "MIN" | "MAX" => self.best
    _ => if self.started { Text(self.sb.to_string()) } else { Null }
  }
}

///|
priv struct Group {
  mut rep : Array[Value]
  mut loaded : Bool
  accs : Array[Acc]
}

///|
fn new_group(specs : Array[AggSpec], width : Int) -> Group {
  { rep: Array::make(width, Null), loaded: false, accs: specs.map(new_acc), }
}

///|
fn Group::add_row(self : Group, row : Array[Value]) -> Unit raise SqlError {
  let mut hit : Bool? = None
  for acc in self.accs {
    let h = acc.add_row(row)
    if h is Some(_) {
      hit = h
    }
  }
  if !self.loaded || hit is Some(true) {
    self.rep = row.copy()
    self.loaded = true
  }
}

///|
/// The row seen by post-aggregation expressions: representative input row
/// followed by the aggregate results.
fn Group::result_row(self : Group) -> Array[Value] raise SqlError {
  let out = self.rep.copy()
  for acc in self.accs {
    out.push(acc.finish())
  }
  out
}
