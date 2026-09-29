// Query planning (binding) and execution: joins, subqueries, compounds.

///|
/// The database of the statement being executed (for subquery binding).
let cur_db : Ref[Database?] = { val: None, }

///|
/// Rows of the enclosing queries while a subquery runs (innermost last).
let outer_stack : Array[Array[Value]] = []

///|
/// Type information of a result column.
priv struct ColInfo {
  name : String
  aff : Affinity?
  coll : Coll?
  explicit : Bool // collation comes from an explicit COLLATE
}

///|
fn col_info_of(name : String, e : Expr) -> ColInfo {
  {
    name,
    aff: expr_affinity(e),
    coll: expr_coll(e),
    explicit: has_explicit_coll(e),
  }
}

///|
/// Comparison info for `l` against a subquery result column.
fn cmp_info_col(l : Expr, r : ColInfo) -> CmpInfo {
  let aff = match (expr_affinity(l), r.aff) {
    (Some(a), Some(b)) =>
      if is_numeric_aff(a) || is_numeric_aff(b) {
        Some(AffNumeric)
      } else {
        None
      }
    (Some(a), None) | (None, Some(a)) =>
      if a == AffNone {
        None
      } else {
        Some(a)
      }
    (None, None) => None
  }
  let coll = if has_explicit_coll(l) {
    expr_coll(l).unwrap_or(CBinary)
  } else if r.explicit {
    r.coll.unwrap_or(CBinary)
  } else {
    match expr_coll(l) {
      Some(c) => c
      None => r.coll.unwrap_or(CBinary)
    }
  }
  { aff, coll, }
}

///|
priv struct SelPlan {
  sources : Array[Source]
  width : Int
  exprs : Array[Expr]
  names : Array[String]
  texts : Array[String] // source text of each result expression
  conj : Array[Array[Expr]] // WHERE conjuncts checked once source k is set
  final_where : Array[Expr] // WHERE conjuncts checked on complete rows
  hkeys : Array[HashKey?] // equi-join lookup per source
  access : Array[Access] // rowid / index lookup per source
  caches : Array[SrcCache] // per source, reused across runs
  group_by : Array[Expr]
  having : Expr?
  actx : AggCtx
  is_agg : Bool
  order_keys : Array[Expr]
  order_by : Array[OrderTerm]
  distinct : Bool
  limit : Expr?
  offset : Expr?
  wfns : Array[WinFn]
}

///|
/// `key = probe` where key uses only one source's columns and probe only
/// earlier sources: rows of that source are looked up by key value.
priv struct HashKey {
  key : Expr
  probe : Expr
  numeric : Bool // numeric comparison affinity applies
  coll : Coll
}

///|
/// Rows of a base table as of a given snapshot, with the lookup index.
priv struct SrcCache {
  mut ver : Int // data_version the rows of a view were computed at (-1: none)
  mut snap : PMap[Int64, Array[Value]]?
  mut data : Array[(Value, Array[Value])]
  mut index : PMap[Value, Array[Int]]?
}

///|
/// True if every slot in `e` lies in [lo, hi) and it holds no subquery.
fn slots_within(e : Expr, lo : Int, hi : Int) -> Bool {
  match e {
    Slot(i, _, _) => i >= lo && i < hi
    SubScalar(_) | SubExists(_) | SubIn(_, _, _, _) | AggRef(_) => false
    _ => expr_children(e).all(c => slots_within(c, lo, hi))
  }
}

///|
fn find_hash_key(cands : Array[Expr], lo : Int, hi : Int) -> HashKey? {
  for c in cands {
    guard c is Cmp(Eq, l, r, info) else { continue }
    if info.aff is Some(AffText) {
      continue
    }
    let numeric = info.aff is Some(AffNumeric | AffInteger | AffReal)
    if max_slot(l) >= lo && slots_within(l, lo, hi) && slots_within(r, 0, lo) {
      return Some({ key: l, probe: r, numeric, coll: info.coll, })
    }
    if max_slot(r) >= lo && slots_within(r, lo, hi) && slots_within(l, 0, lo) {
      return Some({ key: r, probe: l, numeric, coll: info.coll, })
    }
  }
  None
}

///|
priv struct CompPlan {
  first : QPlan
  rest : Array[(CompoundOp, QPlan)]
  cols : Array[ColInfo]
  colls : Array[Coll]
  order : Array[(Int, Bool, Bool, Coll)] // column, desc, nulls first, collation
  limit : Expr?
  offset : Expr?
}

///|
priv enum QPlan {
  PSel(SelPlan)
  PValues(Array[Array[Expr]])
  PComp(CompPlan)
  PRec(RecPlan)
}

///|
priv struct SubPlan {
  plan : QPlan
  corr : Ref[Bool]
  mut cache : Array[Array[Value]]?
  info : ColInfo // first result column
  mut inset : InSet? // lookup set for an uncorrelated IN
}

///|
/// Values of an uncorrelated IN subquery, for fast membership tests.
priv struct InSet {
  raw : PMap[Value, Unit]
  numtext : PMap[Value, Unit] // text forms of numbers (TEXT affinity)
  has_null : Bool
  empty : Bool
}

///|
fn QPlan::cols(self : QPlan) -> Array[ColInfo] {
  match self {
    PSel(p) => p.names.mapi((i, n) => col_info_of(n, p.exprs[i]))
    PValues(rows) =>
      rows[0].mapi((i, _) => {
        name: "column\{i + 1}",
        aff: None,
        coll: None,
        explicit: false,
      })
    PComp(c) => c.cols
    PRec(r) => r.cols
  }
}

///|
fn get_db() -> Database raise SqlError {
  match cur_db.val {
    Some(d) => d
    None => raise sql_err("no database")
  }
}

///|
fn Scope::bind_subquery(
  self : Scope,
  q : Query,
  single : Bool,
) -> SubPlan raise SqlError {
  let corr : Ref[Bool] = { val: false, }
  let plan = prepare_query(q, Some(self), self.level + 1, corr)
  let cols = plan.cols()
  if single && cols.length() != 1 {
    raise sql_err("sub-select returns \{cols.length()} columns - expected 1")
  }
  { plan, corr, cache: None, info: cols[0], inset: None, }
}

///|
fn scope_at(outer : Scope?, level : Int, corr : Ref[Bool]) -> Scope {
  {
    sources: [],
    aliases: [],
    agg: None,
    outer,
    level,
    corr,
    wflag: None,
    win: None,
  }
}

///|
fn prepare_query(
  q : Query,
  outer : Scope?,
  level : Int,
  corr : Ref[Bool],
) -> QPlan raise SqlError {
  match q {
    QSelect(sel) => PSel(prepare_select(sel, outer, level, corr))
    QValues(rows) => {
      let sc = scope_at(outer, level, corr)
      PValues(rows.map(r => r.map(e => sc.bind(e))))
    }
    QCompound(first~, rest~, order_by~, limit~, offset~) => {
      let fp = prepare_query(first, outer, level, corr)
      let members = [fp]
      let prest : Array[(CompoundOp, QPlan)] = []
      let n = fp.cols().length()
      for r in rest {
        let p = prepare_query(r.1, outer, level, corr)
        if p.cols().length() != n {
          let opname = match r.0 {
            UnionAll => "UNION ALL"
            Union => "UNION"
            Intersect => "INTERSECT"
            Except => "EXCEPT"
          }
          raise sql_err(
            "SELECTs to the left and right of \{opname} do not have the same number of result columns",
          )
        }
        members.push(p)
        prest.push((r.0, p))
      }
      let mcols = members.map(m => m.cols())
      let cols : Array[ColInfo] = []
      let colls : Array[Coll] = []
      for i in 0..<n {
        let mut ci = mcols[0][i]
        for mc in mcols {
          if mc[i].coll is Some(_) {
            ci = { ..mcols[0][i], coll: mc[i].coll, explicit: mc[i].explicit, }
            break
          }
        }
        cols.push(ci)
        colls.push(ci.coll.unwrap_or(CBinary))
      }
      let order = compound_order(order_by, members, mcols, colls)
      let sc = scope_at(outer, level, corr)
      PComp({
        first: fp,
        rest: prest,
        cols,
        colls,
        order,
        limit: limit.map(e => sc.bind(e)),
        offset: offset.map(e => sc.bind(e)),
      })
    }
    QWith(ctes~, body~) => {
      let base = push_ctes(ctes)
      let p = prepare_query(body, outer, level, corr) catch {
        e => {
          cte_stack.truncate(base)
          raise e
        }
      }
      cte_stack.truncate(base)
      p
    }
  }
}

///|
/// Resolve the ORDER BY of a compound query to result column numbers.
fn compound_order(
  order_by : Array[OrderTerm],
  members : Array[QPlan],
  mcols : Array[Array[ColInfo]],
  colls : Array[Coll],
) -> Array[(Int, Bool, Bool, Coll)] raise SqlError {
  let n = colls.length()
  let order : Array[(Int, Bool, Bool, Coll)] = []
  for k, t in order_by {
    let (inner, ecoll) = match t.expr {
      Collate(x, c) => (x, Some(c))
      e => (e, None)
    }
    let idx = match inner {
      Lit(Int(v)) => {
        if v < 1L || v > n.to_int64() {
          raise sql_err(
            "\{ordinal(k + 1)} ORDER BY term out of range - should be between 1 and \{n}",
          )
        }
        v.to_int() - 1
      }
      Column(name~, ..) => {
        let mut hit = -1
        for mc in mcols {
          for i, c in mc {
            if hit < 0 && same_name(c.name, name) {
              hit = i
            }
          }
        }
        hit
      }
      _ => -1
    }
    let idx = if idx >= 0 || t.text == "" {
      idx
    } else {
      let want = norm_text(t.text)
      let mut hit = -1
      for m in members {
        if m is PSel(sp) {
          for i, tx in sp.texts {
            if hit < 0 && tx == want {
              hit = i
            }
          }
        }
      }
      hit
    }
    if idx < 0 {
      raise sql_err(
        "\{ordinal(k + 1)} ORDER BY term does not match any column in the result set",
      )
    }
    order.push(
      (
        idx,
        t.desc,
        t.nulls_first.unwrap_or(!t.desc),
        ecoll.unwrap_or(colls[idx]),
      ),
    )
  }
  order
}

///|
/// Expression text normalised for comparison (case and spacing ignored).
fn norm_text(s : String) -> String {
  let sb = StringBuilder()
  for c in s {
    if !c.is_ascii_whitespace() {
      sb.write_char(c.to_ascii_lowercase())
    }
  }
  sb.to_string()
}

///|
fn ordinal(n : Int) -> String {
  let suffix = if n % 100 >= 11 && n % 100 <= 13 {
    "th"
  } else {
    match n % 10 {
      1 => "st"
      2 => "nd"
      3 => "rd"
      _ => "th"
    }
  }
  "\{n}\{suffix}"
}

///|
fn coll_name(c : Coll) -> String {
  match c {
    CBinary => "BINARY"
    CNoCase => "NOCASE"
    CRTrim => "RTRIM"
  }
}

///|
/// Column definitions describing a subquery's result.
fn derived_cols(cols : Array[ColInfo]) -> Array[ColumnDef] {
  cols.map(c => {
    name: c.name,
    type_name: "",
    affinity: c.aff.unwrap_or(AffNone),
    not_null: false,
    primary_key: false,
    pk_desc: false,
    autoincrement: false,
    unique: false,
    default_: None,
    collate: c.coll.map(coll_name),
    checks: [],
    pk_conflict: None,
    nn_conflict: None,
    unique_conflict: None,
  })
}

///|
fn split_and(e : Expr, out : Array[Expr]) -> Unit {
  match e {
    Binary(And, l, r) => {
      split_and(l, out)
      split_and(r, out)
    }
    _ => out.push(e)
  }
}

///|
/// Highest slot referenced by the expression (-1 if none); -2 if it holds
/// a subquery (which must be checked on the complete row).
fn max_slot(e : Expr) -> Int {
  match e {
    Slot(i, _, _) => i
    SubScalar(_) | SubExists(_) | SubIn(_, _, _, _) => -2
    Outer(_, _) => -1
    _ => {
      let mut m = -1
      for c in expr_children(e) {
        let x = max_slot(c)
        if x == -2 {
          return -2
        }
        if x > m {
          m = x
        }
      }
      m
    }
  }
}

///|
fn prepare_select(
  sel : Select,
  outer : Scope?,
  level : Int,
  corr : Ref[Bool],
) -> SelPlan raise SqlError {
  let db = get_db()
  // sources
  let sources : Array[Source] = []
  let mut offset = 0
  let mut has_right = false
  let join_conds : Array[Array[Expr]] = []
  for k, f in sel.from {
    let src = match f.src {
      FTable(name) if find_cte(name) is Some(cte) => {
        let (p, cols, rec) = cte_source(cte, f, level)
        let sname = match f.as_name {
          Some(a) => a
          None => name
        }
        let src = new_source(sname, cols, offset, false, None, p, f.join)
        match rec {
          Some(buf) => src.rec = Some(buf)
          None => src.view = true
        }
        src
      }
      FTable(name) =>
        match db.tables.get(key_of(name)) {
          Some(t) => {
            let sname = match f.as_name {
              Some(a) => a
              None => t.name
            }
            new_source(sname, t.cols, offset, false, Some(t), None, f.join)
          }
          None =>
            match db.views.get(key_of(name)) {
              Some(v) => {
                let p = prepare_view(v, level)
                let cols = derived_cols(p.cols())
                if v.cols is Some(names) {
                  if names.length() != cols.length() {
                    raise sql_err(
                      "expected \{names.length()} columns for '\{v.name}' but got \{cols.length()}",
                    )
                  }
                  for i, n in names {
                    cols[i] = { ..cols[i], name: n, }
                  }
                }
                let sname = match f.as_name {
                  Some(a) => a
                  None => v.name
                }
                let src = new_source(
                  sname,
                  cols,
                  offset,
                  false,
                  None,
                  Some(p),
                  f.join,
                )
                src.view = true
                src
              }
              None =>
                if is_schema_name(name) || db.has_seq_table(name) {
                  let t = if is_schema_name(name) {
                    db.schema_table(name)
                  } else {
                    db.sequence_table(name)
                  }
                  let sname = match f.as_name {
                    Some(a) => a
                    None => name
                  }
                  new_source(
                    sname,
                    t.cols,
                    offset,
                    false,
                    Some(t),
                    None,
                    f.join,
                  )
                } else {
                  raise sql_err("no such table: main.\{name}")
                }
            }
        }
      FSub(q) => {
        let fcorr : Ref[Bool] = { val: false, }
        let p = prepare_query(q, outer, level, fcorr)
        if fcorr.val {
          corr.val = true
        }
        let sname = match f.as_name {
          Some(a) => a
          None => "subquery_\{k}"
        }
        let src = new_source(
          sname,
          derived_cols(p.cols()),
          offset,
          false,
          None,
          Some(p),
          f.join,
        )
        src.view = !fcorr.val
        src
      }
    }
    if f.join is (JRight | JFull) {
      has_right = true
    }
    sources.push(src)
    offset += src.cols.length() + 1
    // join constraint
    if k == 0 {
      continue
    }
    let conds : Array[Expr] = []
    let pairs : Array[String] = []
    if f.natural {
      for c in src.cols {
        if left_col(sources, k, c.name) is Some(_) {
          pairs.push(c.name)
        }
      }
    }
    if f.using_ is Some(names) {
      for n in names {
        pairs.push(n)
      }
    }
    for n in pairs {
      let li = left_col(sources, k, n)
      let ri = src.col_index(n)
      guard li is Some((ls, lc)) && ri is Some(rc) else {
        raise sql_err(
          "cannot join using column \{n} - column not present in both tables",
        )
      }
      let l = sources[ls].col_expr(lc)
      let r = src.col_expr(rc)
      conds.push(Cmp(Eq, l, r, cmp_info(l, r)))
      src.hide[rc] = true
      if f.join is (JRight | JFull) {
        let args = [l, r]
        sources[ls].over[lc] = Some(
          Func(
            name="COALESCE",
            args~,
            star=false,
            distinct=false,
            coll=first_coll(args),
            filter=None,
            order=[],
          ),
        )
      }
    }
    join_conds.push(conds)
  }
  // ON clauses see every table of the FROM clause; an inner join's terms
  // that refer to tables on its right act like WHERE terms.
  let osc : Scope = {
    sources,
    aliases: [],
    agg: None,
    outer,
    level,
    corr,
    wflag: None,
    win: None,
  }
  let late_on : Array[Expr] = []
  for k, f in sel.from {
    if k == 0 {
      continue
    }
    let src = sources[k]
    let conds = join_conds[k - 1]
    if f.on is Some(on) {
      let parts : Array[Expr] = []
      split_and(osc.bind(on), parts)
      let hi = src.offset + src.cols.length() + 1
      for p in parts {
        if slots_within(p, 0, hi) || !(max_slot(p) >= hi) {
          conds.push(p)
        } else if f.join == JInner {
          late_on.push(p)
        } else {
          raise sql_err("ON clause references tables to its right")
        }
      }
    }
    if conds.length() > 0 {
      let mut c = conds[0]
      for i in 1..<conds.length() {
        c = Binary(And, c, conds[i])
      }
      src.on = Some(c)
    }
  }
  let width = offset
  let actx : AggCtx = { specs: [], base: width, inside: false, }
  let wctx : WinCtx = { fns: [], base: { val: width, }, defs: sel.windows, }
  let scope : Scope = {
    sources,
    aliases: [],
    agg: Some(actx),
    outer,
    level,
    corr,
    wflag: None,
    win: Some(wctx),
  }
  for i, s in sources {
    for j in 0..<i {
      if same_name(sources[j].name, s.name) &&
        sel.cols.any(c => {
          c is Star || (c is TableStar(tn) && same_name(tn, s.name))
        }) {
        let c0 = if s.cols.length() > 0 { s.cols[0].name } else { "" }
        raise sql_err("ambiguous column name: main.\{s.name}.\{c0}")
      }
    }
  }
  let wflag : Ref[String] = { val: "", }
  let wscope : Scope = { ..scope, agg: None, wflag: Some(wflag), win: None, }
  let explicit : Array[(String, Expr)] = []
  // result columns
  let exprs : Array[Expr] = []
  let names : Array[String] = []
  let texts : Array[String] = []
  for c in sel.cols {
    match c {
      Star => {
        if sources.length() == 0 {
          raise sql_err("no tables specified")
        }
        for s in sources {
          if s.hidden {
            continue
          }
          for i, cd in s.cols {
            if s.hide[i] {
              continue
            }
            exprs.push(
              match s.over[i] {
                Some(e) => e
                None => s.col_expr(i)
              },
            )
            names.push(cd.name)
            texts.push("")
          }
        }
      }
      TableStar(tn) => {
        let mut found = false
        for s in sources {
          if same_name(s.name, tn) {
            found = true
            for i, cd in s.cols {
              exprs.push(s.col_expr(i))
              names.push(cd.name)
              texts.push("")
            }
            break
          }
        }
        if !found {
          raise sql_err("no such table: \{tn}")
        }
      }
      ExprCol(e, as_name, text) => {
        let b = scope.bind(e)
        exprs.push(b)
        texts.push(norm_text(text))
        names.push(
          match as_name {
            Some(a) => a
            None =>
              match e {
                Column(name~, ..) => name
                _ => text
              }
          },
        )
        if as_name is Some(a) {
          explicit.push((a, b))
        }
      }
    }
  }
  // WHERE, split into conjuncts checked as early as possible
  let conj : Array[Array[Expr]] = sources.map(_ => [])
  let final_where : Array[Expr] = []
  let parts : Array[Expr] = late_on
  if sel.where_ is Some(w) {
    split_and({ ..wscope, aliases: explicit, }.bind(w), parts)
  }
  if parts.length() > 0 {
    for p in parts {
      let m = max_slot(p)
      if has_right || m == -2 || sources.length() == 0 {
        final_where.push(p)
        continue
      }
      let mut k = 0
      for i, s in sources {
        if m >= s.offset {
          k = i
        }
      }
      conj[k].push(p)
    }
  }
  // GROUP BY / HAVING
  let gscope : Scope = { ..wscope, aliases: explicit, wflag: None, }
  let group_by : Array[Expr] = []
  for g in sel.group_by {
    let out_of_range = () => {
      sql_err(
        "GROUP BY term out of range - should be between 1 and \{exprs.length()}",
      )
    }
    let ge = match g {
      Lit(Int(k)) => {
        if k < 1L || k > exprs.length().to_int64() {
          raise out_of_range()
        }
        exprs[k.to_int() - 1]
      }
      Unary(Neg, Lit(Int(_))) => raise out_of_range()
      _ => gscope.bind(g)
    }
    if contains_agg(ge) {
      raise sql_err(
        "aggregate functions are not allowed in the GROUP BY clause",
      )
    }
    if contains_win(ge) {
      raise sql_err("misuse of window function in GROUP BY")
    }
    group_by.push(ge)
  }
  if sel.having is Some(_) && actx.specs.length() == 0 && group_by.length() == 0 {
    raise sql_err("HAVING clause on a non-aggregate query")
  }
  let hscope : Scope = { ..scope, aliases: explicit, win: None, }
  let having = match sel.having {
    Some(h) => Some(hscope.bind(h))
    None => None
  }
  let is_agg0 = actx.specs.length() > 0 || group_by.length() > 0
  // ORDER BY keys
  let oscope : Scope = {
    ..scope,
    aliases: explicit,
    agg: if is_agg0 {
      Some(actx)
    } else {
      None
    },
  }
  let order_keys : Array[Expr] = []
  for term in sel.order_by {
    order_keys.push(resolve_order_term(term.expr, exprs, explicit, oscope))
  }
  let hkeys : Array[HashKey?] = []
  let access : Array[Access] = []
  for k, s in sources {
    let cands : Array[Expr] = []
    if k > 0 && s.on is Some(on) {
      split_and(on, cands)
    }
    if k == 0 || s.join == JInner {
      for c in conj[k] {
        cands.push(c)
      }
    }
    hkeys.push(find_hash_key(cands, s.offset, s.offset + s.cols.length() + 1))
    let hint : OrderHint? = if k > 0 || is_agg0 {
      None
    } else if order_keys.length() > 0 {
      Some({ key: order_keys[0], desc: sel.order_by[0].desc, any_dir: false, })
    } else if sel.distinct && exprs.length() > 0 {
      Some({ key: exprs[0], desc: false, any_dir: true, })
    } else {
      None
    }
    access.push(
      match s.table {
        Some(t) if !has_right =>
          choose_access(
            t,
            s.offset,
            cands,
            hint,
            Some(s.used),
            hkeys[k] is None,
          )
        _ => AScan
      },
    )
  }
  if wflag.val != "" && actx.specs.length() == 0 && group_by.length() == 0 {
    raise sql_err("misuse of aggregate function \{wflag.val}()")
  }
  let lscope = scope_at(outer, level, corr)
  let is_agg = actx.specs.length() > 0 || group_by.length() > 0
  wctx.base.val = if is_agg { width + actx.specs.length() } else { width }
  {
    sources,
    width,
    exprs,
    names,
    texts,
    conj,
    final_where,
    hkeys,
    access,
    caches: sources.map(_ => { ver: -1, snap: None, data: [], index: None, }),
    group_by,
    having,
    actx,
    is_agg,
    order_keys,
    order_by: sel.order_by,
    distinct: sel.distinct,
    limit: sel.limit.map(e => lscope.bind(e)),
    offset: sel.offset.map(e => lscope.bind(e)),
    wfns: wctx.fns,
  }
}

///|
/// Views being expanded (to detect circular definitions).
let view_stack : Array[String] = []

///|
fn prepare_view(v : View, level : Int) -> QPlan raise SqlError {
  let k = key_of(v.name)
  if view_stack.contains(k) {
    raise sql_err("view \{v.name} is circularly defined")
  }
  view_stack.push(k)
  let saved = cte_stack.copy()
  cte_stack.clear()
  let p = prepare_query(v.query, None, level, { val: false, }) catch {
    e => {
      ignore(view_stack.pop())
      cte_stack.append(saved)
      raise e
    }
  }
  ignore(view_stack.pop())
  cte_stack.append(saved)
  p
}

///|
/// First visible column called `name` among sources[0..k): (source, column).
fn left_col(sources : Array[Source], k : Int, name : String) -> (Int, Int)? {
  for i in 0..<k {
    let s = sources[i]
    match s.col_index(name) {
      Some(c) if !s.hide[c] => return Some((i, c))
      _ => ()
    }
  }
  None
}

///|
/// Evaluate a LIMIT or OFFSET expression.
fn eval_limit(e : Expr) -> Int64 raise SqlError {
  let v = eval(e, [])
  match apply_affinity(v, AffNumeric) {
    Int(i) => i
    Real(d) =>
      match real_to_int_exact(d) {
        Some(i) => i
        None => raise sql_err("datatype mismatch")
      }
    _ => raise sql_err("datatype mismatch")
  }
}

///|
/// Evaluate optional LIMIT / OFFSET: (limit or -1, offset >= 0).
fn eval_limits(limit : Expr?, offset : Expr?) -> (Int64, Int64) raise SqlError {
  let l = match limit {
    Some(e) => eval_limit(e)
    None => -1L
  }
  let o = match offset {
    Some(e) => {
      let o = eval_limit(e)
      if o < 0L {
        0L
      } else {
        o
      }
    }
    None => 0L
  }
  (l, o)
}

///|
fn[T] apply_limits(rows : Array[T], limit : Int64, skip : Int64) -> Array[T] {
  let n = rows.length().to_int64()
  let start = if skip < n { skip } else { n }
  let end = if limit < 0L || limit >= n - start { n } else { start + limit }
  if start == 0L && end == n {
    return rows
  }
  rows[start.to_int():end.to_int()].to_owned()
}

///|
/// Resolve an ORDER BY term: ordinal, result as_name, or expression.
fn resolve_order_term(
  e : Expr,
  exprs : Array[Expr],
  explicit : Array[(String, Expr)],
  oscope : Scope,
) -> Expr raise SqlError {
  let (inner, coll) = match e {
    Collate(x, c) => (x, Some(c))
    _ => (e, None)
  }
  let out_of_range = () => {
    sql_err(
      "ORDER BY term out of range - should be between 1 and \{exprs.length()}",
    )
  }
  let key = match inner {
    Lit(Int(k)) => {
      if k < 1L || k > exprs.length().to_int64() {
        raise out_of_range()
      }
      exprs[k.to_int() - 1]
    }
    Unary(Neg, Lit(Int(_))) => raise out_of_range()
    Column(tbl=None, name~, ..) => {
      let mut hit : Expr? = None
      for a in explicit {
        if same_name(a.0, name) {
          hit = Some(a.1)
          break
        }
      }
      match hit {
        Some(h) => h
        None => oscope.bind(inner)
      }
    }
    _ => oscope.bind(inner)
  }
  match coll {
    Some(c) => Collate(key, c)
    None => key
  }
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

///|
/// Run a top-level query; returns the rows and the number of columns.
fn Database::run_query(
  self : Database,
  q : Query,
) -> (Array[Array[Value]], Int) raise SqlError {
  cur_db.val = Some(self)
  let p = prepare_query(q, None, 0, { val: false, })
  (p.run(-1L), p.cols().length())
}

///|
/// Evaluate a subquery for the current row of the enclosing query.
fn SubPlan::rows(
  self : SubPlan,
  row : Array[Value],
  max_rows : Int64,
) -> Array[Array[Value]] raise SqlError {
  if !self.corr.val && self.cache is Some(c) {
    return c
  }
  outer_stack.push(row)
  let r = self.plan.run(max_rows) catch {
    e => {
      ignore(outer_stack.pop())
      raise e
    }
  }
  ignore(outer_stack.pop())
  if !self.corr.val {
    self.cache = Some(r)
  }
  r
}

///|
fn eval_outer(depth : Int, e : Expr) -> Value raise SqlError {
  let n = outer_stack.length()
  if depth > n {
    raise sql_err("invalid outer reference")
  }
  eval(e, outer_stack[n - depth])
}

///|
fn eval_sub_in(
  x : Expr,
  sp : SubPlan,
  neg : Bool,
  info : CmpInfo,
  row : Array[Value],
) -> Value raise SqlError {
  let xv = eval(x, row)
  if !sp.corr.val {
    let set = match sp.inset {
      Some(s) => s
      None => {
        let rows = sp.rows(row, -1L)
        let coll = info.coll
        let cmp = (a : Value, b : Value) => compare_coll(a, b, coll)
        let mut raw : PMap[Value, Unit] = PMap::empty(cmp)
        let mut numtext : PMap[Value, Unit] = PMap::empty(cmp)
        let mut has_null = false
        for r in rows {
          let v = r[0]
          match v {
            Null => has_null = true
            _ =>
              match info.aff {
                Some(AffNumeric | AffInteger | AffReal) =>
                  raw = raw.add(apply_numeric_cmp(v), ())
                Some(AffText) => {
                  raw = raw.add(v, ())
                  if v is (Int(_) | Real(_)) {
                    numtext = numtext.add(num_to_text(v), ())
                  }
                }
                _ => raw = raw.add(v, ())
              }
          }
        }
        let s : InSet = { raw, numtext, has_null, empty: rows.length() == 0, }
        sp.inset = Some(s)
        s
      }
    }
    if set.empty {
      return bool_val(neg)
    }
    if xv is Null {
      return Null
    }
    let found = match info.aff {
      Some(AffNumeric | AffInteger | AffReal) =>
        set.raw.find(apply_numeric_cmp(xv)) is Some(_)
      Some(AffText) =>
        match xv {
          Text(_) =>
            set.raw.find(xv) is Some(_) || set.numtext.find(xv) is Some(_)
          Int(_) | Real(_) =>
            set.raw.find(xv) is Some(_) ||
            set.raw.find(num_to_text(xv)) is Some(_)
          _ => set.raw.find(xv) is Some(_)
        }
      _ => set.raw.find(xv) is Some(_)
    }
    return if found {
      bool_val(!neg)
    } else if set.has_null {
      Null
    } else {
      bool_val(neg)
    }
  }
  let rows = sp.rows(row, -1L)
  if rows.length() == 0 {
    return bool_val(neg)
  }
  if xv is Null {
    return Null
  }
  let mut has_null = false
  for r in rows {
    let v = r[0]
    if v is Null {
      has_null = true
      continue
    }
    let (a, b) = cmp_prepare(xv, v, info.aff)
    if compare_coll(a, b, info.coll) == 0 {
      return bool_val(!neg)
    }
  }
  if has_null {
    Null
  } else {
    bool_val(neg)
  }
}

///|
fn QPlan::run(
  self : QPlan,
  max_rows : Int64,
) -> Array[Array[Value]] raise SqlError {
  match self {
    PSel(p) => p.run(max_rows)
    PValues(rows) => rows.map(r => r.map(e => eval(e, [])))
    PComp(c) => c.run()
    PRec(r) => r.run()
  }
}

///|
fn rows_cmp(colls : Array[Coll]) -> (Array[Value], Array[Value]) -> Int {
  (a, b) => {
    for i in 0..<a.length() {
      let c = compare_coll(a[i], b[i], colls[i])
      if c != 0 {
        return c
      }
    }
    0
  }
}

///|
/// Sort rows and drop duplicates (the first of each equal run is kept).
fn sort_distinct(
  rows : Array[Array[Value]],
  colls : Array[Coll],
) -> Array[Array[Value]] {
  let cmp = rows_cmp(colls)
  stable_sort(rows, cmp)
  let out : Array[Array[Value]] = []
  for r in rows {
    if out.length() > 0 && cmp(out[out.length() - 1], r) == 0 {
      continue
    }
    out.push(r)
  }
  out
}

///|
fn CompPlan::run(self : CompPlan) -> Array[Array[Value]] raise SqlError {
  let colls = self.colls
  let mut acc = self.first.run(-1L)
  for m in self.rest {
    let rows = m.1.run(-1L)
    match m.0 {
      UnionAll => acc = acc + rows
      Union => acc = sort_distinct(acc + rows, colls)
      Intersect | Except => {
        let mut set : PMap[Array[Value], Unit] = PMap::empty(rows_cmp(colls))
        for r in rows {
          set = set.add(r, ())
        }
        let keep = m.0 == Intersect
        acc = sort_distinct(
          acc.filter(r => (set.find(r) is Some(_)) == keep),
          colls,
        )
      }
    }
  }
  if self.order.length() > 0 {
    let order = self.order
    stable_sort(acc, (a, b) => {
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
    })
  }
  let (limit, skip) = eval_limits(self.limit, self.offset)
  apply_limits(acc, limit, skip)
}

///|
priv struct SortRow {
  vals : Array[Value]
  keys : Array[Value]
}

///|
fn SelPlan::run(
  self : SelPlan,
  max_rows : Int64,
) -> Array[Array[Value]] raise SqlError {
  let sources = self.sources
  let n = sources.length()
  let width = self.width
  let exprs = self.exprs
  let order_keys = self.order_keys
  let group_by = self.group_by
  let is_agg = self.is_agg
  let (limit, skip) = eval_limits(self.limit, self.offset)
  let mut stop_at = @int64.MAX_VALUE
  if limit >= 0L && skip <= @int64.MAX_VALUE - limit {
    stop_at = skip + limit
  }
  if max_rows >= 0L && skip + max_rows < stop_at {
    stop_at = skip + max_rows
  }
  let wfns = self.wfns
  let pre : Array[Array[Value]] = []
  let early = order_keys.length() == 0 &&
    wfns.length() == 0 &&
    !self.distinct &&
    !is_agg &&
    stop_at < @int64.MAX_VALUE
  // source rows
  let data : Array[Array[(Value, Array[Value])]] = []
  let indexes : Array[PMap[Value, Array[Int]]?] = sources.map(_ => None)
  for k, s in sources {
    if !(self.access[k] is AScan) {
      data.push([])
      continue
    }
    match s.table {
      Some(t) => {
        let c = self.caches[k]
        if !(c.snap is Some(r) && physical_equal(r, t.rows)) {
          c.snap = Some(t.rows)
          c.data = t.rows.to_array().map(p => (Int(p.0), p.1))
          c.index = None
        }
        data.push(c.data)
        indexes[k] = c.index
      }
      None =>
        match s.sub {
          Some(p) =>
            if s.view {
              let c = self.caches[k]
              if c.ver != data_version.val {
                c.data = p.run(-1L).map(r => (Null, r))
                c.index = None
                c.ver = data_version.val
              }
              data.push(c.data)
              indexes[k] = c.index
            } else {
              data.push(p.run(-1L).map(r => (Null, r)))
            }
          None =>
            match s.rec {
              Some(r) => data.push(r.val.map(x => (Null, x)))
              None => data.push([])
            }
        }
    }
  }
  let rmatched : Array[Array[Bool]] = data.mapi((k, d) => {
    if sources[k].join is (JRight | JFull) {
      Array::make(d.length(), false)
    } else {
      []
    }
  })
  let out : Array[SortRow] = []
  let row : Array[Value] = Array::make(width, Null)
  let gcolls = group_by.map(e => expr_coll(e).unwrap_or(CBinary))
  let mut groups : PMap[Array[Value], Group] = PMap::empty(key_cmp(gcolls))
  let single = new_group(self.actx.specs, width)
  fn check_all(cs : Array[Expr]) -> Bool raise SqlError {
    for c in cs {
      if !(eval(c, row).truth() is Some(true)) {
        return false
      }
    }
    true
  }

  fn emit() -> Bool raise SqlError {
    if !check_all(self.final_where) {
      return true
    }
    if is_agg {
      if group_by.length() == 0 {
        single.add_row(row)
      } else {
        let key = group_by.map(e => eval(e, row))
        let g = match groups.find(key) {
          Some(g) => g
          None => {
            let g = new_group(self.actx.specs, width)
            groups = groups.add(key, g)
            g
          }
        }
        g.add_row(row)
      }
      return true
    }
    if wfns.length() > 0 {
      pre.push(row.copy())
      return true
    }
    let vals = exprs.map(e => eval(e, row))
    let keys = order_keys.map(e => eval(e, row))
    out.push({ vals, keys, })
    !(early && out.length().to_int64() >= stop_at)
  }

  fn set_row(k : Int, rid : Value, vals : Array[Value]) -> Unit {
    let s = sources[k]
    let nc = s.cols.length()
    for i in 0..<nc {
      row[s.offset + i] = vals[i]
    }
    row[s.offset + nc] = rid
  }

  fn set_null(k : Int) -> Unit {
    let s = sources[k]
    for i in 0..<=s.cols.length() {
      row[s.offset + i] = Null
    }
  }

  fn hash_val(v : Value, hk : HashKey) -> Value {
    if hk.numeric {
      apply_numeric_cmp(v)
    } else {
      v
    }
  }

  // candidate rows of source k for the current row of the earlier sources
  fn candidates(k : Int) -> Array[Int]? raise SqlError {
    guard self.hkeys[k] is Some(hk) else { return None }
    let idx = match indexes[k] {
      Some(m) => m
      None => {
        let coll = hk.coll
        let mut m : PMap[Value, Array[Int]] = PMap::empty((a, b) => {
          compare_coll(a, b, coll)
        })
        for j, pair in data[k] {
          set_row(k, pair.0, pair.1)
          let v = eval(hk.key, row)
          if v is Null {
            continue
          }
          let hv = hash_val(v, hk)
          match m.find(hv) {
            Some(list) => list.push(j)
            None => m = m.add(hv, [j])
          }
        }
        indexes[k] = Some(m)
        if sources[k].table is Some(_) || sources[k].view {
          self.caches[k].index = Some(m)
        }
        m
      }
    }
    let p = eval(hk.probe, row)
    if p is Null {
      return Some([])
    }
    Some(idx.find(hash_val(p, hk)).unwrap_or([]))
  }

  fn scan(k : Int) -> Bool raise SqlError {
    if k == n {
      return emit()
    }
    let s = sources[k]
    let mut matched = false
    if !(self.access[k] is AScan) {
      let t = s.table.unwrap()
      for pair in fetch_access(self.access[k], t, row) {
        set_row(k, Int(pair.0), pair.1)
        if s.on is Some(c) && !(eval(c, row).truth() is Some(true)) {
          continue
        }
        matched = true
        if !check_all(self.conj[k]) {
          continue
        }
        if !scan(k + 1) {
          return false
        }
      }
      if !matched && k > 0 && s.join is (JLeft | JFull) {
        set_null(k)
        if check_all(self.conj[k]) && !scan(k + 1) {
          return false
        }
      }
      return true
    }
    let cand = candidates(k)
    let cnt = match cand {
      Some(c) => c.length()
      None => data[k].length()
    }
    for ci in 0..<cnt {
      let j = match cand {
        Some(c) => c[ci]
        None => ci
      }
      let pair = data[k][j]
      set_row(k, pair.0, pair.1)
      if s.on is Some(c) && !(eval(c, row).truth() is Some(true)) {
        continue
      }
      matched = true
      if rmatched[k].length() > 0 {
        rmatched[k][j] = true
      }
      if !check_all(self.conj[k]) {
        continue
      }
      if !scan(k + 1) {
        return false
      }
    }
    if !matched && k > 0 && s.join is (JLeft | JFull) {
      set_null(k)
      if check_all(self.conj[k]) && !scan(k + 1) {
        return false
      }
    }
    true
  }

  if limit != 0L || is_agg {
    let mut go = scan(0)
    // unmatched rows of RIGHT / FULL joins
    for k in 1..<n {
      if !go {
        break
      }
      if rmatched[k].length() == 0 {
        continue
      }
      for j, pair in data[k] {
        if rmatched[k][j] {
          continue
        }
        for i in 0..<k {
          set_null(i)
        }
        set_row(k, pair.0, pair.1)
        if !scan(k + 1) {
          go = false
          break
        }
      }
    }
  }
  if is_agg {
    let glist = if group_by.length() == 0 {
      [single]
    } else {
      groups.to_array().map(p => p.1)
    }
    for g in glist {
      let grow = g.result_row()
      if self.having is Some(h) && !(eval(h, grow).truth() is Some(true)) {
        continue
      }
      if wfns.length() > 0 {
        pre.push(grow)
        continue
      }
      let vals = exprs.map(e => eval(e, grow))
      let keys = order_keys.map(e => eval(e, grow))
      out.push({ vals, keys, })
    }
  }
  if wfns.length() > 0 {
    for r in compute_windows(pre, wfns) {
      let vals = exprs.map(e => eval(e, r))
      let keys = order_keys.map(e => eval(e, r))
      out.push({ vals, keys, })
    }
  }
  // DISTINCT
  let rows = if self.distinct {
    let colls = exprs.map(e => expr_coll(e).unwrap_or(CBinary))
    let mut seen : PMap[Array[Value], Unit] = PMap::empty(key_cmp(colls))
    let kept : Array[SortRow] = []
    for r in out {
      if seen.find(r.vals) is None {
        seen = seen.add(r.vals, ())
        kept.push(r)
      }
    }
    kept
  } else {
    out
  }
  if order_keys.length() > 0 {
    let desc = self.order_by.map(t => t.desc)
    let nulls_first = self.order_by.map(t => t.nulls_first.unwrap_or(!t.desc))
    let colls = order_keys.map(k => expr_coll(k).unwrap_or(CBinary))
    stable_sort(rows, (a, b) => {
      for i in 0..<desc.length() {
        let x = a.keys[i]
        let y = b.keys[i]
        match (x, y) {
          (Null, Null) => continue
          (Null, _) => return if nulls_first[i] { -1 } else { 1 }
          (_, Null) => return if nulls_first[i] { 1 } else { -1 }
          _ => ()
        }
        let c = compare_coll(x, y, colls[i])
        if c != 0 {
          return if desc[i] { -c } else { c }
        }
      }
      0
    })
  }
  let mut lim = limit
  if max_rows >= 0L && (lim < 0L || max_rows < lim) {
    lim = max_rows
  }
  apply_limits(rows, lim, skip).map(r => r.vals)
}
