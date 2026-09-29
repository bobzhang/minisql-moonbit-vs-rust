// Common table expressions: WITH clauses, their expansion when referenced
// in FROM, and recursive CTE evaluation.

///|
/// A CTE visible while preparing a statement.
priv struct CteDef {
  decl : CteDecl
  /// Error message template while a reference to it is not allowed (it is
  /// being expanded).
  mut err : String?
  /// CTEs visible to its body.
  mut env : Array[CteDef]
}

///|
/// CTEs visible at the current point of preparation (innermost last).
let cte_env : Ref[Array[CteDef]] = { val: [], }

///|
/// The recursive table of a recursive CTE while its recursive selects are
/// prepared, by marker name.
priv struct RecTable {
  name : String
  prepared : Prepared
}

///|
let rec_tables : Map[String, RecTable] = Map([])

///|
let rec_counter : Ref[Int] = { val: 0, }

///|
/// Runs `body` with the CTEs of a WITH clause visible.
fn[T] with_ctes(
  ctes : Array[CteDecl],
  body : () -> T raise SqlError,
) -> T raise SqlError {
  let saved = cte_env.val
  let env = saved.copy()
  let defs = ctes.map(d => { decl: d, err: None, env: [], })
  env.append(defs)
  for d in defs {
    d.env = env
  }
  cte_env.val = env
  defer {
    cte_env.val = saved
  }
  body()
}

///|
/// Runs `body` with no CTEs visible (view definitions).
fn[T] without_ctes(body : () -> T raise SqlError) -> T raise SqlError {
  let saved = cte_env.val
  cte_env.val = []
  defer {
    cte_env.val = saved
  }
  body()
}

///|
fn find_cte(name : String) -> CteDef? {
  let env = cte_env.val
  for i = env.length() - 1; i >= 0; i = i - 1 {
    if env[i].decl.name.equal_ignore_ascii_case(name) {
      return Some(env[i])
    }
  }
  None
}

///|
fn is_rec_marker(name : String) -> Bool {
  name.has_prefix("\u{1}")
}

///|
/// Number of FROM items of a core naming `name` directly.
fn direct_refs(sel : Select, name : String) -> Int {
  guard sel.from is Some(f) else { return 0 }
  let leaves : Array[FromLeaf] = []
  flatten_from(f, leaves)
  let mut n = 0
  for l in leaves {
    if l.item is TableRef(name=tn, ..) && tn.equal_ignore_ascii_case(name) {
      n += 1
    }
  }
  n
}

///|
/// Replaces direct references to `name` by the marker of the recursive table.
fn replace_rec_ref(f : FromItem, name : String, marker : String) -> FromItem {
  match f {
    TableRef(name=tn, as_name~) if tn.equal_ignore_ascii_case(name) =>
      TableRef(name=marker, as_name=Some(as_name.unwrap_or(tn)))
    Join(left~, right~, kind~, natural~, on~, using_cols~) =>
      Join(
        left=replace_rec_ref(left, name, marker),
        right=replace_rec_ref(right, name, marker),
        kind~,
        natural~,
        on~,
        using_cols~,
      )
    _ => f
  }
}

///|
fn is_aggregate_core(sel : Select) -> Bool {
  if sel.group_by.length() > 0 {
    return true
  }
  if sel.having is Some(h) && has_aggregate(h) {
    return true
  }
  for rc in sel.columns {
    if rc is ExprCol(e, _, _) && has_aggregate(e) {
      return true
    }
  }
  false
}

///|
fn rename_columns(
  p : Prepared,
  name : String,
  cols : Array[String]?,
) -> Prepared raise SqlError {
  match cols {
    Some(cs) => {
      if cs.length() != p.names.length() {
        raise SqlError(
          "table \{name} has \{p.names.length()} values for \{cs.length()} columns",
        )
      }
      { ..p, names: cs, }
    }
    None => p
  }
}

///|
/// Prepares the query of a CTE referenced in FROM.
fn Database::expand_cte(
  self : Database,
  def : CteDef,
  parent : Scope?,
) -> Prepared raise SqlError {
  let name = def.decl.name
  if def.err is Some(msg) {
    raise SqlError("\{msg}: \{name}")
  }
  let saved = cte_env.val
  cte_env.val = def.env
  defer {
    cte_env.val = saved
    def.err = None
  }
  def.err = Some("circular reference")
  let q = def.decl.query
  // arms of the body and the operator in front of each
  let arms : Array[Select] = [q]
  let ops : Array[CompoundOp?] = [None]
  for part in q.compound {
    arms.push(part.1)
    ops.push(Some(part.0))
  }
  // recursive selects: the trailing arms reading the CTE directly, joined
  // by the last operator (UNION or UNION ALL)
  let mut rec_start = arms.length()
  if q.compound.length() > 0 {
    let last_op = q.compound[q.compound.length() - 1].0
    if last_op is (UnionAll | Union) {
      let mut k = arms.length() - 1
      while k >= 1 && ops[k] == Some(last_op) {
        let n = direct_refs(arms[k], name)
        if n > 1 {
          raise SqlError("multiple references to recursive table: \{name}")
        }
        if n == 0 {
          break
        }
        rec_start = k
        k -= 1
      }
    }
  }
  if rec_start == arms.length() {
    let p = self.prepare_query(q, parent)
    return rename_columns(p, name, def.decl.cols)
  }
  with_ctes(q.with_, () => {
    self.prepare_recursive(def, arms, ops, rec_start, parent)
  })
}

///|
/// A queued row of a recursive CTE with ORDER BY.
priv struct QItem {
  keys : Array[Value]
  seq : Int
  row : Array[Value]
}

///|
fn qitem_cmp(keys : Array[SortKey], a : QItem, b : QItem) -> Int {
  let c = compare_sort_keys(keys, a.keys, b.keys)
  if c != 0 {
    c
  } else {
    a.seq - b.seq
  }
}

///|
fn heap_push(h : Array[QItem], it : QItem, keys : Array[SortKey]) -> Unit {
  h.push(it)
  let mut i = h.length() - 1
  while i > 0 {
    let p = (i - 1) / 2
    if qitem_cmp(keys, h[i], h[p]) < 0 {
      h.swap(i, p)
      i = p
    } else {
      break
    }
  }
}

///|
fn heap_pop(h : Array[QItem], keys : Array[SortKey]) -> QItem {
  let top = h[0]
  let last = h.pop().unwrap()
  if h.length() > 0 {
    h[0] = last
    let n = h.length()
    let mut i = 0
    while true {
      let l = 2 * i + 1
      let r = l + 1
      let mut m = i
      if l < n && qitem_cmp(keys, h[l], h[m]) < 0 {
        m = l
      }
      if r < n && qitem_cmp(keys, h[r], h[m]) < 0 {
        m = r
      }
      if m == i {
        break
      }
      h.swap(i, m)
      i = m
    }
  }
  top
}

///|
fn Database::prepare_recursive(
  self : Database,
  def : CteDef,
  arms : Array[Select],
  ops : Array[CompoundOp?],
  rec_start : Int,
  parent : Scope?,
) -> Prepared raise SqlError {
  let name = def.decl.name
  let q = def.decl.query
  let corr : Ref[Bool] = { val: false, }
  // the initial (non-recursive) selects
  let cores : Array[CorePlan] = []
  for k in 0..<rec_start {
    let c = self.prepare_core(arms[k], parent, corr, false)
    if k > 0 && c.exprs.length() != cores[0].exprs.length() {
      raise SqlError(
        "SELECTs to the left and right of \{ops[k].unwrap().label()} do not have the same number of result columns",
      )
    }
    cores.push(c)
  }
  let ncols = cores[0].exprs.length()
  let colls : Array[(String, Bool)?] = Array::make(ncols, None)
  for j in 0..<ncols {
    for c in cores {
      if expr_coll(c.exprs[j]) is Some(x) {
        colls[j] = Some(x)
        break
      }
    }
  }
  let plain_colls = colls.map(c => {
    match c {
      Some((x, _)) => x
      None => "BINARY"
    }
  })
  let names = match def.decl.cols {
    Some(cs) => {
      if cs.length() != ncols {
        raise SqlError(
          "table \{name} has \{ncols} values for \{cs.length()} columns",
        )
      }
      cs
    }
    None => cores[0].names
  }
  let affs = cores[0].exprs.map(expr_aff_opt)
  // the recursive table holds the single row being processed
  let current : Ref[Array[Array[Value]]] = { val: [], }
  rec_counter.val += 1
  let marker = "\u{1}rec\{rec_counter.val}"
  rec_tables[marker] = {
    name,
    prepared: {
      names,
      affs,
      colls,
      run: _ => current.val,
      correlated: { val: true, },
    },
  }
  defer rec_tables.remove(marker)
  def.err = Some("multiple recursive references")
  let rec_cores : Array[CorePlan] = []
  for k in rec_start..<arms.length() {
    let arm = arms[k]
    if is_aggregate_core(arm) {
      raise SqlError("recursive aggregate queries not supported")
    }
    let rewritten = {
      ..arm,
      from: arm.from.map(f => replace_rec_ref(f, name, marker)),
    }
    let c = self.prepare_core(rewritten, parent, corr, false)
    if c.exprs.length() != ncols {
      raise SqlError(
        "SELECTs to the left and right of \{ops[k].unwrap().label()} do not have the same number of result columns",
      )
    }
    rec_cores.push(c)
  }
  let all_cores = cores.copy()
  all_cores.append(rec_cores)
  let keys = compound_order_keys(q.order_by, all_cores, plain_colls)
  let distinct = ops[ops.length() - 1] == Some(Union)
  let limit_e = q.limit
  let offset_e = q.offset
  let run = fn(penv : Env) -> Array[Array[Value]] raise SqlError {
    let (limit, offset) = eval_limits(limit_e, offset_e)
    let out : Array[Array[Value]] = []
    if limit == 0L {
      return out
    }
    let mut rows = (cores[0].run)(penv)
    for k in 1..<cores.length() {
      rows = combine_rows(
        ops[k].unwrap(),
        rows,
        (cores[k].run)(penv),
        plain_colls,
      )
    }
    let seen : Set[String] = Set([])
    let fifo : Array[Array[Value]] = []
    let mut head = 0
    let heap : Array[QItem] = []
    let mut seq = 0
    let push = fn(r : Array[Value]) {
      if distinct && !seen.add_and_check(row_key(r, plain_colls)) {
        return
      }
      if keys.length() == 0 {
        fifo.push(r)
      } else {
        heap_push(
          heap,
          { keys: keys.map(k => r[k.result_idx]), seq, row: r, },
          keys,
        )
        seq += 1
      }
    }
    for r in rows {
      push(r)
    }
    let mut skip = offset
    while true {
      let row = if keys.length() == 0 {
        if head >= fifo.length() {
          break
        }
        let r = fifo[head]
        head += 1
        // drop consumed rows now and then
        if head > 4096 && head * 2 > fifo.length() {
          fifo.drain(0, head) |> ignore
          head = 0
        }
        r
      } else {
        if heap.length() == 0 {
          break
        }
        heap_pop(heap, keys).row
      }
      if skip > 0L {
        skip -= 1L
      } else {
        out.push(row)
        if limit > 0L && out.length().to_int64() >= limit {
          break
        }
      }
      current.val = [row]
      for c in rec_cores {
        for r in (c.run)(penv) {
          push(r)
        }
      }
    }
    out
  }
  { names, affs, colls, run, correlated: corr, }
}
