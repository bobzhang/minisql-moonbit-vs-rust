///|
/// Structural equality of a key expression bound at slot 0 (`k`) with an
/// expression bound at slot offset `off` (`e`).
fn bexpr_same(k : BExpr, e : BExpr, off : Int) -> Bool {
  let all_same = (xs : Array[BExpr], ys : Array[BExpr]) => {
    if xs.length() != ys.length() {
      return false
    }
    for i, x in xs {
      if !bexpr_same(x, ys[i], off) {
        return false
      }
    }
    true
  }
  match (k, e) {
    (BCol(i, _, _), BCol(j, _, _)) => j == i + off
    (BConst(x), BConst(y)) => same_value(x, y)
    (BCollate(a, c1), BCollate(b, c2)) => c1 == c2 && bexpr_same(a, b, off)
    (BCast(a, t1), BCast(b, t2)) => t1 == t2 && bexpr_same(a, b, off)
    (BUnary(o1, a), BUnary(o2, b)) => o1 == o2 && bexpr_same(a, b, off)
    (BArith(o1, a1, b1), BArith(o2, a2, b2)) =>
      o1 == o2 && bexpr_same(a1, a2, off) && bexpr_same(b1, b2, off)
    (BCmp(o1, a1, b1, f1, c1), BCmp(o2, a2, b2, f2, c2)) =>
      o1 == o2 &&
      f1 == f2 &&
      c1 == c2 &&
      bexpr_same(a1, a2, off) &&
      bexpr_same(b1, b2, off)
    (BAnd(a1, b1), BAnd(a2, b2)) | (BOr(a1, b1), BOr(a2, b2)) =>
      bexpr_same(a1, a2, off) && bexpr_same(b1, b2, off)
    (BIsNull(a, n1), BIsNull(b, n2)) => n1 == n2 && bexpr_same(a, b, off)
    (BInList(x1, i1, n1, f1, c1), BInList(x2, i2, n2, f2, c2)) =>
      n1 == n2 &&
      f1 == f2 &&
      c1 == c2 &&
      bexpr_same(x1, x2, off) &&
      all_same(i1, i2)
    (BFunc(n1, _, a1), BFunc(n2, _, a2)) => n1 == n2 && all_same(a1, a2)
    (BCoalesce(a1), BCoalesce(a2)) => all_same(a1, a2)
    (BMinMax(m1, a1, c1), BMinMax(m2, a2, c2)) =>
      m1 == m2 && c1 == c2 && all_same(a1, a2)
    (BNullIf(a1, b1, f1, c1), BNullIf(a2, b2, f2, c2)) =>
      f1 == f2 && c1 == c2 && bexpr_same(a1, a2, off) && bexpr_same(b1, b2, off)
    (BIif(c1, t1, e1), BIif(c2, t2, e2)) =>
      bexpr_same(c1, c2, off) &&
      bexpr_same(t1, t2, off) &&
      (match (e1, e2) {
        (Some(x), Some(y)) => bexpr_same(x, y, off)
        (None, None) => true
        _ => false
      })
    (BCase(b1, arms1, e1), BCase(b2, arms2, e2)) => {
      let base_ok = match (b1, b2) {
        (Some(x), Some(y)) => bexpr_same(x, y, off)
        (None, None) => true
        _ => false
      }
      let els_ok = match (e1, e2) {
        (Some(x), Some(y)) => bexpr_same(x, y, off)
        (None, None) => true
        _ => false
      }
      base_ok &&
      els_ok &&
      arms1.length() == arms2.length() &&
      arms1
      .mapi((i, a) => {
        let b = arms2[i]
        a.2 == b.2 &&
        a.3 == b.3 &&
        bexpr_same(a.0, b.0, off) &&
        bexpr_same(a.1, b.1, off)
      })
      .all(x => x)
    }
    _ => false
  }
}

///|
/// Identical storage class and value.
fn same_value(a : Value, b : Value) -> Bool {
  match (a, b) {
    (Null, Null) => true
    (Int(x), Int(y)) => x == y
    (Real(x), Real(y)) => x == y
    (Text(x), Text(y)) => x == y
    (Blob(x), Blob(y)) => x == y
    _ => false
  }
}

///|
/// True if the expression can be evaluated before the scan: it reads no
/// row slots (constants and outer columns), or only slots below `limit`.
fn is_probe_expr(e : BExpr, limit : (Int, Int)) -> Bool {
  let (lo, hi) = slot_range(e)
  (lo == no_slot && hi == -1) || (lo >= limit.0 && hi >= 0 && hi < limit.1)
}

///|
/// True if values stored under key affinity `ka` are unchanged when the
/// comparison affinity `aff` is applied, so index order matches comparison.
fn affinity_safe(aff : Affinity, ka : Affinity?) -> Bool {
  match aff {
    AffNone => true
    AffText => ka == Some(AffText)
    _ =>
      match ka {
        Some(AffInteger | AffReal | AffNumeric) => true
        _ => false
      }
  }
}

///|
/// A constraint on one index key: equality with one of several values
/// (expression, affinity, NULL matches), or a lower/upper bound
/// (expression, affinity, inclusive).
priv enum KeyCons {
  CEq(Array[(BExpr, Affinity, Bool)])
  CLo(BExpr, Affinity, Bool)
  CHi(BExpr, Affinity, Bool)
}

///|
fn flip_op(op : BinOp) -> BinOp {
  match op {
    Lt => Gt
    Le => Ge
    Gt => Lt
    Ge => Le
    _ => op
  }
}

///|
/// Constraint a filter term places on key expression `key` (bound at slot
/// 0, compared at offset `off`) with collation `kcoll` and affinity `ka`.
fn term_constraint(
  term : BExpr,
  key : BExpr,
  off : Int,
  kcoll : Coll,
  ka : Affinity?,
  limit : (Int, Int),
) -> KeyCons? {
  match term {
    BCmp(op, a, b, aff, coll) => {
      let (op2, rhs) = if bexpr_same(key, a, off) && is_probe_expr(b, limit) {
        (op, b)
      } else if bexpr_same(key, b, off) && is_probe_expr(a, limit) {
        (flip_op(op), a)
      } else {
        return None
      }
      if coll != kcoll || !affinity_safe(aff, ka) {
        return None
      }
      match op2 {
        Eq => Some(CEq([(rhs, aff, false)]))
        Is => Some(CEq([(rhs, aff, true)]))
        Gt => Some(CLo(rhs, aff, false))
        Ge => Some(CLo(rhs, aff, true))
        Lt => Some(CHi(rhs, aff, false))
        Le => Some(CHi(rhs, aff, true))
        _ => None
      }
    }
    BOr(l, r) =>
      // `k = a OR k = b` acts as `k IN (a, b)`.
      match
        (
          term_constraint(l, key, off, kcoll, ka, limit),
          term_constraint(r, key, off, kcoll, ka, limit),
        ) {
        (Some(CEq(x)), Some(CEq(y))) if or_eq_leaves(l) && or_eq_leaves(r) =>
          Some(CEq([..x, ..y]))
        _ => None
      }
    BIsNull(x, false) if bexpr_same(key, x, off) =>
      Some(CEq([(BConst(Null), AffNone, true)]))
    BInList(x, items, false, aff, coll) if bexpr_same(key, x, off) &&
      items.all(i => is_probe_expr(i, limit)) &&
      coll == kcoll &&
      affinity_safe(aff, ka) => Some(CEq(items.map(i => (i, aff, false))))
    _ => None
  }
}

///|
/// An index access: equality constraints on a key prefix, then optional
/// bounds on the next key. `index` None means the rowid.
priv struct IndexPlan {
  index : Index?
  eqs : Array[Array[(BExpr, Affinity, Bool)]]
  lo : (BExpr, Affinity, Bool)?
  hi : (BExpr, Affinity, Bool)?
  /// Positions of the filter terms the access fully enforces.
  consumed : Array[Int]
  /// The bounds apply to the rowid after a fully fixed index key.
  rowid_range : Bool
}

///|
/// Builds the longest usable plan over the given keys from the filter terms:
/// equalities on a key prefix, then bounds on the next key.
fn plan_keys(
  index : Index?,
  keys : Array[BExpr],
  colls : Array[Coll],
  filters : Array[BExpr],
  off : Int,
  limit : (Int, Int),
  rowid_keys? : Array[BExpr] = [],
) -> IndexPlan? {
  let eqs = []
  let consumed = []
  let mut lo = None
  let mut hi = None
  let mut lo_term = -1
  let mut hi_term = -1
  for j, key in keys {
    let ka = key.affinity()
    let mut eq : Array[(BExpr, Affinity, Bool)]? = None
    let mut eq_term = -1
    lo = None
    hi = None
    for fi, f in filters {
      match term_constraint(f, key, off, colls[j], ka, limit) {
        Some(CEq(alts)) =>
          match eq {
            Some(prev) if prev.length() == 1 => ()
            _ => {
              eq = Some(alts)
              eq_term = fi
            }
          }
        Some(CLo(e, a, inc)) =>
          if lo is None {
            lo = Some((e, a, inc))
            lo_term = fi
          }
        Some(CHi(e, a, inc)) =>
          if hi is None {
            hi = Some((e, a, inc))
            hi_term = fi
          }
        None => ()
      }
    }
    match eq {
      Some(alts) => {
        eqs.push(alts)
        consumed.push(eq_term)
      }
      None => break
    }
  }
  let mut rowid_range = false
  if eqs.length() == keys.length() {
    lo = None
    hi = None
    // Index entries end with the rowid, which can bound the scan.
    if index is Some(_) {
      for rk in rowid_keys {
        for fi, f in filters {
          match term_constraint(f, rk, off, CBinary, Some(AffInteger), limit) {
            Some(CLo(e, a, inc)) =>
              if lo is None {
                lo = Some((e, a, inc))
                lo_term = fi
              }
            Some(CHi(e, a, inc)) =>
              if hi is None {
                hi = Some((e, a, inc))
                hi_term = fi
              }
            _ => ()
          }
        }
      }
      rowid_range = lo is Some(_) || hi is Some(_)
    }
  }
  if lo is Some(_) {
    consumed.push(lo_term)
  }
  if hi is Some(_) {
    consumed.push(hi_term)
  }
  if eqs.length() == 0 && lo is None && hi is None {
    return None
  }
  Some({ index, eqs, lo, hi, consumed, rowid_range, })
}

///|
/// True if the filter terms imply the partial-index predicate.
fn implies_predicate(pred : BExpr, filters : Array[BExpr], off : Int) -> Bool {
  let conj = []
  split_and(pred, conj)
  for c in conj {
    let ok = filters.any(f => {
      if bexpr_same(c, f, off) {
        return true
      }
      // `x IS NOT NULL` follows from a comparison of x.
      if c is BIsNull(x, true) {
        implies_not_null(f, x, off)
      } else {
        false
      }
    })
    if !ok {
      return false
    }
  }
  true
}

///|
/// SQLite's LogEst addition (log of the sum of two estimates).
fn log_est_add(a : Int, b : Int) -> Int {
  let x = [
    10, 10, 9, 9, 8, 8, 7, 7, 7, 6, 6, 6, 5, 5, 5, 4, 4, 4, 4, 3, 3, 3, 3, 3, 3,
    2, 2, 2, 2, 2, 2, 2,
  ]
  let (hi, lo) = if a >= b { (a, b) } else { (b, a) }
  if hi > lo + 49 {
    hi
  } else if hi > lo + 31 {
    hi + 1
  } else {
    hi + x[hi - lo]
  }
}

///|
/// Default estimated table size (LogEst of 1M rows).
let default_rows : Int = 200

///|
/// True if the index holds every column in `used`.
fn index_covers(t : Table, idx : Index, used : Array[Bool]) -> Bool {
  if idx.pred is Some(_) || idx.is_expression() {
    return false
  }
  for i in 0..<t.columns.length() {
    if used[i] && i != t.ipk && !idx.col_idx.contains(i) {
      return false
    }
  }
  true
}

///|
/// Estimated cost and output rows (LogEst) of an index plan, following
/// SQLite's defaults for tables without statistics.
fn plan_cost(
  t : Table,
  p : IndexPlan,
  used : Array[Bool],
  tw : Int,
) -> (Int, Int) {
  let partial = match p.index {
    Some(idx) => idx.pred is Some(_)
    None => false
  }
  let rsize = if partial { default_rows - 10 } else { default_rows }
  let est = (j : Int) => {
    // Rows matching the first j keys.
    if j == 0 {
      return rsize
    }
    match p.index {
      None => 0
      Some(idx) =>
        if idx.unique && j == idx.keys.length() {
          0
        } else {
          [33, 32, 30, 28, 26].get(j - 1).unwrap_or(23)
        }
    }
  }
  let mut nout = rsize
  let mut nin = 0
  for j, alts in p.eqs {
    nout += est(j + 1) - est(j)
    if alts.length() == 1 && alts[0].0 is BConst(Null) && alts[0].2 {
      nout += 10
    }
    if alts.length() > 1 {
      nin += log_est(alts.length())
    }
  }
  let nb = (if p.lo is Some(_) { 1 } else { 0 }) +
    (if p.hi is Some(_) { 1 } else { 0 })
  if nb > 0 {
    let mut nnew = nout - 20 * nb
    if nb == 2 {
      nnew -= 20
    }
    if nnew < 10 {
      nnew = 10
    }
    nout -= nb
    if nnew < nout {
      nout = nnew
    }
  }
  let mut run = match p.index {
    None => log_est_add(est_log(rsize), nout + 16)
    Some(idx) => {
      let r = log_est_add(
        est_log(rsize),
        nout + 1 + 15 * index_row_width(t, idx) / tw,
      )
      if index_covers(t, idx, used) {
        r
      } else {
        log_est_add(r, nout + 16)
      }
    }
  }
  run += nin
  nout += nin
  (run, nout)
}

///|
/// Picks the cheapest index (or rowid) access for a table source at `off`,
/// or None when a full scan is cheaper. Ties go to the rowid, then to the
/// newest index, as in SQLite.
fn choose_index_plan(
  t : Table,
  filters : Array[BExpr],
  off : Int,
  used : Array[Bool],
  probe_limit? : (Int, Int) = (0, 0),
  per_row? : Bool = false,
) -> IndexPlan? {
  if filters.length() == 0 {
    return None
  }
  let ncols = t.columns.length()
  let tw = table_row_width(t)
  let mut best : IndexPlan? = None
  let mut best_cost = default_rows + 16
  match covering_index(t, used) {
    Some(idx) =>
      best_cost = default_rows + 1 + 15 * index_row_width(t, idx) / tw
    None => ()
  }
  if per_row {
    // Probed once per row of another table: anything beats a scan.
    best_cost = @int.MAX_VALUE
  }
  let consider = (p : IndexPlan?) => {
    if p is Some(x) {
      let c = plan_cost(t, x, used, tw).0
      if c < best_cost {
        best = Some(x)
        best_cost = c
      }
    }
  }
  let rowid_key = BCol(ncols, AffInteger, CBinary)
  consider(plan_keys(None, [rowid_key], [CBinary], filters, off, probe_limit))
  if t.ipk >= 0 {
    let coll = t.columns[t.ipk].coll
    let k = BCol(t.ipk, AffInteger, coll)
    consider(plan_keys(None, [k], [coll], filters, off, probe_limit))
  }
  for i = t.indexes.length() - 1; i >= 0; i = i - 1 {
    let idx = t.indexes[i]
    if idx.pred is Some(p) && !implies_predicate(p, filters, off) {
      continue
    }
    consider(
      plan_keys(
        Some(idx),
        idx.keys,
        idx.colls,
        filters,
        off,
        probe_limit,
        rowid_keys=rowid_keys(t),
      ),
    )
  }
  best
}

///|
fn dedupe_sorted(vals : Array[Value], coll : Coll) -> Array[Value] {
  vals.sort_by((a, b) => compare_values_coll(a, b, coll))
  let out = []
  for v in vals {
    match out.last() {
      Some(l) if compare_values_coll(l, v, coll) == 0 => ()
      _ => out.push(v)
    }
  }
  out
}

///|
/// Feeds the rows (rowid, values) selected by an index plan to `f`, in index
/// order (reversed if `rev`), until `f` returns false. Probe expressions are
/// evaluated against `row`.
fn run_index_plan(
  t : Table,
  p : IndexPlan,
  row? : Array[Value] = [],
  rev? : Bool = false,
  f : (Int64, Array[Value]) -> Bool raise SqlError,
) -> Unit raise SqlError {
  let colls = match p.index {
    Some(idx) => idx.colls
    None => [CBinary]
  }
  let mut prefixes : Array[Array[Value]] = [[]]
  for j, alts in p.eqs {
    let vals = []
    for a in alts {
      let v = apply_cmp_affinity(eval(a.0, row), a.1)
      if v is Null && !a.2 {
        continue
      }
      vals.push(v)
    }
    let vals = if vals.length() > 1 {
      dedupe_sorted(vals, colls[j])
    } else {
      vals
    }
    // Probe in index order.
    if p.index is Some(idx) && idx.descs[j] {
      vals.rev_in_place()
    }
    if vals.length() == 0 {
      return
    }
    let next = []
    for pre in prefixes {
      for v in vals {
        next.push([..pre, v])
      }
    }
    prefixes = next
  }
  if rev {
    prefixes.rev_in_place()
  }
  let bound_value = (b : (BExpr, Affinity, Bool)?) => {
    match b {
      Some((e, aff, inc)) => Some((apply_cmp_affinity(eval(e, row), aff), inc))
      None => None
    }
  }
  let lo = bound_value(p.lo)
  let hi = bound_value(p.hi)
  if lo is Some((Null, _)) || hi is Some((Null, _)) {
    return
  }
  match p.index {
    None => {
      // Rowid access.
      if p.eqs.length() > 0 {
        for pre in prefixes {
          let id = match pre[0] {
            Int(i) => i
            Real(r) =>
              match real_to_exact_int(r) {
                Some(i) => i
                None => continue
              }
            _ => continue
          }
          if t.rows.get(id) is Some(r) && !f(id, r) {
            return
          }
        }
        return
      }
      guard rowid_bounds(lo, hi) is Some((low, high)) else { return }
      t.rows.scan(Some(low), Some(high), rev, f)
    }
    Some(idx) => {
      let descs = idx.descs
      let j = p.eqs.length()
      let desc = j < descs.length() && descs[j]
      // Bounds in tree order: a DESC key stores larger values first.
      let (tlo, thi) = if desc { (hi, lo) } else { (lo, hi) }
      let ranged = lo is Some(_) || hi is Some(_)
      let mut go = true
      if p.rowid_range {
        // Full key fixed: scan the rowid range of each prefix.
        guard rowid_bounds(lo, hi) is Some((low, high)) else { return }
        for pre in prefixes {
          let lk : IKey = { vals: pre, rowid: low, colls, descs, bound: 0, }
          let hk : IKey = { vals: pre, rowid: high, colls, descs, bound: 0, }
          idx.tree.scan(Some(lk), Some(hk), rev, (k, r) => {
            go = f(k.rowid, r)
            go
          })
          if !go {
            return
          }
        }
        return
      }
      for pre in prefixes {
        let low : IKey = match tlo {
          Some((v, inc)) =>
            {
              vals: [..pre, v],
              rowid: 0L,
              colls,
              descs,
              bound: if inc {
                -1
              } else {
                1
              },
            }
          None =>
            if ranged && !desc {
              { vals: [..pre, Null], rowid: 0L, colls, descs, bound: 1, }
            } else {
              { vals: pre, rowid: 0L, colls, descs, bound: -1, }
            }
        }
        let high : IKey = match thi {
          Some((v, inc)) =>
            {
              vals: [..pre, v],
              rowid: 0L,
              colls,
              descs,
              bound: if inc {
                1
              } else {
                -1
              },
            }
          None =>
            if ranged && desc {
              { vals: [..pre, Null], rowid: 0L, colls, descs, bound: -1, }
            } else {
              { vals: pre, rowid: 0L, colls, descs, bound: 1, }
            }
        }
        if Compare::compare(low, high) > 0 {
          continue
        }
        idx.tree.scan(Some(low), Some(high), rev, (k, r) => {
          go = f(k.rowid, r)
          go
        })
        if !go {
          return
        }
      }
    }
  }
}

///|
/// True if an OR tree consists only of `=` comparisons.
fn or_eq_leaves(e : BExpr) -> Bool {
  match e {
    BOr(l, r) => or_eq_leaves(l) && or_eq_leaves(r)
    BCmp(Eq, _, _, _, _) => true
    _ => false
  }
}

///|
/// SQLite's logarithmic estimate (10 * log2(x)).
fn log_est(x0 : Int) -> Int {
  let a = [0, 2, 3, 5, 6, 7, 8, 9]
  let mut x = x0
  let mut y = 40
  if x < 8 {
    if x < 2 {
      return 0
    }
    while x < 8 {
      y -= 10
      x = x << 1
    }
  } else {
    while x > 255 {
      y += 40
      x = x >> 4
    }
    while x > 15 {
      y += 10
      x = x >> 1
    }
  }
  a[x & 7] + y - 10
}

///|
/// SQLite's estimate of a column's size (1 = an integer) from its type.
fn column_size_est(type_name : String) -> Int {
  if type_name.trim().length() == 0 {
    return 1
  }
  guard affinity_of_type(type_name) is (AffText | AffNone) else { return 1 }
  let t = type_name.to_lower()
  let mut zchar = -1
  for i = 0; i + 4 <= t.length(); i = i + 1 {
    let w = t[i:i + 4]
    if w == "char" {
      zchar = i + 4
    } else if w == "blob" && i + 4 < t.length() && t[i + 4] == '(' {
      zchar = i + 4
    }
  }
  let mut v = 0
  if zchar >= 0 {
    let mut i = zchar
    while i < t.length() && !(t[i] >= '0' && t[i] <= '9') {
      i += 1
    }
    while i < t.length() && t[i] >= '0' && t[i] <= '9' && v < 100000 {
      v = v * 10 + (t[i].to_int() - '0'.to_int())
      i += 1
    }
  } else {
    v = 16
  }
  v = v / 4 + 1
  if v > 255 {
    255
  } else {
    v
  }
}

///|
fn table_row_width(t : Table) -> Int {
  let mut w = 0
  for c in t.columns {
    w += column_size_est(c.type_name)
  }
  if t.ipk < 0 {
    w += 1
  }
  log_est(w * 4)
}

///|
fn index_row_width(t : Table, idx : Index) -> Int {
  let mut w = 1 // the rowid
  for c in idx.col_idx {
    w += if c < 0 { 1 } else { column_size_est(t.columns[c].type_name) }
  }
  log_est(w * 4)
}

///|
/// The narrowest full index holding every column in `used` (columns, then
/// the rowid), for scans that need no other column.
fn covering_index(t : Table, used : Array[Bool]) -> Index? {
  if !used.any(x => x) {
    return None
  }
  let n = t.columns.length()
  let tw = table_row_width(t)
  let mut best : Index? = None
  let mut best_w = 0
  for k = t.indexes.length() - 1; k >= 0; k = k - 1 {
    let idx = t.indexes[k]
    if idx.pred is Some(_) || idx.is_expression() {
      continue
    }
    let w = index_row_width(t, idx)
    if w >= tw {
      continue
    }
    let mut covers = true
    for i in 0..<n {
      if used[i] && i != t.ipk && !idx.col_idx.contains(i) {
        covers = false
        break
      }
    }
    if covers && (best is None || w < best_w) {
      best = Some(idx)
      best_w = w
    }
  }
  best
}

///|
/// The row order a query would like from its (single) table scan: ORDER BY
/// terms (kind 0), GROUP BY terms (kind 1) or DISTINCT columns (kind 2).
priv struct OrderHint {
  /// Expression, descending, explicit NULLS FIRST, collation.
  terms : Array[(BExpr, Bool, Bool?, Coll)]
  kind : Int
  /// Number of result columns (sorting cost).
  ncols : Int
  has_limit : Bool
  /// When the scan delivers the order: stop after this many rows (-1 = no
  /// limit), skipping rows where `nonnull` is NULL (min/max optimization).
  limit : Int
  nonnull : BExpr?
}

///|
/// Order request from a query to its table source, and whether the chosen
/// scan delivers it.
priv struct OrderCtx {
  mut hint : OrderHint?
  mut satisfied : Bool
  /// Rows are filtered after the scan, so it cannot stop early.
  mut filtered_later : Bool
}

///|
/// Number of leading hint terms a scan of `index` (None = rowid order)
/// delivers, and whether the scan must run backwards. `single_eq[j]` tells
/// which leading keys are fixed by an equality.
fn order_satisfied(
  t : Table,
  index : Index?,
  single_eq : Array[Bool],
  eq_count : Int,
  hint : OrderHint,
  filters : Array[BExpr],
  off : Int,
) -> (Int, Bool) {
  let terms = hint.terms
  let n = terms.length()
  if index is None && eq_count > 0 && single_eq.all(x => x) {
    return (n, false)
  }
  let sat = Array::make(n, false)
  let ncols = t.columns.length()
  // Terms fixed to a constant by the WHERE clause are always in order.
  for i, term in terms {
    for f in filters {
      if f is BCmp(Eq | Is, a, b, _, coll) && coll == term.3 {
        if (bexpr_same(term.0, a, 0) && is_probe_expr(b, (0, 0))) ||
          (bexpr_same(term.0, b, 0) && is_probe_expr(a, (0, 0))) {
          sat[i] = true
        }
      }
    }
  }
  let is_rowid = (e : BExpr) => {
    match e {
      BCol(i, _, _) => i == off + ncols || (t.ipk >= 0 && i == off + t.ipk)
      _ => false
    }
  }
  let (keys, colls, descs, unique) = match index {
    Some(idx) => (idx.keys, idx.colls, idx.descs, idx.unique)
    None => ([], [], [], true)
  }
  let mut rev = false
  let mut rev_set = false
  let mut distinct = false
  let mut j = 0
  let nkeys = keys.length()
  while j <= nkeys {
    if j < nkeys && j < eq_count {
      if single_eq[j] {
        j += 1
        continue
      }
      break
    }
    let mut matched = false
    for i in 0..<n {
      if sat[i] {
        continue
      }
      let term = terms[i]
      let ok = if j == nkeys {
        is_rowid(term.0)
      } else {
        bexpr_same(keys[j], term.0, off) && colls[j] == term.3
      }
      if ok {
        if hint.kind == 0 {
          let key_desc = if j == nkeys { false } else { descs[j] }
          let r = key_desc != term.1
          // Non-default NULL placement works on the first free key only
          // (SQLite scans the NULLs separately).
          if term.2 is Some(nf) && nf != !term.1 && j != eq_count {
            break
          }
          if rev_set && r != rev {
            break
          }
          rev = r
          rev_set = true
        }
        sat[i] = true
        matched = true
        break
      }
      if hint.kind == 0 {
        break
      }
    }
    if !matched {
      break
    }
    if j == nkeys {
      distinct = true
    }
    j += 1
  }
  if j == nkeys && unique && eq_count >= nkeys && nkeys > 0 {
    distinct = true
  }
  if distinct {
    for i in 0..<n {
      sat[i] = true
    }
  }
  let mut k = 0
  while k < n && sat[k] {
    k += 1
  }
  (k, rev)
}

///|
fn est_log(n : Int) -> Int {
  if n <= 10 {
    0
  } else {
    log_est(n) - 33
  }
}

///|
/// A candidate scan in `choose_access` (SQLite's WhereLoop).
priv struct Cand {
  plan : IndexPlan?
  mut run : Int
  mut nout : Int
  indexed : Bool
  covering : Bool
  consumed : Array[Int]
  /// Loops that may deliver a different order are compared separately.
  sort_idx : Int
}

///|
/// SQLite's whereLoopCheaperProperSubset: x uses a proper subset of y's
/// terms and is not more expensive in both cost and rows.
fn cheaper_proper_subset(x : Cand, y : Cand) -> Bool {
  if x.consumed.length() >= y.consumed.length() {
    return false
  }
  if x.run > y.run && x.nout > y.nout {
    return false
  }
  if !x.consumed.all(c => y.consumed.contains(c)) {
    return false
  }
  !(x.covering && !y.covering)
}

///|
/// Picks how to scan a table source: an index or rowid plan (None = the
/// table in rowid order), whether to scan backwards, and whether the scan
/// delivers the hinted order. Follows SQLite's cost estimates for tables
/// without statistics, including the cost of sorting.
fn choose_access(
  t : Table,
  filters : Array[BExpr],
  off : Int,
  used : Array[Bool],
  hint : OrderHint?,
) -> (IndexPlan?, Bool, Bool) {
  let ncols = t.columns.length()
  let tw = table_row_width(t)
  let loops : Array[Cand] = []
  let is_rowid = (e : BExpr) => {
    e is BCol(c, _, _) && (c == off + ncols || (t.ipk >= 0 && c == off + t.ipk))
  }
  let insert = (
    p : IndexPlan?,
    run : Int,
    nout0 : Int,
    covering : Bool,
    sort_idx : Int,
  ) => {
    let nrow = match p {
      Some({ index: Some(idx), .. }) if idx.pred is Some(_) => default_rows - 10
      _ => default_rows
    }
    let consumed = match p {
      Some(x) => x.consumed
      None => []
    }
    // Output estimate after the terms the plan does not enforce.
    let mut nout = nout0 - (filters.length() - consumed.length())
    let mut reduce = 0
    for fi, f in filters {
      if !consumed.contains(fi) && f is BCmp(Eq | Is, _, _, _, _) {
        reduce = 20
      }
    }
    if nout > nrow - reduce {
      nout = nrow - reduce
    }
    let c : Cand = {
      plan: p,
      run,
      nout,
      indexed: p is Some({ index: Some(_), .. }),
      covering,
      consumed,
      sort_idx,
    }
    if c.indexed {
      for x in loops {
        if !x.indexed {
          continue
        }
        if cheaper_proper_subset(x, c) {
          c.run = if x.run < c.run { x.run } else { c.run }
          c.nout = if x.nout - 1 < c.nout { x.nout - 1 } else { c.nout }
        } else if cheaper_proper_subset(c, x) {
          c.run = if x.run > c.run { x.run } else { c.run }
          c.nout = if x.nout + 1 > c.nout { x.nout + 1 } else { c.nout }
        }
      }
    }
    for i, x in loops {
      if x.sort_idx != c.sort_idx {
        continue
      }
      if x.run <= c.run && x.nout <= c.nout {
        return
      }
      if c.run <= x.run && c.nout <= x.nout {
        loops[i] = c
        return
      }
    }
    loops.push(c)
  }
  let helps = (keys : Array[BExpr]) => {
    match hint {
      Some(h) =>
        h.terms.any(term => {
          is_rowid(term.0) || keys.any(k => bexpr_same(k, term.0, off))
        })
      None => false
    }
  }
  // The table itself: full scan, then rowid lookups.
  let pk_sort = if helps([]) { 1 } else { 0 }
  insert(None, default_rows + 16, default_rows, true, pk_sort)
  if filters.length() > 0 {
    let rowid_key = BCol(ncols, AffInteger, CBinary)
    let keys = [rowid_key]
    if t.ipk >= 0 {
      keys.push(BCol(t.ipk, AffInteger, t.columns[t.ipk].coll))
    }
    for k in keys {
      let coll = k.collation().unwrap_or(CBinary)
      match plan_keys(None, [k], [coll], filters, off, (0, 0)) {
        Some(p) => {
          let (c, n) = plan_cost(t, p, used, tw)
          insert(Some(p), c, n, true, pk_sort)
        }
        None => ()
      }
    }
  }
  for i = t.indexes.length() - 1; i >= 0; i = i - 1 {
    let idx = t.indexes[i]
    if idx.pred is Some(pr) && !implies_predicate(pr, filters, off) {
      continue
    }
    let covering = index_covers(t, idx, used)
    let sort_idx = if helps(idx.keys) { i + 2 } else { 0 }
    // Full scan of the index.
    let w = index_row_width(t, idx)
    if (covering && w < tw) || idx.pred is Some(_) || sort_idx > 0 {
      let rsize = if idx.pred is Some(_) {
        default_rows - 10
      } else {
        default_rows
      }
      let mut cost = rsize + 1 + 15 * w / tw
      if !covering {
        // Terms answerable from the index save table lookups.
        let mut lookup = rsize + 16
        for f in filters {
          if !term_covered(f, idx, t, off) {
            break
          }
          lookup -= 1
          if f is BCmp(Eq | Is, _, _, _, _) {
            lookup -= 19
          }
        }
        cost = log_est_add(cost, lookup)
      }
      let p : IndexPlan = {
        index: Some(idx),
        eqs: [],
        lo: None,
        hi: None,
        consumed: [],
        rowid_range: false,
      }
      insert(Some(p), cost, rsize, covering, sort_idx)
    }
    match
      plan_keys(
        Some(idx),
        idx.keys,
        idx.colls,
        filters,
        off,
        (0, 0),
        rowid_keys=rowid_keys(t),
      ) {
      Some(p) => {
        let (c, n) = plan_cost(t, p, used, tw)
        insert(Some(p), c, n, covering, sort_idx)
      }
      None => ()
    }
  }
  // Pick the cheapest loop, counting the sort it may need.
  let mut best : (IndexPlan?, Bool, Bool) = (None, false, false)
  let mut best_cost = @int.MAX_VALUE
  let mut best_nout = @int.MAX_VALUE
  for c in loops {
    let mut total = c.run
    let mut satisfied = false
    let mut rev = false
    if hint is Some(h) {
      let (index, eqs) = match c.plan {
        Some(x) => (x.index, x.eqs)
        None => (None, [])
      }
      let single = eqs.map(a => a.length() == 1)
      let (nsat, r) = order_satisfied(
        t,
        index,
        single,
        eqs.length(),
        h,
        filters,
        off,
      )
      let nterms = h.terms.length()
      if nsat >= nterms {
        satisfied = true
        rev = r
      } else {
        let mut sort = c.nout + log_est((h.ncols + 59) / 30)
        if nsat > 0 {
          sort += log_est((nterms - nsat) * 100 / nterms) - 66
        }
        if h.has_limit {
          sort += 10
        }
        sort += est_log(c.nout)
        total = log_est_add(c.run, sort) + 3
      }
    }
    // Ties go to the plan producing fewer rows.
    if total < best_cost || (total == best_cost && c.nout < best_nout) {
      best = (c.plan, rev, satisfied)
      best_cost = total
      best_nout = c.nout
    }
  }
  best
}

///|
/// True if every column the term reads is available in the index.
fn term_covered(e : BExpr, idx : Index, t : Table, off : Int) -> Bool {
  match e {
    BCol(i, _, _) => {
      let c = i - off
      c == t.columns.length() || c == t.ipk || idx.col_idx.contains(c)
    }
    BSlot(_) | BSubq(_) | BExists(_, _) | BInSub(_, _, _, _, _) => false
    _ => e.children().all(x => term_covered(x, idx, t, off))
  }
}

///|
/// True if the filter term can only be true when `x` (bound at slot 0) is
/// not NULL.
fn implies_not_null(f : BExpr, x : BExpr, off : Int) -> Bool {
  // `e` is NULL whenever x is.
  fn propagates(e : BExpr) -> Bool {
    if bexpr_same(x, e, off) {
      return true
    }
    match e {
      BArith(_, l, r) => propagates(l) || propagates(r)
      BCollate(y, _) | BUnary(_, y) => propagates(y)
      _ => false
    }
  }
  match f {
    BCmp(Eq | Ne | Lt | Le | Gt | Ge, a, b, _, _) =>
      propagates(a) || propagates(b)
    BInList(y, _, false, _, _) => propagates(y)
    BIsNull(y, true) => bexpr_same(x, y, off)
    BOr(l, r) if or_eq_leaves(f) =>
      implies_not_null(l, x, off) && implies_not_null(r, x, off)
    BAnd(l, r) => implies_not_null(l, x, off) || implies_not_null(r, x, off)
    _ => false
  }
}

///|
/// Expressions (bound at slot 0) naming the rowid of `t`.
fn rowid_keys(t : Table) -> Array[BExpr] {
  let keys = [BCol(t.columns.length(), AffInteger, CBinary)]
  if t.ipk >= 0 {
    keys.push(BCol(t.ipk, AffInteger, CBinary))
  }
  keys
}

///|
/// Integer rowid range [low, high] for the given bounds (after affinity);
/// None if no rowid can satisfy them.
fn rowid_bounds(lo : (Value, Bool)?, hi : (Value, Bool)?) -> (Int64, Int64)? {
  let mut low = @int64.MIN_VALUE
  let mut high = @int64.MAX_VALUE
  match lo {
    Some((Int(i), inc)) => {
      if !inc && i == @int64.MAX_VALUE {
        return None
      }
      low = if inc { i } else { i + 1L }
    }
    Some((Real(r), inc)) => {
      let c = if inc { r.ceil() } else { r.floor() + 1.0 }
      if c >= 9223372036854775807.0 {
        return None
      }
      if c > -9223372036854775808.0 {
        low = c.to_int64()
      }
    }
    Some(_) => return None
    None => ()
  }
  match hi {
    Some((Int(i), inc)) => {
      if !inc && i == @int64.MIN_VALUE {
        return None
      }
      high = if inc { i } else { i - 1L }
    }
    Some((Real(r), inc)) => {
      let c = if inc { r.floor() } else { r.ceil() - 1.0 }
      if c < -9223372036854775808.0 {
        return None
      }
      if c < 9223372036854775807.0 {
        high = c.to_int64()
      }
    }
    _ => ()
  }
  if low > high {
    None
  } else {
    Some((low, high))
  }
}
