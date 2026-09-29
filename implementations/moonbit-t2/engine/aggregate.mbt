// Aggregate functions: extraction from expressions, accumulation and
// finalization.

///|
fn map_opt(
  e : Expr?,
  f : (Expr) -> Expr raise SqlError,
) -> Expr? raise SqlError {
  match e {
    Some(x) => Some(f(x))
    None => None
  }
}

///|
/// Rebuilds an expression with `f` applied to each direct child.
fn Expr::map_children(
  self : Expr,
  f : (Expr) -> Expr raise SqlError,
) -> Expr raise SqlError {
  match self {
    Lit(_) | Col(..) | Slot(..) | AggRef(..) => self
    Subquery(_) | Exists(_) | ScalarQ(_) | ExistsQ(_) => self
    InSelect(x, q, n) => InSelect(f(x), q, n)
    InQ(x, q, n) => InQ(f(x), q, n)
    Unary(op, x) => Unary(op, f(x))
    Binary(op, l, r) => Binary(op, f(l), f(r))
    IsNull(x, n) => IsNull(f(x), n)
    Is(l, r, n) => Is(f(l), f(r), n)
    Between(x, lo, hi, n) => Between(f(x), f(lo), f(hi), n)
    InList(x, items, n) => InList(f(x), items.map(f), n)
    Like(op, x, p, esc, n) => Like(op, f(x), f(p), map_opt(esc, f), n)
    Func(name~, args~, distinct~, star~, filter~, order~) =>
      Func(
        name~,
        args=args.map(f),
        distinct~,
        star~,
        filter=map_opt(filter, f),
        order=order.map(t => { ..t, expr: f(t.expr), }),
      )
    Case(base, whens, els) =>
      Case(map_opt(base, f), whens.map(w => (f(w.0), f(w.1))), map_opt(els, f))
    Cast(x, t) => Cast(f(x), t)
    Collate(x, c) => Collate(f(x), c)
    WinFunc(func, spec) => {
      // the arguments and window expressions, not the call itself
      let inner = match func {
        Func(name~, args~, distinct~, star~, filter~, order~) =>
          Func(
            name~,
            args=args.map(f),
            distinct~,
            star~,
            filter=map_opt(filter, f),
            order=order.map(t => { ..t, expr: f(t.expr), }),
          )
        _ => func
      }
      WinFunc(inner, {
        ..spec,
        partition: spec.partition.map(f),
        order: spec.order.map(t => { ..t, expr: f(t.expr), }),
      })
    }
  }
}

///|
/// True if the (unbound) expression contains an aggregate call.
fn has_aggregate(e : Expr) -> Bool {
  if e is Func(name~, args~, ..) && is_aggregate_call(name, args.length()) {
    return true
  }
  let mut found = false
  ignore(
    e.map_children(x => {
      if !found && has_aggregate(x) {
        found = true
      }
      x
    }),
  ) catch {
    _ => ()
  }
  found
}

///|
priv struct AggInfo {
  name : String
  args : Array[Expr] // bound
  distinct : Bool
  star : Bool
  filter : Expr?
  order : Array[SortKey]
  coll : String // collation of the first argument
}

///|
priv struct AggCtx {
  base : Int // slot of the first aggregate result in a group row
  aggs : Array[AggInfo]
  scope : Scope
}

///|
/// Builds a sort key from an ORDER BY term whose expression is already
/// bound (collations stripped into `explicit`).
fn make_sort_key(
  bound : Expr,
  explicit : String?,
  result_idx : Int,
  t : OrderTerm,
) -> SortKey {
  let coll = match explicit {
    Some(c) => c
    None =>
      match expr_coll(bound) {
        Some((c, _)) => c
        None => "BINARY"
      }
  }
  { expr: bound, result_idx, desc: t.desc, nulls: t.nulls, coll, }
}

///|
/// Replaces aggregate calls in an unbound expression by AggRef nodes,
/// registering them in `ctx`.
fn extract_aggs(e : Expr, ctx : AggCtx) -> Expr raise SqlError {
  match e {
    Func(name~, args~, distinct~, star~, filter~, order~) if is_aggregate_call(
        name,
        args.length(),
      ) => {
      if outer_aggregate(e, Some(ctx.scope)) is Some(r) {
        return r
      }
      let n = args.length()
      let (lo, hi) = aggregate_arity[name]
      if n < lo || n > hi {
        raise SqlError("wrong number of arguments to function \{name}()")
      }
      if distinct && n != 1 {
        raise SqlError("DISTINCT aggregates must have exactly one argument")
      }
      let scope = Some(ctx.scope)
      let bargs = args.map(a => bind_expr(a, scope))
      let bfilter = map_opt(filter, x => bind_expr(x, scope))
      let keys = order.map(t => {
        let mut term = t.expr
        let mut explicit : String? = None
        while term is Collate(inner, c) {
          if explicit is None {
            explicit = Some(check_collation(c))
          }
          term = inner
        }
        make_sort_key(bind_expr(term, scope), explicit, -1, t)
      })
      let coll = if n > 0 {
        match expr_coll(bargs[0]) {
          Some((c, _)) => c
          None => "BINARY"
        }
      } else {
        "BINARY"
      }
      let idx = ctx.base + ctx.aggs.length()
      ctx.aggs.push({
        name,
        args: bargs,
        distinct,
        star,
        filter: bfilter,
        order: keys,
        coll,
      })
      AggRef(depth=0, idx~, coll=first_explicit(bargs))
    }
    _ => e.map_children(x => extract_aggs(x, ctx))
  }
}

///|
/// One input fed to an aggregate.
priv struct AggItem {
  vals : Array[Value]
  keys : Array[Value]
  row : Array[Value]
}

///|
/// Accumulated inputs of one aggregate within one group.
priv struct AggAcc {
  items : Array[AggItem]
  seen : Set[String]
}

///|
fn new_accs(n : Int) -> Array[AggAcc] {
  Array::makei(n, _ => { items: [], seen: Set([]), })
}

///|
let no_values : Array[Value] = []

///|
let empty_item : AggItem = { vals: no_values, keys: no_values, row: no_values, }

///|
/// Feeds the current row (in `env`) to aggregate `info`.
fn AggInfo::step(
  self : AggInfo,
  acc : AggAcc,
  env : Env,
  keep_row : Bool,
) -> Unit raise SqlError {
  if self.filter is Some(f) && truthy(eval(f, env)) != Some(true) {
    return
  }
  let vals = if self.args.length() == 0 {
    no_values
  } else {
    self.args.map(a => eval(a, env))
  }
  if self.distinct {
    if vals[0] is Null {
      return
    }
    let sb = StringBuilder()
    value_key(sb, vals[0], self.coll)
    if !acc.seen.add_and_check(sb.to_string()) {
      return
    }
  }
  let keys = if self.order.length() == 0 {
    no_values
  } else {
    self.order.map(k => eval(k.expr, env))
  }
  if vals.length() == 0 && keys.length() == 0 && !keep_row {
    acc.items.push(empty_item)
    return
  }
  acc.items.push({
    vals,
    keys,
    row: if keep_row {
      env.row.copy()
    } else {
      no_values
    },
  })
}

///|
priv struct SumCtx {
  mut r_sum : Double
  mut r_err : Double
  mut i_sum : Int64
  mut cnt : Int64
  mut approx : Bool
  mut ovrfl : Bool
}

///|
fn SumCtx::kbn_step(self : SumCtx, r : Double) -> Unit {
  let s = self.r_sum
  let t = s + r
  if s.abs() > r.abs() {
    self.r_err += s - t + r
  } else {
    self.r_err += r - t + s
  }
  self.r_sum = t
}

///|
fn SumCtx::kbn_step_int(self : SumCtx, v : Int64) -> Unit {
  if v <= -4503599627370496L || v >= 4503599627370496L {
    let sm = v % 16384L
    self.kbn_step((v - sm).to_double())
    self.kbn_step(sm.to_double())
  } else {
    self.kbn_step(v.to_double())
  }
}

///|
fn SumCtx::kbn_init(self : SumCtx, v : Int64) -> Unit {
  if v <= -4503599627370496L || v >= 4503599627370496L {
    let sm = v % 16384L
    self.r_sum = (v - sm).to_double()
    self.r_err = sm.to_double()
  } else {
    self.r_sum = v.to_double()
    self.r_err = 0.0
  }
}

///|
fn SumCtx::add(self : SumCtx, v : Value) -> Unit {
  let num = match v {
    Null => return
    Text(s) => parse_numeric_text(s).unwrap_or(v)
    _ => v
  }
  self.cnt += 1L
  if !self.approx {
    match num {
      Int(i) =>
        match add_checked(self.i_sum, i) {
          Some(r) => self.i_sum = r
          None => {
            self.ovrfl = true
            self.kbn_init(self.i_sum)
            self.approx = true
            self.kbn_step_int(i)
          }
        }
      _ => {
        self.kbn_init(self.i_sum)
        self.approx = true
        self.kbn_step(value_to_double(num))
      }
    }
  } else {
    match num {
      Int(i) => self.kbn_step_int(i)
      _ => {
        self.ovrfl = false
        self.kbn_step(value_to_double(num))
      }
    }
  }
}

///|
fn SumCtx::approx_value(self : SumCtx) -> Double {
  if self.approx {
    if self.r_err.is_inf() || self.r_err.is_nan() {
      self.r_sum
    } else {
      self.r_sum + self.r_err
    }
  } else {
    self.i_sum.to_double()
  }
}

///|
/// Computes the aggregate's value. The second result is the index (in feed
/// order) of the item that last set min()/max(), or -1.
fn AggInfo::finalize(
  self : AggInfo,
  acc : AggAcc,
) -> (Value, AggItem?) raise SqlError {
  let items = if self.order.length() > 0 {
    let idx = Array::makei(acc.items.length(), i => i)
    idx.sort_by((a, b) => {
      let c = compare_sort_keys(
        self.order,
        acc.items[a].keys,
        acc.items[b].keys,
      )
      if c != 0 {
        c
      } else {
        a - b
      }
    })
    idx.map(i => acc.items[i])
  } else {
    acc.items
  }
  match self.name {
    "count" =>
      if self.star || self.args.length() == 0 {
        (Int(items.length().to_int64()), None)
      } else {
        let mut n = 0L
        for it in items {
          if !(it.vals[0] is Null) {
            n += 1L
          }
        }
        (Int(n), None)
      }
    "sum" | "total" | "avg" => {
      let s : SumCtx = {
        r_sum: 0.0,
        r_err: 0.0,
        i_sum: 0L,
        cnt: 0L,
        approx: false,
        ovrfl: false,
      }
      for it in items {
        s.add(it.vals[0])
      }
      match self.name {
        "total" => (Real(s.approx_value()), None)
        "avg" =>
          if s.cnt == 0L {
            (Null, None)
          } else {
            (real_result(s.approx_value() / s.cnt.to_double()), None)
          }
        _ =>
          if s.cnt == 0L {
            (Null, None)
          } else if s.approx {
            if s.ovrfl {
              raise SqlError("integer overflow")
            }
            (real_result(s.approx_value()), None)
          } else {
            (Int(s.i_sum), None)
          }
      }
    }
    "min" | "max" => {
      let is_max = self.name == "max"
      let mut best = Null
      let mut loaded : AggItem? = None
      for it in items {
        let v = it.vals[0]
        if v is Null {
          if best is Null {
            loaded = Some(it)
          }
          continue
        }
        if best is Null {
          best = v
          loaded = Some(it)
        } else {
          let c = value_compare_coll(best, v, self.coll)
          if (is_max && c < 0) || (!is_max && c > 0) {
            best = v
            loaded = Some(it)
          }
        }
      }
      (best, loaded)
    }
    _ => {
      // group_concat / string_agg
      let sb = StringBuilder()
      let mut any = false
      for it in items {
        let v = it.vals[0]
        if v is Null {
          continue
        }
        if any {
          if it.vals.length() > 1 {
            let sep = it.vals[1]
            if !(sep is Null) {
              sb.write_string(sep.to_text())
            }
          } else {
            sb.write_char(',')
          }
        }
        any = true
        sb.write_string(v.to_text())
      }
      if any {
        (Text(sb.to_string()), None)
      } else {
        (Null, None)
      }
    }
  }
}
