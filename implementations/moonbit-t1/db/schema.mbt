// Tables, unique indexes and database state.

///|
/// Definition of an explicit (CREATE INDEX) index, kept for rebinding.
priv struct IndexDef {
  cols : Array[IndexCol]
  where_ : Expr?
  sql : String
}

///|
/// An index over columns or expressions of a table. Keys are the key values
/// followed by the rowid, so equal key values never collide in the map.
priv struct Index {
  name : String
  exprs : Array[Expr] // key expressions bound against [cols..., rowid]
  cols : Array[Int] // column of each key part, -1 for an expression
  colls : Array[Coll]
  descs : Array[Bool]
  affs : Array[Affinity]
  unique : Bool
  conflict : Conflict?
  where_ : Expr? // partial index predicate (bound)
  def : IndexDef? // None for automatic indexes
  seq : Int // position in sqlite_schema
  mut map : PMap[Array[Value], Int64]
}

///|
fn key_cmp(colls : Array[Coll]) -> (Array[Value], Array[Value]) -> Int {
  (a, b) => {
    let n = if a.length() < b.length() { a.length() } else { b.length() }
    for i in 0..<n {
      let coll = if i < colls.length() { colls[i] } else { CBinary }
      let c = compare_coll(a[i], b[i], coll)
      if c != 0 {
        return c
      }
    }
    a.length() - b.length()
  }
}

///|
/// Index key order: like `key_cmp`, with DESC key parts reversed.
fn index_key_cmp(
  colls : Array[Coll],
  descs : Array[Bool],
) -> (Array[Value], Array[Value]) -> Int {
  (a, b) => {
    let n = if a.length() < b.length() { a.length() } else { b.length() }
    for i in 0..<n {
      let coll = if i < colls.length() { colls[i] } else { CBinary }
      let c = compare_coll(a[i], b[i], coll)
      if c != 0 {
        return if i < descs.length() && descs[i] { -c } else { c }
      }
    }
    a.length() - b.length()
  }
}

///|
/// Key values of a row (without the rowid); None if a partial index does
/// not cover the row.
fn Index::key_vals(
  self : Index,
  vals : Array[Value],
  rowid : Int64,
) -> Array[Value]? raise SqlError {
  let simple = self.where_ is None && self.cols.all(c => c >= 0)
  if simple {
    return Some(self.cols.map(c => vals[c]))
  }
  let row = vals.copy()
  row.push(Int(rowid))
  if self.where_ is Some(w) && !(eval(w, row).truth() is Some(true)) {
    return None
  }
  Some(self.exprs.map(e => eval(e, row)))
}

///|
fn Index::add_row(
  self : Index,
  vals : Array[Value],
  rowid : Int64,
) -> Unit raise SqlError {
  if self.key_vals(vals, rowid) is Some(k) {
    k.push(Int(rowid))
    self.map = self.map.add(k, rowid)
  }
}

///|
fn Index::remove_row(
  self : Index,
  vals : Array[Value],
  rowid : Int64,
) -> Unit raise SqlError {
  if self.key_vals(vals, rowid) is Some(k) {
    k.push(Int(rowid))
    self.map = self.map.remove(k)
  }
}

///|
/// Rowid of a row (other than `self_rowid`) whose key equals that of the
/// given row. Keys containing NULL never conflict.
fn Index::find_conflict(
  self : Index,
  vals : Array[Value],
  rowid : Int64,
  self_rowid : Int64?,
) -> Int64? raise SqlError {
  guard self.key_vals(vals, rowid) is Some(key) else { return None }
  let n = key.length()
  if key.any(v => v is Null) {
    return None
  }
  key.push(Int(@int64.MIN_VALUE))
  let mut found : Int64? = None
  self.map.each_from(Some(key), (k, rid) => {
    for i in 0..<n {
      if compare_coll(k[i], key[i], self.colls[i]) != 0 {
        return false
      }
    }
    if self_rowid is Some(s) && s == rid {
      return true
    }
    found = Some(rid)
    false
  })
  found
}

///|
priv struct Table {
  name : String
  cols : Array[ColumnDef]
  constraints : Array[TableConstraint]
  sql : String
  rowid_alias : Int? // column that is an INTEGER PRIMARY KEY
  autoinc : Bool
  rowid_conflict : Conflict? // ON CONFLICT clause of the INTEGER PRIMARY KEY
  indexes : Array[Index] // in constraint-checking order
  checks : Array[Expr] // bound against the row layout [cols..., rowid]
  seq : Int // position in sqlite_schema
  mut rows : PMap[Int64, Array[Value]]
  mut seq_val : Int64 // AUTOINCREMENT high-water mark
}

///|
fn rowid_cmp(a : Int64, b : Int64) -> Int {
  if a < b {
    -1
  } else if a > b {
    1
  } else {
    0
  }
}

///|
fn Table::insert_row(
  self : Table,
  rowid : Int64,
  vals : Array[Value],
) -> Unit raise SqlError {
  data_version.val += 1
  self.rows = self.rows.add(rowid, vals)
  for ix in self.indexes {
    ix.add_row(vals, rowid)
  }
}

///|
fn Table::delete_row(self : Table, rowid : Int64) -> Unit raise SqlError {
  guard self.rows.find(rowid) is Some(vals) else { return }
  data_version.val += 1
  self.rows = self.rows.remove(rowid)
  for ix in self.indexes {
    ix.remove_row(vals, rowid)
  }
}

///|
fn find_rowid_alias(
  cols : Array[ColumnDef],
  constraints : Array[TableConstraint],
) -> Int? {
  for i, c in cols {
    if c.primary_key && !c.pk_desc && c.type_name.to_upper() == "INTEGER" {
      return Some(i)
    }
  }
  for tc in constraints {
    if tc is TPrimaryKey(names, _) && names.length() == 1 {
      for i, c in cols {
        if same_name(c.name, names[0]) && c.type_name.to_upper() == "INTEGER" {
          return Some(i)
        }
      }
    }
  }
  None
}

///|
fn col_index_in(cols : Array[ColumnDef], name : String) -> Int? {
  for i, c in cols {
    if same_name(c.name, name) {
      return Some(i)
    }
  }
  None
}

///|
/// Build a table from a CREATE TABLE statement. `seq` is the table's
/// position in sqlite_schema; its automatic indexes follow it.
fn build_table(
  name : String,
  cols : Array[ColumnDef],
  constraints : Array[TableConstraint],
  sql : String,
  seq : Int,
) -> Table raise SqlError {
  for i, c in cols {
    for j in 0..<i {
      if same_name(cols[j].name, c.name) {
        raise sql_err("duplicate column name: \{c.name}")
      }
    }
  }
  let rowid_alias = find_rowid_alias(cols, constraints)
  let mut autoinc = false
  let mut rowid_conflict : Conflict? = None
  for i, c in cols {
    if c.autoincrement {
      if rowid_alias != Some(i) {
        raise sql_err("AUTOINCREMENT is only allowed on an INTEGER PRIMARY KEY")
      }
      autoinc = true
    }
    if rowid_alias == Some(i) && c.primary_key {
      rowid_conflict = c.pk_conflict
    }
  }
  // unique indexes in creation order
  let created : Array[Index] = []
  fn add_index(idx_cols : Array[Int], conflict : Conflict?) -> Unit {
    for ix in created {
      if ix.cols == idx_cols {
        return
      }
    }
    let colls = idx_cols.map(i => col_coll(cols[i]))
    let n = created.length() + 1
    created.push({
      name: "sqlite_autoindex_\{name}_\{n}",
      exprs: idx_cols.map(i => Slot(i, cols[i].affinity, col_coll(cols[i]))),
      cols: idx_cols,
      colls,
      descs: idx_cols.map(_ => false),
      affs: idx_cols.map(i => cols[i].affinity),
      unique: true,
      conflict,
      where_: None,
      def: None,
      seq: seq + n,
      map: PMap::empty(key_cmp(colls)),
    })
  }

  for i, c in cols {
    if c.primary_key && rowid_alias != Some(i) {
      add_index([i], c.pk_conflict)
    }
    if c.unique {
      add_index([i], c.unique_conflict)
    }
  }
  for tc in constraints {
    match tc {
      TPrimaryKey(names, conflict) | TUnique(names, conflict) => {
        let idx_cols : Array[Int] = []
        for n in names {
          match col_index_in(cols, n) {
            Some(i) => idx_cols.push(i)
            None => raise sql_err("no such column: \{n}")
          }
        }
        if tc is TPrimaryKey(_, _) &&
          rowid_alias is Some(ai) &&
          idx_cols == [ai] {
          rowid_conflict = conflict
        } else {
          add_index(idx_cols, conflict)
        }
      }
      _ => ()
    }
  }
  created.rev_in_place()
  let t : Table = {
    name,
    cols,
    constraints,
    sql,
    rowid_alias,
    autoinc,
    rowid_conflict,
    indexes: created,
    checks: [],
    seq,
    rows: PMap::empty(rowid_cmp),
    seq_val: 0L,
  }
  // bind CHECK constraints against the table's own row
  let scope = simple_scope([table_source(name, t, 0, false)])
  for c in cols {
    for e in c.checks {
      t.checks.push(scope.bind(e))
    }
  }
  for tc in constraints {
    if tc is TCheck(e) {
      t.checks.push(scope.bind(e))
    }
  }
  t
}

///|
fn has_subquery_ast(e : Expr) -> Bool {
  match e {
    SubQ(_) | ExistsQ(_) | InQ(_, _, _) => true
    _ => expr_children(e).any(has_subquery_ast)
  }
}

///|
/// Build an explicit index over table `t` (without filling it).
fn make_index(
  t : Table,
  name : String,
  unique : Bool,
  def : IndexDef,
  seq : Int,
) -> Index raise SqlError {
  for c in def.cols {
    if has_subquery_ast(c.expr) {
      raise sql_err("subqueries prohibited in index expressions")
    }
  }
  if def.where_ is Some(w) && has_subquery_ast(w) {
    raise sql_err("subqueries prohibited in partial index WHERE clauses")
  }
  let scope = simple_scope([table_source(t.name, t, 0, false)])
  let exprs : Array[Expr] = []
  let cols : Array[Int] = []
  let colls : Array[Coll] = []
  let affs : Array[Affinity] = []
  let ncols = t.cols.length()
  for c in def.cols {
    let b = scope.bind(c.expr)
    if contains_agg(b) {
      raise sql_err("misuse of aggregate function in index")
    }
    exprs.push(b)
    cols.push(
      match b {
        Slot(i, _, _) if i < ncols => i
        _ => -1
      },
    )
    colls.push(
      match c.coll {
        Some(x) => x
        None => expr_coll(b).unwrap_or(CBinary)
      },
    )
    affs.push(expr_affinity(b).unwrap_or(AffNone))
  }
  let where_ = match def.where_ {
    Some(w) => {
      let b = scope.bind(w)
      if contains_agg(b) {
        raise sql_err("misuse of aggregate function in index WHERE clause")
      }
      Some(b)
    }
    None => None
  }
  {
    name,
    exprs,
    cols,
    colls,
    descs: def.cols.map(c => c.desc),
    affs,
    unique,
    conflict: None,
    where_,
    def: Some(def),
    seq,
    map: PMap::empty(index_key_cmp(colls, def.cols.map(c => c.desc))),
  }
}

///|
fn unique_index_error(t : Table, ix : Index) -> SqlError {
  if ix.cols.any(c => c < 0) {
    sql_err("UNIQUE constraint failed: index '\{ix.name}'")
  } else {
    let parts = ix.cols.map(i => "\{t.name}.\{t.cols[i].name}")
    sql_err("UNIQUE constraint failed: " + parts.join(", "))
  }
}

///|
/// Add every row of the table to a new index, checking uniqueness.
fn fill_index(t : Table, ix : Index) -> Unit raise SqlError {
  let rows = t.rows.to_array()
  for p in rows {
    if ix.unique && ix.find_conflict(p.1, p.0, None) is Some(_) {
      raise unique_index_error(t, ix)
    }
    ix.add_row(p.1, p.0)
  }
}

///|
priv struct ConnState {
  mut changes : Int64
  mut total_changes : Int64
  mut last_rowid : Int64
}

///|
let conn : ConnState = { changes: 0L, total_changes: 0L, last_rowid: 0L, }

///|
priv struct View {
  name : String
  cols : Array[String]?
  query : Query
  sql : String
  seq : Int
}

///|
struct Database {
  tables : Map[String, Table]
  views : Map[String, View]
  mut next_seq : Int
  mut stmt_changes : Int64
  mut dml_started : Bool
  mut fail_keep : Bool
  /// Set when ON CONFLICT ROLLBACK fired: the whole transaction is undone.
  mut rollback_all : Bool
  /// State at BEGIN while a transaction is open.
  mut txn : DbSnap?
  /// The transaction was opened by SAVEPOINT (RELEASE of it commits).
  mut txn_by_savepoint : Bool
  savepoints : Array[(String, DbSnap)]
  /// Root pages of objects loaded from a database file (by lowercase name).
  roots : Map[String, Int]
  /// Position of sqlite_sequence in sqlite_schema, once it exists.
  mut seq_table : Int?
}

///|
pub fn Database::new() -> Database {
  {
    tables: Map([]),
    views: Map([]),
    next_seq: 1,
    stmt_changes: 0L,
    dml_started: false,
    fail_keep: false,
    rollback_all: false,
    txn: None,
    txn_by_savepoint: false,
    savepoints: [],
    roots: Map([]),
    seq_table: None,
  }
}

///|
priv struct TableSnap {
  key : String
  table : Table
  rows : PMap[Int64, Array[Value]]
  seq_val : Int64
  indexes : Array[Index]
  maps : Array[PMap[Array[Value], Int64]]
}

///|
priv struct DbSnap {
  tables : Array[TableSnap]
  views : Array[(String, View)]
  next_seq : Int
  seq_table : Int?
}

///|
fn Database::snapshot(self : Database) -> DbSnap {
  let out : Array[TableSnap] = []
  for k, t in self.tables {
    out.push({
      key: k,
      table: t,
      rows: t.rows,
      seq_val: t.seq_val,
      indexes: t.indexes.copy(),
      maps: t.indexes.map(ix => ix.map),
    })
  }
  let views : Array[(String, View)] = []
  for k, v in self.views {
    views.push((k, v))
  }
  { tables: out, views, next_seq: self.next_seq, seq_table: self.seq_table, }
}

///|
/// Bumped on every row change (invalidates cached view contents).
let data_version : Ref[Int] = { val: 0, }

///|
fn Database::restore(self : Database, snap : DbSnap) -> Unit {
  data_version.val += 1
  self.tables.clear()
  for s in snap.tables {
    s.table.rows = s.rows
    s.table.seq_val = s.seq_val
    s.table.indexes.clear()
    for i, ix in s.indexes {
      ix.map = s.maps[i]
      s.table.indexes.push(ix)
    }
    self.tables[s.key] = s.table
  }
  self.views.clear()
  for v in snap.views {
    self.views[v.0] = v.1
  }
  self.next_seq = snap.next_seq
  self.seq_table = snap.seq_table
}

///|
fn key_of(name : String) -> String {
  name.to_lower()
}

///|
fn same_name(a : String, b : String) -> Bool {
  a.to_lower() == b.to_lower()
}

///|
fn is_schema_name(name : String) -> Bool {
  let l = name.to_lower()
  l == "sqlite_schema" ||
  l == "sqlite_master" ||
  l == "sqlite_temp_schema" ||
  l == "sqlite_temp_master"
}

///|
fn Database::get_table(self : Database, name : String) -> Table raise SqlError {
  match self.tables.get(key_of(name)) {
    Some(t) => t
    None => raise sql_err("no such table: \{name}")
  }
}

///|
/// A table that DML may modify.
fn Database::writable_table(
  self : Database,
  name : String,
) -> Table raise SqlError {
  if self.views.get(key_of(name)) is Some(v) {
    raise sql_err("cannot modify \{v.name} because it is a view")
  }
  if is_schema_name(name) && !self.tables.contains(key_of(name)) {
    raise sql_err("table sqlite_master may not be modified")
  }
  self.get_table(name)
}

///|
/// The table owning index `name` and the index's position in it.
fn Database::find_index(self : Database, name : String) -> (Table, Int)? {
  for _, t in self.tables {
    for i, ix in t.indexes {
      if same_name(ix.name, name) {
        return Some((t, i))
      }
    }
  }
  None
}

///|
/// Kind of the schema object called `name`, if any.
fn Database::object_kind(self : Database, name : String) -> String? {
  if self.tables.contains(key_of(name)) {
    Some("table")
  } else if self.views.contains(key_of(name)) {
    Some("view")
  } else if self.find_index(name) is Some(_) {
    Some("index")
  } else {
    None
  }
}

///|
fn Database::take_seq(self : Database, n : Int) -> Int {
  let s = self.next_seq
  self.next_seq += n
  s
}

///|
fn text_col(name : String, type_name : String) -> ColumnDef {
  {
    name,
    type_name,
    affinity: affinity_of_type(type_name),
    not_null: false,
    primary_key: false,
    pk_desc: false,
    autoincrement: false,
    unique: false,
    default_: None,
    collate: None,
    checks: [],
    pk_conflict: None,
    nn_conflict: None,
    unique_conflict: None,
  }
}

///|
/// A read-only snapshot of sqlite_schema, as a table called `name`.
fn Database::schema_table(self : Database, name : String) -> Table {
  let cols = [
    text_col("type", "text"),
    text_col("name", "text"),
    text_col("tbl_name", "text"),
    text_col("rootpage", "int"),
    text_col("sql", "text"),
  ]
  let t = build_table(name, cols, [], "", 0) catch { _ => abort("schema") }
  let entries : Array[(Int, Array[Value])] = []
  for _, tb in self.tables {
    entries.push(
      (
        tb.seq,
        [Text("table"), Text(tb.name), Text(tb.name), Int(0), Text(tb.sql)],
      ),
    )
    for ix in tb.indexes {
      let sql = match ix.def {
        Some(d) => Text(d.sql)
        None => Null
      }
      entries.push(
        (ix.seq, [Text("index"), Text(ix.name), Text(tb.name), Int(0), sql]),
      )
    }
  }
  if self.seq_table is Some(sq) {
    entries.push(
      (
        sq,
        [
          Text("table"),
          Text("sqlite_sequence"),
          Text("sqlite_sequence"),
          Int(0),
          Text("CREATE TABLE sqlite_sequence(name,seq)"),
        ],
      ),
    )
  }
  for _, v in self.views {
    entries.push(
      (v.seq, [Text("view"), Text(v.name), Text(v.name), Null, Text(v.sql)]),
    )
  }
  entries.sort_by((a, b) => a.0 - b.0)
  let mut rows : PMap[Int64, Array[Value]] = PMap::empty(rowid_cmp)
  for i, e in entries {
    let vals = e.1
    if vals[3] is Null {
      vals[3] = Int(0L)
    } else if vals[1] is Text(n) && self.roots.get(key_of(n)) is Some(r) {
      vals[3] = Int(r.to_int64())
    } else {
      vals[3] = Int((i + 2).to_int64())
    }
    rows = rows.add((i + 1).to_int64(), vals)
  }
  t.rows = rows
  t
}

///|
fn Table::col_index(self : Table, name : String) -> Int? {
  col_index_in(self.cols, name)
}

///|
fn Database::has_seq_table(self : Database, name : String) -> Bool {
  self.seq_table is Some(_) && name.to_lower() == "sqlite_sequence"
}

///|
/// A read-only snapshot of sqlite_sequence, as a table called `name`.
fn Database::sequence_table(self : Database, name : String) -> Table {
  let cols = [text_col("name", ""), text_col("seq", "")]
  let t = build_table(name, cols, [], "", 0) catch { _ => abort("schema") }
  let tabs : Array[Table] = []
  for _, tb in self.tables {
    if tb.autoinc && tb.seq_val > 0L {
      tabs.push(tb)
    }
  }
  tabs.sort_by((a, b) => a.seq - b.seq)
  let mut rows : PMap[Int64, Array[Value]] = PMap::empty(rowid_cmp)
  for i, tb in tabs {
    rows = rows.add((i + 1).to_int64(), [Text(tb.name), Int(tb.seq_val)])
  }
  t.rows = rows
  t
}
