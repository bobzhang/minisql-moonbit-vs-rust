///|
/// An index entry (or a search bound). Keys compare column by column under
/// the index collations, then by rowid. A bound whose `vals` is a prefix of
/// an entry's sorts before (`bound` < 0) or after (`bound` > 0) every entry
/// sharing that prefix.
pub(all) struct IKey {
  vals : Array[Value]
  rowid : Int64
  colls : Array[Coll]
  descs : Array[Bool]
  bound : Int
}

///|
pub impl Compare for IKey with fn compare(self, other) {
  let n = if self.vals.length() < other.vals.length() {
    self.vals.length()
  } else {
    other.vals.length()
  }
  for k in 0..<n {
    let c = compare_values_coll(self.vals[k], other.vals[k], self.colls[k])
    if c != 0 {
      return if self.descs[k] { -c } else { c }
    }
  }
  if self.vals.length() == other.vals.length() {
    if self.bound != other.bound {
      return self.bound.compare(other.bound)
    }
    if self.bound != 0 {
      return 0
    }
    return self.rowid.compare(other.rowid)
  }
  if self.vals.length() == n {
    // self is the shorter one: a bound
    if self.bound > 0 {
      1
    } else {
      -1
    }
  } else if other.bound > 0 {
    -1
  } else {
    1
  }
}

///|
pub impl Eq for IKey with fn equal(self, other) {
  Compare::compare(self, other) == 0
}

///|
/// A table index: an explicit CREATE INDEX or the automatic index behind a
/// UNIQUE / PRIMARY KEY constraint.
pub(all) struct Index {
  mut name : String
  /// Name of the indexed table.
  mut table : String
  unique : Bool
  /// Number n of an automatic index sqlite_autoindex_<table>_<n>; 0 if the
  /// index was created explicitly.
  auto_num : Int
  conflict : String?
  cols : Array[IndexedCol]
  where_ : Expr?
  /// Table column of each key, or -1 for an expression key.
  col_idx : Array[Int]
  colls : Array[Coll]
  descs : Array[Bool]
  /// Key expressions and predicate, bound against the table at slot 0.
  keys : Array[BExpr]
  pred : BExpr?
  /// Entries mapped to the row they index (without the rowid).
  tree : SortedChunks[IKey, Array[Value]]
  mut seq : Int
  mut sql : String?
}

///|
/// Key values of a full row (columns + rowid), or None if the row is outside
/// a partial index.
fn Index::key_values(self : Index, full : Array[Value]) -> Array[Value]? {
  if self.pred is Some(p) {
    let ok = eval(p, full).truth() catch { _ => None }
    if ok != Some(true) {
      return None
    }
  }
  Some(self.keys.map(k => eval(k, full) catch { _ => Null }))
}

///|
fn Index::add_row(
  self : Index,
  full : Array[Value],
  rowid : Int64,
  row : Array[Value],
) -> Unit {
  if self.key_values(full) is Some(vals) {
    self.tree.set(
      { vals, rowid, colls: self.colls, descs: self.descs, bound: 0, },
      row,
    )
  }
}

///|
fn Index::remove_row(self : Index, full : Array[Value], rowid : Int64) -> Unit {
  if self.key_values(full) is Some(vals) {
    self.tree.remove({
      vals,
      rowid,
      colls: self.colls,
      descs: self.descs,
      bound: 0,
    })
  }
}

///|
/// Rowids of the entries whose key starts with `prefix`.
fn Index::lookup(self : Index, prefix : Array[Value]) -> Array[Int64] {
  let out = []
  let lo = {
    vals: prefix,
    rowid: 0L,
    colls: self.colls,
    descs: self.descs,
    bound: -1,
  }
  let hi = {
    vals: prefix,
    rowid: 0L,
    colls: self.colls,
    descs: self.descs,
    bound: 1,
  }
  self.tree.scan(Some(lo), Some(hi), false, (k, _) => {
    out.push(k.rowid)
    true
  })
  out
}

///|
/// For a unique index: the rowid of another row holding the same key as
/// `full`, if any. Keys containing NULL never conflict.
fn Index::find_conflict(
  self : Index,
  full : Array[Value],
  self_rowid : Int64?,
) -> Int64? {
  guard self.key_values(full) is Some(vals) else { return None }
  for v in vals {
    if v is Null {
      return None
    }
  }
  for r in self.lookup(vals) {
    if Some(r) != self_rowid {
      return Some(r)
    }
  }
  None
}

///|
fn Index::is_expression(self : Index) -> Bool {
  self.col_idx.any(c => c < 0)
}
