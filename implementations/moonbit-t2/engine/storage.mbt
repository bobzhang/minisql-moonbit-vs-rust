// Row and index storage: index keys, row maintenance and snapshots used for
// statement atomicity, transactions and savepoints.

///|
/// Order of index entries: key parts by collation and direction, then rowid.
fn index_cmp(
  colls : Array[String],
  descs : Array[Bool],
) -> (Array[Value], Array[Value]) -> Int {
  let n = colls.length()
  fn(a : Array[Value], b : Array[Value]) -> Int {
    for i in 0..<n {
      let c = value_compare_coll(a[i], b[i], colls[i])
      if c != 0 {
        return if descs[i] { -c } else { c }
      }
    }
    value_compare(a[n], b[n])
  }
}

///|
/// Compares a (partial) key `parts` with an entry; `bias` decides the
/// result when all parts are equal (-1: before such entries, 1: after).
fn Index::probe_cmp(
  self : Index,
  parts : Array[Value],
  bias : Int,
  key : Array[Value],
) -> Int {
  for i in 0..<parts.length() {
    let c = value_compare_coll(parts[i], key[i], self.colls[i])
    if c != 0 {
      return if self.descs[i] { -c } else { c }
    }
  }
  bias
}

///|
/// Key of a row (key parts then rowid), or None when a partial index does
/// not cover the row.
fn Index::key_of(
  self : Index,
  vals : Array[Value],
  rowid : Int64,
) -> Array[Value]? raise SqlError {
  let n = self.cols.length()
  let mut env : Env? = None
  let get_env = fn() -> Env {
    match env {
      Some(e) => e
      None => {
        let e : Env = { row: row_with_rowid(vals, rowid), parent: None, }
        env = Some(e)
        e
      }
    }
  }
  if self.where_ is Some(w) && truthy(eval(w, get_env())) != Some(true) {
    return None
  }
  let key = Array::make(n + 1, Null)
  for i in 0..<n {
    let c = self.cols[i]
    key[i] = if c >= 0 { vals[c] } else { eval(self.exprs[i], get_env()) }
  }
  key[n] = Int(rowid)
  Some(key)
}

///|
/// For a unique index: the rowid of another entry with the same key parts.
fn Index::conflict_with(
  self : Index,
  key : Array[Value],
  self_rowid : Int64?,
) -> Int64? {
  let n = self.cols.length()
  for i in 0..<n {
    if key[i] is Null {
      return None
    }
  }
  let prefix = key[0:n].to_owned()
  let mut found : Int64? = None
  self.entries.each_ge(k => self.probe_cmp(prefix, -1, k), (k, _) => {
    if self.probe_cmp(prefix, 1, k) < 0 {
      return false
    }
    guard k[n] is Int(r) else { return true }
    if Some(r) != self_rowid {
      found = Some(r)
      false
    } else {
      true
    }
  })
  found
}

///|
/// Visits, in index order, the rowids of entries whose first parts equal
/// `prefix` and whose next part lies within the value bounds `lo`/`hi`
/// (value, inclusive).
fn Index::scan(
  self : Index,
  prefix : Array[Value],
  lo : (Value, Bool)?,
  hi : (Value, Bool)?,
  f : (Int64, Array[Value]) -> Bool raise SqlError,
  reverse? : Bool = false,
) -> Unit raise SqlError {
  let n = self.cols.length()
  let m = prefix.length()
  let desc = m < n && self.descs[m]
  let (start, end) = if desc { (hi, lo) } else { (lo, hi) }
  let (sparts, sbias) = match start {
    Some((v, incl)) => {
      let a = prefix.copy()
      a.push(v)
      (a, if incl { -1 } else { 1 })
    }
    None => (prefix, -1)
  }
  let (eparts, ebias) = match end {
    Some((v, incl)) => {
      let a = prefix.copy()
      a.push(v)
      (a, if incl { 1 } else { -1 })
    }
    None => (prefix, 1)
  }
  if reverse {
    self.entries.each_le_by(k => self.probe_cmp(eparts, ebias, k), (k, vals) => {
      if self.probe_cmp(sparts, sbias, k) > 0 {
        return false
      }
      match k[n] {
        Int(r) => f(r, vals)
        _ => true
      }
    })
    return
  }
  self.entries.each_ge(k => self.probe_cmp(sparts, sbias, k), (k, vals) => {
    if self.probe_cmp(eparts, ebias, k) < 0 {
      return false
    }
    match k[n] {
      Int(r) => f(r, vals)
      _ => true
    }
  })
}

///|
/// Text naming the index in constraint errors.
fn Index::label(self : Index, t : Table) -> String {
  if self.cols.all(c => c >= 0) {
    self.cols.map(c => t.name + "." + t.columns[c].name).join(", ")
  } else {
    "index '\{self.name}'"
  }
}

///|
/// Fills a new index from the table's rows, enforcing uniqueness.
fn Index::populate(self : Index, t : Table) -> Unit raise SqlError {
  t.rows.each_while((rowid, vals) => {
    if self.key_of(vals, rowid) is Some(k) {
      if self.unique && self.conflict_with(k, None) is Some(_) {
        raise SqlError("UNIQUE constraint failed: \{self.label(t)}")
      }
      self.entries.set(k, vals)
    }
    true
  })
}

///|
fn find_aggregate_name(e : Expr) -> String? {
  if e is Func(name~, args~, ..) && is_aggregate_call(name, args.length()) {
    return Some(name)
  }
  let mut found : String? = None
  for c in expr_children(e) {
    if found is None {
      found = find_aggregate_name(c)
    }
  }
  found
}

///|
fn has_subquery(e : Expr) -> Bool {
  match e {
    Subquery(_) | Exists(_) | InSelect(_, _, _) => true
    ScalarQ(_) | ExistsQ(_) | InQ(_, _, _) => true
    _ => expr_children(e).any(has_subquery)
  }
}

///|
/// Binds an index definition against its table.
fn build_index(
  t : Table,
  name : String,
  unique~ : Bool,
  origin~ : Int,
  conflict~ : Conflict,
  parts~ : Array[IndexPart],
  where_src~ : Expr?,
  sql~ : String?,
  seq~ : Int,
) -> Index raise SqlError {
  for p in parts {
    if find_aggregate_name(p.expr) is Some(f) {
      raise SqlError("misuse of aggregate function \{f}()")
    }
    if has_subquery(p.expr) {
      raise SqlError("subqueries prohibited in index expressions")
    }
  }
  if where_src is Some(w) {
    if find_aggregate_name(w) is Some(f) {
      raise SqlError("misuse of aggregate function \{f}()")
    }
    if has_subquery(w) {
      raise SqlError("subqueries prohibited in partial index WHERE clauses")
    }
  }
  let scope = new_scope([new_source(t.name, t, 0)], None)
  let ncols = t.columns.length()
  let cols : Array[Int] = []
  let exprs : Array[Expr] = []
  let colls : Array[String] = []
  let descs : Array[Bool] = []
  let affs : Array[Affinity] = []
  for p in parts {
    let b = bind_expr(p.expr, Some(scope))
    let explicit = match p.coll {
      Some(c) => Some(check_collation(c))
      None => None
    }
    match b {
      Slot(depth=0, idx~, ..) if idx < ncols => {
        cols.push(idx)
        colls.push(explicit.unwrap_or(t.columns[idx].coll.unwrap_or("BINARY")))
        affs.push(t.columns[idx].aff)
      }
      _ => {
        cols.push(-1)
        colls.push(
          explicit.unwrap_or(
            match expr_coll(b) {
              Some((c, _)) => c
              None => "BINARY"
            },
          ),
        )
        affs.push(expr_affinity(b))
      }
    }
    exprs.push(b)
    descs.push(p.desc)
  }
  let where_ = match where_src {
    Some(w) => Some(bind_expr(w, Some(scope)))
    None => None
  }
  {
    name,
    unique,
    origin,
    conflict,
    parts,
    where_src,
    sql,
    seq,
    cols,
    exprs,
    colls,
    descs,
    affs,
    where_,
    rootpage: 0,
    entries: OrdMap::new(index_cmp(colls, descs)),
  }
}

// ---------------------------------------------------------------------------
// Row operations (maintain the indexes)
// ---------------------------------------------------------------------------

///|
fn Table::raw_insert(
  self : Table,
  rowid : Int64,
  vals : Array[Value],
) -> Unit raise SqlError {
  self.rows.set(rowid, vals)
  for idx in self.indexes {
    if idx.key_of(vals, rowid) is Some(k) {
      idx.entries.set(k, vals)
    }
  }
  self.version = next_version()
}

///|
fn Table::raw_delete(
  self : Table,
  rowid : Int64,
) -> Array[Value]? raise SqlError {
  guard self.rows.get(rowid) is Some(vals) else { return None }
  for idx in self.indexes {
    if idx.key_of(vals, rowid) is Some(k) {
      idx.entries.remove(k)
    }
  }
  self.rows.remove(rowid)
  self.version = next_version()
  Some(vals)
}

///|
fn Database::insert_row(
  self : Database,
  t : Table,
  rowid : Int64,
  vals : Array[Value],
) -> Unit raise SqlError {
  ignore(self)
  t.raw_insert(rowid, vals)
  if t.autoinc && rowid > t.seq {
    t.seq = rowid
  }
}

///|
fn Database::delete_row(
  self : Database,
  t : Table,
  rowid : Int64,
) -> Unit raise SqlError {
  ignore(self)
  ignore(t.raw_delete(rowid))
}

///|
fn Table::rowid_label(self : Table) -> String {
  if self.ipk >= 0 {
    self.name + "." + self.columns[self.ipk].name
  } else {
    self.name + ".rowid"
  }
}

// ---------------------------------------------------------------------------
// Snapshots
// ---------------------------------------------------------------------------

///|
fn Table::snapshot(self : Table) -> TableSnap {
  {
    t: self,
    name: self.name,
    columns: self.columns,
    rows: self.rows.copy(),
    ipk: self.ipk,
    seq: self.seq,
    indexes: self.indexes.copy(),
    entries: self.indexes.map(i => i.entries.copy()),
    checks: self.checks,
    sql: self.sql,
  }
}

///|
fn TableSnap::restore(self : TableSnap) -> Unit {
  let t = self.t
  t.name = self.name
  t.columns = self.columns
  t.rows = self.rows.copy()
  t.ipk = self.ipk
  t.seq = self.seq
  t.indexes = self.indexes.copy()
  for i, idx in self.indexes {
    idx.entries = self.entries[i].copy()
  }
  t.checks = self.checks
  t.sql = self.sql
  t.version = next_version()
}

///|
fn Database::snapshot(self : Database) -> DbSnap {
  {
    tables: self.tables.to_array(),
    views: self.views.to_array(),
    tsnaps: self.tables.values().map(t => t.snapshot()).to_array(),
    sequence_seq: self.sequence_seq,
  }
}

///|
fn Database::restore(self : Database, s : DbSnap) -> Unit {
  self.tables = Map(s.tables)
  self.views = Map(s.views)
  self.sequence_seq = s.sequence_seq
  for ts in s.tsnaps {
    ts.restore()
  }
}
