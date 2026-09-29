// Common table expressions (WITH), including recursive ones.

///|
/// A CTE in scope while a statement is bound.
priv struct Cte {
  def : CteDef
  /// CTEs visible inside its body (its own WITH clause and outer ones).
  mut env : Array[Cte]
  /// Set while its body is bound: references raise this message + name.
  mut err : String?
  /// Set while a recursive arm is bound: the FROM item that reads the
  /// current row, the buffer holding it and its columns.
  mut rec : (FromItem, Ref[Array[Array[Value]]], Array[ColumnDef])?
}

///|
/// CTEs in scope, innermost last.
let cte_stack : Array[Cte] = []

///|
/// Bring the CTEs of a WITH clause into scope; returns the previous depth.
fn push_ctes(ctes : Array[CteDef]) -> Int {
  let base = cte_stack.length()
  let objs : Array[Cte] = ctes.map(d => {
    def: d,
    env: [],
    err: None,
    rec: None,
  })
  for o in objs {
    cte_stack.push(o)
  }
  let env = cte_stack.copy()
  for o in objs {
    o.env = env
  }
  base
}

///|
fn find_cte(name : String) -> Cte? {
  for i = cte_stack.length() - 1; i >= 0; i = i - 1 {
    if same_name(cte_stack[i].def.name, name) {
      return Some(cte_stack[i])
    }
  }
  None
}

///|
/// Column definitions of a CTE, named by its column list if it has one.
fn cte_cols(
  cte : Cte,
  infos : Array[ColInfo],
) -> Array[ColumnDef] raise SqlError {
  let cols = derived_cols(infos)
  if cte.def.cols is Some(names) {
    if names.length() != cols.length() {
      raise sql_err(
        "table \{cte.def.name} has \{cols.length()} values for \{names.length()} columns",
      )
    }
    for i, n in names {
      cols[i] = { ..cols[i], name: n, }
    }
  }
  cols
}

///|
/// Plan for a FROM item naming a CTE: (subquery plan, columns, recursive
/// buffer when the item is the recursive reference).
fn cte_source(
  cte : Cte,
  f : FromItem,
  level : Int,
) -> (QPlan?, Array[ColumnDef], Ref[Array[Array[Value]]]?) raise SqlError {
  if cte.rec is Some((item, buf, cols)) && physical_equal(item, f) {
    return (None, cols, Some(buf))
  }
  if cte.err is Some(msg) {
    raise sql_err(msg + cte.def.name)
  }
  let saved = cte_stack.copy()
  cte_stack.clear()
  cte_stack.append(cte.env)
  let p = prepare_cte(cte, level) catch {
    e => {
      cte.err = None
      cte.rec = None
      cte_stack.clear()
      cte_stack.append(saved)
      raise e
    }
  }
  cte_stack.clear()
  cte_stack.append(saved)
  (Some(p), cte_cols(cte, p.cols()), None)
}

///|
/// Move the recursive reference of a recursive arm to the front of its FROM
/// clause (it holds a single row), when that does not change the result.
fn reorder_rec_arm(sel : Select, name : String) -> (Select, FromItem) {
  let mut k = 0
  for i, fi in sel.from {
    if fi.src is FTable(n) && same_name(n, name) {
      k = i
      break
    }
  }
  let item = sel.from[k]
  if k == 0 {
    return (sel, item)
  }
  let simple = sel.from.all(fi => {
      fi.join == JInner && !fi.natural && fi.using_ is None
    }) &&
    !sel.cols.any(c => c is (Star | TableStar(_)))
  if !simple {
    return (sel, item)
  }
  let mut w : Expr? = None
  let conds : Array[Expr] = sel.from.filter_map(fi => fi.on)
  if sel.where_ is Some(x) {
    conds.push(x)
  }
  for c in conds {
    w = match w {
      Some(x) => Some(Binary(And, x, c))
      None => Some(c)
    }
  }
  let first = { ..item, join: JInner, on: None, }
  let from = [first]
  for i, fi in sel.from {
    if i != k {
      from.push({ ..fi, join: JInner, on: None, })
    }
  }
  ({ ..sel, from, where_: w, }, first)
}

///|
fn op_name(op : CompoundOp) -> String {
  match op {
    UnionAll => "UNION ALL"
    Union => "UNION"
    Intersect => "INTERSECT"
    Except => "EXCEPT"
  }
}

///|
/// Bind the body of a CTE (the CTE stack holds its environment).
fn prepare_cte(cte : Cte, level : Int) -> QPlan raise SqlError {
  let name = cte.def.name
  let q = cte.def.query
  let plain = () => {
    cte.err = Some("circular reference: ")
    let p = prepare_query(q, None, level, { val: false, })
    cte.err = None
    p
  }
  guard q is QCompound(first~, rest~, order_by~, limit~, offset~) &&
    rest.length() > 0 &&
    rest[rest.length() - 1].0 is (Union | UnionAll) else {
    return plain()
  }
  let lastop = rest[rest.length() - 1].0
  let mut i = rest.length() - 1
  while i >= 0 && rest[i].0 == lastop {
    let refs = match rest[i].1 {
      QSelect(sel) =>
        sel.from
        .filter(fi => fi.src is FTable(n) && same_name(n, name))
        .length()
      _ => 0
    }
    if refs > 1 {
      raise sql_err("multiple references to recursive table: \{name}")
    }
    if refs == 0 {
      break
    }
    i -= 1
  }
  let first_rec = i + 1
  if first_rec >= rest.length() {
    return plain()
  }
  let setup_q = if first_rec == 0 {
    first
  } else {
    QCompound(
      first~,
      rest=rest[0:first_rec].to_owned(),
      order_by=[],
      limit=None,
      offset=None,
    )
  }
  cte.err = Some("circular reference: ")
  let setup = prepare_query(setup_q, None, level, { val: false, })
  let scols = setup.cols()
  let ncol = scols.length()
  let cols = cte_cols(cte, scols)
  let buf : Ref[Array[Array[Value]]] = { val: [], }
  cte.err = Some("multiple recursive references: ")
  let arms : Array[SelPlan] = []
  for j in first_rec..<rest.length() {
    guard rest[j].1 is QSelect(sel0) else { raise sql_err("bad recursive CTE") }
    let (sel, item) = reorder_rec_arm(sel0, name)
    cte.rec = Some((item, buf, cols))
    let p = prepare_select(sel, None, level, { val: false, })
    cte.rec = None
    if p.is_agg {
      raise sql_err("recursive aggregate queries not supported")
    }
    if p.wfns.length() > 0 {
      raise sql_err("cannot use window functions in recursive queries")
    }
    if p.exprs.length() != ncol {
      raise sql_err(
        "SELECTs to the left and right of \{op_name(rest[j].0)} do not have the same number of result columns",
      )
    }
    arms.push(p)
  }
  cte.err = None
  let members = [setup]
  for a in arms {
    members.push(PSel(a))
  }
  let colls = scols.map(c => c.coll.unwrap_or(CBinary))
  let order = compound_order(
    order_by,
    members,
    members.map(m => m.cols()),
    colls,
  )
  let sc = scope_at(None, level, { val: false, })
  PRec({
    setup,
    arms,
    buf,
    distinct: lastop == Union,
    cols: scols,
    colls,
    order,
    limit: limit.map(e => sc.bind(e)),
    offset: offset.map(e => sc.bind(e)),
  })
}

///|
/// A recursive CTE: setup rows seed a queue; each row taken from the queue
/// is output and fed (as the recursive table) to the recursive arms.
priv struct RecPlan {
  setup : QPlan
  arms : Array[SelPlan]
  buf : Ref[Array[Array[Value]]]
  distinct : Bool // UNION: rows already queued are dropped
  cols : Array[ColInfo]
  colls : Array[Coll]
  order : Array[(Int, Bool, Bool, Coll)] // queue order (ORDER BY)
  limit : Expr?
  offset : Expr?
}

///|
fn RecPlan::run(self : RecPlan) -> Array[Array[Value]] raise SqlError {
  let (limit, skip) = eval_limits(self.limit, self.offset)
  let out : Array[Array[Value]] = []
  if limit == 0L {
    return out
  }
  let order = self.order
  let cmp_rows = (a : Array[Value], b : Array[Value]) => {
    for o in order {
      let (i, desc, nulls_first, coll) = o
      let x = a[i]
      let y = b[i]
      match (x, y) {
        (Null, Null) => continue
        (Null, _) => return if nulls_first { -1 } else { 1 }
        (_, Null) => return if nulls_first { 1 } else { -1 }
        _ => ()
      }
      let c = compare_coll(x, y, coll)
      if c != 0 {
        return if desc { -c } else { c }
      }
    }
    0
  }
  // FIFO queue (no ORDER BY) or binary heap ordered by (ORDER BY, seq)
  let fifo : Array[Array[Value]] = []
  let mut head = 0
  let heap : Array[(Array[Value], Int)] = []
  let mut seq = 0
  let less = (a : (Array[Value], Int), b : (Array[Value], Int)) => {
    let c = cmp_rows(a.0, b.0)
    if c != 0 {
      c < 0
    } else {
      a.1 < b.1
    }
  }
  let use_heap = order.length() > 0
  let mut seen : PMap[Array[Value], Unit] = PMap::empty(rows_cmp(self.colls))
  let distinct = self.distinct
  fn add(r : Array[Value]) -> Unit {
    if distinct {
      if seen.find(r) is Some(_) {
        return
      }
      seen = seen.add(r, ())
    }
    if use_heap {
      heap.push((r, seq))
      seq += 1
      let mut c = heap.length() - 1
      while c > 0 {
        let p = (c - 1) / 2
        if less(heap[c], heap[p]) {
          heap.swap(c, p)
          c = p
        } else {
          break
        }
      }
    } else {
      fifo.push(r)
    }
  }

  fn pop() -> Array[Value]? {
    if use_heap {
      if heap.length() == 0 {
        return None
      }
      let top = heap[0]
      let last = heap.pop().unwrap()
      if heap.length() > 0 {
        heap[0] = last
        let n = heap.length()
        let mut c = 0
        while true {
          let l = 2 * c + 1
          let r = l + 1
          let mut best = c
          if l < n && less(heap[l], heap[best]) {
            best = l
          }
          if r < n && less(heap[r], heap[best]) {
            best = r
          }
          if best == c {
            break
          }
          heap.swap(c, best)
          c = best
        }
      }
      Some(top.0)
    } else if head < fifo.length() {
      let r = fifo[head]
      head += 1
      if head > 4096 && head * 2 > fifo.length() {
        let rest = fifo[head:].to_owned()
        fifo.clear()
        fifo.append(rest)
        head = 0
      }
      Some(r)
    } else {
      None
    }
  }

  for r in self.setup.run(-1L) {
    add(r)
  }
  let mut to_skip = skip
  while pop() is Some(r) {
    if to_skip > 0L {
      to_skip -= 1L
    } else {
      out.push(r)
      if limit > 0L && out.length().to_int64() >= limit {
        break
      }
    }
    self.buf.val = [r]
    for arm in self.arms {
      for nr in arm.run(-1L) {
        add(nr)
      }
    }
  }
  self.buf.val = []
  out
}
