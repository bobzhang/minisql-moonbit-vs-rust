// Access-path selection (rowid and index lookups, transient indexes), join
// ordering and the nested-loop scan driven by the chosen plan.

///|
/// Equality constraint on one key part: candidate values (several for IN),
/// the comparison affinity applied to them, and whether NULL matches (IS).
priv struct EqPart {
  exprs : Array[Expr]
  aff : Affinity
  null_ok : Bool
}

///|
priv struct RangeB {
  expr : Expr
  incl : Bool
  aff : Affinity
}

///|
priv enum Access {
  AScan
  ARowidEq(EqPart)
  ARowidRange(RangeB?, RangeB?)
  AIndex(Index, Array[EqPart], RangeB?, RangeB?)
  /// Transient index on column `col` with collation `coll`, built on first
  /// use and cached while the table is unchanged.
  AAuto(Int, String, EqPart, Ref[(Int, Index)?])
  /// Transient index over the materialized rows of a subquery or view,
  /// built once per run.
  AMatAuto(Int, String, EqPart)
}

///|
priv struct Level {
  src : Int
  mut access : Access
  conds : Array[Expr]
  /// Visit the candidates in descending order.
  mut reverse : Bool
}

///|
priv struct ScanPlan {
  sources : Array[Source]
  width : Int
  levels : Array[Level]
  final_conds : Array[Expr]
  /// RIGHT/FULL joins: plain nested loops over materialized rows.
  simple : Bool
  level_conds : Array[Array[Expr]]
  /// Rows of uncorrelated subqueries/views in FROM (and their transient
  /// indexes), reused while no table changes (global data version).
  mat_cache : Array[(Int, Array[Array[Value]])?]
  mat_idx_cache : Array[(Int, Index)?]
}

///|
priv enum TOp {
  OEq
  OIs
  OLt
  OLe
  OGt
  OGe
  OIn(Array[Expr])
}

///|
/// A usable shape of a WHERE/ON term: `col op other`.
priv struct Form {
  col : Expr
  op : TOp
  other : Expr
  aff : Affinity
  coll : String? // None: any collation
}

///|
fn flip_op(op : BinOp) -> TOp? {
  match op {
    Eq => Some(OEq)
    Lt => Some(OGt)
    Le => Some(OGe)
    Gt => Some(OLt)
    Ge => Some(OLe)
    _ => None
  }
}

///|
fn direct_op(op : BinOp) -> TOp? {
  match op {
    Eq => Some(OEq)
    Lt => Some(OLt)
    Le => Some(OLe)
    Gt => Some(OGt)
    Ge => Some(OGe)
    _ => None
  }
}

///|
fn term_forms(c : Expr, out : Array[Form]) -> Unit {
  match c {
    Binary(Or, _, _) => {
      // x = a OR x = b ... works like x IN (a, b, ...)
      let disj : Array[Expr] = []
      disjuncts(c, disj)
      let per : Array[Array[Form]] = disj.map(d => {
        let fs : Array[Form] = []
        term_forms(d, fs)
        fs.filter(f => f.op is OEq)
      })
      for cand in per[0] {
        let items : Array[Expr] = []
        for fs in per {
          for f in fs {
            if expr_equal(f.col, cand.col) &&
              f.aff == cand.aff &&
              f.coll == cand.coll {
              items.push(f.other)
              break
            }
          }
        }
        if items.length() == disj.length() {
          out.push({ ..cand, op: OIn(items), other: Lit(Null), })
        }
      }
    }
    Binary(op, l, r) => {
      let aff = comparison_affinity(l, r)
      let coll = Some(binary_coll(l, r))
      if direct_op(op) is Some(o) {
        out.push({ col: l, op: o, other: r, aff, coll, })
      }
      if flip_op(op) is Some(o) {
        out.push({ col: r, op: o, other: l, aff, coll, })
      }
    }
    Is(l, r, false) => {
      let aff = comparison_affinity(l, r)
      let coll = Some(binary_coll(l, r))
      out.push({ col: l, op: OIs, other: r, aff, coll, })
      out.push({ col: r, op: OIs, other: l, aff, coll, })
    }
    IsNull(x, false) =>
      out.push({ col: x, op: OIs, other: Lit(Null), aff: AffNone, coll: None, })
    Between(x, lo, hi, false) => {
      out.push({
        col: x,
        op: OGe,
        other: lo,
        aff: comparison_affinity(x, lo),
        coll: Some(binary_coll(x, lo)),
      })
      out.push({
        col: x,
        op: OLe,
        other: hi,
        aff: comparison_affinity(x, hi),
        coll: Some(binary_coll(x, hi)),
      })
    }
    InList(x, items, false) if items.length() > 0 =>
      out.push({
        col: x,
        op: OIn(items),
        other: Lit(Null),
        aff: expr_affinity(x),
        coll: Some(
          match expr_coll(x) {
            Some((c, _)) => c
            None => "BINARY"
          },
        ),
      })
    _ => ()
  }
}

///|
fn disjuncts(e : Expr, out : Array[Expr]) -> Unit {
  match e {
    Binary(Or, l, r) => {
      disjuncts(l, out)
      disjuncts(r, out)
    }
    _ => out.push(e)
  }
}

///|
fn Form::exprs(self : Form) -> Array[Expr] {
  match self.op {
    OIn(items) => items
    _ => [self.other]
  }
}

///|
fn Form::is_eq(self : Form) -> Bool {
  self.op is (OEq | OIs | OIn(_))
}

///|
/// Index of the source containing slot `idx` of the joined row.
fn source_of_slot(sources : Array[Source], idx : Int) -> Int {
  for i, s in sources {
    if idx >= s.offset && idx <= s.offset + s.table.columns.length() {
      return i
    }
  }
  sources.length() - 1
}

///|
/// True if the expression can be evaluated once the sources marked in
/// `placed` are bound.
fn expr_avail(e : Expr, sources : Array[Source], placed : Array[Bool]) -> Bool {
  match e {
    Slot(depth=0, idx~, ..) => placed[source_of_slot(sources, idx)]
    Slot(..) | Lit(_) => true
    ScalarQ(q) | ExistsQ(q) => !q.correlated
    InQ(x, q, _) => !q.correlated && expr_avail(x, sources, placed)
    AggRef(..) | Col(..) | Subquery(_) | Exists(_) | InSelect(_, _, _) => false
    _ => expr_children(e).all(c => expr_avail(c, sources, placed))
  }
}

///|
/// True if the expression refers to an enclosing query.
fn has_outer_ref(e : Expr) -> Bool {
  match e {
    Slot(depth~, ..) => depth > 0
    ScalarQ(_) | ExistsQ(_) | InQ(_, _, _) => false
    _ => expr_children(e).any(has_outer_ref)
  }
}

///|
fn offset_slots(e : Expr, off : Int) -> Expr {
  match e {
    Slot(depth=0, idx~, aff~, coll~) =>
      Slot(depth=0, idx=idx + off, aff~, coll~)
    _ => e.map_children(x => offset_slots(x, off)) catch { _ => e }
  }
}

///|
fn affinity_ok(cmp : Affinity, part : Affinity) -> Bool {
  match cmp {
    AffNone => true
    AffText => part == AffText
    _ => is_numeric_aff(part)
  }
}

///|
fn is_rowid_ref(e : Expr, src : Source) -> Bool {
  guard src.sub is None && e is Slot(depth=0, idx~, ..) else { return false }
  let t = src.table
  idx == src.offset + t.columns.length() ||
  (t.ipk >= 0 && idx == src.offset + t.ipk)
}

///|
/// Whether the WHERE terms imply a partial index's condition.
fn implied(w : Expr, terms : Array[Expr]) -> Bool {
  let parts : Array[Expr] = []
  conjuncts(w, parts)
  parts.all(p => {
    if terms.any(t => expr_equal(t, p)) {
      return true
    }
    let not_null = match p {
      IsNull(x, true) => Some(x)
      Is(x, Lit(Null), true) => Some(x)
      Unary(Not, IsNull(x, false)) => Some(x)
      _ => None
    }
    if not_null is Some(x) {
      let forms : Array[Form] = []
      for t in terms {
        term_forms(t, forms)
      }
      return forms.any(f => !(f.op is OIs) && expr_equal(f.col, x))
    }
    false
  })
}

///|
/// Candidate access paths for a source with their estimated rows per probe.
priv struct Choice {
  access : Access
  rows : Double
  used : Int
  build : Double // one-time cost
}

///|
fn choose_access(
  sources : Array[Source],
  si : Int,
  forms : Array[Form],
  terms : Array[Expr],
  placed : Array[Bool],
  auto_ok : Bool,
) -> Choice {
  let src = sources[si]
  let n = src.table.rows.length().to_double()
  let scan : Choice = {
    access: AScan,
    rows: if src.sub is Some(_) {
      src.est_rows.unwrap_or(100.0)
    } else {
      n
    },
    used: 0,
    build: 0.0,
  }
  let usable = forms.filter(f => {
    f.exprs().all(x => expr_avail(x, sources, placed))
  })
  if usable.length() == 0 {
    return scan
  }
  if src.sub is Some(_) {
    if !auto_ok {
      return scan
    }
    for f in usable {
      guard f.op is OEq && f.col is Slot(depth=0, idx=j, ..) else { continue }
      let c = j - src.offset
      if c < 0 || c >= src.table.columns.length() {
        continue
      }
      if placed.iter().any(x => x) || has_outer_ref(f.other) {
        return {
          access: AMatAuto(c, f.coll.unwrap_or("BINARY"), {
            exprs: [f.other],
            aff: f.aff,
            null_ok: false,
          }),
          rows: 10.0,
          used: 1,
          build: 200.0,
        }
      }
    }
    return scan
  }
  let mut best = scan
  // rowid
  for f in usable {
    if f.is_eq() && is_rowid_ref(f.col, src) {
      let k = f.exprs().length().to_double()
      if k < best.rows {
        best = {
          access: ARowidEq({ exprs: f.exprs(), aff: f.aff, null_ok: false, }),
          rows: k,
          used: 1,
          build: 0.0,
        }
      }
    }
  }
  if best.access is AScan {
    let mut lo : RangeB? = None
    let mut hi : RangeB? = None
    for f in usable {
      if !is_rowid_ref(f.col, src) {
        continue
      }
      match f.op {
        OGt | OGe =>
          if lo is None {
            lo = Some({ expr: f.other, incl: f.op is OGe, aff: f.aff, })
          }
        OLt | OLe =>
          if hi is None {
            hi = Some({ expr: f.other, incl: f.op is OLe, aff: f.aff, })
          }
        _ => ()
      }
    }
    if lo is Some(_) || hi is Some(_) {
      let both = lo is Some(_) && hi is Some(_)
      best = {
        access: ARowidRange(lo, hi),
        rows: if both {
          n / 16.0
        } else {
          n / 4.0
        },
        used: if both {
          2
        } else {
          1
        },
        build: 0.0,
      }
    }
  }
  // indexes
  let off = src.offset
  for idx in src.table.indexes {
    if idx.where_ is Some(w) && !implied(offset_slots(w, off), terms) {
      continue
    }
    let nparts = idx.cols.length()
    let matches = fn(e : Expr, k : Int) -> Bool {
      let c = idx.cols[k]
      if c >= 0 {
        e is Slot(depth=0, idx=j, ..) && j == off + c
      } else {
        expr_equal(e, offset_slots(idx.exprs[k], off))
      }
    }
    let ok = fn(f : Form, k : Int) -> Bool {
      matches(f.col, k) &&
      affinity_ok(f.aff, idx.affs[k]) &&
      (match f.coll {
        Some(c) => c.equal_ignore_ascii_case(idx.colls[k])
        None => true
      })
    }
    let eqs : Array[EqPart] = []
    let mut combos = 1.0
    for k in 0..<nparts {
      let mut found : EqPart? = None
      for f in usable {
        if f.is_eq() && ok(f, k) {
          found = Some({ exprs: f.exprs(), aff: f.aff, null_ok: f.op is OIs, })
          combos = combos * f.exprs().length().to_double()
          break
        }
      }
      match found {
        Some(e) => eqs.push(e)
        None => break
      }
    }
    let mut lo : RangeB? = None
    let mut hi : RangeB? = None
    let m = eqs.length()
    if m < nparts {
      for f in usable {
        if !ok(f, m) {
          continue
        }
        match f.op {
          OGt | OGe =>
            if lo is None {
              lo = Some({ expr: f.other, incl: f.op is OGe, aff: f.aff, })
            }
          OLt | OLe =>
            if hi is None {
              hi = Some({ expr: f.other, incl: f.op is OLe, aff: f.aff, })
            }
          _ => ()
        }
      }
    }
    if m == 0 && lo is None && hi is None {
      continue
    }
    let mut rows = if m == 0 {
      n
    } else if idx.unique && m == nparts {
      1.0
    } else {
      let mut r = 10.0
      for _ in 1..<m {
        r = r / 2.0
      }
      if r > n {
        n
      } else {
        r
      }
    }
    if lo is Some(_) && hi is Some(_) {
      rows = rows / 16.0
    } else if lo is Some(_) || hi is Some(_) {
      rows = rows / 4.0
    }
    rows = rows * combos
    // lookups cost a table fetch per entry
    let est = rows * 1.5 + 1.0
    let used = m +
      (if lo is Some(_) { 1 } else { 0 }) +
      (if hi is Some(_) { 1 } else { 0 })
    if est < best.rows || (best.access is AScan && rows < n) {
      best = { access: AIndex(idx, eqs, lo, hi), rows, used, build: 0.0, }
    }
  }
  // transient index for an equality on a plain column
  if auto_ok && best.access is AScan && n > 16.0 {
    for f in usable {
      guard f.op is OEq && f.col is Slot(depth=0, idx=j, ..) else { continue }
      let c = j - off
      if c < 0 || c >= src.table.columns.length() {
        continue
      }
      // only worthwhile when probed repeatedly
      let repeated = placed.iter().any(x => x) || has_outer_ref(f.other)
      if !repeated {
        continue
      }
      best = {
        access: AAuto(
          c,
          f.coll.unwrap_or("BINARY"),
          { exprs: [f.other], aff: f.aff, null_ok: false, },
          { val: None, },
        ),
        rows: 10.0,
        used: 1,
        build: n * 2.0,
      }
      break
    }
  }
  best
}

///|
/// Next permutation in lexicographic order; false when `a` was the last.
fn next_perm(a : Array[Int]) -> Bool {
  let n = a.length()
  let mut i = n - 2
  while i >= 0 && a[i] >= a[i + 1] {
    i -= 1
  }
  if i < 0 {
    return false
  }
  let mut j = n - 1
  while a[j] <= a[i] {
    j -= 1
  }
  a.swap(i, j)
  let mut l = i + 1
  let mut r = n - 1
  while l < r {
    a.swap(l, r)
    l += 1
    r -= 1
  }
  true
}

///|
/// Assigns each term to the first position (in `order`) where all the
/// sources it uses are bound; -1 when it must wait for the full row.
fn term_positions(
  terms : Array[Expr],
  sources : Array[Source],
  order : Array[Int],
) -> Array[Int] {
  let pos = Array::make(sources.length(), 0)
  for p, s in order {
    pos[s] = p
  }
  terms.map(t => {
    match conj_sources(t, sources) {
      None => -1
      Some(list) => {
        let mut m = 0
        for s in list {
          if pos[s] > m {
            m = pos[s]
          }
        }
        m
      }
    }
  })
}

///|
/// Sources referenced by a bound term, or None when it cannot be
/// determined (correlated subqueries).
fn conj_sources(e : Expr, sources : Array[Source]) -> Array[Int]? {
  let out : Array[Int] = []
  fn go(x : Expr) -> Bool {
    match x {
      ScalarQ(q) | ExistsQ(q) => !q.correlated
      InQ(y, q, _) => !q.correlated && go(y)
      Slot(depth=0, idx~, ..) => {
        out.push(source_of_slot(sources, idx))
        true
      }
      _ => expr_children(x).all(go)
    }
  }

  if go(e) {
    Some(out)
  } else {
    None
  }
}

///|
/// Plans the scan of `sources` filtered by the bound WHERE clause.
fn plan_scan(sources : Array[Source], where_ : Expr?) -> ScanPlan {
  let n = sources.length()
  let mut width = 0
  for s in sources {
    width += s.table.columns.length() + 1
  }
  let terms : Array[Expr] = []
  if where_ is Some(w) {
    conjuncts(w, terms)
  }
  if sources.any(s => s.kind is (JRight | JFull)) {
    // WHERE terms can only be checked on complete rows
    return {
      sources,
      width,
      levels: [],
      final_conds: terms,
      simple: true,
      level_conds: Array::makei(n, _ => []),
      mat_cache: [],
      mat_idx_cache: [],
    }
  }
  if n == 0 {
    return {
      sources,
      width,
      levels: [],
      final_conds: terms,
      simple: false,
      level_conds: [],
      mat_cache: [],
      mat_idx_cache: [],
    }
  }
  let inner_only = sources.all(s => s.kind is JInner)
  if inner_only {
    // ON conditions of inner joins are plain filters
    for s in sources {
      if s.on is Some(on) {
        conjuncts(on, terms)
        s.on = None
      }
    }
  }
  let where_forms : Array[Form] = []
  for t in terms {
    term_forms(t, where_forms)
  }
  // candidate forms and terms per source
  let src_forms : Array[Array[Form]] = []
  let src_terms : Array[Array[Expr]] = []
  for s in sources {
    let fs : Array[Form] = []
    let ts : Array[Expr] = []
    if s.on is Some(on) {
      conjuncts(on, ts)
      for t in ts {
        term_forms(t, fs)
      }
    }
    if !(s.kind is JLeft) {
      fs.append(where_forms)
      ts.append(terms)
    }
    src_forms.push(fs)
    src_terms.push(ts)
  }
  let evaluate = fn(order : Array[Int]) -> (Double, Array[Choice]) {
    let placed = Array::make(n, false)
    let positions = term_positions(terms, sources, order)
    let mut outer = 1.0
    let mut total = 0.0
    let choices : Array[Choice] = []
    for p, si in order {
      let ch = choose_access(
        sources,
        si,
        src_forms[si],
        src_terms[si],
        placed,
        true,
      )
      choices.push(ch)
      total += outer * (ch.rows + 1.0) + ch.build
      let mut nconds = 0
      for q in positions {
        if q == p {
          nconds += 1
        }
      }
      let extra = nconds - ch.used
      let mut rows = ch.rows
      for _ in 0..<extra {
        rows = rows * 0.25
      }
      if rows < 1.0 {
        rows = 1.0
      }
      outer = outer * rows
      placed[si] = true
    }
    (total, choices)
  }
  let identity = Array::makei(n, i => i)
  let (base_cost, base_choices) = evaluate(identity)
  let mut order = identity
  let mut choices = base_choices
  if inner_only && n >= 2 && n <= 6 {
    let perm = identity.copy()
    let mut best_cost = base_cost
    while next_perm(perm) {
      let (c, ch) = evaluate(perm)
      if c < best_cost {
        best_cost = c
        order = perm.copy()
        choices = ch
      }
    }
    if best_cost >= base_cost * 0.5 {
      order = identity
      choices = base_choices
    }
  }
  let positions = term_positions(terms, sources, order)
  let levels : Array[Level] = []
  for p, si in order {
    let conds : Array[Expr] = []
    for k, t in terms {
      if positions[k] == p {
        conds.push(t)
      }
    }
    levels.push({ src: si, access: choices[p].access, conds, reverse: false, })
  }
  let final_conds : Array[Expr] = []
  for k, t in terms {
    if positions[k] < 0 {
      final_conds.push(t)
    }
  }
  {
    sources,
    width,
    levels,
    final_conds,
    simple: false,
    level_conds: [],
    mat_cache: Array::make(n, None),
    mat_idx_cache: Array::make(n, None),
  }
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

///|
/// Sorted, de-duplicated values in the order of index part `k`.
fn sort_part_values(
  vs : Array[Value],
  coll : String,
  desc : Bool,
) -> Array[Value] {
  vs.sort_by((a, b) => {
    let c = value_compare_coll(a, b, coll)
    if desc {
      -c
    } else {
      c
    }
  })
  let out : Array[Value] = []
  for v in vs {
    match out.last() {
      Some(l) if value_compare_coll(l, v, coll) == 0 => ()
      _ => out.push(v)
    }
  }
  out
}

///|
fn index_lookup(
  idx : Index,
  eqs : Array[EqPart],
  lo : RangeB?,
  hi : RangeB?,
  env : Env,
  f : (Int64, Array[Value]) -> Bool raise SqlError,
  reverse? : Bool = false,
) -> Unit raise SqlError {
  let lists : Array[Array[Value]] = []
  for k, eq in eqs {
    let vs : Array[Value] = []
    for e in eq.exprs {
      let v = apply_cmp_affinity(eval(e, env), eq.aff)
      if v is Null && !eq.null_ok {
        continue
      }
      vs.push(v)
    }
    let sorted = sort_part_values(vs, idx.colls[k], idx.descs[k])
    if sorted.length() == 0 {
      return
    }
    if reverse {
      sorted.rev_in_place()
    }
    lists.push(sorted)
  }
  let bound = fn(b : RangeB?) -> ((Value, Bool)?, Bool) raise SqlError {
    match b {
      Some(r) => {
        let v = apply_cmp_affinity(eval(r.expr, env), r.aff)
        if v is Null {
          (None, false)
        } else {
          (Some((v, r.incl)), true)
        }
      }
      None => (None, true)
    }
  }
  let (lo_v0, ok1) = bound(lo)
  let (hi_v, ok2) = bound(hi)
  if !ok1 || !ok2 {
    return
  }
  // NULLs never satisfy a range
  let lo_v = if lo_v0 is None && hi_v is Some(_) {
    Some((Null, false))
  } else {
    lo_v0
  }
  let m = eqs.length()
  let prefix = Array::make(m, Null)
  let mut stop = false
  let g = fn(r : Int64, vals : Array[Value]) -> Bool raise SqlError {
    if f(r, vals) {
      true
    } else {
      stop = true
      false
    }
  }
  fn go(k : Int) raise SqlError {
    if stop {
      return
    }
    if k == m {
      idx.scan(prefix.copy(), lo_v, hi_v, g, reverse~)
      return
    }
    for v in lists[k] {
      prefix[k] = v
      go(k + 1)
    }
  }

  go(0)
}

///|
fn rowid_of_probe(v : Value) -> Int64? {
  match v {
    Int(i) => Some(i)
    Real(d) => real_to_int_exact(d)
    _ => None
  }
}

///|
/// Inclusive rowid bounds of a range, or None when it is empty.
fn rowid_bounds(
  lo : RangeB?,
  hi : RangeB?,
  env : Env,
) -> (Int64, Int64)? raise SqlError {
  let mut a = @int64.MIN_VALUE
  let mut b = @int64.MAX_VALUE
  match lo {
    Some(r) =>
      match apply_cmp_affinity(eval(r.expr, env), AffNumeric) {
        Null => return None
        Int(i) =>
          if r.incl {
            a = i
          } else if i == @int64.MAX_VALUE {
            return None
          } else {
            a = i + 1L
          }
        Real(d) => {
          let c = if r.incl { d.ceil() } else { d.floor() + 1.0 }
          if c.is_nan() || c > 9.2e18 {
            return None
          }
          if c > -9.2e18 {
            a = c.to_int64()
          }
        }
        _ => return None
      }
    None => ()
  }
  match hi {
    Some(r) =>
      match apply_cmp_affinity(eval(r.expr, env), AffNumeric) {
        Null => return None
        Int(i) =>
          if r.incl {
            b = i
          } else if i == @int64.MIN_VALUE {
            return None
          } else {
            b = i - 1L
          }
        Real(d) => {
          let c = if r.incl { d.floor() } else { d.ceil() - 1.0 }
          if c.is_nan() || c < -9.2e18 {
            return None
          }
          if c < 9.2e18 {
            b = c.to_int64()
          }
        }
        _ => ()
      }
    None => ()
  }
  if a > b {
    None
  } else {
    Some((a, b))
  }
}

///|
/// A transient index on column `col` whose keys are the column values
/// converted by the comparison affinity `aff` (probes are converted the
/// same way), so it serves `col = expr` under any affinity combination.
fn auto_index(
  t : Table,
  col : Int,
  coll : String,
  aff : Affinity,
  cache : Ref[(Int, Index)?],
) -> Index raise SqlError {
  if cache.val is Some((v, idx)) && v == t.version {
    return idx
  }
  let idx = build_index(
    t,
    "auto",
    unique=false,
    origin=0,
    conflict=CDefault,
    parts=[
      {
        expr: Slot(
          depth=0,
          idx=col,
          aff=t.columns[col].aff,
          coll=t.columns[col].coll,
        ),
        coll: Some(coll),
        desc: false,
      },
    ],
    where_src=None,
    sql=None,
    seq=0,
  )
  t.rows.each_while((rowid, vals) => {
    idx.entries.set([apply_cmp_affinity(vals[col], aff), Int(rowid)], vals)
    true
  })
  cache.val = Some((t.version, idx))
  idx
}

///|
/// Visits the candidate rows of a level (column values and rowid) until
/// `visit` returns false.
fn each_candidate(
  lv : Level,
  src : Source,
  mat : Array[Array[Value]]?,
  mat_idx : Array[Index?],
  mat_cache : Array[(Int, Index)?],
  mat_ver : Int,
  env : Env,
  visit : (Array[Value], Value) -> Bool raise SqlError,
) -> Unit raise SqlError {
  if mat is Some(rows) {
    if lv.access is AMatAuto(col, coll, eq) {
      let idx = match mat_idx[lv.src] {
        Some(i) => i
        None => {
          let tmp : Table = { ..src.table, rows: new_rows(), }
          for i, r in rows {
            tmp.rows.set(i.to_int64(), r)
          }
          let i = auto_index(tmp, col, coll, eq.aff, { val: None, })
          mat_idx[lv.src] = Some(i)
          if src.sub is Some(p) && !p.correlated.val {
            mat_cache[lv.src] = Some((mat_ver, i))
          }
          i
        }
      }
      index_lookup(idx, [eq], None, None, env, (_, v) => visit(v, Null))
      return
    }
    for r in rows {
      if !visit(r, Null) {
        break
      }
    }
    return
  }
  let t = src.table
  let fetch = fn(r : Int64) -> Bool raise SqlError {
    match t.rows.get(r) {
      Some(v) => visit(v, Int(r))
      None => true
    }
  }
  let reverse = lv.reverse
  match lv.access {
    AScan =>
      if reverse {
        t.rows.each_rev_while((rowid, vals) => visit(vals, Int(rowid)))
      } else {
        t.rows.each_while((rowid, vals) => visit(vals, Int(rowid)))
      }
    ARowidEq(eq) => {
      let ids : Array[Value] = []
      for e in eq.exprs {
        if rowid_of_probe(apply_cmp_affinity(eval(e, env), AffNumeric))
          is Some(r) {
          ids.push(Int(r))
        }
      }
      let sorted = sort_part_values(ids, "BINARY", false)
      if reverse {
        sorted.rev_in_place()
      }
      for v in sorted {
        if v is Int(r) && !fetch(r) {
          break
        }
      }
    }
    ARowidRange(lo, hi) =>
      match rowid_bounds(lo, hi, env) {
        Some((a, b)) =>
          if reverse {
            t.rows.each_le_rev(b, (k, v) => {
              if k < a {
                false
              } else {
                visit(v, Int(k))
              }
            })
          } else {
            t.rows.each_from(a, (k, v) => {
              if k > b {
                false
              } else {
                visit(v, Int(k))
              }
            })
          }
        None => ()
      }
    AIndex(idx, eqs, lo, hi) =>
      index_lookup(idx, eqs, lo, hi, env, (r, v) => visit(v, Int(r)), reverse~)
    AAuto(col, coll, eq, cache) => {
      let idx = auto_index(t, col, coll, eq.aff, cache)
      index_lookup(idx, [eq], None, None, env, (r, v) => visit(v, Int(r)))
    }
    AMatAuto(_, _, _) => ()
  }
}

///|
/// Runs the plan, calling `f` for every joined row satisfying the
/// conditions.
fn ScanPlan::run(
  self : ScanPlan,
  penv : Env,
  f : (Env) -> Unit raise SqlError,
  stop? : Ref[Bool] = { val: false, },
) -> Unit raise SqlError {
  if self.simple {
    scan_sources(
      self.sources,
      self.width,
      self.level_conds,
      self.final_conds,
      penv,
      f,
    )
    return
  }
  let parent = Some(penv)
  let sources = self.sources
  let n = self.levels.length()
  let buf = Array::make(self.width, Null)
  let env : Env = { row: buf, parent, }
  let check = fn(conds : Array[Expr]) -> Bool raise SqlError {
    for c in conds {
      if truthy(eval(c, env)) != Some(true) {
        return false
      }
    }
    true
  }
  if n == 0 {
    let e0 : Env = { row: [], parent, }
    for c in self.final_conds {
      if truthy(eval(c, e0)) != Some(true) {
        return
      }
    }
    f(e0)
    return
  }
  let ver = counters[1]
  let mat_idx : Array[Index?] = Array::make(sources.length(), None)
  let mats : Array[Array[Array[Value]]?] = []
  for i, s in sources {
    match s.sub {
      Some(p) =>
        if p.correlated.val {
          mats.push(Some((p.run)(penv)))
        } else {
          match self.mat_cache[i] {
            Some((v, rows)) if v == ver => {
              mats.push(Some(rows))
              if self.mat_idx_cache[i] is Some((v2, idx)) && v2 == ver {
                mat_idx[i] = Some(idx)
              }
            }
            _ => {
              let rows = (p.run)(penv)
              self.mat_cache[i] = Some((ver, rows))
              self.mat_idx_cache[i] = None
              mats.push(Some(rows))
            }
          }
        }
      None => mats.push(None)
    }
  }
  fn level(p : Int) raise SqlError {
    if p == n {
      // the row buffer is reused: consumers copy what they keep
      if check(self.final_conds) {
        f(env)
      }
      return
    }
    let lv = self.levels[p]
    let src = sources[lv.src]
    let ncols = src.table.columns.length()
    let off = src.offset
    let mut any = false
    each_candidate(
      lv,
      src,
      mats[lv.src],
      mat_idx,
      self.mat_idx_cache,
      ver,
      env,
      (vals, rowid) => {
        for k in 0..<ncols {
          buf[off + k] = vals[k]
        }
        buf[off + ncols] = rowid
        if src.on is Some(on) && truthy(eval(on, env)) != Some(true) {
          return true
        }
        any = true
        if check(lv.conds) {
          level(p + 1)
        }
        !stop.val
      },
    )
    if !any && src.kind is JLeft {
      null_fill(buf, src)
      if check(lv.conds) {
        level(p + 1)
      }
    }
  }

  level(0)
}

///|
/// One ORDER BY requirement: bound expression, direction, NULLS placement
/// (0 default, 1 first, 2 last) and collation.
priv struct OrderReq {
  expr : Expr
  desc : Bool
  nulls : Int
  coll : String
  /// Either direction will do (GROUP BY without a matching ORDER BY term).
  any_dir : Bool
}

///|
/// Tries to make the scan produce rows in the requested order (by the
/// outermost level's rowid or index order). With `allow_switch`, a full
/// scan may be replaced by a scan of a suitable index. Returns true when
/// the rows come out ordered.
fn ScanPlan::try_order(
  self : ScanPlan,
  reqs : Array[OrderReq],
  allow_switch : Bool,
) -> Bool {
  if self.simple || self.levels.length() == 0 || reqs.length() == 0 {
    return false
  }
  let lv = self.levels[0]
  let src = self.sources[lv.src]
  if src.sub is Some(_) {
    return false
  }
  let off = src.offset
  // NULLS FIRST/LAST must agree with the natural placement
  let nulls_ok = fn(r : OrderReq) {
    r.nulls == 0 || (r.nulls == 1 && !r.desc) || (r.nulls == 2 && r.desc)
  }
  if !reqs.all(r => nulls_ok(r)) {
    return false
  }
  // a rowid term makes later terms redundant only without joins
  let single = self.levels.length() == 1
  let rowid_first = is_rowid_ref(reqs[0].expr, src) &&
    (single || reqs.length() == 1)
  match lv.access {
    AScan | ARowidRange(_, _) if rowid_first => {
      lv.reverse = reqs[0].desc
      return true
    }
    ARowidEq(eq) if eq.exprs.length() == 1 && single => return true
    _ => ()
  }
  let index_match = fn(idx : Index, m : Int) -> Bool? {
    // Some(reverse) when the index order (after m equality parts) gives
    // the requested order
    let nparts = idx.cols.length()
    let matches = fn(e : Expr, k : Int) -> Bool {
      let c = idx.cols[k]
      if c >= 0 {
        e is Slot(depth=0, idx=j, ..) && j == off + c
      } else {
        expr_equal(e, offset_slots(idx.exprs[k], off))
      }
    }
    let mut pi = 0
    let mut rev : Bool? = None
    for ri, r in reqs {
      // equality parts are constant: skip them
      let mut matched_eq = false
      for k in 0..<m {
        if matches(r.expr, k) {
          matched_eq = true
        }
      }
      if matched_eq {
        continue
      }
      while pi < m {
        pi += 1
      }
      if pi >= nparts {
        // entries with equal keys are in rowid order
        if is_rowid_ref(r.expr, src) && (single || ri == reqs.length() - 1) {
          let d = r.desc
          match rev {
            Some(x) => if x != d { return None }
            None => rev = Some(d)
          }
          return rev
        }
        return None
      }
      if !matches(r.expr, pi) || !r.coll.equal_ignore_ascii_case(idx.colls[pi]) {
        return None
      }
      if r.any_dir {
        pi += 1
        continue
      }
      let d = r.desc != idx.descs[pi]
      match rev {
        Some(x) => if x != d { return None }
        None => rev = Some(d)
      }
      pi += 1
    }
    Some(rev.unwrap_or(false))
  }
  match lv.access {
    AIndex(idx, eqs, _, _) => {
      if !eqs.all(e => e.exprs.length() == 1) {
        return false
      }
      match index_match(idx, eqs.length()) {
        Some(rev) => {
          lv.reverse = rev
          true
        }
        None => false
      }
    }
    AScan if allow_switch => {
      let terms : Array[Expr] = []
      for l in self.levels {
        terms.append(l.conds)
      }
      for idx in src.table.indexes {
        if idx.where_ is Some(w) && !implied(offset_slots(w, off), terms) {
          continue
        }
        if index_match(idx, 0) is Some(rev) {
          lv.access = AIndex(idx, [], None, None)
          lv.reverse = rev
          return true
        }
      }
      false
    }
    _ => false
  }
}
