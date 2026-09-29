///|
/// True for functions that only exist as window functions.
fn is_window_only(name : String) -> Bool {
  match name {
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
    | "nth_value" => true
    _ => false
  }
}

///|
/// Replaces `OVER name` / `OVER (name ...)` references with the complete
/// window definition from the WINDOW clause.
fn resolve_windows(
  e : Expr,
  defs : Array[(String, WindowSpec)],
) -> Expr raise SqlError {
  match e {
    Func(fc) if fc.over is Some(w) => {
      let fc2 = { ..fc, over: Some(resolve_window_spec(w, defs, 0)), }
      map_expr_children(Func(fc2), x => resolve_windows(x, defs))
    }
    _ => map_expr_children(e, x => resolve_windows(x, defs))
  }
}

///|
fn resolve_window_spec(
  w : WindowSpec,
  defs : Array[(String, WindowSpec)],
  depth : Int,
) -> WindowSpec raise SqlError {
  guard w.base is Some(name) else { return w }
  let f = fold_name(name)
  let mut found : WindowSpec? = None
  for d in defs {
    if fold_name(d.0) == f {
      found = Some(d.1)
      break
    }
  }
  guard found is Some(b0) && depth < 50 else {
    raise err("no such window: " + name)
  }
  let b = resolve_window_spec(b0, defs, depth + 1)
  if w.partition_by.length() > 0 {
    raise err("cannot override PARTITION BY clause of window " + name)
  }
  if w.order_by.length() > 0 && b.order_by.length() > 0 {
    raise err("cannot override ORDER BY clause of window " + name)
  }
  if b.frame is Some(_) && (w.order_by.length() > 0 || w.frame is Some(_)) {
    raise err("cannot override frame specification of window " + name)
  }
  {
    base: None,
    partition_by: b.partition_by,
    order_by: if w.order_by.length() > 0 {
      w.order_by
    } else {
      b.order_by
    },
    frame: if w.frame is Some(_) {
      w.frame
    } else {
      b.frame
    },
  }
}

///|
/// Replaces window function calls with `AggSlot(base + k)`, collecting them
/// in `wins`.
fn extract_windows(
  e : Expr,
  wins : Array[FuncCall],
  base : Int,
) -> Expr raise SqlError {
  match e {
    Func(fc) if fc.over is Some(_) => {
      wins.push(fc)
      AggSlot(base + wins.length() - 1)
    }
    _ => map_expr_children(e, x => extract_windows(x, wins, base))
  }
}

///|
priv enum WBound {
  WUnbounded
  WPreceding(BExpr)
  WCurrent
  WFollowing(BExpr)
}

///|
priv struct WinFunc {
  /// Slot of the result in the extended row.
  slot : Int
  kind : String
  args : Array[BExpr]
  filter : BExpr?
  agg : AggSpec?
}

///|
/// Window functions sharing one window definition.
priv struct WinGroup {
  key : String
  partition : Array[BExpr]
  pcolls : Array[Coll]
  order : Array[BExpr]
  oterms : Array[OrderTerm]
  ocolls : Array[Coll]
  unit : String
  start : WBound
  end : WBound
  exclude : String
  funcs : Array[WinFunc]
}

///|
fn Database::bind_frame_bound(
  self : Database,
  b : FrameBound,
) -> WBound raise SqlError {
  match b {
    UnboundedPreceding | UnboundedFollowing => WUnbounded
    CurrentRow => WCurrent
    Preceding(e) => WPreceding(bind_expr(self, Scope::empty(), e))
    Following(e) => WFollowing(bind_expr(self, Scope::empty(), e))
  }
}

///|
/// Binds the window functions `wins` (result slots from `base`) in `scope`,
/// grouped by window definition in order of first appearance.
fn Database::compile_windows(
  self : Database,
  scope : Scope,
  wins : Array[FuncCall],
  base : Int,
) -> Array[WinGroup] raise SqlError {
  let groups : Array[WinGroup] = []
  for k, fc in wins {
    guard fc.over is Some(w) else { continue }
    let name = fc.name.to_lower()
    let n = fc.args.length()
    let is_agg = !is_window_only(name) &&
      is_aggregate_call({ ..fc, over: None, })
    if !is_agg && !is_window_only(name) {
      raise err(fc.name + "() may not be used as a window function")
    }
    if fc.distinct {
      raise err("DISTINCT is not supported for window functions")
    }
    if fc.order_by.length() > 0 {
      raise err(
        "ORDER BY may not be used with window function " + fc.name + "()",
      )
    }
    if !is_agg && fc.filter is Some(_) {
      raise err(
        "FILTER clause may only be used with aggregate window functions",
      )
    }
    let ok = match name {
      "row_number" | "rank" | "dense_rank" | "percent_rank" | "cume_dist" =>
        n == 0
      "ntile" | "first_value" | "last_value" => n == 1
      "lag" | "lead" => n >= 1 && n <= 3
      "nth_value" => n == 2
      _ => true
    }
    if !ok || (fc.star && !is_agg) {
      raise err("wrong number of arguments to function " + fc.name + "()")
    }
    let agg = if is_agg {
      Some(self.bind_aggregate(scope, { ..fc, over: None, }))
    } else {
      None
    }
    let func : WinFunc = {
      slot: base + k,
      kind: name,
      args: fc.args.map(a => bind_expr(self, scope, a)),
      filter: fc.filter.map(x => bind_expr(self, scope, x)),
      agg,
    }
    let key = "\{Repr(w)}"
    let mut placed = false
    for g in groups {
      if g.key == key {
        g.funcs.push(func)
        placed = true
        break
      }
    }
    if placed {
      continue
    }
    let partition = w.partition_by.map(e => bind_expr(self, scope, e))
    let order = w.order_by.map(t => bind_expr(self, scope, t.expr))
    let (unit, start, end, exclude) = match w.frame {
      None => ("RANGE", WUnbounded, WCurrent, "NO OTHERS")
      Some(f) => {
        let bad = match (f.start, f.end) {
          (UnboundedFollowing, _) | (_, UnboundedPreceding) => true
          (Following(_), Preceding(_) | CurrentRow) => true
          (CurrentRow, Preceding(_)) => true
          _ => false
        }
        if bad {
          raise err("unsupported frame specification")
        }
        let has_offset = (b : FrameBound) => b is (Preceding(_) | Following(_))
        if f.unit == "RANGE" &&
          (has_offset(f.start) || has_offset(f.end)) &&
          order.length() != 1 {
          raise err(
            "RANGE with offset PRECEDING/FOLLOWING requires one ORDER BY expression",
          )
        }
        (
          f.unit,
          self.bind_frame_bound(f.start),
          self.bind_frame_bound(f.end),
          f.exclude,
        )
      }
    }
    groups.push({
      key,
      partition,
      pcolls: partition.map(p => check_coll(p.collation().unwrap_or(CBinary))),
      order,
      oterms: w.order_by,
      ocolls: order.map(o => check_coll(o.collation().unwrap_or(CBinary))),
      unit,
      start,
      end,
      exclude,
      funcs: [func],
    })
  }
  groups
}

///|
/// Computes the window functions of `groups` over `rows` (each `width`
/// wide); returns the rows extended with `nwin` result slots, in the order
/// of the first window's sort.
fn run_windows(
  groups : Array[WinGroup],
  rows : Array[Array[Value]],
  width : Int,
  nwin : Int,
) -> Array[Array[Value]] raise SqlError {
  let mut cur = rows.map(r => {
    let row = Array(capacity=width + nwin)
    for i in 0..<width {
      row.push(if i < r.length() { r[i] } else { Null })
    }
    for _ in 0..<nwin {
      row.push(Null)
    }
    row
  })
  for gi = groups.length() - 1; gi >= 0; gi = gi - 1 {
    cur = window_pass(groups[gi], cur)
  }
  cur
}

///|
fn frame_offset(
  e : BExpr,
  unit : String,
  is_start : Bool,
) -> Value raise SqlError {
  let v = eval(e, [])
  let what = if is_start { "starting" } else { "ending" }
  if unit == "RANGE" {
    match v {
      Int(i) if i >= 0L => v
      Real(r) if r >= 0.0 => v
      _ => raise err("frame \{what} offset must be a non-negative number")
    }
  } else {
    match v {
      Int(i) if i >= 0L => v
      Real(r) if r >= 0.0 && r == r.floor() && r < 9.0e18 => Int(r.to_int64())
      _ => raise err("frame \{what} offset must be a non-negative integer")
    }
  }
}

///|
fn clamp_offset(v : Value) -> Int {
  match v {
    Int(i) => if i > 1000000000L { 1000000000 } else { i.to_int() }
    _ => 0
  }
}

///|
fn is_numeric_value(v : Value) -> Bool {
  v is (Int(_) | Real(_))
}

///|
/// Sorts the rows by the group's window and computes its functions.
fn window_pass(
  g : WinGroup,
  rows : Array[Array[Value]],
) -> Array[Array[Value]] raise SqlError {
  let n = rows.length()
  let pkeys = rows.map(r => g.partition.map(p => eval(p, r)))
  let okeys = rows.map(r => g.order.map(o => eval(o, r)))
  let idx = Array::makei(n, i => i)
  if g.partition.length() > 0 || g.order.length() > 0 {
    idx.sort_by((a, b) => {
      for k, c in g.pcolls {
        let x = compare_values_coll(pkeys[a][k], pkeys[b][k], c)
        if x != 0 {
          return x
        }
      }
      let c = compare_order_keys(g.oterms, g.ocolls, okeys[a], okeys[b])
      if c != 0 {
        c
      } else {
        a - b
      }
    })
  }
  let sorted = idx.map(i => rows[i])
  let keys = idx.map(i => okeys[i])
  if n == 0 {
    return sorted
  }
  // Frame offsets are evaluated once.
  let start_off = match g.start {
    WPreceding(e) | WFollowing(e) => frame_offset(e, g.unit, true)
    _ => Null
  }
  let end_off = match g.end {
    WPreceding(e) | WFollowing(e) => frame_offset(e, g.unit, false)
    _ => Null
  }
  let mut ps = 0
  while ps < n {
    let mut pe = ps + 1
    while pe < n {
      let mut same = true
      for k, c in g.pcolls {
        if compare_values_coll(pkeys[idx[ps]][k], pkeys[idx[pe]][k], c) != 0 {
          same = false
          break
        }
      }
      if !same {
        break
      }
      pe += 1
    }
    window_partition(g, sorted[ps:pe], keys[ps:pe], start_off, end_off)
    ps = pe
  }
  sorted
}

///|
/// First position in [lo, hi) of `keys` (numeric, sorted in the window's
/// direction) not before `target`, or (strict) after it.
fn range_search(
  keys : ArrayView[Array[Value]],
  lo : Int,
  hi : Int,
  target : Double,
  desc : Bool,
  strict : Bool,
) -> Int {
  let t = Real(target)
  let mut a = lo
  let mut b = hi
  while a < b {
    let mid = a + (b - a) / 2
    let c0 = compare_values(keys[mid][0], t)
    let c = if desc { -c0 } else { c0 }
    let before = if strict { c <= 0 } else { c < 0 }
    if before {
      a = mid + 1
    } else {
      b = mid
    }
  }
  a
}

///|
fn window_partition(
  g : WinGroup,
  rows : ArrayView[Array[Value]],
  keys : ArrayView[Array[Value]],
  start_off : Value,
  end_off : Value,
) -> Unit raise SqlError {
  let m = rows.length()
  // Peer groups.
  let gid = Array::make(m, 0)
  let gstart : Array[Int] = [0]
  for j in 1..<m {
    if compare_order_keys(g.oterms, g.ocolls, keys[j - 1], keys[j]) != 0 {
      gstart.push(j)
    }
    gid[j] = gstart.length() - 1
  }
  let ngroups = gstart.length()
  let gend = (x : Int) => if x + 1 < ngroups { gstart[x + 1] } else { m }
  // Numeric segment of the (single) ORDER BY key, for RANGE offsets.
  let mut ns = 0
  let mut ne = 0
  let desc = g.oterms.length() > 0 && g.oterms[0].desc
  if g.unit == "RANGE" &&
    (start_off is (Int(_) | Real(_)) || end_off is (Int(_) | Real(_))) {
    ns = m
    for j in 0..<m {
      if is_numeric_value(keys[j][0]) {
        if ns == m {
          ns = j
        }
        ne = j + 1
      }
    }
    if ns == m {
      ns = 0
      ne = 0
    }
  }
  let bound = (j : Int, b : WBound, off : Value, is_start : Bool) => {
    let gj = gid[j]
    match b {
      WUnbounded => if is_start { 0 } else { m }
      WCurrent =>
        if g.unit == "ROWS" {
          if is_start {
            j
          } else {
            j + 1
          }
        } else if is_start {
          gstart[gj]
        } else {
          gend(gj)
        }
      WPreceding(_) | WFollowing(_) => {
        let prec = b is WPreceding(_)
        match g.unit {
          "ROWS" => {
            let o = clamp_offset(off)
            let p = if prec { j - o } else { j + o }
            let p2 = if is_start { p } else { p + 1 }
            if p2 < 0 {
              0
            } else if p2 > m {
              m
            } else {
              p2
            }
          }
          "GROUPS" => {
            let o = clamp_offset(off)
            let t = if prec { gj - o } else { gj + o }
            if is_start {
              if t < 0 {
                0
              } else if t >= ngroups {
                m
              } else {
                gstart[t]
              }
            } else if t < 0 {
              0
            } else if t >= ngroups {
              m
            } else {
              gend(t)
            }
          }
          _ => {
            let v = keys[j][0]
            if !is_numeric_value(v) {
              if is_start {
                gstart[gj]
              } else {
                gend(gj)
              }
            } else {
              let d = off.as_double()
              let forward = prec == desc
              let target = if forward {
                v.as_double() + d
              } else {
                v.as_double() - d
              }
              range_search(keys, ns, ne, target, desc, !is_start)
            }
          }
        }
      }
    }
  }
  let los = Array::makei(m, j => bound(j, g.start, start_off, true))
  let his = Array::makei(m, j => bound(j, g.end, end_off, false))
  // Whether position p is excluded from the frame of row j.
  let excluded = (j : Int, p : Int) => {
    match g.exclude {
      "CURRENT ROW" => p == j
      "GROUP" => gid[p] == gid[j]
      "TIES" => p != j && gid[p] == gid[j]
      _ => false
    }
  }
  let has_exclude = g.exclude != "NO OTHERS"
  for f in g.funcs {
    let argv = (j : Int, k : Int) => eval(f.args[k], rows[j])
    match f.kind {
      "row_number" =>
        for j in 0..<m {
          rows[j][f.slot] = Int((j + 1).to_int64())
        }
      "rank" =>
        for j in 0..<m {
          rows[j][f.slot] = Int((gstart[gid[j]] + 1).to_int64())
        }
      "dense_rank" =>
        for j in 0..<m {
          rows[j][f.slot] = Int((gid[j] + 1).to_int64())
        }
      "percent_rank" =>
        for j in 0..<m {
          rows[j][f.slot] = Real(
            if m > 1 {
              gstart[gid[j]].to_double() / (m - 1).to_double()
            } else {
              0.0
            },
          )
        }
      "cume_dist" =>
        for j in 0..<m {
          rows[j][f.slot] = Real(gend(gid[j]).to_double() / m.to_double())
        }
      "ntile" => {
        let np = argv(0, 0).as_int64()
        if np <= 0L {
          raise err("argument of ntile must be a positive integer")
        }
        let total = m.to_int64()
        let size = total / np
        for j in 0..<m {
          let row = j.to_int64()
          let v = if size == 0L {
            row + 1L
          } else {
            let large = total - np * size
            let small = large * (size + 1L)
            if row < small {
              1L + row / (size + 1L)
            } else {
              1L + large + (row - small) / size
            }
          }
          rows[j][f.slot] = Int(v)
        }
      }
      "lag" | "lead" => {
        let vals = Array::makei(m, j => argv(j, 0))
        let res = Array::make(m, Null)
        for j in 0..<m {
          let off = if f.args.length() > 1 { argv(j, 1) } else { Int(1L) }
          if off is Null {
            continue
          }
          let o = off.as_int64()
          let t = if f.kind == "lag" {
            j.to_int64() - o
          } else {
            j.to_int64() + o
          }
          res[j] = if t >= 0L && t < m.to_int64() {
            vals[t.to_int()]
          } else if f.args.length() > 2 {
            argv(j, 2)
          } else {
            Null
          }
        }
        for j in 0..<m {
          rows[j][f.slot] = res[j]
        }
      }
      "first_value" | "last_value" | "nth_value" => {
        let vals = Array::makei(m, j => argv(j, 0))
        let res = Array::make(m, Null)
        for j in 0..<m {
          let lo = los[j]
          let hi = his[j]
          let mut nth = 1L
          if f.kind == "nth_value" {
            let nv = argv(j, 1)
            nth = match nv {
              Int(i) => i
              Real(r) if r == r.floor() => r.to_int64()
              _ => 0L
            }
            if nth <= 0L {
              raise err(
                "second argument to nth_value must be a positive integer",
              )
            }
          }
          if f.kind == "last_value" {
            for p = hi - 1; p >= lo; p = p - 1 {
              if !has_exclude || !excluded(j, p) {
                res[j] = vals[p]
                break
              }
            }
          } else {
            let mut cnt = 0L
            for p in lo..<hi {
              if !has_exclude || !excluded(j, p) {
                cnt += 1L
                if cnt == nth {
                  res[j] = vals[p]
                  break
                }
              }
            }
          }
        }
        for j in 0..<m {
          rows[j][f.slot] = res[j]
        }
      }
      _ => {
        guard f.agg is Some(spec) else { continue }
        let vals = Array::makei(m, j => spec.args.map(a => eval(a, rows[j])))
        let pass = Array::makei(m, j => {
          match spec.filter {
            Some(x) => eval(x, rows[j]).truth() == Some(true)
            None => true
          }
        })
        let res = Array::make(m, Null)
        let invertible = spec.kind is ("count" | "sum" | "total" | "avg")
        if has_exclude || (!invertible && !(g.start is WUnbounded)) {
          for j in 0..<m {
            let st = AggState::new()
            for p in los[j]..<his[j] {
              if pass[p] && (!has_exclude || !excluded(j, p)) {
                agg_step(spec, st, vals[p]) |> ignore
              }
            }
            res[j] = agg_finalize(spec, st)
          }
        } else {
          let st = AggState::new()
          let mut clo = 0
          let mut chi = 0
          for j in 0..<m {
            let lo = los[j]
            let hi = his[j]
            while clo < lo && clo < chi {
              if pass[clo] {
                agg_inverse(spec, st, vals[clo])
              }
              clo += 1
            }
            if clo < lo {
              clo = lo
              if chi < lo {
                chi = lo
              }
            }
            while chi < hi {
              if pass[chi] {
                agg_step(spec, st, vals[chi]) |> ignore
              }
              chi += 1
            }
            res[j] = agg_finalize(spec, st)
          }
        }
        for j in 0..<m {
          rows[j][f.slot] = res[j]
        }
      }
    }
  }
}

///|
/// Removes one row's argument values from an invertible aggregate.
fn agg_inverse(spec : AggSpec, st : AggState, args : Array[Value]) -> Unit {
  match spec.kind {
    "count" => if args.length() == 0 || !(args[0] is Null) { st.count -= 1L }
    _ => {
      let v = args[0]
      let (is_int, ival, rval) = match v {
        Null => return
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
      st.count -= 1L
      if !st.approx {
        let x = st.isum
        let r = x - ival
        if ((x ^ ival) & (x ^ r)) < 0L {
          st.ovrfl = true
          kbn_init(st, x)
          st.approx = true
          kbn_step_int(st, -ival)
        } else {
          st.isum = r
        }
      } else if is_int {
        if ival == @int64.MIN_VALUE {
          kbn_step_int(st, @int64.MAX_VALUE)
          kbn_step_int(st, 1L)
        } else {
          kbn_step_int(st, -ival)
        }
      } else {
        kbn_step(st, -rval)
      }
    }
  }
}
