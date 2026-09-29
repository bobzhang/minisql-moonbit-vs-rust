///|
/// True if a function call (without OVER) names an aggregate function.
fn is_aggregate_call(fc : FuncCall) -> Bool {
  match fc.name.to_lower() {
    "count" | "sum" | "total" | "avg" | "group_concat" | "string_agg" => true
    "min" | "max" => fc.args.length() <= 1
    _ => false
  }
}

///|
/// Rebuilds `e` with `f` applied to each direct sub-expression.
/// Subqueries are left untouched.
fn map_expr_children(
  e : Expr,
  f : (Expr) -> Expr raise SqlError,
) -> Expr raise SqlError {
  let opt = (x : Expr?) => {
    match x {
      Some(y) => Some(f(y))
      None => None
    }
  }
  match e {
    Lit(_) | Column(_, _, _) | Param(_) | AggSlot(_) => e
    Exists(_, _) | Subquery(_) => e
    Unary(op, x) => Unary(op, f(x))
    Binary(op, l, r) => Binary(op, f(l), f(r))
    IsNull(x, neg) => IsNull(f(x), neg)
    Between(x, l, h, neg) => Between(f(x), f(l), f(h), neg)
    InList(x, items, neg) => InList(f(x), items.map(f), neg)
    InSelect(x, sel, neg) => InSelect(f(x), sel, neg)
    Like(op, l, p, esc, neg) => Like(op, f(l), f(p), opt(esc), neg)
    Case(b, whens, els) =>
      Case(opt(b), whens.map(w => (f(w.0), f(w.1))), opt(els))
    Cast(x, t) => Cast(f(x), t)
    Collate(x, c) => Collate(f(x), c)
    Func(fc) =>
      Func({
        ..fc,
        args: fc.args.map(f),
        filter: opt(fc.filter),
        order_by: fc.order_by.map(t => { ..t, expr: f(t.expr), }),
        over: match fc.over {
          Some(w) =>
            Some({
              ..w,
              partition_by: w.partition_by.map(f),
              order_by: w.order_by.map(t => { ..t, expr: f(t.expr), }),
            })
          None => None
        },
      })
  }
}

///|
/// Replaces aggregate calls with `AggSlot(k)`, collecting them in `aggs`.
/// With `db`, aggregates inside subqueries whose arguments only reference
/// this query's columns are hoisted too (they belong to this query).
fn extract_aggregates(
  e : Expr,
  aggs : Array[FuncCall],
  db? : Database,
) -> Expr raise SqlError {
  match e {
    Func(fc) if fc.over is None && is_aggregate_call(fc) => {
      aggs.push(fc)
      AggSlot(aggs.length() - 1)
    }
    Subquery(sel) if db is Some(d) => Subquery(d.hoist_select_aggs(sel, aggs))
    Exists(sel, neg) if db is Some(d) =>
      Exists(d.hoist_select_aggs(sel, aggs), neg)
    InSelect(x, sel, neg) if db is Some(d) =>
      InSelect(
        extract_aggregates(x, aggs, db=d),
        d.hoist_select_aggs(sel, aggs),
        neg,
      )
    _ => map_expr_children(e, x => extract_aggregates(x, aggs, db?))
  }
}

///|
/// Qualifier of the hidden scope table exposing an aggregate query's
/// aggregate values to its subqueries.
let agg_table_name = "\u{1}agg"

///|
fn collect_columns(e : Expr, out : Array[(String?, String)]) -> Unit {
  let _ = map_expr_children(e, x => {
    if x is Column(t, n, _) {
      out.push((t, n))
    }
    collect_columns(x, out)
    x
  }) catch {
    _ => e
  }
  if e is Column(t, n, _) {
    out.push((t, n))
  }
}

///|
/// Replaces, in a subquery's own clauses, aggregate calls whose column
/// references all lie outside the subquery's FROM with references to
/// hoisted aggregates of the enclosing query.
fn Database::hoist_select_aggs(
  self : Database,
  sel : Select,
  aggs : Array[FuncCall],
) -> Select raise SqlError {
  guard sel.first is Simple(core) && sel.rest.length() == 0 else { return sel }
  let names : Array[String] = []
  let tables : Array[Table] = []
  let mut any_source = false
  fn walk(item : FromItem) {
    match item {
      TableRef(n, a) => {
        names.push(fold_name(a.unwrap_or(n)))
        match self.find_table(n) {
          Some(t) => tables.push(t)
          None => any_source = true
        }
      }
      SubqueryRef(_, a) => {
        if a is Some(x) {
          names.push(fold_name(x))
        }
        any_source = true
      }
      Join(l, r, _, _, _, _) => {
        walk(l)
        walk(r)
      }
    }
  }
  if core.from is Some(f) {
    walk(f)
  }
  let is_inner = (c : (String?, String)) => {
    match c.0 {
      Some(t) => names.contains(fold_name(t))
      None =>
        any_source ||
        is_rowid_name(fold_name(c.1)) ||
        tables.any(t => t.column_index(c.1) is Some(_))
    }
  }
  let mut changed = false
  fn hoist(e : Expr) -> Expr raise SqlError {
    match e {
      Func(fc) if fc.over is None && is_aggregate_call(fc) => {
        let cols = []
        for a in fc.args {
          collect_columns(a, cols)
        }
        if cols.length() > 0 && !cols.any(is_inner) {
          aggs.push(fc)
          changed = true
          Column(Some(agg_table_name), (aggs.length() - 1).to_string(), false)
        } else {
          e
        }
      }
      _ => map_expr_children(e, hoist)
    }
  }
  let columns = core.columns.map(rc => {
    match rc {
      ExprCol(e, a) => ExprCol(hoist(e), a)
      _ => rc
    }
  })
  let where_ = core.where_.map(hoist)
  let having = core.having.map(hoist)
  if !changed {
    return sel
  }
  { ..sel, first: Simple({ ..core, columns, where_, having, }), }
}

///|
/// Replaces bare identifiers that are not FROM columns but match a
/// result-column alias with the aliased expression.
fn substitute_aliases(
  e : Expr,
  scope : Scope,
  columns : Array[ResultCol],
) -> Expr raise SqlError {
  match e {
    Column(None, name, _) => {
      let resolves = try {
        bind_column(scope, None, name, false) |> ignore
        true
      } catch {
        _ => false
      }
      if !resolves {
        let f = fold_name(name)
        for rc in columns {
          if rc is ExprCol(x, Some(a)) && fold_name(a) == f {
            return x
          }
        }
      }
      e
    }
    _ => map_expr_children(e, x => substitute_aliases(x, scope, columns))
  }
}

///|
priv struct AggSpec {
  kind : String
  args : Array[BExpr]
  distinct : Bool
  filter : BExpr?
  order : Array[BExpr]
  order_terms : Array[OrderTerm]
  order_colls : Array[Coll]
  coll : Coll
}

///|
priv struct AggState {
  mut count : Int64
  mut isum : Int64
  mut rsum : Double
  mut rerr : Double
  mut approx : Bool
  mut ovrfl : Bool
  mut best : Value?
  text : StringBuilder
  mut any : Bool
  seen : Set[String]
  buffered : Array[(Array[Value], Array[Value])]
}

///|
fn AggState::new() -> AggState {
  {
    count: 0L,
    isum: 0L,
    rsum: 0.0,
    rerr: 0.0,
    approx: false,
    ovrfl: false,
    best: None,
    text: StringBuilder(),
    any: false,
    seen: Set([]),
    buffered: [],
  }
}

///|
fn Database::bind_aggregate(
  self : Database,
  scope : Scope,
  fc : FuncCall,
) -> AggSpec raise SqlError {
  let kind = fc.name.to_lower()
  let n = fc.args.length()
  let ok = match kind {
    "count" => n <= 1 && !(fc.star && n > 0)
    "group_concat" => n == 1 || n == 2
    "string_agg" => n == 2
    _ => n == 1
  }
  if !ok || (fc.star && kind != "count") {
    raise err("wrong number of arguments to function " + fc.name + "()")
  }
  if fc.distinct && n != 1 {
    raise err("DISTINCT aggregates must have exactly one argument")
  }
  let args = fc.args.map(a => bind_expr(self, scope, a))
  let order = fc.order_by.map(t => bind_expr(self, scope, t.expr))
  {
    kind,
    args,
    distinct: fc.distinct,
    filter: fc.filter.map(x => bind_expr(self, scope, x)),
    order,
    order_terms: fc.order_by,
    order_colls: order.map(o => check_coll(o.collation().unwrap_or(CBinary))),
    coll: if n > 0 {
      check_coll(args[0].collation().unwrap_or(CBinary))
    } else {
      CBinary
    },
  }
}

///|
fn kbn_step(st : AggState, r : Double) -> Unit {
  let s = st.rsum
  let t = s + r
  if s.abs() > r.abs() {
    st.rerr += s - t + r
  } else {
    st.rerr += r - t + s
  }
  st.rsum = t
}

///|
fn kbn_step_int(st : AggState, i : Int64) -> Unit {
  if i <= -4503599627370496L || i >= 4503599627370496L {
    let sm = i % 16384L
    kbn_step(st, (i - sm).to_double())
    kbn_step(st, sm.to_double())
  } else {
    kbn_step(st, i.to_double())
  }
}

///|
fn kbn_init(st : AggState, i : Int64) -> Unit {
  if i <= -4503599627370496L || i >= 4503599627370496L {
    let sm = i % 16384L
    st.rsum = (i - sm).to_double()
    st.rerr = sm.to_double()
  } else {
    st.rsum = i.to_double()
    st.rerr = 0.0
  }
}

///|
/// Feeds one row's argument values to an aggregate. Returns false when a
/// min()/max() did not take its value from this row.
fn agg_step(spec : AggSpec, st : AggState, args : Array[Value]) -> Bool {
  match spec.kind {
    "count" => {
      if args.length() == 0 || !(args[0] is Null) {
        st.count += 1L
      }
      true
    }
    "sum" | "total" | "avg" => {
      let v = args[0]
      // sqlite3_value_numeric_type: text that looks numeric converts.
      let (is_int, ival, rval) = match v {
        Null => return true
        Int(i) => (true, i, 0.0)
        Real(r) => (false, 0L, r)
        Text(s) =>
          match text_to_numeric_strict(s) {
            Some(Int(i)) => (true, i, 0.0)
            Some(x) => (false, 0L, x.as_double())
            None => (false, 0L, v.as_double())
          }
        Blob(_) => (false, 0L, v.as_double())
      }
      st.count += 1L
      if !st.approx {
        if !is_int {
          kbn_init(st, st.isum)
          st.approx = true
          kbn_step(st, rval)
        } else {
          let x = st.isum
          let r = x + ival
          if ((x ^ r) & (ival ^ r)) < 0L {
            st.ovrfl = true
            kbn_init(st, st.isum)
            st.approx = true
            kbn_step_int(st, ival)
          } else {
            st.isum = r
          }
        }
      } else if is_int {
        kbn_step_int(st, ival)
      } else {
        st.ovrfl = false
        kbn_step(st, rval)
      }
      true
    }
    "min" | "max" => {
      let v = args[0]
      match st.best {
        None => {
          if !(v is Null) {
            st.best = Some(v)
          }
          true
        }
        Some(b) => {
          if v is Null {
            return false
          }
          let c = compare_values_coll(b, v, spec.coll)
          if (spec.kind == "max" && c < 0) || (spec.kind == "min" && c > 0) {
            st.best = Some(v)
            true
          } else {
            false
          }
        }
      }
    }
    _ => {
      // group_concat / string_agg
      let v = args[0]
      if v is Null {
        return true
      }
      if st.any {
        if args.length() == 2 {
          if !(args[1] is Null) {
            st.text.write_string(args[1].to_text())
          }
        } else {
          st.text.write_char(',')
        }
      }
      st.any = true
      st.text.write_string(v.to_text())
      true
    }
  }
}

///|
fn kbn_result(st : AggState) -> Double {
  if st.rerr.is_inf() || st.rerr.is_nan() {
    st.rsum
  } else {
    st.rsum + st.rerr
  }
}

///|
fn agg_finalize(spec : AggSpec, st : AggState) -> Value raise SqlError {
  if st.buffered.length() > 0 {
    let idx = Array::makei(st.buffered.length(), i => i)
    idx.sort_by((a, b) => {
      let c = compare_order_keys(
        spec.order_terms,
        spec.order_colls,
        st.buffered[a].1,
        st.buffered[b].1,
      )
      if c != 0 {
        c
      } else {
        a - b
      }
    })
    for i in idx {
      agg_step(spec, st, st.buffered[i].0) |> ignore
    }
    st.buffered.clear()
  }
  match spec.kind {
    "count" => Int(st.count)
    "sum" =>
      if st.count == 0L {
        Null
      } else if st.approx {
        if st.ovrfl {
          raise err("integer overflow")
        }
        real_result(kbn_result(st))
      } else {
        Int(st.isum)
      }
    "total" =>
      if st.approx {
        real_result(kbn_result(st))
      } else {
        Real(st.isum.to_double())
      }
    "avg" =>
      if st.count == 0L {
        Null
      } else {
        let r = if st.approx { kbn_result(st) } else { st.isum.to_double() }
        real_result(r / st.count.to_double())
      }
    "min" | "max" => st.best.unwrap_or(Null)
    _ => if st.any { Text(st.text.to_string()) } else { Null }
  }
}

///|
priv struct Group {
  keys : Array[Value]
  states : Array[AggState]
  mut bare : Array[Value]
}

///|
fn Database::compile_aggregate(
  self : Database,
  core : SimpleSelect,
  order_by : Array[OrderTerm],
  limit : Expr?,
  offset : Expr?,
  scope : Scope,
  produce : () -> Array[Array[Value]] raise SqlError,
  columns : Array[ResultCol],
  having : Expr?,
  order_exprs : Array[Expr],
  aggs : Array[FuncCall],
  order_ctx : OrderCtx,
  wins : Array[FuncCall],
) -> Compiled raise SqlError {
  // GROUP BY terms: ordinals and aliases refer to result columns.
  let group_by = core.group_by.map(g => {
    let g2 = match g {
      Lit(Int(n)) => {
        if n < 1L || n > core.columns.length().to_int64() {
          raise err(
            "GROUP BY term out of range - should be between 1 and \{core.columns.length()}",
          )
        }
        match core.columns[n.to_int() - 1] {
          ExprCol(x, _) => x
          _ => g
        }
      }
      _ => substitute_aliases(g, scope, core.columns)
    }
    let tmp : Array[FuncCall] = []
    let g3 = extract_aggregates(g2, tmp)
    if tmp.length() > 0 {
      raise err("aggregate functions are not allowed in the GROUP BY clause")
    }
    bind_expr(self, scope, g3)
  })
  let gcolls = group_by.map(g => check_coll(g.collation().unwrap_or(CBinary)))
  if group_by.length() > 0 {
    order_ctx.hint = Some({
      terms: group_by.mapi((k, g) => (g, false, None, gcolls[k])),
      kind: 1,
      ncols: core.columns.length(),
      has_limit: limit is Some(_),
      limit: -1,
      nonnull: None,
    })
  } else if aggs.length() == 1 &&
    !core.distinct &&
    aggs[0].args.length() == 1 &&
    !aggs[0].distinct &&
    aggs[0].filter is None &&
    aggs[0].order_by.length() == 0 &&
    aggs[0].over is None &&
    (aggs[0].name.to_lower() == "min" || aggs[0].name.to_lower() == "max") {
    // min()/max() alone: read the first non-NULL value in index order.
    let arg = bind_expr(self, scope, aggs[0].args[0])
    order_ctx.hint = Some({
      terms: [
        (
          arg,
          aggs[0].name.to_lower() == "max",
          None,
          check_coll(arg.collation().unwrap_or(CBinary)),
        ),
      ],
      kind: 0,
      ncols: core.columns.length(),
      has_limit: true,
      limit: 1,
      nonnull: Some(arg),
    })
  }
  let specs = aggs.map(fc => self.bind_aggregate(scope, fc))
  let agg_cols = aggs.mapi((k, _) => simple_column(k.to_string()))
  let ascope = Scope::new(
    [
      ..scope.tables,
      ScopeTable::new(
        agg_table_name,
        agg_cols,
        scope.width,
        -1,
        qualified_only=true,
      ),
    ],
    scope.width,
    parent?=scope.parent,
    corr=scope.corr,
  )
  let (exprs, names) = self.bind_result_columns(ascope, columns)
  let having_b = having.map(h => bind_expr(self, ascope, h))
  let wgroups = self.compile_windows(ascope, wins, scope.width + aggs.length())
  let ext_width = scope.width + aggs.length()
  let order = order_exprs.mapi((k, e) => {
    bind_order_term(self, ascope, core.columns, exprs, k, e)
  })
  let ocolls = order.map(o => check_coll(o.collation().unwrap_or(CBinary)))
  let dcolls = if core.distinct {
    exprs.map(x => check_coll(x.collation().unwrap_or(CBinary)))
  } else {
    []
  }
  let run = () => {
    let groups : Array[Group] = []
    let index : Map[String, Int] = Map([])
    let new_group = (keys : Array[Value], bare : Array[Value]) => {
      groups.push({ keys, states: specs.map(_ => AggState::new()), bare, })
      groups.length() - 1
    }
    for row in produce() {
      let keys = group_by.map(g => eval(g, row))
      let before = groups.length()
      let gi = if group_by.length() == 0 {
        if groups.length() == 0 {
          new_group([], row)
        } else {
          0
        }
      } else {
        let sb = StringBuilder()
        for k, v in keys {
          write_value_key(sb, v, gcolls[k])
        }
        let key = sb.to_string()
        match index.get(key) {
          Some(i) => i
          None => {
            let i = new_group(keys, row)
            index[key] = i
            i
          }
        }
      }
      let g = groups[gi]
      // Bare columns come from the group's first row, or from the row that
      // last updated the final min()/max() that ran.
      let mut hit : Bool? = None
      for k, spec in specs {
        if spec.filter is Some(f) && eval(f, row).truth() != Some(true) {
          continue
        }
        let st = g.states[k]
        let args = spec.args.map(a => eval(a, row))
        if spec.distinct {
          if args[0] is Null {
            continue
          }
          let sb = StringBuilder()
          write_value_key(sb, args[0], spec.coll)
          if !st.seen.add_and_check(sb.to_string()) {
            continue
          }
        }
        if spec.order.length() > 0 {
          st.buffered.push((args, spec.order.map(o => eval(o, row))))
          continue
        }
        let took = agg_step(spec, st, args)
        if spec.kind is ("min" | "max") {
          hit = Some(took)
        }
      }
      if groups.length() > before || hit == Some(true) {
        g.bare = row
      }
    }
    if groups.length() == 0 && group_by.length() == 0 {
      new_group([], Array::make(scope.width, Null)) |> ignore
    }
    // Groups come out in GROUP BY key order, or in scan order when the
    // scan already delivers them grouped.
    let gidx = Array::makei(groups.length(), i => i)
    if group_by.length() > 0 && !order_ctx.satisfied {
      gidx.sort_by((a, b) => {
        let ka = groups[a].keys
        let kb = groups[b].keys
        for k in 0..<ka.length() {
          let c = compare_values_coll(ka[k], kb[k], gcolls[k])
          if c != 0 {
            return c
          }
        }
        a - b
      })
    }
    let out : Array[Array[Value]] = []
    let okeys : Array[Array[Value]] = []
    let mut exts = []
    for gi in gidx {
      let g = groups[gi]
      let ext = Array(capacity=ext_width)
      for i in 0..<scope.width {
        ext.push(if i < g.bare.length() { g.bare[i] } else { Null })
      }
      for k, spec in specs {
        ext.push(agg_finalize(spec, g.states[k]))
      }
      if having_b is Some(h) && eval(h, ext).truth() != Some(true) {
        continue
      }
      exts.push(ext)
    }
    if wgroups.length() > 0 {
      exts = run_windows(wgroups, exts, ext_width, wins.length())
    }
    for ext in exts {
      out.push(exprs.map(x => eval(x, ext)))
      if order.length() > 0 {
        okeys.push(order.map(o => eval(o, ext)))
      }
    }
    self.finish(
      out,
      okeys,
      ocolls,
      order_by,
      core.distinct,
      dcolls,
      limit,
      offset,
    )
  }
  { names, exprs, colls: exprs.map(x => x.collation()), run, }
}
