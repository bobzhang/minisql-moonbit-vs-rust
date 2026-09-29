// Window functions: extraction from expressions, window definitions and
// frames, and evaluation over the rows of a query.

///|
let window_arity : Map[String, (Int, Int)] = {
  "row_number": (0, 0),
  "rank": (0, 0),
  "dense_rank": (0, 0),
  "percent_rank": (0, 0),
  "cume_dist": (0, 0),
  "ntile": (1, 1),
  "lag": (1, 3),
  "lead": (1, 3),
  "first_value": (1, 1),
  "last_value": (1, 1),
  "nth_value": (2, 2),
}

///|
fn is_window_only(name : String) -> Bool {
  window_arity.contains(name)
}

///|
/// A distinct PARTITION BY / ORDER BY combination (one sorting pass).
priv struct WinSort {
  partition : Array[Expr]
  pcolls : Array[String]
  order : Array[SortKey]
}

///|
priv struct WinInfo {
  name : String
  args : Array[Expr] // bound
  filter : Expr?
  sort : Int // index into WinCtx::sorts
  frame : Frame
  start_n : Value // evaluated offset of an `N PRECEDING/FOLLOWING` start
  end_n : Value
  coll : String // collation of the first argument
}

///|
priv struct WinCtx {
  base : Int // slot of the first window result
  wins : Array[WinInfo]
  sorts : Array[WinSort]
  scope : Scope
  named : Array[(String, WindowSpec)]
  /// Aggregates of the query (window definitions may use them).
  mut agg : AggCtx?
}

///|
/// Number of window function calls in an unbound expression.
fn count_winfuncs(e : Expr) -> Int {
  let mut n = if e is WinFunc(_, _) { 1 } else { 0 }
  for c in expr_children(e) {
    n += count_winfuncs(c)
  }
  n
}

///|
/// Resolves references to named windows.
fn resolve_window(
  spec : WindowSpec,
  named : Array[(String, WindowSpec)],
  depth? : Int = 0,
) -> WindowSpec raise SqlError {
  guard spec.base is Some(b) else { return spec }
  let mut found : WindowSpec? = None
  for w in named {
    if w.0.equal_ignore_ascii_case(b) {
      found = Some(w.1)
      break
    }
  }
  guard found is Some(f) && depth < 50 else {
    raise SqlError("no such window: \{b}")
  }
  let base = resolve_window(f, named, depth=depth + 1)
  if spec.named_only {
    return base
  }
  if spec.partition.length() > 0 {
    raise SqlError("cannot override PARTITION clause of window \{b}")
  }
  if base.order.length() > 0 && spec.order.length() > 0 {
    raise SqlError("cannot override ORDER BY clause of window \{b}")
  }
  if base.frame is Some(_) {
    raise SqlError("cannot override frame specification of window \{b}")
  }
  {
    base: None,
    partition: base.partition,
    order: if spec.order.length() > 0 {
      spec.order
    } else {
      base.order
    },
    frame: spec.frame,
    named_only: false,
  }
}

///|
/// Evaluates a frame offset (a constant expression).
fn frame_offset(
  e : Expr,
  unit : FrameUnit,
  what : String,
) -> Value raise SqlError {
  let v0 = eval_const(e)
  let v = match v0 {
    Text(s) => parse_numeric_text(s).unwrap_or(v0)
    _ => v0
  }
  if unit is FRange {
    match v {
      Int(i) if i >= 0L => v
      Real(d) if d >= 0.0 => v
      _ => raise SqlError("frame \{what} offset must be a non-negative number")
    }
  } else {
    match v {
      Int(i) if i >= 0L => v
      Real(d) if d >= 0.0 && real_to_int_exact(d) is Some(i) => Int(i)
      _ => raise SqlError("frame \{what} offset must be a non-negative integer")
    }
  }
}

///|
fn bound_rank(b : FrameBound) -> Int {
  match b {
    UnboundedPreceding => 0
    Preceding(_) => 1
    CurrentRow => 2
    Following(_) => 3
    UnboundedFollowing => 4
  }
}

///|
fn bind_sort_term(t : OrderTerm, scope : Scope) -> SortKey raise SqlError {
  let mut term = t.expr
  let mut explicit : String? = None
  while term is Collate(inner, c) {
    if explicit is None {
      explicit = Some(check_collation(c))
    }
    term = inner
  }
  make_sort_key(bind_expr(term, Some(scope)), explicit, -1, t)
}

///|
fn same_sort(a : WinSort, b : WinSort) -> Bool {
  a.partition.length() == b.partition.length() &&
  a.order.length() == b.order.length() &&
  a.partition.iter().zip(b.partition.iter()).all(p => expr_equal(p.0, p.1)) &&
  a.pcolls.iter().zip(b.pcolls.iter()).all(p => p.0 == p.1) &&
  a.order
  .iter()
  .zip(b.order.iter())
  .all(p => {
    expr_equal(p.0.expr, p.1.expr) &&
    p.0.desc == p.1.desc &&
    p.0.nulls == p.1.nulls &&
    p.0.coll == p.1.coll
  })
}

///|
/// Replaces window function calls in an expression (whose aggregates are
/// already extracted) by references to their result slots.
fn extract_wins(e : Expr, ctx : WinCtx) -> Expr raise SqlError {
  match e {
    WinFunc(func, spec0) => {
      guard func is Func(name~, args~, distinct~, star~, filter~, order~) else {
        raise SqlError("bad window function")
      }
      ignore(star)
      let n = args.length()
      let is_agg = is_aggregate_call(name, n) || aggregate_arity.contains(name)
      if is_window_only(name) {
        let (lo, hi) = window_arity[name]
        if n < lo || n > hi {
          raise SqlError("wrong number of arguments to function \{name}()")
        }
        if filter is Some(_) {
          raise SqlError(
            "FILTER clause may only be used with aggregate window functions",
          )
        }
      } else if is_agg {
        let (lo, hi) = aggregate_arity[name]
        if n < lo || n > hi {
          raise SqlError("wrong number of arguments to function \{name}()")
        }
      } else if function_arity.contains(name) {
        raise SqlError("\{name}() may not be used as a window function")
      } else {
        raise SqlError("no such function: \{name}")
      }
      if distinct {
        raise SqlError("DISTINCT is not supported for window functions")
      }
      if order.length() > 0 {
        raise SqlError("ORDER BY may not be used with non-aggregate \{name}()")
      }
      let spec = match (spec0.base, ctx.agg) {
        (Some(_), Some(a)) => {
          let s = resolve_window(spec0, ctx.named)
          {
            ..s,
            partition: s.partition.map(x => extract_aggs(x, a)),
            order: s.order.map(t => { ..t, expr: extract_aggs(t.expr, a), }),
          }
        }
        _ => resolve_window(spec0, ctx.named)
      }
      let scope = ctx.scope
      let bargs = args.map(a => bind_expr(a, Some(scope)))
      let bfilter = map_opt(filter, x => bind_expr(x, Some(scope)))
      let partition = spec.partition.map(x => bind_expr(x, Some(scope)))
      let sort : WinSort = {
        partition,
        pcolls: partition.map(x => {
          match expr_coll(x) {
            Some((c, _)) => c
            None => "BINARY"
          }
        }),
        order: spec.order.map(t => bind_sort_term(t, scope)),
      }
      let mut si = -1
      for i, s in ctx.sorts {
        if same_sort(s, sort) {
          si = i
          break
        }
      }
      if si < 0 {
        si = ctx.sorts.length()
        ctx.sorts.push(sort)
      }
      let frame : Frame = match spec.frame {
        Some(f) => f
        None =>
          {
            unit: FRange,
            start: UnboundedPreceding,
            end: CurrentRow,
            exclude: ExNoOthers,
          }
      }
      let rs = bound_rank(frame.start)
      let re = bound_rank(frame.end)
      if rs == 4 || re == 0 || (rs == 2 && re == 1) || (rs == 3 && re <= 2) {
        raise SqlError("unsupported frame specification")
      }
      if frame.unit is FRange &&
        (
          frame.start is (Preceding(_) | Following(_)) ||
          frame.end is (Preceding(_) | Following(_))
        ) &&
        sort.order.length() != 1 {
        raise SqlError(
          "RANGE with offset PRECEDING/FOLLOWING requires exactly one ORDER BY term",
        )
      }
      let start_n = match frame.start {
        Preceding(x) | Following(x) => frame_offset(x, frame.unit, "starting")
        _ => Null
      }
      let end_n = match frame.end {
        Preceding(x) | Following(x) => frame_offset(x, frame.unit, "ending")
        _ => Null
      }
      let coll = if n > 0 {
        match expr_coll(bargs[0]) {
          Some((c, _)) => c
          None => "BINARY"
        }
      } else {
        "BINARY"
      }
      let idx = ctx.base + ctx.wins.length()
      ctx.wins.push({
        name,
        args: bargs,
        filter: bfilter,
        sort: si,
        frame,
        start_n,
        end_n,
        coll,
      })
      AggRef(depth=0, idx~, coll=None)
    }
    _ => e.map_children(x => extract_wins(x, ctx))
  }
}

// ---------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------

///|
/// Incremental state of an aggregate over a sliding frame.
priv struct WinAgg {
  name : String
  coll : String
  mut count : Int64
  sum : SumCtx
  // min/max: positions of candidate values (monotonic deque)
  mm : Array[Int]
  mut mm_head : Int
  // group_concat: (position) of the non-NULL values in the frame
  gc : Array[Int]
  mut gc_head : Int
}

///|
fn WinAgg::new(name : String, coll : String) -> WinAgg {
  {
    name,
    coll,
    count: 0L,
    sum: {
      r_sum: 0.0,
      r_err: 0.0,
      i_sum: 0L,
      cnt: 0L,
      approx: false,
      ovrfl: false,
    },
    mm: [],
    mm_head: 0,
    gc: [],
    gc_head: 0,
  }
}

///|
fn SumCtx::remove(self : SumCtx, v : Value) -> Unit {
  let num = match v {
    Null => return
    Text(s) => parse_numeric_text(s).unwrap_or(v)
    _ => v
  }
  self.cnt -= 1L
  if !self.approx {
    match sub_checked(self.i_sum, value_to_int64(num)) {
      Some(r) => self.i_sum = r
      None => {
        self.ovrfl = true
        self.approx = true
      }
    }
  } else {
    match num {
      Int(i) =>
        if i != @int64.MIN_VALUE {
          self.kbn_step_int(-i)
        } else {
          self.kbn_step_int(@int64.MAX_VALUE)
          self.kbn_step_int(1L)
        }
      _ => self.kbn_step(-value_to_double(num))
    }
  }
}

///|
/// Argument values of the rows of a partition for one function.
priv struct PartVals {
  vals : Array[Array[Value]]
  ok : Array[Bool] // FILTER result
}

///|
fn WinAgg::add(self : WinAgg, pv : PartVals, p : Int) -> Unit {
  if !pv.ok[p] {
    return
  }
  let vs = pv.vals[p]
  match self.name {
    "count" => if vs.length() == 0 || !(vs[0] is Null) { self.count += 1L }
    "sum" | "total" | "avg" => self.sum.add(vs[0])
    "min" | "max" => {
      let v = vs[0]
      if v is Null {
        return
      }
      let is_max = self.name == "max"
      while self.mm.length() > self.mm_head {
        let b = pv.vals[self.mm[self.mm.length() - 1]][0]
        let c = value_compare_coll(b, v, self.coll)
        if (is_max && c < 0) || (!is_max && c > 0) {
          ignore(self.mm.pop())
        } else {
          break
        }
      }
      self.mm.push(p)
    }
    _ => if !(vs[0] is Null) { self.gc.push(p) }
  }
}

///|
fn WinAgg::remove(self : WinAgg, pv : PartVals, p : Int) -> Unit {
  if !pv.ok[p] {
    return
  }
  let vs = pv.vals[p]
  match self.name {
    "count" => if vs.length() == 0 || !(vs[0] is Null) { self.count -= 1L }
    "sum" | "total" | "avg" => self.sum.remove(vs[0])
    "min" | "max" =>
      if self.mm.length() > self.mm_head && self.mm[self.mm_head] == p {
        self.mm_head += 1
      }
    _ =>
      if self.gc.length() > self.gc_head && self.gc[self.gc_head] == p {
        self.gc_head += 1
      }
  }
}

///|
fn WinAgg::value(self : WinAgg, pv : PartVals) -> Value raise SqlError {
  match self.name {
    "count" => Int(self.count)
    "sum" => {
      let s = self.sum
      if s.cnt <= 0L {
        Null
      } else if s.approx {
        if s.ovrfl {
          raise SqlError("integer overflow")
        }
        real_result(s.approx_value())
      } else {
        Int(s.i_sum)
      }
    }
    "total" => Real(self.sum.approx_value())
    "avg" =>
      if self.sum.cnt <= 0L {
        Null
      } else {
        real_result(self.sum.approx_value() / self.sum.cnt.to_double())
      }
    "min" | "max" =>
      if self.mm.length() > self.mm_head {
        pv.vals[self.mm[self.mm_head]][0]
      } else {
        Null
      }
    _ => {
      if self.gc.length() <= self.gc_head {
        return Null
      }
      let sb = StringBuilder()
      for i in self.gc_head..<self.gc.length() {
        let vs = pv.vals[self.gc[i]]
        if i > self.gc_head {
          if vs.length() > 1 {
            if !(vs[1] is Null) {
              sb.write_string(vs[1].to_text())
            }
          } else {
            sb.write_char(',')
          }
        }
        sb.write_string(vs[0].to_text())
      }
      Text(sb.to_string())
    }
  }
}

///|
/// Peer-group structure of a sorted partition.
priv struct Peers {
  gid : Array[Int] // group index of each position
  first : Array[Int] // first position of each group
  last : Array[Int] // last position of each group
}

///|
/// First position in [lo, hi) where `pred` holds (`pred` is monotonic:
/// false then true); `hi` if none.
fn lower_pos(lo : Int, hi : Int, pred : (Int) -> Bool) -> Int {
  let mut a = lo
  let mut b = hi
  while a < b {
    let m = a + (b - a) / 2
    if pred(m) {
      b = m
    } else {
      a = m + 1
    }
  }
  a
}

///|
/// Inclusive frame bounds [fs, fe] (positions in the partition) of the row
/// at position `pos`.
fn frame_bounds(
  w : WinInfo,
  key : SortKey?,
  okeys : Array[Value],
  peers : Peers,
  pos : Int,
  n : Int,
) -> (Int, Int) {
  let g = peers.gid[pos]
  let ng = peers.first.length()
  let off = fn(v : Value) -> Int64 {
    match v {
      Int(i) => i
      _ => value_to_int64(v)
    }
  }
  let range_bound = fn(v : Value, sign : Int, is_start : Bool) -> Int {
    // sign: -1 for PRECEDING, +1 for FOLLOWING (in sort direction)
    guard key is Some(k) else { return if is_start { 0 } else { n - 1 } }
    let cur = okeys[pos]
    if cur is Null {
      return if is_start { peers.first[g] } else { peers.last[g] }
    }
    let delta = if k.desc { -sign } else { sign }
    // text and blob values are not offset (their frame is the peer group)
    let target = if cur is (Text(_) | Blob(_)) {
      cur
    } else if delta < 0 {
      arith(Sub, cur, v)
    } else {
      arith(Add, cur, v)
    }
    let cmp = fn(p : Int) -> Int {
      compare_sort_keys([k], [okeys[p]], [target])
    }
    if is_start {
      lower_pos(0, n, p => cmp(p) >= 0)
    } else {
      lower_pos(0, n, p => cmp(p) > 0) - 1
    }
  }
  let fs = match w.frame.start {
    UnboundedPreceding => 0
    CurrentRow =>
      match w.frame.unit {
        FRows => pos
        _ => peers.first[g]
      }
    Preceding(_) =>
      match w.frame.unit {
        FRows => {
          let o = off(w.start_n)
          if o > pos.to_int64() {
            0
          } else {
            pos - o.to_int()
          }
        }
        FGroups => {
          let o = off(w.start_n)
          if o > g.to_int64() {
            0
          } else {
            peers.first[g - o.to_int()]
          }
        }
        FRange => range_bound(w.start_n, -1, true)
      }
    Following(_) =>
      match w.frame.unit {
        FRows => {
          let o = off(w.start_n)
          if o >= (n - pos).to_int64() {
            n
          } else {
            pos + o.to_int()
          }
        }
        FGroups => {
          let o = off(w.start_n)
          if o >= (ng - g).to_int64() {
            n
          } else {
            peers.first[g + o.to_int()]
          }
        }
        FRange => range_bound(w.start_n, 1, true)
      }
    UnboundedFollowing => n
  }
  let fe = match w.frame.end {
    UnboundedFollowing => n - 1
    CurrentRow =>
      match w.frame.unit {
        FRows => pos
        _ => peers.last[g]
      }
    Preceding(_) =>
      match w.frame.unit {
        FRows => {
          let o = off(w.end_n)
          if o > pos.to_int64() {
            -1
          } else {
            pos - o.to_int()
          }
        }
        FGroups => {
          let o = off(w.end_n)
          if o > g.to_int64() {
            -1
          } else {
            peers.last[g - o.to_int()]
          }
        }
        FRange => range_bound(w.end_n, -1, false)
      }
    Following(_) =>
      match w.frame.unit {
        FRows => {
          let o = off(w.end_n)
          if o >= (n - 1 - pos).to_int64() {
            n - 1
          } else {
            pos + o.to_int()
          }
        }
        FGroups => {
          let o = off(w.end_n)
          if o >= (ng - 1 - g).to_int64() {
            n - 1
          } else {
            peers.last[g + o.to_int()]
          }
        }
        FRange => range_bound(w.end_n, 1, false)
      }
    UnboundedPreceding => -1
  }
  (fs, fe)
}

///|
/// Positions of the frame [fs, fe] without the excluded rows.
fn frame_positions(
  w : WinInfo,
  peers : Peers,
  pos : Int,
  fs : Int,
  fe : Int,
) -> Array[Int] {
  let out : Array[Int] = []
  let g = peers.gid[pos]
  for p in fs..<=fe {
    let skip = match w.frame.exclude {
      ExNoOthers => false
      ExCurrentRow => p == pos
      ExGroup => peers.gid[p] == g
      ExTies => p != pos && peers.gid[p] == g
    }
    if !skip {
      out.push(p)
    }
  }
  out
}

///|
fn positive_int(v : Value) -> Int64? {
  let num = match v {
    Text(s) => parse_numeric_text(s).unwrap_or(v)
    _ => v
  }
  match num {
    Int(i) if i > 0L => Some(i)
    Real(d) =>
      match real_to_int_exact(d) {
        Some(i) if i > 0L => Some(i)
        _ => None
      }
    _ => None
  }
}

///|
/// Computes the window functions of `ctx` over `rows` (each row has room
/// for the results), reordering `rows` as SQLite's sorting passes do.
fn compute_windows(
  ctx : WinCtx,
  rows : Array[Array[Value]],
  penv : Env,
) -> Unit raise SqlError {
  let parent = Some(penv)
  // sorting passes in reverse order of first use
  for si = ctx.sorts.length() - 1; si >= 0; si = si - 1 {
    let sort = ctx.sorts[si]
    let nrows = rows.length()
    let pkeys = rows.map(r => {
      let env : Env = { row: r, parent, }
      sort.partition.map(x => eval(x, env))
    })
    let okeys = rows.map(r => {
      let env : Env = { row: r, parent, }
      sort.order.map(k => eval(k.expr, env))
    })
    let cmp_part = fn(a : Int, b : Int) -> Int {
      let ka = pkeys[a]
      let kb = pkeys[b]
      for j in 0..<ka.length() {
        let c = value_compare_coll(ka[j], kb[j], sort.pcolls[j])
        if c != 0 {
          return c
        }
      }
      0
    }
    let perm = Array::makei(nrows, i => i)
    if sort.partition.length() > 0 || sort.order.length() > 0 {
      perm.sort_by((a, b) => {
        let c = cmp_part(a, b)
        if c != 0 {
          return c
        }
        let c2 = compare_sort_keys(sort.order, okeys[a], okeys[b])
        if c2 != 0 {
          c2
        } else {
          a - b
        }
      })
    }
    let sorted_rows = perm.map(i => rows[i])
    let sorted_okeys = perm.map(i => okeys[i])
    for i in 0..<nrows {
      rows[i] = sorted_rows[i]
    }
    let wins : Array[(Int, WinInfo)] = []
    for k, w in ctx.wins {
      if w.sort == si {
        wins.push((k, w))
      }
    }
    // partitions
    let mut ps = 0
    while ps < nrows {
      let mut pe = ps + 1
      while pe < nrows && cmp_part(perm[ps], perm[pe]) == 0 {
        pe += 1
      }
      compute_partition(ctx, wins, sort, rows, sorted_okeys, ps, pe, penv)
      ps = pe
    }
  }
}

///|
fn compute_partition(
  ctx : WinCtx,
  wins : Array[(Int, WinInfo)],
  sort : WinSort,
  rows : Array[Array[Value]],
  okeys : Array[Array[Value]],
  ps : Int,
  pe : Int,
  penv : Env,
) -> Unit raise SqlError {
  let parent = Some(penv)
  let n = pe - ps
  let env_at = fn(p : Int) -> Env { { row: rows[ps + p], parent, } }
  // peer groups
  let gid = Array::make(n, 0)
  let first : Array[Int] = []
  let last : Array[Int] = []
  for p in 0..<n {
    if p == 0 ||
      compare_sort_keys(sort.order, okeys[ps + p - 1], okeys[ps + p]) != 0 {
      if p > 0 {
        last.push(p - 1)
      }
      first.push(p)
    }
    gid[p] = first.length() - 1
  }
  if n > 0 {
    last.push(n - 1)
  }
  let peers : Peers = { gid, first, last, }
  let key : SortKey? = if sort.order.length() == 1 {
    Some(sort.order[0])
  } else {
    None
  }
  let pokeys = Array::makei(n, p => {
    if okeys[ps + p].length() > 0 {
      okeys[ps + p][0]
    } else {
      Null
    }
  })
  for kw in wins {
    let (k, w) = kw
    let slot = ctx.base + k
    let set = fn(p : Int, v : Value) { rows[ps + p][slot] = v }
    match w.name {
      "row_number" =>
        for p in 0..<n {
          set(p, Int((p + 1).to_int64()))
        }
      "rank" =>
        for p in 0..<n {
          set(p, Int((first[gid[p]] + 1).to_int64()))
        }
      "dense_rank" =>
        for p in 0..<n {
          set(p, Int((gid[p] + 1).to_int64()))
        }
      "percent_rank" =>
        for p in 0..<n {
          let v = if n > 1 {
            first[gid[p]].to_double() / (n - 1).to_double()
          } else {
            0.0
          }
          set(p, Real(v))
        }
      "cume_dist" =>
        for p in 0..<n {
          set(p, Real((last[gid[p]] + 1).to_double() / n.to_double()))
        }
      "ntile" =>
        for p in 0..<n {
          let a = eval(w.args[0], env_at(p))
          let nt = if a is Null { 0L } else { value_to_int64(a) }
          if nt <= 0L {
            raise SqlError("argument of ntile must be a positive integer")
          }
          let total = n.to_int64()
          let size = total / nt
          let v = if size == 0L {
            p.to_int64() + 1L
          } else {
            let large = total - nt * size
            let small = large * (size + 1L)
            let row = p.to_int64()
            if row < small {
              1L + row / (size + 1L)
            } else {
              1L + large + (row - small) / size
            }
          }
          set(p, Int(v))
        }
      "lag" | "lead" =>
        for p in 0..<n {
          let env = env_at(p)
          // SQLite seeks the target row in its buffer of the partition:
          // a non-integral offset finds nothing, and a lag() looking
          // ahead only finds the next row
          let mut o : Int64? = Some(1L)
          if w.args.length() > 1 {
            let ov = eval(w.args[1], env)
            let num = match ov {
              Text(s) => parse_numeric_text(s).unwrap_or(Int(0L))
              Blob(_) => Int(0L)
              _ => ov
            }
            o = match num {
              Int(i) => Some(i)
              Real(d) => real_to_int_exact(d)
              _ => None
            }
          }
          let t = match o {
            None => -1L
            Some(o) if w.name == "lag" =>
              if o < -1L {
                -1L
              } else {
                p.to_int64() - o
              }
            Some(o) => p.to_int64() + o
          }
          let v = if t >= 0L && t < n.to_int64() {
            eval(w.args[0], env_at(t.to_int()))
          } else if w.args.length() > 2 {
            eval(w.args[2], env)
          } else {
            Null
          }
          set(p, v)
        }
      "first_value" | "last_value" | "nth_value" => {
        let vals = Array::makei(n, p => eval(w.args[0], env_at(p)))
        for p in 0..<n {
          let mut nth = 1L
          if w.name == "nth_value" {
            match positive_int(eval(w.args[1], env_at(p))) {
              Some(i) => nth = i
              None =>
                raise SqlError(
                  "second argument to nth_value must be a positive integer",
                )
            }
          }
          let (fs, fe) = frame_bounds(w, key, pokeys, peers, p, n)
          let v = if w.frame.exclude is ExNoOthers {
            if fs > fe {
              Null
            } else if w.name == "last_value" {
              vals[fe]
            } else if nth - 1L <= (fe - fs).to_int64() {
              vals[fs + (nth - 1L).to_int()]
            } else {
              Null
            }
          } else {
            let ps_ = frame_positions(w, peers, p, fs, fe)
            if ps_.length() == 0 {
              Null
            } else if w.name == "last_value" {
              vals[ps_[ps_.length() - 1]]
            } else if nth <= ps_.length().to_int64() {
              vals[ps_[(nth - 1L).to_int()]]
            } else {
              Null
            }
          }
          set(p, v)
        }
      }
      _ => {
        // aggregate over the frame
        let pv : PartVals = {
          vals: Array::makei(n, p => {
            let env = env_at(p)
            w.args.map(a => eval(a, env))
          }),
          ok: Array::makei(n, _ => true),
        }
        if w.filter is Some(f) {
          for p in 0..<n {
            pv.ok[p] = truthy(eval(f, env_at(p))) == Some(true)
          }
        }
        if w.frame.exclude is ExNoOthers {
          let acc = WinAgg::new(w.name, w.coll)
          let mut cs = 0
          let mut ce = -1
          for p in 0..<n {
            let (fs, fe) = frame_bounds(w, key, pokeys, peers, p, n)
            while cs < fs {
              if cs <= ce {
                acc.remove(pv, cs)
              }
              cs += 1
            }
            if ce < cs - 1 {
              ce = cs - 1
            }
            while ce < fe {
              ce += 1
              acc.add(pv, ce)
            }
            set(p, acc.value(pv))
          }
        } else {
          for p in 0..<n {
            let (fs, fe) = frame_bounds(w, key, pokeys, peers, p, n)
            let acc = WinAgg::new(w.name, w.coll)
            for q in frame_positions(w, peers, p, fs, fe) {
              acc.add(pv, q)
            }
            set(p, acc.value(pv))
          }
        }
      }
    }
  }
}
