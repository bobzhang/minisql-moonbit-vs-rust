// Access paths: rowid and index lookups for one table of a query.

///|
priv struct Bound {
  expr : Expr
  incl : Bool
  aff : Affinity?
}

///|
/// Equality constraint on one key part: probe values (several for IN),
/// comparison affinity, and whether NULL matches (IS).
priv struct EqCons {
  probes : Array[Expr]
  aff : Affinity?
  is_ : Bool
}

///|
priv enum Access {
  AScan
  ARowid(eq~ : EqCons?, lo~ : Bound?, hi~ : Bound?, rev~ : Bool)
  AIndex(
    ix~ : Index,
    eqs~ : Array[EqCons],
    lo~ : Bound?,
    hi~ : Bound?,
    rev~ : Bool
  )
  /// Every row, in the order of an index.
  AFull(ix~ : Index, rev~ : Bool)
}

///|
/// True if `e` can be evaluated before the source whose first slot is `lo`
/// is scanned: it uses only earlier sources, outer rows and constants.
fn probe_ok(e : Expr, lo : Int) -> Bool {
  match e {
    Slot(i, _, _) => i < lo
    Outer(_, _) | Lit(_) | BigIntLit => true
    SubScalar(_)
    | SubExists(_)
    | SubIn(_, _, _, _)
    | AggRef(_)
    | Column(..)
    | SubQ(_)
    | ExistsQ(_)
    | InQ(_, _, _) => false
    Func(name~, ..) if name == "RANDOM" || name == "RANDOMBLOB" => false
    _ => expr_children(e).all(c => probe_ok(c, lo))
  }
}

///|
fn values_same(a : Value, b : Value) -> Bool {
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
/// Structural equality of bound expressions; slots of `b` are shifted by `off`.
fn expr_same(a : Expr, b : Expr, off : Int) -> Bool {
  match (a, b) {
    (Lit(x), Lit(y)) => values_same(x, y)
    (BigIntLit, BigIntLit) => true
    (Slot(i, _, _), Slot(j, _, _)) => i == j + off
    (Unary(o1, x), Unary(o2, y)) => o1 == o2 && expr_same(x, y, off)
    (Binary(o1, l1, r1), Binary(o2, l2, r2))
    | (Cmp(o1, l1, r1, _), Cmp(o2, l2, r2, _)) =>
      o1 == o2 && expr_same(l1, l2, off) && expr_same(r1, r2, off)
    (IsNull(x, n1), IsNull(y, n2)) => n1 == n2 && expr_same(x, y, off)
    (Collate(x, c1), Collate(y, c2)) => c1 == c2 && expr_same(x, y, off)
    (Cast(x, a1), Cast(y, a2)) => a1 == a2 && expr_same(x, y, off)
    (
      Func(name=n1, args=a1, distinct=d1, ..),
      Func(name=n2, args=a2, distinct=d2, ..),
    ) =>
      n1 == n2 &&
      d1 == d2 &&
      a1.length() == a2.length() &&
      a1.iter().zip(a2.iter()).all(p => expr_same(p.0, p.1, off))
    (Between(x1, l1, h1, n1, _, _), Between(x2, l2, h2, n2, _, _)) =>
      n1 == n2 &&
      expr_same(x1, x2, off) &&
      expr_same(l1, l2, off) &&
      expr_same(h1, h2, off)
    (InList(x1, i1, n1, _), InList(x2, i2, n2, _)) =>
      n1 == n2 &&
      expr_same(x1, x2, off) &&
      i1.length() == i2.length() &&
      i1.iter().zip(i2.iter()).all(p => expr_same(p.0, p.1, off))
    (
      Like(glob=g1, lhs=l1, pat=p1, esc=e1, neg=n1),
      Like(glob=g2, lhs=l2, pat=p2, esc=e2, neg=n2),
    ) =>
      g1 == g2 &&
      n1 == n2 &&
      expr_same(l1, l2, off) &&
      expr_same(p1, p2, off) &&
      (match (e1, e2) {
        (None, None) => true
        (Some(x), Some(y)) => expr_same(x, y, off)
        _ => false
      })
    _ => false
  }
}

///|
/// A usable constraint `target op probe(s)`.
priv struct Term {
  target : Expr
  op : BinOp // Eq (also IS and IN), Lt, Le, Gt, Ge
  probes : Array[Expr]
  info : CmpInfo
  is_ : Bool
}

///|
fn flip_op(op : BinOp) -> BinOp {
  match op {
    Lt => Gt
    Le => Ge
    Gt => Lt
    Ge => Le
    o => o
  }
}

///|
fn collect_terms(cands : Array[Expr], lo : Int, hi : Int) -> Array[Term] {
  let out : Array[Term] = []
  let on_src = (e : Expr) => slots_within(e, lo, hi) && max_slot(e) >= lo
  for c in cands {
    match c {
      Cmp(op, l, r, info) if op is (Eq | Lt | Le | Gt | Ge | Is) => {
        let is_ = op == Is
        let op2 = if is_ { Eq } else { op }
        if on_src(l) && probe_ok(r, lo) {
          out.push({ target: l, op: op2, probes: [r], info, is_, })
        } else if on_src(r) && probe_ok(l, lo) {
          out.push({ target: r, op: flip_op(op2), probes: [l], info, is_, })
        }
      }
      IsNull(x, false) =>
        if on_src(x) {
          out.push({
            target: x,
            op: Eq,
            probes: [Lit(Null)],
            info: default_info,
            is_: true,
          })
        }
      InList(x, items, false, info) =>
        if on_src(x) && items.all(i => probe_ok(i, lo)) {
          out.push({ target: x, op: Eq, probes: items, info, is_: false, })
        }
      Between(x, l, h, false, i1, i2) =>
        if on_src(x) && probe_ok(l, lo) && probe_ok(h, lo) {
          out.push({ target: x, op: Ge, probes: [l], info: i1, is_: false, })
          out.push({ target: x, op: Le, probes: [h], info: i2, is_: false, })
        }
      _ => ()
    }
  }
  out
}

///|
fn aff_ok(aff : Affinity?, idx : Affinity) -> Bool {
  match aff {
    None | Some(AffNone) => true
    Some(AffText) => idx == AffText
    Some(_) => is_numeric_aff(idx)
  }
}

///|
/// True if the conjuncts `cands` imply the partial-index predicate `w`.
fn implies(
  cands : Array[Expr],
  terms : Array[Term],
  w : Expr,
  off : Int,
) -> Bool {
  let parts : Array[Expr] = []
  split_and(w, parts)
  parts.all(p => {
    if cands.any(c => expr_same(c, p, off)) {
      return true
    }
    match p {
      IsNull(x, true) => terms.any(t => !t.is_ && expr_same(t.target, x, off))
      _ => false
    }
  })
}

///|
/// SQLite's logarithmic size estimate (sqlite3LogEst).
fn log_est(x0 : Int) -> Int {
  let a = [0, 2, 3, 5, 6, 7, 8, 9]
  let mut x = x0
  let mut y = 40
  if x < 2 {
    return 0
  }
  if x < 8 {
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
/// Estimated width of a column (SQLite's szEst).
fn col_size_est(c : ColumnDef) -> Int {
  let tn = c.type_name.to_upper()
  if tn == "" {
    return 1
  }
  let mut v = 0
  if c.affinity is (AffText | AffNone) {
    let digits_after = (pos : Int) => {
      let mut n = 0
      let mut seen = false
      for i in pos..<tn.length() {
        let ch = tn[i].to_int()
        if ch >= 48 && ch <= 57 {
          n = n * 10 + (ch - 48)
          seen = true
          if n > 100000 {
            break
          }
        } else if seen {
          break
        }
      }
      n
    }
    match tn.find("CHAR") {
      Some(p) => v = digits_after(p + 4)
      None =>
        if tn.contains("CLOB") || tn.contains("TEXT") {
          v = 16
        } else {
          match tn.find("BLOB") {
            Some(p) if p + 4 < tn.length() && tn[p + 4] == '(' =>
              v = digits_after(p + 4)
            _ => v = 16
          }
        }
    }
  }
  let r = v / 4 + 1
  if r > 255 {
    255
  } else {
    r
  }
}

///|
fn table_width(t : Table) -> Int {
  let mut w = 0
  for c in t.cols {
    w += col_size_est(c)
  }
  if t.rowid_alias is None {
    w += 1
  }
  log_est(w * 4)
}

///|
fn index_width(t : Table, ix : Index) -> Int {
  let mut w = 1 // rowid
  for c in ix.cols {
    w += if c >= 0 { col_size_est(t.cols[c]) } else { 1 }
  }
  log_est(w * 4)
}

///|
/// True if the index holds every column the query reads.
fn covers(t : Table, ix : Index, used : Array[Bool]?) -> Bool {
  guard used is Some(u) else { return false }
  if ix.where_ is Some(_) {
    return false
  }
  for i in 0..<t.cols.length() {
    if u[i] && t.rowid_alias != Some(i) && !ix.cols.contains(i) {
      return false
    }
  }
  true
}

///|
/// Leading ORDER BY (or DISTINCT) key the scan order should follow.
priv struct OrderHint {
  key : Expr
  desc : Bool
  any_dir : Bool // DISTINCT: either direction will do
}

///|
fn hint_matches(h : OrderHint, ix : Index, j : Int, off : Int) -> Bool {
  let (inner, coll) = match h.key {
    Collate(x, c) => (x, Some(c))
    e => (e, expr_coll(e))
  }
  j < ix.exprs.length() &&
  expr_same(inner, ix.exprs[j], off) &&
  coll.unwrap_or(CBinary) == ix.colls[j]
}

///|
/// Choose how to read table `t` whose row starts at slot `off`, given the
/// conjuncts that must hold for its rows. `used` marks the columns the
/// query reads (None: all).
fn choose_access(
  t : Table,
  off : Int,
  cands : Array[Expr],
  hint : OrderHint?,
  used : Array[Bool]?,
  cov_scan : Bool,
) -> Access {
  let ncols = t.cols.length()
  let terms = collect_terms(cands, off, off + ncols + 1)
  let is_rowid = (e : Expr) => {
    match e {
      Slot(i, _, _) => i == off + ncols || t.rowid_alias == Some(i - off)
      _ => false
    }
  }
  let mut best : Access = AScan
  let mut best_score = 0
  let mut single_range = false
  let mut best_cov = false
  let mut best_w = 0
  {
    let mut eq : EqCons? = None
    let mut lo : Bound? = None
    let mut hi : Bound? = None
    for tm in terms {
      if !is_rowid(tm.target) || tm.is_ {
        continue
      }
      let b : Bound = {
        expr: tm.probes[0],
        incl: tm.op is (Le | Ge),
        aff: None,
      }
      match tm.op {
        Eq =>
          if eq is None {
            eq = Some({ probes: tm.probes, aff: None, is_: false, })
          }
        Gt | Ge => if lo is None { lo = Some(b) }
        _ => if hi is None { hi = Some(b) }
      }
    }
    if eq is Some(_) {
      return ARowid(eq~, lo=None, hi=None, rev=false)
    }
    if lo is Some(_) || hi is Some(_) {
      let rev = match hint {
        Some(h) => is_rowid(h.key) && h.desc
        None => false
      }
      best = ARowid(eq=None, lo~, hi~, rev~)
      best_score = 1 +
        (if lo is Some(_) { 3 } else { 0 }) +
        (if hi is Some(_) { 3 } else { 0 })
      single_range = !(lo is Some(_) && hi is Some(_))
    }
  }
  for ix in t.indexes {
    if ix.where_ is Some(w) && !implies(cands, terms, w, off) {
      continue
    }
    let n = ix.exprs.length()
    let eqs : Array[EqCons] = []
    let mut lo : Bound? = None
    let mut hi : Bound? = None
    let usable = (tm : Term, j : Int) => {
      expr_same(tm.target, ix.exprs[j], off) &&
      (
        tm.probes[0] is Lit(Null) ||
        (aff_ok(tm.info.aff, ix.affs[j]) && tm.info.coll == ix.colls[j])
      )
    }
    while eqs.length() < n {
      let j = eqs.length()
      let mut hit : Term? = None
      for tm in terms {
        if tm.op == Eq && usable(tm, j) {
          hit = Some(tm)
          break
        }
      }
      guard hit is Some(tm) else { break }
      eqs.push({ probes: tm.probes, aff: tm.info.aff, is_: tm.is_, })
    }
    if eqs.length() < n {
      let j = eqs.length()
      for tm in terms {
        if tm.op == Eq || !usable(tm, j) {
          continue
        }
        let b : Bound = {
          expr: tm.probes[0],
          incl: tm.op is (Le | Ge),
          aff: tm.info.aff,
        }
        match tm.op {
          Gt | Ge => if lo is None { lo = Some(b) }
          _ => if hi is None { hi = Some(b) }
        }
      }
    }
    let mut score = eqs.length() * 10 +
      (if lo is Some(_) { 3 } else { 0 }) +
      (if hi is Some(_) { 3 } else { 0 })
    if score > 0 && ix.unique && eqs.length() == n {
      score += 1000
    }
    let cov = covers(t, ix, used)
    let w = index_width(t, ix)
    if score > best_score ||
      (
        score > 0 &&
        score == best_score &&
        best is AIndex(..) &&
        ((cov && !best_cov) || (cov == best_cov && w < best_w))
      ) {
      best_score = score
      best_cov = cov
      best_w = w
      let m = eqs.length()
      let rev = match hint {
        Some(h) =>
          hint_matches(h, ix, m, off) && !h.any_dir && h.desc != ix.descs[m]
        None => false
      }
      best = AIndex(ix~, eqs~, lo~, hi~, rev~)
      single_range = m == 0 && !(lo is Some(_) && hi is Some(_))
    }
  }
  // an index that yields the ORDER BY / DISTINCT order beats a full scan
  // or a range with a single bound
  if hint is Some(h) && (best is AScan || single_range) {
    let keep = match best {
      AIndex(ix~, ..) => hint_matches(h, ix, 0, off)
      ARowid(..) => is_rowid(h.key)
      _ => false
    }
    if !keep && !is_rowid(h.key) {
      for ix in t.indexes {
        if ix.where_ is None && hint_matches(h, ix, 0, off) {
          return AFull(ix~, rev=!h.any_dir && h.desc != ix.descs[0])
        }
      }
    }
  }
  // covering index scan when the index is narrower than the table
  if best is AScan && cov_scan && used is Some(_) {
    let tw = table_width(t)
    let mut best_w = tw
    for ix in t.indexes {
      if ix.where_ is Some(_) {
        continue
      }
      if !covers(t, ix, used) {
        continue
      }
      let w = index_width(t, ix)
      if w < best_w {
        best_w = w
        best = AFull(ix~, rev=false)
      }
    }
  }
  best
}

///|
/// Convert a probe value the way the comparison converts it.
fn conv_probe(v : Value, aff : Affinity?) -> Value {
  match aff {
    Some(AffText) => num_to_text(v)
    Some(AffNumeric | AffInteger | AffReal) => apply_numeric_cmp(v)
    _ => v
  }
}

///|
/// Distinct probe values of an equality constraint, in key order.
fn eq_values(
  e : EqCons,
  row : Array[Value],
  coll : Coll,
  desc : Bool,
) -> Array[Value] raise SqlError {
  let vals : Array[Value] = []
  for p in e.probes {
    let v = conv_probe(eval(p, row), e.aff)
    if v is Null && !e.is_ {
      continue
    }
    vals.push(v)
  }
  if vals.length() > 1 {
    stable_sort(vals, (a, b) => {
      let c = compare_coll(a, b, coll)
      if desc {
        -c
      } else {
        c
      }
    })
    let out : Array[Value] = [vals[0]]
    for i in 1..<vals.length() {
      if compare_coll(vals[i], out[out.length() - 1], coll) != 0 {
        out.push(vals[i])
      }
    }
    return out
  }
  vals
}

///|
/// Rows of `t` selected by an access path (a superset of the rows that
/// satisfy the terms it was built from), for the current `row`.
fn fetch_access(
  acc : Access,
  t : Table,
  row : Array[Value],
) -> Array[(Int64, Array[Value])] raise SqlError {
  let out : Array[(Int64, Array[Value])] = []
  let rids : Array[Int64] = []
  let mut reverse = false
  match acc {
    AScan => return out
    AFull(ix~, rev~) =>
      if rev {
        ix.map.each_rev_from(None, (_, rid) => {
          rids.push(rid)
          true
        })
      } else {
        ix.map.each_from(None, (_, rid) => {
          rids.push(rid)
          true
        })
      }
    ARowid(eq~, lo~, hi~, rev~) => {
      match eq {
        Some(e) => {
          let seen : Array[Int64] = []
          for v in eq_values(e, row, CBinary, false) {
            let rid = match apply_numeric_cmp(v) {
              Int(i) => i
              Real(d) =>
                match real_to_int_exact(d) {
                  Some(i) => i
                  None => continue
                }
              _ => continue
            }
            if seen.contains(rid) {
              continue
            }
            seen.push(rid)
            if t.rows.find(rid) is Some(vals) {
              out.push((rid, vals))
            }
          }
          return out
        }
        None => ()
      }
      let mut lov : Int64? = None
      let mut lo_incl = true
      let mut hiv : Int64? = None
      let mut hi_incl = true
      if lo is Some(b) {
        match apply_numeric_cmp(eval(b.expr, row)) {
          Int(i) => {
            lov = Some(i)
            lo_incl = b.incl
          }
          Real(d) =>
            if d > 9.2e18 {
              return out
            } else if d > -9.2e18 {
              lov = Some(d.floor().to_int64())
            }
          Null | Text(_) | Blob(_) => return out
        }
      }
      if hi is Some(b) {
        match apply_numeric_cmp(eval(b.expr, row)) {
          Int(i) => {
            hiv = Some(i)
            hi_incl = b.incl
          }
          Real(d) =>
            if d < -9.2e18 {
              return out
            } else if d < 9.2e18 {
              hiv = Some(d.ceil().to_int64())
            }
          Null => return out
          Text(_) | Blob(_) => ()
        }
      }
      t.rows.each_from(lov, (k, v) => {
        if lov is Some(l) && k == l && !lo_incl {
          return true
        }
        if hiv is Some(h) && (k > h || (k == h && !hi_incl)) {
          return false
        }
        out.push((k, v))
        true
      })
      if rev {
        out.rev_in_place()
      }
      return out
    }
    AIndex(ix~, eqs~, lo~, hi~, rev~) => {
      reverse = rev
      let colls = ix.colls
      let descs = ix.descs
      let m = eqs.length()
      // candidate prefixes (cartesian product of the equality values)
      let mut prefixes : Array[Array[Value]] = [[]]
      for j, e in eqs {
        let vals = eq_values(e, row, colls[j], descs[j])
        let next : Array[Array[Value]] = []
        for p in prefixes {
          for v in vals {
            let q = p.copy()
            q.push(v)
            next.push(q)
          }
        }
        prefixes = next
      }
      let lov = match lo {
        Some(b) => {
          let v = conv_probe(eval(b.expr, row), b.aff)
          if v is Null {
            return out
          }
          Some(v)
        }
        None => None
      }
      let hiv = match hi {
        Some(b) => {
          let v = conv_probe(eval(b.expr, row), b.aff)
          if v is Null {
            return out
          }
          Some(v)
        }
        None => None
      }
      let desc = m < descs.length() && descs[m]
      // in key order, the bound met first and the one that ends the scan
      let (first, first_v, last, last_v) = if desc {
        (hi, hiv, lo, lov)
      } else {
        (lo, lov, hi, hiv)
      }
      for prefix in prefixes {
        let start = prefix.copy()
        if first_v is Some(v) {
          start.push(v)
        }
        ix.map.each_from(if start.length() > 0 { Some(start) } else { None }, (
          k,
          rid,
        ) => {
          for i in 0..<m {
            if compare_coll(k[i], prefix[i], colls[i]) != 0 {
              return false
            }
          }
          if m < colls.length() {
            let v = k[m]
            // position of v relative to a bound, in scan direction
            let dir = (x : Value) => {
              let c = compare_coll(v, x, colls[m])
              if desc {
                -c
              } else {
                c
              }
            }
            match first {
              Some(b) => {
                let c = dir(first_v.unwrap())
                if c < 0 || (c == 0 && !b.incl) {
                  return true
                }
              }
              None => if !desc && last is Some(_) && v is Null { return true }
            }
            match last {
              Some(b) => {
                let c = dir(last_v.unwrap())
                if c > 0 || (c == 0 && !b.incl) {
                  return false
                }
              }
              None => if desc && first is Some(_) && v is Null { return false }
            }
          }
          rids.push(rid)
          true
        })
      }
    }
  }
  if reverse {
    rids.rev_in_place()
  }
  for rid in rids {
    if t.rows.find(rid) is Some(vals) {
      out.push((rid, vals))
    }
  }
  out
}
