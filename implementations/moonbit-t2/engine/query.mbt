// Query planning and execution: FROM sources and joins, SELECT cores,
// compound queries, VALUES and subqueries.

///|
/// The database executing the current statement (subqueries are prepared
/// while binding expressions).
let cur_db_ref : Ref[Database?] = { val: None, }

///|
fn cur_db() -> Database {
  match cur_db_ref.val {
    Some(db) => db
    None => Database::new()
  }
}

///|
/// A prepared query: result column metadata and a runner taking the
/// environment of the enclosing query.
priv struct Prepared {
  names : Array[String]
  affs : Array[Affinity?]
  colls : Array[(String, Bool)?]
  run : (Env) -> Array[Array[Value]] raise SqlError
  correlated : Ref[Bool]
}

///|
fn Prepared::expect_one_column(self : Prepared) -> Unit raise SqlError {
  let n = self.names.length()
  if n != 1 {
    raise SqlError("sub-select returns \{n} columns - expected 1")
  }
}

///|
fn Prepared::to_subquery(self : Prepared) -> SubQuery {
  {
    run: self.run,
    correlated: self.correlated.val,
    aff: self.affs[0],
    coll: self.colls[0],
    cache: None,
    in_keys: None,
    in_null: false,
  }
}

///|
/// Rows of a subquery for the current outer row (cached when uncorrelated).
fn SubQuery::rows(
  self : SubQuery,
  env : Env,
) -> Array[Array[Value]] raise SqlError {
  if self.correlated {
    return (self.run)(env)
  }
  match self.cache {
    Some(r) => r
    None => {
      let r = (self.run)(env)
      self.cache = Some(r)
      r
    }
  }
}

///|
/// A prepared SELECT or VALUES core.
priv struct CorePlan {
  exprs : Array[Expr]
  aliases : Array[String?]
  names : Array[String]
  scope : Scope
  run : (Env) -> Array[Array[Value]] raise SqlError
}

///|
fn prepared_of(c : CorePlan, corr : Ref[Bool]) -> Prepared {
  {
    names: c.names,
    affs: c.exprs.map(expr_aff_opt),
    colls: c.exprs.map(expr_coll),
    run: c.run,
    correlated: corr,
  }
}

///|
/// A table-like object describing the columns of a subquery in FROM.
fn pseudo_table(name : String, p : Prepared) -> Table {
  let cols : Array[Column] = []
  for i, n in p.names {
    let aff = p.affs[i].unwrap_or(AffUnset)
    cols.push({
      name: n,
      decl_type: "",
      aff,
      coll: match p.colls[i] {
        Some((c, _)) => Some(c)
        None => None
      },
      def: {
        name: n,
        decl_type: "",
        primary_key: false,
        pk_desc: false,
        pk_conflict: CDefault,
        autoincrement: false,
        not_null: false,
        nn_conflict: CDefault,
        unique: false,
        unique_conflict: CDefault,
        default: None,
        checks: [],
        collate: None,
      },
    })
  }
  {
    name,
    columns: cols,
    rows: new_rows(),
    ipk: -1,
    ipk_conflict: CDefault,
    autoinc: false,
    seq: 0L,
    indexes: [],
    checks: [],
    schema_seq: 0,
    rootpage: 0,
    version: 0,
    sql: "",
  }
}

// ---------------------------------------------------------------------------
// Expression helpers
// ---------------------------------------------------------------------------

///|
fn expr_children(e : Expr) -> Array[Expr] {
  let out : Array[Expr] = []
  let _ = e.map_children(x => {
    out.push(x)
    x
  }) catch {
    _ => e
  }
  out
}

///|
/// Adds `d` to the depth of every column reference of a bound expression
/// (containing no subqueries).
fn shift_depth(e : Expr, d : Int) -> Expr {
  if d == 0 {
    return e
  }
  match e {
    Slot(depth~, idx~, aff~, coll~) => Slot(depth=depth + d, idx~, aff~, coll~)
    _ => e.map_children(x => shift_depth(x, d)) catch { _ => e }
  }
}

///|
/// Splits an expression into its AND-ed terms.
fn conjuncts(e : Expr, out : Array[Expr]) -> Unit {
  match e {
    Binary(And, l, r) => {
      conjuncts(l, out)
      conjuncts(r, out)
    }
    _ => out.push(e)
  }
}

///|
/// Structural equality of bound expressions (for matching ORDER BY terms
/// against result columns).
fn expr_equal(a : Expr, b : Expr) -> Bool {
  match (a, b) {
    (Lit(x), Lit(y)) =>
      x.type_name() == y.type_name() && value_compare(x, y) == 0
    (Slot(depth=d1, idx=i1, ..), Slot(depth=d2, idx=i2, ..)) =>
      d1 == d2 && i1 == i2
    (AggRef(idx=i1, ..), AggRef(idx=i2, ..)) => i1 == i2
    (Unary(o1, x1), Unary(o2, x2)) => o1 == o2 && expr_equal(x1, x2)
    (Binary(o1, l1, r1), Binary(o2, l2, r2)) =>
      o1 == o2 && expr_equal(l1, l2) && expr_equal(r1, r2)
    (Collate(x1, c1), Collate(x2, c2)) => c1 == c2 && expr_equal(x1, x2)
    (Cast(x1, t1), Cast(x2, t2)) =>
      t1.to_upper() == t2.to_upper() && expr_equal(x1, x2)
    (IsNull(x1, n1), IsNull(x2, n2)) => n1 == n2 && expr_equal(x1, x2)
    (
      Func(name=n1, args=a1, distinct=d1, ..),
      Func(name=n2, args=a2, distinct=d2, ..),
    ) =>
      n1 == n2 &&
      d1 == d2 &&
      a1.length() == a2.length() &&
      a1.iter().zip(a2.iter()).all(p => expr_equal(p.0, p.1))
    _ => false
  }
}

///|
/// The smallest scope depth of the column references in a bound expression.
fn min_depth(e : Expr) -> Int? {
  match e {
    Slot(depth~, ..) => Some(depth)
    AggRef(depth~, ..) => Some(depth)
    ScalarQ(_) | ExistsQ(_) => None
    _ => {
      let mut m : Int? = None
      for c in expr_children(e) {
        if min_depth(c) is Some(d) && (m is None || Some(d) < m) {
          m = Some(d)
        }
      }
      m
    }
  }
}

///|
/// An aggregate call whose arguments only refer to an enclosing aggregate
/// query belongs to that query: registers it there and returns a reference
/// to its value.
fn outer_aggregate(e : Expr, scope : Scope?) -> Expr? raise SqlError {
  guard e is Func(args~, filter~, ..) && scope is Some(sc) else { return None }
  let parts = args.map(a => bind_expr(a, scope))
  if filter is Some(f) {
    parts.push(bind_expr(f, scope))
  }
  let mut d : Int? = None
  for p in parts {
    if min_depth(p) is Some(x) && (d is None || Some(x) < d) {
      d = Some(x)
    }
  }
  guard d is Some(depth) && depth >= 1 else { return None }
  let mut s = sc
  for _ in 0..<depth {
    match s.parent {
      Some(p) => s = p
      None => return None
    }
  }
  guard s.agg_ctx.val is Some(ctx) else { return None }
  match extract_aggs(e, ctx) {
    AggRef(idx~, coll~, ..) => Some(AggRef(depth~, idx~, coll~))
    _ => None
  }
}

// ---------------------------------------------------------------------------
// Sorting and limits
// ---------------------------------------------------------------------------

///|
/// Stable sort of `rows` by precomputed sort-key values.
fn sort_rows(
  rows : Array[Array[Value]],
  keys : Array[SortKey],
  keyvals : Array[Array[Value]],
) -> Array[Array[Value]] {
  let idx = Array::makei(rows.length(), i => i)
  idx.sort_by((a, b) => {
    let c = compare_sort_keys(keys, keyvals[a], keyvals[b])
    if c != 0 {
      c
    } else {
      a - b
    }
  })
  idx.map(i => rows[i])
}

///|
fn eval_limits(limit : Expr?, offset : Expr?) -> (Int64, Int64) raise SqlError {
  let mut l = -1L
  let mut o = 0L
  match limit {
    Some(e) => {
      l = eval_limit(e)
      match offset {
        Some(x) => o = eval_limit(x)
        None => ()
      }
    }
    None => ()
  }
  if o < 0L {
    o = 0L
  }
  (l, o)
}

///|
fn apply_limit(
  rows : Array[Array[Value]],
  limit : Int64,
  offset : Int64,
) -> Array[Array[Value]] {
  if limit < 0L && offset <= 0L {
    return rows
  }
  let n = rows.length().to_int64()
  let start = if offset > n { n } else { offset }
  let mut end = n
  if limit >= 0L && limit < end - start {
    end = start + limit
  }
  rows[start.to_int():end.to_int()].to_owned()
}

// ---------------------------------------------------------------------------
// FROM clause
// ---------------------------------------------------------------------------

///|
priv struct FromLeaf {
  item : FromItem
  mut kind : JoinKind
  mut natural : Bool
  mut on : Expr?
  mut using_cols : Array[String]?
}

///|
fn flatten_from(item : FromItem, out : Array[FromLeaf]) -> Unit {
  match item {
    Join(left~, right~, kind~, natural~, on~, using_cols~) => {
      flatten_from(left, out)
      let start = out.length()
      flatten_from(right, out)
      let leaf = out[start]
      leaf.kind = kind
      leaf.natural = natural
      leaf.using_cols = using_cols
      if out.length() - start > 1 && on is Some(c) {
        // parenthesized join group: check the condition after its last item
        let last = out[out.length() - 1]
        last.on = match last.on {
          Some(x) => Some(Binary(And, x, c))
          None => Some(c)
        }
        leaf.on = None
      } else {
        leaf.on = on
      }
    }
    _ =>
      out.push({
        item,
        kind: JInner,
        natural: false,
        on: None,
        using_cols: None,
      })
  }
}

///|
fn and_opt(a : Expr?, b : Expr) -> Expr {
  match a {
    Some(x) => Binary(And, x, b)
    None => b
  }
}

///|
/// Builds the sources of a FROM clause, binding join conditions.
fn Database::build_from(
  self : Database,
  from : FromItem?,
  parent : Scope?,
  corr : Ref[Bool],
) -> Array[Source] raise SqlError {
  let sources : Array[Source] = []
  guard from is Some(item) else { return sources }
  let leaves : Array[FromLeaf] = []
  flatten_from(item, leaves)
  let mut offset = 0
  for i, leaf in leaves {
    let src = match leaf.item {
      TableRef(name~, as_name~) if is_rec_marker(name) => {
        let rt = rec_tables[name]
        let sname = as_name.unwrap_or(rt.name)
        new_source(
          sname,
          pseudo_table(sname, rt.prepared),
          offset,
          sub=rt.prepared,
          kind=leaf.kind,
          est_rows=1.0,
        )
      }
      TableRef(name~, as_name~) if find_cte(name) is Some(def) => {
        let p = self.expand_cte(def, parent)
        if p.correlated.val {
          corr.val = true
        }
        let sname = as_name.unwrap_or(def.decl.name)
        new_source(sname, pseudo_table(sname, p), offset, sub=p, kind=leaf.kind)
      }
      TableRef(name~, as_name~) =>
        match self.find_table(name) {
          Some(t) =>
            new_source(as_name.unwrap_or(t.name), t, offset, kind=leaf.kind)
          None => {
            let (p, sname) = match self.find_view(name) {
              Some(v) => (self.prepare_view(v), v.name)
              None =>
                if is_schema_table_name(name) {
                  (self.schema_prepared(), name)
                } else if name.equal_ignore_ascii_case("sqlite_sequence") &&
                  self.sequence_seq > 0 {
                  (self.sequence_prepared(), name)
                } else {
                  raise SqlError("no such table: \{name}")
                }
            }
            let sname = as_name.unwrap_or(sname)
            new_source(
              sname,
              pseudo_table(sname, p),
              offset,
              sub=p,
              kind=leaf.kind,
            )
          }
        }
      SubqueryRef(query~, as_name~) => {
        let p = self.prepare_query(query, parent)
        if p.correlated.val {
          corr.val = true
        }
        let name = as_name.unwrap_or("")
        new_source(name, pseudo_table(name, p), offset, sub=p, kind=leaf.kind)
      }
      Join(..) => abort("unreachable")
    }
    offset += src.table.columns.length() + 1
    sources.push(src)
    if i == 0 {
      continue
    }
    // USING / NATURAL columns
    let using_names : Array[String] = match leaf.using_cols {
      Some(names) => names
      None =>
        if leaf.natural {
          let out : Array[String] = []
          for c in src.table.columns {
            let mut found = false
            for j in 0..<i {
              let l = sources[j]
              if l.table.find_column(c.name) is Some(k) && !l.merged[k] {
                found = true
              }
            }
            if found {
              out.push(c.name)
            }
          }
          out
        } else {
          []
        }
    }
    let mut cond : Expr? = None
    for name in using_names {
      let mut left : (Int, Int)? = None
      for j in 0..<i {
        let l = sources[j]
        if l.table.find_column(name) is Some(k) && !l.merged[k] {
          left = Some((j, k))
          break
        }
      }
      let rc = src.table.find_column(name)
      guard left is Some((lj, lk)) && rc is Some(rk) else {
        raise SqlError(
          "cannot join using column \{name} - column not present in both tables",
        )
      }
      let l = sources[lj]
      let lcol = l.table.columns[lk]
      let lexpr = match l.overrides.get(lk) {
        Some(o) => o
        None => Slot(depth=0, idx=l.offset + lk, aff=lcol.aff, coll=lcol.coll)
      }
      let rcol = src.table.columns[rk]
      let rexpr = Slot(
        depth=0,
        idx=src.offset + rk,
        aff=rcol.aff,
        coll=rcol.coll,
      )
      cond = Some(and_opt(cond, Binary(Eq, lexpr, rexpr)))
      src.merged[rk] = true
      if leaf.kind is (JRight | JFull) {
        l.overrides[lk] = Func(
          name="coalesce",
          args=[lexpr, rexpr],
          distinct=false,
          star=false,
          filter=None,
          order=[],
        )
      }
    }
    match leaf.on {
      Some(on) => {
        let scope = new_scope(sources.copy(), parent, correlated=corr)
        cond = Some(and_opt(cond, bind_expr(on, Some(scope))))
      }
      None => ()
    }
    src.on = cond
  }
  sources
}

///|
/// Materialized rows of one source for a scan.
priv struct SrcRows {
  vals : Array[Array[Value]]
  rowids : Array[Int64]?
  ncols : Int
}

///|
fn source_rows(src : Source, penv : Env) -> SrcRows raise SqlError {
  let ncols = src.table.columns.length()
  match src.sub {
    Some(p) => { vals: (p.run)(penv), rowids: None, ncols, }
    None => {
      let vals : Array[Array[Value]] = []
      let rowids : Array[Int64] = []
      src.table.rows.each_while((rowid, v) => {
        vals.push(v)
        rowids.push(rowid)
        true
      })
      { vals, rowids: Some(rowids), ncols, }
    }
  }
}

///|
fn SrcRows::load(
  self : SrcRows,
  j : Int,
  buf : Array[Value],
  off : Int,
) -> Unit {
  let v = self.vals[j]
  for k in 0..<self.ncols {
    buf[off + k] = v[k]
  }
  buf[off + self.ncols] = match self.rowids {
    Some(r) => Int(r[j])
    None => Null
  }
}

///|
fn null_fill(buf : Array[Value], src : Source) -> Unit {
  for k in 0..<=src.table.columns.length() {
    buf[src.offset + k] = Null
  }
}

///|
/// Nested-loop scan over the sources, calling `f` for every joined row that
/// satisfies the conditions. `level_conds[i]` are checked once sources
/// 0..=i are bound; `final_conds` once all are.
fn scan_sources(
  sources : Array[Source],
  width : Int,
  level_conds : Array[Array[Expr]],
  final_conds : Array[Expr],
  penv : Env,
  f : (Env) -> Unit raise SqlError,
) -> Unit raise SqlError {
  let parent = Some(penv)
  let n = sources.length()
  if n == 0 {
    let env : Env = { row: [], parent, }
    for c in final_conds {
      if truthy(eval(c, env)) != Some(true) {
        return
      }
    }
    f(env)
    return
  }
  let data : Array[SrcRows] = []
  for s in sources {
    data.push(source_rows(s, penv))
  }
  let buf = Array::make(width, Null)
  let env : Env = { row: buf, parent, }
  let matched : Array[Array[Bool]?] = sources.mapi((i, s) => {
    if s.kind is (JRight | JFull) {
      Some(Array::make(data[i].vals.length(), false))
    } else {
      None
    }
  })
  fn check(conds : Array[Expr]) -> Bool raise SqlError {
    for c in conds {
      if truthy(eval(c, env)) != Some(true) {
        return false
      }
    }
    true
  }

  fn level(i : Int) -> Unit raise SqlError {
    if i == n {
      if check(final_conds) {
        f({ row: buf.copy(), parent, })
      }
      return
    }
    let src = sources[i]
    let d = data[i]
    let mut any = false
    for j in 0..<d.vals.length() {
      d.load(j, buf, src.offset)
      if src.on is Some(on) && truthy(eval(on, env)) != Some(true) {
        continue
      }
      any = true
      if matched[i] is Some(m) {
        m[j] = true
      }
      if check(level_conds[i]) {
        level(i + 1)
      }
    }
    if !any && src.kind is (JLeft | JFull) {
      null_fill(buf, src)
      if check(level_conds[i]) {
        level(i + 1)
      }
    }
  }

  level(0)
  // unmatched rows of RIGHT/FULL joins, NULL-extended on the left
  for i in 0..<n {
    if matched[i] is Some(m) {
      for j in 0..<m.length() {
        if m[j] {
          continue
        }
        for k in 0..<i {
          null_fill(buf, sources[k])
        }
        data[i].load(j, buf, sources[i].offset)
        if check(level_conds[i]) {
          level(i + 1)
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// SELECT cores
// ---------------------------------------------------------------------------

///|
/// A group of rows in an aggregate query.
priv struct Group {
  keys : Array[Value]
  first_row : Array[Value]
  accs : Array[AggAcc]
}

///|
fn Database::prepare_values(
  self : Database,
  rows : Array[Array[Expr]],
  parent : Scope?,
  corr : Ref[Bool],
) -> CorePlan raise SqlError {
  ignore(self)
  let width = rows[0].length()
  for r in rows {
    if r.length() != width {
      raise SqlError("all VALUES must have the same number of terms")
    }
  }
  let scope = new_scope([], parent, correlated=corr)
  let bound = rows.map(r => r.map(e => bind_expr(e, Some(scope))))
  let names = Array::makei(width, i => "column\{i + 1}")
  {
    exprs: bound[0],
    aliases: Array::make(width, None),
    names,
    scope,
    run: penv => {
      let env : Env = { row: [], parent: Some(penv), }
      bound.map(r => r.map(e => eval(e, env)))
    },
  }
}

///|
/// Prepares one SELECT core. With `with_order`, its ORDER BY and LIMIT are
/// applied too (a simple, non-compound query).
fn Database::prepare_core(
  self : Database,
  sel : Select,
  parent : Scope?,
  corr : Ref[Bool],
  with_order : Bool,
) -> CorePlan raise SqlError {
  if sel.values is Some(rows) {
    return self.prepare_values(rows, parent, corr)
  }
  let sources = self.build_from(sel.from, parent, corr)
  let mut row_width = 0
  for s in sources {
    row_width += s.table.columns.length() + 1
  }
  let agg_ref : Ref[AggCtx?] = { val: None, }
  let scope = new_scope(sources, parent, correlated=corr, agg_ctx=agg_ref)
  // aggregate query?
  let order_by = if with_order { sel.order_by } else { [] }
  let mut is_agg = sel.group_by.length() > 0 ||
    (sel.having is Some(h) && has_aggregate(h))
  for rc in sel.columns {
    if rc is ExprCol(e, _, _) && has_aggregate(e) {
      is_agg = true
    }
  }
  for t in order_by {
    if has_aggregate(t.expr) {
      is_agg = true
    }
  }
  if !is_agg && sel.having is Some(_) {
    raise SqlError("HAVING clause on a non-aggregate query")
  }
  // window functions: result slots after the row, before any aggregates
  let mut nwin = 0
  for rc in sel.columns {
    if rc is ExprCol(e, _, _) {
      nwin += count_winfuncs(e)
    }
  }
  for t in order_by {
    nwin += count_winfuncs(t.expr)
  }
  let win : WinCtx? = if nwin > 0 {
    Some({
      base: row_width,
      wins: [],
      sorts: [],
      scope,
      named: sel.windows,
      agg: None,
    })
  } else {
    None
  }
  let agg_base = row_width + nwin
  let agg : AggCtx? = if is_agg {
    Some({ base: agg_base, aggs: [], scope, })
  } else {
    None
  }
  agg_ref.val = agg
  if win is Some(w) {
    w.agg = agg
  }
  let (exprs, aliases, names) = expand_result_cols(
    sel.columns,
    scope,
    agg?,
    win?,
  )
  let where_ = match sel.where_ {
    Some(w) => Some(bind_expr(w, Some(scope)))
    None => None
  }
  let alias_list : Array[(String, Expr)] = []
  for j, a in aliases {
    if a is Some(an) {
      alias_list.push((an, exprs[j]))
    }
  }
  let order_scope = new_scope(
    sources,
    parent,
    aliases=alias_list,
    correlated=corr,
    agg_ctx=agg_ref,
  )
  // GROUP BY terms
  let group_exprs : Array[Expr] = []
  if sel.group_by.length() > 0 {
    let galiases : Array[(String, Expr)] = []
    for j, rc in sel.columns {
      if rc is ExprCol(e, Some(an), _) && !has_aggregate(e) {
        galiases.push((an, exprs[j]))
      }
    }
    let gscope = new_scope(
      sources,
      parent,
      aliases=galiases,
      correlated=corr,
      agg_ctx=agg_ref,
    )
    for i, g in sel.group_by {
      if has_aggregate(g) {
        raise SqlError(
          "aggregate functions are not allowed in the GROUP BY clause",
        )
      }
      let ordinal = match g {
        Lit(Int(k)) => Some(k)
        Unary(Pos, Lit(Int(k))) => Some(k)
        Unary(Neg, Lit(Int(k))) => Some(-k)
        _ => None
      }
      match ordinal {
        Some(k) => {
          if k < 1L || k > exprs.length().to_int64() {
            raise SqlError(
              "\{i + 1}\{ordinal_suffix(i + 1)} GROUP BY term out of range - should be between 1 and \{exprs.length()}",
            )
          }
          let j = k.to_int() - 1
          if sel.columns.length() > j &&
            sel.columns[j] is ExprCol(e, _, _) &&
            has_aggregate(e) {
            raise SqlError(
              "aggregate functions are not allowed in the GROUP BY clause",
            )
          }
          group_exprs.push(exprs[j])
        }
        None => group_exprs.push(bind_expr(g, Some(gscope)))
      }
    }
  }
  let having = match (sel.having, agg) {
    (Some(h), Some(ctx)) =>
      Some(bind_expr(extract_aggs(h, ctx), Some(order_scope)))
    _ => None
  }
  // ORDER BY terms
  let keys : Array[SortKey] = []
  for i, t in order_by {
    keys.push(bind_order_term(i, t, exprs, aliases, order_scope, agg, win?))
  }
  let limit_e = if with_order { sel.limit } else { None }
  let offset_e = if with_order { sel.offset } else { None }
  // distinct collations
  let dcolls = exprs.map(x => {
    match expr_coll(x) {
      Some((c, _)) => c
      None => "BINARY"
    }
  })
  let plan = plan_scan(sources, where_)
  // rows already come out in ORDER BY order?
  let ordered = agg is None &&
    win is None &&
    keys.length() > 0 &&
    plan.try_order(
      keys.map(k => {
        expr: k.expr,
        desc: k.desc,
        nulls: k.nulls,
        coll: k.coll,
        any_dir: false,
      }),
      limit_e is Some(_),
    )
  // a lone min()/max() can stop at the first non-NULL value in index order
  let minmax_arg : Expr? = match agg {
    Some(ctx) if group_exprs.length() == 0 && ctx.aggs.length() == 1 => {
      let a = ctx.aggs[0]
      if a.name is ("min" | "max") &&
        a.args.length() == 1 &&
        !a.distinct &&
        a.filter is None &&
        a.order.length() == 0 &&
        plan.try_order(
          [
            {
              expr: a.args[0],
              desc: a.name == "max",
              nulls: 0,
              coll: a.coll,
              any_dir: false,
            },
          ],
          true,
        ) {
        Some(a.args[0])
      } else {
        None
      }
    }
    _ => None
  }
  // GROUP BY through an index: groups come out in scan order (as SQLite
  // emits them), with the direction of a matching ORDER BY term
  let group_ordered = agg is Some(_) &&
    group_exprs.length() > 0 &&
    minmax_arg is None &&
    plan.try_order(
      group_exprs.map(g => {
        let coll = match expr_coll(g) {
          Some((c, _)) => c
          None => "BINARY"
        }
        let mut desc = false
        let mut any_dir = true
        for k in keys {
          if expr_equal(k.expr, g) {
            desc = k.desc
            any_dir = false
            break
          }
        }
        { expr: g, desc, nulls: 0, coll, any_dir, }
      }),
      true,
    )
  let run = fn(penv : Env) -> Array[Array[Value]] raise SqlError {
    let (limit, offset) = eval_limits(limit_e, offset_e)
    let stop : Ref[Bool] = { val: false, }
    let seen : Set[String] = Set([])
    let results : Array[Array[Value]] = []
    let sort_keys : Array[Array[Value]] = []
    // Produces an output row from an environment.
    let emit = fn(env : Env) raise SqlError {
      let out = exprs.map(x => eval(x, env))
      if sel.distinct {
        let sb = StringBuilder()
        for j, v in out {
          value_key(sb, v, dcolls[j])
        }
        if !seen.add_and_check(sb.to_string()) {
          return
        }
      }
      if keys.length() > 0 && !ordered {
        let ks = keys.map(k => {
          if k.result_idx >= 0 {
            out[k.result_idx]
          } else {
            eval(k.expr, env)
          }
        })
        sort_keys.push(ks)
      }
      results.push(out)
      if ordered && limit >= 0L && results.length().to_int64() >= offset + limit {
        stop.val = true
      }
    }
    let scan = fn(f : (Env) -> Unit raise SqlError) raise SqlError {
      plan.run(penv, f, stop~)
    }
    // with window functions, rows are collected and emitted afterwards
    let win_rows : Array[Array[Value]] = []
    let sink = fn(env : Env) raise SqlError {
      match win {
        None => emit(env)
        Some(_) =>
          if env.row.length() >= agg_base {
            win_rows.push(env.row)
          } else {
            let r = Array::make(agg_base, Null)
            for j in 0..<env.row.length() {
              r[j] = env.row[j]
            }
            win_rows.push(r)
          }
      }
    }
    match agg {
      None => scan(sink)
      Some(ctx) => {
        let aggs = ctx.aggs
        // bare columns follow the last min()/max() aggregate
        let mut minmax = -1
        for i, a in aggs {
          if a.name is ("min" | "max") {
            minmax = i
          }
        }
        let gcolls = group_exprs.map(x => {
          match expr_coll(x) {
            Some((c, _)) => c
            None => "BINARY"
          }
        })
        let groups : Map[String, Group] = Map([])
        scan(env => {
          let gk = group_exprs.map(x => eval(x, env))
          let key = if gk.length() == 0 {
            ""
          } else {
            let sb = StringBuilder()
            for j, v in gk {
              value_key(sb, v, gcolls[j])
            }
            sb.to_string()
          }
          let g = match groups.get(key) {
            Some(g) => g
            None => {
              let g : Group = {
                keys: gk,
                first_row: env.row.copy(),
                accs: new_accs(aggs.length()),
              }
              groups[key] = g
              g
            }
          }
          if minmax_arg is Some(x) {
            if !(eval(x, env) is Null) {
              aggs[0].step(g.accs[0], env, true)
              stop.val = true
            }
            return
          }
          for i, a in aggs {
            a.step(g.accs[i], env, i == minmax)
          }
        })
        let glist = groups.values().to_array()
        if group_exprs.length() == 0 && glist.length() == 0 {
          glist.push({
            keys: [],
            first_row: Array::make(row_width, Null),
            accs: new_accs(aggs.length()),
          })
        }
        if group_exprs.length() > 0 && !group_ordered {
          let idx = Array::makei(glist.length(), i => i)
          idx.sort_by((a, b) => {
            let ka = glist[a].keys
            let kb = glist[b].keys
            for j in 0..<ka.length() {
              let c = value_compare_coll(ka[j], kb[j], gcolls[j])
              if c != 0 {
                return c
              }
            }
            a - b
          })
          let sorted = idx.map(i => glist[i])
          glist.clear()
          glist.append(sorted)
        }
        for g in glist {
          let row = Array::make(agg_base + aggs.length(), Null)
          let mut rep = g.first_row
          for i, a in aggs {
            let (v, loaded) = a.finalize(g.accs[i])
            row[agg_base + i] = v
            if i == minmax && loaded is Some(it) {
              rep = it.row
            }
          }
          for j in 0..<row_width {
            row[j] = rep[j]
          }
          let env : Env = { row, parent: Some(penv), }
          match having {
            Some(h) => if truthy(eval(h, env)) != Some(true) { continue }
            None => ()
          }
          sink(env)
        }
      }
    }
    if win is Some(w) {
      compute_windows(w, win_rows, penv)
      for r in win_rows {
        emit({ row: r, parent: Some(penv), })
      }
    }
    let rows = if keys.length() > 0 && !ordered {
      sort_rows(results, keys, sort_keys)
    } else {
      results
    }
    apply_limit(rows, limit, offset)
  }
  { exprs, aliases, names, scope, run, }
}

// ---------------------------------------------------------------------------
// Compound queries
// ---------------------------------------------------------------------------

///|
fn row_key(r : Array[Value], colls : Array[String]) -> String {
  let sb = StringBuilder()
  for j, v in r {
    value_key(sb, v, colls[j])
  }
  sb.to_string()
}

///|
/// Rows in ascending order of all columns (the order SQLite's temporary
/// index produces for UNION, INTERSECT and EXCEPT).
fn sorted_distinct(
  rows : Array[Array[Value]],
  colls : Array[String],
) -> Array[Array[Value]] {
  rows.sort_by((a, b) => {
    for j in 0..<a.length() {
      let c = value_compare_coll(a[j], b[j], colls[j])
      if c != 0 {
        return c
      }
    }
    0
  })
  rows
}

///|
fn combine_rows(
  op : CompoundOp,
  left : Array[Array[Value]],
  right : Array[Array[Value]],
  colls : Array[String],
) -> Array[Array[Value]] {
  match op {
    UnionAll => {
      let out = left.copy()
      out.append(right)
      out
    }
    Union => {
      let m : Map[String, Array[Value]] = Map([])
      for r in left {
        m[row_key(r, colls)] = r
      }
      for r in right {
        m[row_key(r, colls)] = r
      }
      sorted_distinct(m.values().to_array(), colls)
    }
    Intersect | Except => {
      let m : Map[String, Array[Value]] = Map([])
      for r in left {
        m[row_key(r, colls)] = r
      }
      let rk : Set[String] = Set([])
      for r in right {
        rk.add(row_key(r, colls))
      }
      let out : Array[Array[Value]] = []
      for k, r in m {
        if rk.contains(k) == (op == Intersect) {
          out.push(r)
        }
      }
      sorted_distinct(out, colls)
    }
  }
}

///|
/// Sort keys of a compound query's ORDER BY: terms refer to result columns
/// (by ordinal, alias or matching expression).
fn compound_order_keys(
  order_by : Array[OrderTerm],
  cores : Array[CorePlan],
  plain_colls : Array[String],
) -> Array[SortKey] raise SqlError {
  let ncols = cores[0].exprs.length()
  let keys : Array[SortKey] = []
  for i, t in order_by {
    let mut term = t.expr
    let mut explicit : String? = None
    while term is Collate(inner, c) {
      if explicit is None {
        explicit = Some(check_collation(c))
      }
      term = inner
    }
    let ordinal = match term {
      Lit(Int(k)) => Some(k)
      Unary(Pos, Lit(Int(k))) => Some(k)
      Unary(Neg, Lit(Int(k))) => Some(-k)
      _ => None
    }
    let mut idx = -1
    match ordinal {
      Some(k) => {
        if k < 1L || k > ncols.to_int64() {
          raise SqlError(
            "\{i + 1}\{ordinal_suffix(i + 1)} ORDER BY term out of range - should be between 1 and \{ncols}",
          )
        }
        idx = k.to_int() - 1
      }
      None => {
        if term is Col(tbl=None, name~, ..) {
          for c in cores {
            for j, a in c.aliases {
              if a is Some(an) && an.equal_ignore_ascii_case(name) {
                idx = j
                break
              }
            }
            if idx >= 0 {
              break
            }
          }
        }
        if idx < 0 {
          for c in cores {
            let bound = bind_expr(term, Some(c.scope)) catch { _ => continue }
            for j, x in c.exprs {
              if expr_equal(bound, x) {
                idx = j
                break
              }
            }
            if idx >= 0 {
              break
            }
          }
        }
        if idx < 0 {
          raise SqlError(
            "\{i + 1}\{ordinal_suffix(i + 1)} ORDER BY term does not match any column in the result set",
          )
        }
      }
    }
    keys.push({
      expr: cores[0].exprs[idx],
      result_idx: idx,
      desc: t.desc,
      nulls: t.nulls,
      coll: explicit.unwrap_or(plain_colls[idx]),
    })
  }
  keys
}

///|
/// Prepares a full query (possibly compound) whose names may refer to the
/// enclosing scope `parent`.
fn Database::prepare_query(
  self : Database,
  sel : Select,
  parent : Scope?,
) -> Prepared raise SqlError {
  if sel.with_.length() > 0 {
    return with_ctes(sel.with_, () => {
      self.prepare_query({ ..sel, with_: [], }, parent)
    })
  }
  let corr : Ref[Bool] = { val: false, }
  if sel.compound.length() == 0 && sel.values is None {
    return prepared_of(self.prepare_core(sel, parent, corr, true), corr)
  }
  let cores = [self.prepare_core(sel, parent, corr, false)]
  let ncols = cores[0].exprs.length()
  for part in sel.compound {
    let c = self.prepare_core(part.1, parent, corr, false)
    if c.exprs.length() != ncols {
      raise SqlError(
        "SELECTs to the left and right of \{part.0.label()} do not have the same number of result columns",
      )
    }
    cores.push(c)
  }
  // column collations: the leftmost core whose column has one
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
  let keys = compound_order_keys(sel.order_by, cores, plain_colls)
  let ops = sel.compound.map(p => p.0)
  let limit_e = sel.limit
  let offset_e = sel.offset
  let run = fn(penv : Env) -> Array[Array[Value]] raise SqlError {
    let (limit, offset) = eval_limits(limit_e, offset_e)
    let mut rows = (cores[0].run)(penv)
    for k, op in ops {
      rows = combine_rows(op, rows, (cores[k + 1].run)(penv), plain_colls)
    }
    if keys.length() > 0 {
      let kv = rows.map(r => keys.map(k => r[k.result_idx]))
      rows = sort_rows(rows, keys, kv)
    }
    apply_limit(rows, limit, offset)
  }
  {
    names: cores[0].names,
    affs: cores[0].exprs.map(expr_aff_opt),
    colls,
    run,
    correlated: corr,
  }
}
