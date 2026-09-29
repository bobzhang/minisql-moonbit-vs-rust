// Window functions: binding and evaluation.

///|
/// One bound window function call.
priv struct WinFn {
  name : String // upper case
  args : Array[Expr]
  agg : AggSpec? // aggregate used as a window function
  partition : Array[Expr]
  pcolls : Array[Coll]
  order : Array[AggOrder]
  frame : Frame // offsets bound, evaluated once per run
}

///|
/// Window functions of a SELECT and its named window definitions.
priv struct WinCtx {
  fns : Array[WinFn]
  base : Ref[Int] // slot of the first window result in the extended row
  defs : Array[(String, WinDef)]
}

///|
fn contains_win(e : Expr) -> Bool {
  match e {
    WinRef(_, _) => true
    _ => expr_children(e).any(contains_win)
  }
}

///|
/// Argument count range of a built-in window-only function.
fn window_only_arity(name : String) -> (Int, Int)? {
  match name {
    "ROW_NUMBER" | "RANK" | "DENSE_RANK" | "PERCENT_RANK" | "CUME_DIST" =>
      Some((0, 0))
    "NTILE" => Some((1, 1))
    "LAG" | "LEAD" => Some((1, 3))
    "FIRST_VALUE" | "LAST_VALUE" => Some((1, 1))
    "NTH_VALUE" => Some((2, 2))
    _ => None
  }
}

///|
fn lookup_window(
  name : String,
  defs : Array[(String, WinDef)],
  depth : Int,
) -> WinDef raise SqlError {
  for i = defs.length() - 1; i >= 0; i = i - 1 {
    if same_name(defs[i].0, name) {
      return merge_windef(defs[i].1, defs, depth + 1)
    }
  }
  raise sql_err("no such window: \{name}")
}

///|
/// Resolve the base window of a definition (`OVER (w ORDER BY ...)`).
fn merge_windef(
  d : WinDef,
  defs : Array[(String, WinDef)],
  depth : Int,
) -> WinDef raise SqlError {
  match d.base {
    None => d
    Some(b) => {
      if depth > 64 {
        raise sql_err("no such window: \{b}")
      }
      let base = lookup_window(b, defs, depth)
      if d.partition.length() > 0 {
        raise sql_err("cannot override PARTITION clause of window: \{b}")
      }
      if d.order.length() > 0 && base.order.length() > 0 {
        raise sql_err("cannot override ORDER BY clause of window: \{b}")
      }
      if base.frame is Some(_) {
        raise sql_err("cannot override frame specification of window: \{b}")
      }
      {
        base: None,
        partition: base.partition,
        order: if d.order.length() > 0 {
          d.order
        } else {
          base.order
        },
        frame: d.frame,
      }
    }
  }
}

///|
fn Scope::bind_window(self : Scope, w : WinAst) -> Expr raise SqlError {
  let name = w.name
  let lname = name.to_lower()
  guard self.win is Some(ctx) else {
    raise sql_err("misuse of window function \{lname}()")
  }
  let n = w.args.length()
  let only = window_only_arity(name)
  let is_agg = only is None && is_aggregate_call(name, n)
  if only is None && !is_agg {
    if func_arity(name) is Some(_) {
      raise sql_err("\{lname}() may not be used as a window function")
    }
    raise sql_err("no such function: \{lname}")
  }
  if w.distinct {
    raise sql_err("DISTINCT is not supported for window functions")
  }
  if w.order.length() > 0 {
    raise sql_err("ORDER BY may not be used with non-aggregate \{lname}()")
  }
  match only {
    Some((lo, hi)) => {
      if w.star || n < lo || n > hi {
        raise sql_err("wrong number of arguments to function \{lname}()")
      }
      if w.filter is Some(_) {
        raise sql_err(
          "FILTER clause may only be used with aggregate window functions",
        )
      }
    }
    None => {
      let (lo, hi) = match name {
        "COUNT" => (0, 1)
        "GROUP_CONCAT" => (1, 2)
        "STRING_AGG" => (2, 2)
        _ => (1, 1)
      }
      if (w.star && name != "COUNT") || (w.star && n > 0) || n < lo || n > hi {
        raise sql_err("wrong number of arguments to function \{lname}()")
      }
    }
  }
  let def = match w.over {
    OverName(wn) => lookup_window(wn, ctx.defs, 0)
    OverDef(d) => merge_windef(d, ctx.defs, 0)
  }
  let inner = { ..self, win: None, }
  let args = w.args.map(a => inner.bind(a))
  let agg : AggSpec? = if is_agg {
    Some({
      name,
      args,
      star: w.star || n == 0,
      distinct: false,
      filter: match w.filter {
        Some(f) => Some(inner.bind(f))
        None => None
      },
      order: [],
      coll: if args.length() > 0 {
        expr_coll(args[0]).unwrap_or(CBinary)
      } else {
        CBinary
      },
    })
  } else {
    None
  }
  let partition = def.partition.map(e => inner.bind(e))
  let order : Array[AggOrder] = []
  for t in def.order {
    let k = inner.bind(t.expr)
    order.push({
      key: k,
      desc: t.desc,
      nulls_first: t.nulls_first.unwrap_or(!t.desc),
      coll: expr_coll(k).unwrap_or(CBinary),
    })
  }
  let es = empty_scope()
  let bind_bound = (b : FrameBound) => {
    match b {
      Pre(e) => Pre(es.bind(e))
      Fol(e) => Fol(es.bind(e))
      _ => b
    }
  }
  let frame : Frame = match def.frame {
    None => { unit: FRange, start: UnbPre, end: CurRow, exclude: ExNone, }
    Some(f) => {
      let has_off = f.start is (Pre(_) | Fol(_)) || f.end is (Pre(_) | Fol(_))
      if f.unit == FRange && has_off && order.length() != 1 {
        raise sql_err(
          "RANGE with offset PRECEDING/FOLLOWING requires one ORDER BY expression",
        )
      }
      { ..f, start: bind_bound(f.start), end: bind_bound(f.end), }
    }
  }
  let idx = ctx.fns.length()
  ctx.fns.push({
    name,
    args,
    agg,
    partition,
    pcolls: partition.map(e => expr_coll(e).unwrap_or(CBinary)),
    order,
    frame,
  })
  WinRef(idx, ctx.base)
}

// ---------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------

///|
/// Undo `add_row` (sliding frames) for count, sum, total and avg.
fn Acc::remove_row(self : Acc, row : Array[Value]) -> Unit raise SqlError {
  let spec = self.spec
  if spec.filter is Some(f) && !(eval(f, row).truth() is Some(true)) {
    return
  }
  if spec.star {
    self.cnt -= 1L
    return
  }
  let v0 = eval(spec.args[0], row)
  if spec.name == "COUNT" {
    if !(v0 is Null) {
      self.cnt -= 1L
    }
    return
  }
  let v = match v0 {
    Text(_) => apply_affinity(v0, AffNumeric)
    _ => v0
  }
  if v is Null {
    return
  }
  self.cnt -= 1L
  if !self.approx {
    if v is Int(i) {
      let r = self.isum - i
      if ((self.isum ^ i) & (self.isum ^ r)) < 0L {
        self.kbn_init(self.isum)
        self.kbn_step_int(-i)
        self.ovrfl = true
        self.approx = true
      } else {
        self.isum = r
      }
    }
  } else {
    match v {
      Int(i) =>
        if i != @int64.MIN_VALUE {
          self.kbn_step_int(-i)
        } else {
          self.kbn_step_int(@int64.MAX_VALUE)
          self.kbn_step_int(1L)
        }
      _ => self.kbn_step(-v.to_double())
    }
  }
}

///|
fn can_remove(name : String) -> Bool {
  name is ("COUNT" | "SUM" | "TOTAL" | "AVG")
}

///|
/// Validate a ROWS / GROUPS offset (non-negative integer).
fn int_offset(e : Expr, start : Bool) -> Int64 raise SqlError {
  let v = eval(e, [])
  let v = match v {
    Text(_) => apply_affinity(v, AffNumeric)
    _ => v
  }
  let which = if start { "starting" } else { "ending" }
  let err = sql_err("frame \{which} offset must be a non-negative integer")
  match v {
    Int(i) => if i < 0L { raise err } else { i }
    Real(d) =>
      match real_to_int_exact(d) {
        Some(i) if i >= 0L => i
        _ => raise err
      }
    _ => raise err
  }
}

///|
/// Validate a RANGE offset (non-negative number).
fn num_offset(e : Expr, start : Bool) -> Value raise SqlError {
  let v = eval(e, [])
  let v = match v {
    Text(_) => apply_affinity(v, AffNumeric)
    _ => v
  }
  let which = if start { "starting" } else { "ending" }
  let err = sql_err("frame \{which} offset must be a non-negative number")
  match v {
    Int(i) => if i < 0L { raise err } else { v }
    Real(d) => if d < 0.0 || d.is_nan() { raise err } else { v }
    _ => raise err
  }
}

///|
fn clamp_pos(x : Int64, m : Int) -> Int {
  if x < 0L {
    0
  } else if x > m.to_int64() {
    m
  } else {
    x.to_int()
  }
}

///|
/// Compute window function values for `rows`, taken in the order `input`;
/// returns one value per row and the order in which the rows were processed
/// (partition, then ORDER BY; ties keep their input order).
fn WinFn::compute(
  self : WinFn,
  rows : Array[Array[Value]],
  input : Array[Int],
) -> (Array[Value], Array[Int]) raise SqlError {
  let n = rows.length()
  let pk = rows.map(r => self.partition.map(e => eval(e, r)))
  let ok = rows.map(r => self.order.map(o => eval(o.key, r)))
  let pcolls = self.pcolls
  let order = self.order
  let pcmp = (a : Int, b : Int) => {
    let x = pk[a]
    let y = pk[b]
    for i in 0..<x.length() {
      let c = compare_coll(x[i], y[i], pcolls[i])
      if c != 0 {
        return c
      }
    }
    0
  }
  let ocmp = (a : Int, b : Int) => {
    let x = ok[a]
    let y = ok[b]
    for i, o in order {
      match (x[i], y[i]) {
        (Null, Null) => continue
        (Null, _) => return if o.nulls_first { -1 } else { 1 }
        (_, Null) => return if o.nulls_first { 1 } else { -1 }
        _ => ()
      }
      let c = compare_coll(x[i], y[i], o.coll)
      if c != 0 {
        return if o.desc { -c } else { c }
      }
    }
    0
  }
  let idx = input.copy()
  stable_sort(idx, (a, b) => {
    let c = pcmp(a, b)
    if c != 0 {
      c
    } else {
      ocmp(a, b)
    }
  })
  // frame offsets
  let f = self.frame
  let uses_frame = self.agg is Some(_) ||
    self.name is ("FIRST_VALUE" | "LAST_VALUE" | "NTH_VALUE")
  let mut soff_i = 0L
  let mut eoff_i = 0L
  let mut soff_v : Value = Null
  let mut eoff_v : Value = Null
  if uses_frame {
    match f.start {
      Pre(e) | Fol(e) =>
        if f.unit == FRange {
          soff_v = num_offset(e, true)
        } else {
          soff_i = int_offset(e, true)
        }
      _ => ()
    }
    match f.end {
      Pre(e) | Fol(e) =>
        if f.unit == FRange {
          eoff_v = num_offset(e, false)
        } else {
          eoff_i = int_offset(e, false)
        }
      _ => ()
    }
  }
  let res : Array[Value] = Array::make(n, Null)
  let mut p0 = 0
  while p0 < n {
    let mut p1 = p0 + 1
    while p1 < n && pcmp(idx[p0], idx[p1]) == 0 {
      p1 += 1
    }
    let part = idx[p0:p1].to_owned()
    self.run_partition(
      rows, ok, part, res, ocmp, soff_i, eoff_i, soff_v, eoff_v,
    )
    p0 = p1
  }
  (res, idx)
}

///|
fn WinFn::run_partition(
  self : WinFn,
  rows : Array[Array[Value]],
  ok : Array[Array[Value]],
  part : Array[Int],
  res : Array[Value],
  ocmp : (Int, Int) -> Int,
  soff_i : Int64,
  eoff_i : Int64,
  soff_v : Value,
  eoff_v : Value,
) -> Unit raise SqlError {
  let m = part.length()
  // peer groups
  let peer : Array[Int] = Array::make(m, 0)
  let gstart : Array[Int] = []
  let gend : Array[Int] = []
  for j in 0..<m {
    if j == 0 || ocmp(part[j - 1], part[j]) != 0 {
      if j > 0 {
        gend.push(j)
      }
      gstart.push(j)
    }
    peer[j] = gstart.length() - 1
  }
  gend.push(m)
  let ng = gstart.length()
  let row_at = (j : Int) => rows[part[j]]
  match self.name {
    "ROW_NUMBER" => {
      for j in 0..<m {
        res[part[j]] = Int((j + 1).to_int64())
      }
      return
    }
    "RANK" => {
      for j in 0..<m {
        res[part[j]] = Int((gstart[peer[j]] + 1).to_int64())
      }
      return
    }
    "DENSE_RANK" => {
      for j in 0..<m {
        res[part[j]] = Int((peer[j] + 1).to_int64())
      }
      return
    }
    "PERCENT_RANK" => {
      for j in 0..<m {
        res[part[j]] = Real(
          if m > 1 {
            gstart[peer[j]].to_double() / (m - 1).to_double()
          } else {
            0.0
          },
        )
      }
      return
    }
    "CUME_DIST" => {
      for j in 0..<m {
        res[part[j]] = Real(gend[peer[j]].to_double() / m.to_double())
      }
      return
    }
    "NTILE" => {
      if m == 0 {
        return
      }
      // like SQLite, the bucket count comes from the partition's first row
      let np = eval(self.args[0], row_at(0)).to_int64()
      if np <= 0L {
        raise sql_err("argument of ntile must be a positive integer")
      }
      for j in 0..<m {
        let total = m.to_int64()
        let size = total / np
        let jj = j.to_int64()
        let b = if size == 0L {
          jj + 1L
        } else {
          let nlarge = total - np * size
          let ismall = nlarge * (size + 1L)
          if jj < ismall {
            1L + jj / (size + 1L)
          } else {
            1L + nlarge + (jj - ismall) / size
          }
        }
        res[part[j]] = Int(b)
      }
      return
    }
    "LAG" | "LEAD" => {
      for j in 0..<m {
        let r = row_at(j)
        let off : Int64? = if self.args.length() > 1 {
          let v = eval(self.args[1], r)
          let v = match v {
            Text(_) => text_to_numeric(v.to_text().unwrap_or(""))
            Blob(_) => Int(0L)
            _ => v
          }
          match v {
            Int(i) => Some(i)
            Real(d) => real_to_int_exact(d)
            _ => None
          }
        } else {
          Some(1L)
        }
        let target = match off {
          Some(o) =>
            if self.name == "LAG" {
              j.to_int64() - o
            } else {
              j.to_int64() + o
            }
          None => -1L
        }
        res[part[j]] = if target >= 0L && target < m.to_int64() {
          eval(self.args[0], row_at(target.to_int()))
        } else if self.args.length() > 2 {
          eval(self.args[2], r)
        } else {
          Null
        }
      }
      return
    }
    _ => ()
  }
  // frame-based functions
  let f = self.frame
  let mut nlo = 0
  let mut nhi = 0
  if f.unit == FRange && self.order.length() > 0 {
    let mut first = -1
    let mut last = -1
    for j in 0..<m {
      if !(ok[part[j]][0] is Null) {
        if first < 0 {
          first = j
        }
        last = j
      }
    }
    if first >= 0 {
      nlo = first
      nhi = last + 1
    }
  }
  let desc = self.order.length() > 0 && self.order[0].desc
  // first position in [nlo, nhi) whose key satisfies the bound
  let range_pos = (j : Int, off : Value, pre : Bool, is_start : Bool) => {
    let k = ok[part[j]][0]
    if k is Null {
      return if is_start { gstart[peer[j]] } else { gend[peer[j]] }
    }
    let target = if pre != desc {
      arith(Sub, k, off)
    } else {
      arith(Add, k, off)
    }
    let sat = (p : Int) => {
      let c = compare_values(ok[part[p]][0], target)
      match (desc, is_start) {
        (false, true) => c >= 0
        (false, false) => c > 0
        (true, true) => c <= 0
        (true, false) => c < 0
      }
    }
    let mut lo = nlo
    let mut hi = nhi
    while lo < hi {
      let mid = lo + (hi - lo) / 2
      if sat(mid) {
        hi = mid
      } else {
        lo = mid + 1
      }
    }
    lo
  }
  let bounds = (j : Int) => {
    let g = peer[j]
    let jj = j.to_int64()
    let (fs, fe) = match f.unit {
      FRows => {
        let fs = match f.start {
          UnbPre => 0
          Pre(_) => clamp_pos(jj - soff_i, m)
          CurRow => j
          Fol(_) => clamp_pos(jj + soff_i, m)
          UnbFol => m
        }
        let fe = match f.end {
          UnbPre => 0
          Pre(_) => clamp_pos(jj - eoff_i + 1L, m)
          CurRow => j + 1
          Fol(_) => clamp_pos(jj + eoff_i + 1L, m)
          UnbFol => m
        }
        (fs, fe)
      }
      FGroups => {
        let gg = g.to_int64()
        let ngg = ng.to_int64()
        let fs = match f.start {
          UnbPre => 0
          Pre(_) => {
            let t = gg - soff_i
            gstart[if t < 0L { 0 } else { t.to_int() }]
          }
          CurRow => gstart[g]
          Fol(_) => {
            let t = gg + soff_i
            if t < ngg {
              gstart[t.to_int()]
            } else {
              m
            }
          }
          UnbFol => m
        }
        let fe = match f.end {
          UnbPre => 0
          Pre(_) => {
            let t = gg - eoff_i
            if t >= 0L {
              gend[t.to_int()]
            } else {
              0
            }
          }
          CurRow => gend[g]
          Fol(_) => {
            let t = gg + eoff_i
            gend[if t >= ngg { ng - 1 } else { t.to_int() }]
          }
          UnbFol => m
        }
        (fs, fe)
      }
      FRange => {
        let fs = match f.start {
          UnbPre => 0
          Pre(_) => range_pos(j, soff_v, true, true)
          CurRow => gstart[g]
          Fol(_) => range_pos(j, soff_v, false, true)
          UnbFol => m
        }
        let fe = match f.end {
          UnbPre => 0
          Pre(_) => range_pos(j, eoff_v, true, false)
          CurRow => gend[g]
          Fol(_) => range_pos(j, eoff_v, false, false)
          UnbFol => m
        }
        (fs, fe)
      }
    }
    (fs, if fe < fs { fs } else { fe })
  }
  let excluded = (p : Int, j : Int) => {
    match f.exclude {
      ExNone => false
      ExCurrent => p == j
      ExGroup => peer[p] == peer[j]
      ExTies => peer[p] == peer[j] && p != j
    }
  }
  match self.agg {
    Some(spec) => {
      if f.exclude != ExNone {
        for j in 0..<m {
          let (fs, fe) = bounds(j)
          let acc = new_acc(spec)
          for p in fs..<fe {
            if !excluded(p, j) {
              ignore(acc.add_row(row_at(p)))
            }
          }
          res[part[j]] = acc.finish()
        }
        return
      }
      if spec.name is ("MIN" | "MAX") {
        self.minmax_partition(spec, part, rows, res, bounds)
        return
      }
      let removable = can_remove(spec.name)
      let mut acc = new_acc(spec)
      let mut a = 0
      let mut b = 0
      for j in 0..<m {
        let (fs, fe) = bounds(j)
        if fs < a || fe < b || (!removable && fs > a) {
          acc = new_acc(spec)
          a = fs
          b = fs
        }
        while a < fs && a < b {
          acc.remove_row(row_at(a))
          a += 1
        }
        if a < fs {
          a = fs
          b = fs
        }
        while b < fe {
          ignore(acc.add_row(row_at(b)))
          b += 1
        }
        res[part[j]] = acc.finish()
      }
    }
    None =>
      for j in 0..<m {
        let (fs, fe) = bounds(j)
        let want = match self.name {
          "NTH_VALUE" => {
            let v = eval(self.args[1], row_at(j))
            let nv = match v {
              Text(_) => text_to_numeric(v.to_text().unwrap_or(""))
              _ => v
            }
            let k = match nv {
              Int(i) => i
              Real(d) =>
                match real_to_int_exact(d) {
                  Some(i) => i
                  None => 0L
                }
              _ => 0L
            }
            if k <= 0L {
              raise sql_err(
                "second argument to nth_value must be a positive integer",
              )
            }
            k
          }
          "FIRST_VALUE" => 1L
          _ => -1L // LAST_VALUE
        }
        let mut hit = -1
        if want > 0L {
          let mut cnt = 0L
          for p in fs..<fe {
            if excluded(p, j) {
              continue
            }
            cnt += 1L
            if cnt == want {
              hit = p
              break
            }
          }
        } else {
          for p = fe - 1; p >= fs; p = p - 1 {
            if !excluded(p, j) {
              hit = p
              break
            }
          }
        }
        res[part[j]] = if hit >= 0 {
          eval(self.args[0], row_at(hit))
        } else {
          Null
        }
      }
  }
}

///|
/// Append the values of all window functions to each row; returns the
/// extended rows in output order. Like SQLite, windows are applied from the
/// last to the first, each one sorting the output of the previous one.
fn compute_windows(
  rows : Array[Array[Value]],
  fns : Array[WinFn],
) -> Array[Array[Value]] raise SqlError {
  let n = rows.length()
  let vals : Array[Array[Value]] = Array::make(fns.length(), [])
  let mut order = Array::makei(n, i => i)
  for k = fns.length() - 1; k >= 0; k = k - 1 {
    let (v, idx) = fns[k].compute(rows, order)
    vals[k] = v
    order = idx
  }
  order.map(i => {
    let r = rows[i].copy()
    for v in vals {
      r.push(v[i])
    }
    r
  })
}

///|
/// min() / max() over sliding frames with a monotonic deque: positions whose
/// values can still become the extremum, best first.
fn WinFn::minmax_partition(
  self : WinFn,
  spec : AggSpec,
  part : Array[Int],
  rows : Array[Array[Value]],
  res : Array[Value],
  bounds : (Int) -> (Int, Int),
) -> Unit raise SqlError {
  ignore(self)
  let is_max = spec.name == "MAX"
  let coll = spec.coll
  let dpos : Array[Int] = []
  let dval : Array[Value] = []
  let mut head = 0
  let mut a = 0
  let mut b = 0
  for j in 0..<part.length() {
    let (fs, fe) = bounds(j)
    if fs < a || fe < b || b < fs {
      dpos.clear()
      dval.clear()
      head = 0
      b = fs
    }
    a = fs
    while head < dpos.length() && dpos[head] < a {
      head += 1
    }
    while b < fe {
      let row = rows[part[b]]
      let pass = match spec.filter {
        Some(f) => eval(f, row).truth() is Some(true)
        None => true
      }
      if pass {
        let v = eval(spec.args[0], row)
        if !(v is Null) {
          while dpos.length() > head {
            let c = compare_coll(dval[dval.length() - 1], v, coll)
            if (is_max && c < 0) || (!is_max && c > 0) {
              ignore(dpos.pop())
              ignore(dval.pop())
            } else {
              break
            }
          }
          dpos.push(b)
          dval.push(v)
        }
      }
      b += 1
    }
    if head > 4096 && head * 2 > dpos.length() {
      let p2 = dpos[head:].to_owned()
      let v2 = dval[head:].to_owned()
      dpos.clear()
      dval.clear()
      dpos.append(p2)
      dval.append(v2)
      head = 0
    }
    res[part[j]] = if head < dpos.length() { dval[head] } else { Null }
  }
}
