///|
/// The single current row of a recursive CTE, read by its recursive selects.
priv struct WorkTable {
  table_name : String
  names : Array[String]
  exprs : Array[BExpr]
  colls : Array[Coll?]
  rows : Ref[Array[Array[Value]]]
  mut refs : Int
}

///|
/// A name visible to FROM through a WITH clause: either a CTE definition
/// (compiled at each reference, in the environment `env`) or the working
/// table of a recursive CTE being compiled.
priv struct CteBinding {
  name : String
  cte : Cte?
  id : Int
  mut env : Array[CteBinding]
  work : WorkTable?
}

///|
let cte_env : Ref[Array[CteBinding]] = { val: [], }

///|
/// CTEs whose bodies are being compiled (cycle detection).
let cte_active : Set[Int] = Set([])

///|
/// Set while compiling the target table of UPDATE/DELETE, which always
/// names a real table.
let dml_target : Ref[Bool] = { val: false, }

///|
let cte_next_id : Ref[Int] = { val: 0, }

///|
/// Runs `f` with `env` as the visible CTEs.
fn[T] with_cte_env(
  env : Array[CteBinding],
  f : () -> T raise SqlError,
) -> T raise SqlError {
  let saved = cte_env.val
  cte_env.val = env
  let r = f() catch {
    e => {
      cte_env.val = saved
      raise e
    }
  }
  cte_env.val = saved
  r
}

///|
/// The environment after a WITH clause: every CTE of the clause sees all of
/// them (and the enclosing ones).
fn make_cte_env(ctes : Array[Cte]) -> Array[CteBinding] raise SqlError {
  let seen : Set[String] = Set([])
  let env = cte_env.val.copy()
  let added = []
  for c in ctes {
    let f = fold_name(c.name)
    if !seen.add_and_check(f) {
      raise err("duplicate WITH table name: " + c.name)
    }
    cte_next_id.val += 1
    let b : CteBinding = {
      name: f,
      cte: Some(c),
      id: cte_next_id.val,
      env: [],
      work: None,
    }
    env.push(b)
    added.push(b)
  }
  for b in added {
    b.env = env
  }
  env
}

///|
fn find_cte(name : String) -> CteBinding? {
  let env = cte_env.val
  if env.length() == 0 {
    return None
  }
  let f = fold_name(name)
  for i = env.length() - 1; i >= 0; i = i - 1 {
    if env[i].name == f {
      return Some(env[i])
    }
  }
  None
}

///|
/// Number of references to `name` among the tables of a FROM clause (not
/// looking into subqueries).
fn count_from_refs(item : FromItem, name : String) -> Int {
  match item {
    TableRef(n, _) => if fold_name(n) == name { 1 } else { 0 }
    SubqueryRef(_, _) => 0
    Join(l, r, _, _, _, _) =>
      count_from_refs(l, name) + count_from_refs(r, name)
  }
}

///|
fn core_from_refs(core : SelectCore, name : String) -> Int {
  match core {
    Simple(s) =>
      match s.from {
        Some(f) => count_from_refs(f, name)
        None => 0
      }
    Values(_) => 0
  }
}

///|
fn core_is_aggregate(core : SelectCore) -> Bool raise SqlError {
  guard core is Simple(s) else { return false }
  if s.group_by.length() > 0 {
    return true
  }
  let aggs : Array[FuncCall] = []
  for rc in s.columns {
    if rc is ExprCol(e, _) {
      extract_aggregates(e, aggs) |> ignore
    }
  }
  if s.having is Some(h) {
    extract_aggregates(h, aggs) |> ignore
  }
  aggs.length() > 0
}

///|
/// A FROM source reading a CTE.
fn Database::cte_source(
  self : Database,
  b : CteBinding,
  alias : String?,
  offset : Int,
  outer : Scope?,
  corr : Ref[Bool],
  chain : Array[Source],
) -> Source raise SqlError {
  if b.work is Some(w) {
    w.refs += 1
    let c : Compiled = {
      names: w.names,
      exprs: w.exprs,
      colls: w.colls,
      run: () => w.rows.val,
    }
    return subquery_source(
      c,
      w.names,
      alias.unwrap_or(w.table_name),
      offset,
      chain,
      true,
      small=true,
    )
  }
  guard b.cte is Some(cte) else { raise err("no such table: " + b.name) }
  if cte_active.contains(b.id) {
    raise err("circular reference: " + cte.name)
  }
  cte_active.add(b.id)
  let sub_corr : Ref[Bool] = { val: false, }
  let c = with_cte_env(b.env, () => {
    self.compile_cte_body(cte, b, outer, sub_corr)
  }) catch {
    e => {
      cte_active.remove(b.id)
      raise e
    }
  }
  cte_active.remove(b.id)
  if sub_corr.val {
    corr.val = true
  }
  let names = if cte.columns.length() > 0 {
    if cte.columns.length() != c.names.length() {
      raise err(
        "table \{cte.name} has \{c.names.length()} values for \{cte.columns.length()} columns",
      )
    }
    cte.columns
  } else {
    c.names
  }
  subquery_source(
    c,
    names,
    alias.unwrap_or(cte.name),
    offset,
    chain,
    sub_corr.val,
  )
}

///|
fn compound_op_name(op : CompoundOp) -> String {
  match op {
    Union => "UNION"
    UnionAll => "UNION ALL"
    Intersect => "INTERSECT"
    Except => "EXCEPT"
  }
}

///|
/// Compiles the body of a CTE; a body whose trailing UNION [ALL] arms read
/// the CTE itself is evaluated as a recursive query.
fn Database::compile_cte_body(
  self : Database,
  cte : Cte,
  b : CteBinding,
  outer : Scope?,
  corr : Ref[Bool],
) -> Compiled raise SqlError {
  let sel = cte.select
  if sel.with_.length() > 0 {
    let env = make_cte_env(sel.with_)
    return with_cte_env(env, () => {
      self.compile_cte_body(
        { ..cte, select: { ..sel, with_: [], }, },
        b,
        outer,
        corr,
      )
    })
  }
  let arms = [sel.first, ..sel.rest.map(r => r.1)]
  let ops = sel.rest.map(r => r.0)
  let mut k = arms.length()
  if ops.length() > 0 {
    let last = ops[ops.length() - 1]
    if last is (Union | UnionAll) {
      while k > 1 && ops[k - 2] == last {
        let n = core_from_refs(arms[k - 1], b.name)
        if n == 0 {
          break
        }
        if n > 1 {
          raise err("multiple references to recursive table: " + cte.name)
        }
        k -= 1
      }
    }
  }
  if k == arms.length() {
    return self.compile_select(sel, outer, corr)
  }
  for i in k..<arms.length() {
    if core_is_aggregate(arms[i]) {
      raise err("recursive aggregate queries not supported")
    }
  }
  let anchor_sel : Select = {
    with_: [],
    recursive: false,
    first: arms[0],
    rest: sel.rest[0:k - 1].to_owned(),
    order_by: [],
    limit: None,
    offset: None,
  }
  let ac = self.compile_select(anchor_sel, outer, corr)
  let ncols = ac.names.length()
  let work : WorkTable = {
    table_name: cte.name,
    names: if cte.columns.length() == ncols {
      cte.columns
    } else {
      ac.names
    },
    exprs: ac.exprs,
    colls: ac.colls,
    rows: { val: [], },
    refs: 0,
  }
  let wb : CteBinding = {
    name: b.name,
    cte: None,
    id: -1,
    env: [],
    work: Some(work),
  }
  let last_op = ops[ops.length() - 1]
  let recs = with_cte_env([..cte_env.val, wb], () => {
    let out = []
    for i in k..<arms.length() {
      let rc = self.compile_core(arms[i], [], None, None, outer, corr)
      if rc.names.length() != ncols {
        raise err(
          "SELECTs to the left and right of " +
          compound_op_name(last_op) +
          " do not have the same number of result columns",
        )
      }
      out.push(rc)
    }
    out
  })
  if work.refs != recs.length() {
    raise err("multiple recursive references: " + cte.name)
  }
  let colls = ac.colls
  let order = sel.order_by.mapi((i, t) => {
    compound_order_term([ac, ..recs], colls, i, t.expr)
  })
  let ocolls = order.map(o => o.1)
  let terms = sel.order_by
  let distinct = last_op is Union
  let dcolls = colls.map(c => c.unwrap_or(CBinary))
  let limit_e = sel.limit
  let offset_e = sel.offset
  {
    names: ac.names,
    exprs: ac.exprs,
    colls,
    run: () => {
      let mut limit = -1L
      let mut skip = 0L
      if limit_e is Some(l) {
        limit = self.eval_limit(l)
      }
      if offset_e is Some(o) {
        skip = self.eval_limit(o)
      }
      let out : Array[Array[Value]] = []
      if limit == 0L {
        return out
      }
      let seen : Set[String] = Set([])
      let fifo : Array[Array[Value]] = []
      let mut head = 0
      let heap = RowHeap::new(terms, ocolls)
      let push = (row : Array[Value]) => {
        if distinct && !seen.add_and_check(row_key(row, dcolls)) {
          return
        }
        if order.length() == 0 {
          fifo.push(row)
        } else {
          heap.push(order.map(o => row[o.0]), row)
        }
      }
      for r in (ac.run)() {
        push(r)
      }
      while true {
        let row = if order.length() == 0 {
          if head >= fifo.length() {
            break
          }
          let r = fifo[head]
          head += 1
          // Release consumed queue entries now and then.
          if head > 4096 && head * 2 > fifo.length() {
            fifo.drain(0, head) |> ignore
            head = 0
          }
          r
        } else {
          match heap.pop() {
            Some(r) => r
            None => break
          }
        }
        if skip > 0L {
          skip -= 1L
        } else {
          out.push(row)
          if limit > 0L && out.length().to_int64() >= limit {
            break
          }
        }
        work.rows.val = [row]
        for rc in recs {
          for r in (rc.run)() {
            push(r)
          }
        }
      }
      work.rows.val = []
      out
    },
  }
}

///|
/// A priority queue of rows ordered by ORDER BY keys, ties in insertion
/// order.
priv struct RowHeap {
  terms : Array[OrderTerm]
  colls : Array[Coll]
  items : Array[(Array[Value], Int, Array[Value])]
  mut seq : Int
}

///|
fn RowHeap::new(terms : Array[OrderTerm], colls : Array[Coll]) -> RowHeap {
  { terms, colls, items: [], seq: 0, }
}

///|
fn RowHeap::less(self : RowHeap, i : Int, j : Int) -> Bool {
  let a = self.items[i]
  let b = self.items[j]
  let c = compare_order_keys(self.terms, self.colls, a.0, b.0)
  if c != 0 {
    c < 0
  } else {
    a.1 < b.1
  }
}

///|
fn RowHeap::push(
  self : RowHeap,
  keys : Array[Value],
  row : Array[Value],
) -> Unit {
  self.items.push((keys, self.seq, row))
  self.seq += 1
  let mut i = self.items.length() - 1
  while i > 0 {
    let p = (i - 1) / 2
    if self.less(i, p) {
      self.items.swap(i, p)
      i = p
    } else {
      break
    }
  }
}

///|
fn RowHeap::pop(self : RowHeap) -> Array[Value]? {
  let n = self.items.length()
  if n == 0 {
    return None
  }
  let top = self.items[0].2
  let last = self.items.pop().unwrap()
  if n > 1 {
    self.items[0] = last
    let m = n - 1
    let mut i = 0
    while true {
      let l = 2 * i + 1
      let r = l + 1
      let mut best = i
      if l < m && self.less(l, best) {
        best = l
      }
      if r < m && self.less(r, best) {
        best = r
      }
      if best == i {
        break
      }
      self.items.swap(i, best)
      i = best
    }
  }
  Some(top)
}
