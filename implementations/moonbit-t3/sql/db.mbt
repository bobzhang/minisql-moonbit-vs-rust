///|
pub(all) struct TableColumn {
  name : String
  type_name : String
  affinity : Affinity
  coll : Coll
  def : ColumnDef
}

///|
pub(all) struct Table {
  mut name : String
  columns : Array[TableColumn]
  /// The (possibly rewritten) definition the table was built from.
  mut def : CreateTable
  rows : SortedChunks[Int64, Array[Value]]
  mut max_rowid : Int64
  mut max_dirty : Bool
  /// Column index of the INTEGER PRIMARY KEY (rowid alias), or -1.
  ipk : Int
  ipk_conflict : String?
  autoinc : Bool
  mut seq : Int64
  /// Unique indexes in the order constraints are checked.
  uniques : Array[Index]
  /// All indexes, in creation order.
  indexes : Array[Index]
  checks : Array[(String, BExpr)]
  defaults : Array[BExpr?]
  /// Bumped on every row change (invalidates cached automatic indexes).
  mut version : Int
  /// Position in sqlite_schema.
  mut schema_seq : Int
  mut sql : String?
}

///|
pub(all) struct View {
  name : String
  temp : Bool
  columns : Array[String]
  mut select : Select
  seq : Int
  mut sql : String?
}

///|
priv enum Undo {
  UInsert(Table, Int64)
  UDelete(Table, Int64, Array[Value])
  USeq(Table, Int64)
  UFn(() -> Unit)
}

///|
pub(all) struct Database {
  tables : Map[String, Table]
  views : Map[String, View]
  indexes : Map[String, Index]
  mut schema_seq : Int
  priv undo : Array[Undo]
  mut in_txn : Bool
  /// The transaction was opened by SAVEPOINT (RELEASE of the last one commits).
  mut txn_by_savepoint : Bool
  savepoints : Array[(String, Int)]
  /// Set when an OR ROLLBACK conflict aborts the whole transaction.
  mut rollback_txn : Bool
  /// Text of the statement being executed.
  mut cur_sql : String
  /// Views being expanded (cycle detection).
  expanding : Set[String]
  /// sqlite_schema position of sqlite_sequence (0 = not created yet).
  mut sequence_seq : Int
  mut changes : Int64
  mut total_changes : Int64
  mut last_rowid : Int64
  mut stmt_changes : Int64
  /// Set when a FAIL conflict aborts a statement: its earlier changes stay.
  mut fail_keep : Bool
  /// Set once a DML statement starts modifying data.
  mut in_dml : Bool
}

///|
pub fn Database::new() -> Database {
  {
    tables: Map([]),
    views: Map([]),
    indexes: Map([]),
    schema_seq: 0,
    undo: [],
    in_txn: false,
    txn_by_savepoint: false,
    savepoints: [],
    rollback_txn: false,
    cur_sql: "",
    expanding: Set([]),
    sequence_seq: 0,
    changes: 0L,
    total_changes: 0L,
    last_rowid: 0L,
    stmt_changes: 0L,
    fail_keep: false,
    in_dml: false,
  }
}

///|
pub fn fold_name(s : String) -> String {
  s.to_lower()
}

///|
pub fn Database::find_table(self : Database, name : String) -> Table? {
  self.tables.get(fold_name(name))
}

///|
pub fn Database::get_table(
  self : Database,
  name : String,
) -> Table raise SqlError {
  match self.find_table(name) {
    Some(t) => t
    None => raise err("no such table: " + name)
  }
}

///|
pub fn Table::column_index(self : Table, name : String) -> Int? {
  let f = fold_name(name)
  for i, c in self.columns {
    if fold_name(c.name) == f {
      return Some(i)
    }
  }
  None
}

///|
/// Appends a normalized form of `v` under collation `coll` so that values
/// that compare equal produce identical keys.
pub fn write_value_key(sb : StringBuilder, v : Value, coll : Coll) -> Unit {
  match v {
    Null => sb.write_string("N;")
    Int(i) => sb.write_string("I\{i};")
    Real(r) =>
      match real_to_exact_int(r) {
        Some(i) => sb.write_string("I\{i};")
        None => sb.write_string("R\{r.reinterpret_as_int64()};")
      }
    Text(s) => {
      let t = match coll {
        CNoCase => {
          let b = StringBuilder()
          for c in s {
            b.write_char(c.to_ascii_lowercase())
          }
          b.to_string()
        }
        CRTrim => rtrim_spaces(s)
        _ => s
      }
      sb.write_string("T\{t.length()}:")
      sb.write_string(t)
    }
    Blob(b) => sb.write_string("B" + blob_to_hex(b) + ";")
  }
}

///|
/// Bumped on every row change in any table.
let data_version : Ref[Int] = { val: 0, }

///|
fn Table::raw_put(self : Table, rowid : Int64, row : Array[Value]) -> Unit {
  self.version += 1
  data_version.val += 1
  self.rows.set(rowid, row)
  if self.rows.length() == 1 || rowid > self.max_rowid {
    self.max_rowid = rowid
  }
  if self.indexes.length() > 0 {
    let full = full_row(row, rowid)
    for idx in self.indexes {
      idx.add_row(full, rowid, row)
    }
  }
}

///|
fn Table::raw_remove(self : Table, rowid : Int64) -> Array[Value]? {
  guard self.rows.get(rowid) is Some(row) else { return None }
  self.version += 1
  data_version.val += 1
  self.rows.remove(rowid)
  if self.indexes.length() > 0 {
    let full = full_row(row, rowid)
    for idx in self.indexes {
      idx.remove_row(full, rowid)
    }
  }
  if rowid == self.max_rowid {
    self.max_dirty = true
  }
  Some(row)
}

///|
/// Largest rowid currently in the table (0 when empty).
pub fn Table::current_max_rowid(self : Table) -> Int64 {
  self.rows.max_key().unwrap_or(0L)
}

///|
fn Database::row_insert(
  self : Database,
  t : Table,
  rowid : Int64,
  row : Array[Value],
) -> Unit {
  t.raw_put(rowid, row)
  self.undo.push(UInsert(t, rowid))
}

///|
fn Database::row_delete(self : Database, t : Table, rowid : Int64) -> Unit {
  if t.raw_remove(rowid) is Some(old) {
    self.undo.push(UDelete(t, rowid, old))
  }
}

///|
fn Database::set_seq(self : Database, t : Table, v : Int64) -> Unit {
  self.undo.push(USeq(t, t.seq))
  t.seq = v
}

///|
fn Database::rollback_to(self : Database, mark : Int) -> Unit {
  while self.undo.length() > mark {
    match self.undo.pop() {
      Some(UInsert(t, id)) => t.raw_remove(id) |> ignore
      Some(UDelete(t, id, row)) => t.raw_put(id, row)
      Some(USeq(t, v)) => t.seq = v
      Some(UFn(f)) => f()
      None => break
    }
  }
}

///|
/// Result of executing one statement.
pub(all) struct QueryResult {
  columns : Array[String]
  rows : Array[Array[Value]]
}

///|
fn empty_result() -> QueryResult {
  { columns: [], rows: [], }
}

///|
fn Database::end_txn(self : Database) -> Unit {
  self.in_txn = false
  self.txn_by_savepoint = false
  self.savepoints.clear()
  self.undo.clear()
}

///|
pub fn Database::execute(
  self : Database,
  sql : String,
) -> QueryResult raise SqlError {
  let stmt = parse_statement(sql)
  self.cur_sql = sql
  let mark = self.undo.length()
  self.stmt_changes = 0L
  self.fail_keep = false
  self.in_dml = false
  self.rollback_txn = false
  outer_rows.clear()
  self.expanding.clear()
  cte_env.val = []
  dml_target.val = false
  cte_active.clear()
  let res = self.execute_stmt(stmt) catch {
    e => {
      if self.rollback_txn {
        self.rollback_to(0)
        self.end_txn()
        self.changes = 0L
      } else if self.in_dml {
        if self.fail_keep {
          self.changes = self.stmt_changes
          self.total_changes += self.stmt_changes
        } else {
          self.rollback_to(mark)
          self.changes = 0L
        }
      } else {
        self.rollback_to(mark)
      }
      if !self.in_txn {
        self.undo.clear()
      }
      raise e
    }
  }
  if self.in_dml {
    self.changes = self.stmt_changes
    self.total_changes += self.stmt_changes
  }
  if !self.in_txn {
    self.undo.clear()
  }
  res
}

///|
fn Database::execute_stmt(
  self : Database,
  stmt : Stmt,
) -> QueryResult raise SqlError {
  match stmt {
    CreateTableStmt(ct) => self.create_table(ct)
    DropTableStmt(name, if_exists) => self.drop_table(name, if_exists)
    CreateIndexStmt(ci) => self.create_index(ci)
    DropIndexStmt(name, if_exists) => self.drop_index(name, if_exists)
    CreateViewStmt(cv) => self.create_view(cv)
    DropViewStmt(name, if_exists) => self.drop_view(name, if_exists)
    AlterStmt(name, action) => self.alter_table(name, action)
    BeginStmt => {
      if self.in_txn {
        raise err("cannot start a transaction within a transaction")
      }
      self.undo.clear()
      self.in_txn = true
      self.txn_by_savepoint = false
    }
    CommitStmt => {
      if !self.in_txn {
        raise err("cannot commit - no transaction is active")
      }
      self.end_txn()
    }
    RollbackStmt(None) => {
      if !self.in_txn {
        raise err("cannot rollback - no transaction is active")
      }
      self.rollback_to(0)
      self.end_txn()
    }
    RollbackStmt(Some(name)) => {
      let i = self.find_savepoint(name)
      self.rollback_to(self.savepoints[i].1)
      self.savepoints.truncate(i + 1)
    }
    SavepointStmt(name) => {
      if !self.in_txn {
        self.undo.clear()
        self.in_txn = true
        self.txn_by_savepoint = true
      }
      self.savepoints.push((name, self.undo.length()))
    }
    ReleaseStmt(name) => {
      let i = self.find_savepoint(name)
      self.savepoints.truncate(i)
      if self.savepoints.length() == 0 && self.txn_by_savepoint {
        self.end_txn()
      }
    }
    InsertStmt(ins) => return self.exec_insert(ins)
    UpdateStmt(upd) => return self.exec_update(upd)
    DeleteStmt(del) => return self.exec_delete(del)
    SelectStmt(sel) => return self.run_select(sel)
    WithStmt(ctes, inner) => {
      let env = make_cte_env(ctes)
      return with_cte_env(env, () => self.execute_stmt(inner))
    }
  }
  empty_result()
}

///|
fn Database::find_savepoint(
  self : Database,
  name : String,
) -> Int raise SqlError {
  let f = fold_name(name)
  for i = self.savepoints.length() - 1; i >= 0; i = i - 1 {
    if fold_name(self.savepoints[i].0) == f {
      return i
    }
  }
  raise err("no such savepoint: " + name)
}

///|
fn Database::next_seq(self : Database) -> Int {
  self.schema_seq += 1
  self.schema_seq
}

///|
/// Kind of the schema object using `name` ("table", "view", "index"), if any.
fn Database::object_kind(self : Database, name : String) -> String? {
  let f = fold_name(name)
  if self.tables.contains(f) {
    Some("table")
  } else if self.views.contains(f) {
    Some("view")
  } else if self.indexes.contains(f) {
    Some("index")
  } else {
    None
  }
}

///|
fn check_reserved_name(name : String) -> Unit raise SqlError {
  if fold_name(name).has_prefix("sqlite_") {
    raise err("object name reserved for internal use: " + name)
  }
}

///|
/// Adds a table and its indexes to the schema (undoable).
fn Database::register_table(self : Database, t : Table) -> Unit {
  self.tables[fold_name(t.name)] = t
  for idx in t.indexes {
    self.indexes[fold_name(idx.name)] = idx
  }
  self.undo.push(UFn(() => self.unregister_table_raw(t)))
}

///|
fn Database::unregister_table_raw(self : Database, t : Table) -> Unit {
  self.tables.remove(fold_name(t.name))
  for idx in t.indexes {
    self.indexes.remove(fold_name(idx.name))
  }
}

///|
/// Removes a table and its indexes from the schema (undoable).
fn Database::unregister_table(self : Database, t : Table) -> Unit {
  self.unregister_table_raw(t)
  self.undo.push(
    UFn(() => {
      self.tables[fold_name(t.name)] = t
      for idx in t.indexes {
        self.indexes[fold_name(idx.name)] = idx
      }
    }),
  )
}

///|
fn Database::drop_table(
  self : Database,
  name : String,
  if_exists : Bool,
) -> Unit raise SqlError {
  match self.find_table(name) {
    Some(t) => {
      if fold_name(t.name).has_prefix("sqlite_") {
        raise err("table " + t.name + " may not be dropped")
      }
      self.unregister_table(t)
    }
    None =>
      if self.views.contains(fold_name(name)) {
        raise err("use DROP VIEW to delete view " + name)
      } else if !if_exists {
        raise err("no such table: " + name)
      }
  }
}

///|
fn Database::create_table(
  self : Database,
  ct : CreateTable,
) -> Unit raise SqlError {
  match self.object_kind(ct.name) {
    Some("index") => raise err("there is already an index named " + ct.name)
    Some(kind) => {
      if ct.if_not_exists {
        return
      }
      raise err(kind + " " + ct.name + " already exists")
    }
    None => ()
  }
  check_reserved_name(ct.name)
  let t = self.build_table(ct, Some(normalize_create_sql(self.cur_sql)))
  t.schema_seq = self.next_seq()
  for idx in t.indexes {
    idx.seq = self.next_seq()
  }
  self.register_table(t)
  if t.autoinc && self.sequence_seq == 0 {
    self.sequence_seq = self.next_seq()
    self.undo.push(UFn(() => self.sequence_seq = 0))
  }
}

///|
/// Builds an automatic index over plain table columns.
fn auto_index(
  table : String,
  columns : Array[TableColumn],
  cols : Array[Int],
  colls : Array[Coll],
  descs : Array[Bool],
  conflict : String?,
  num : Int,
) -> Index {
  {
    name: "sqlite_autoindex_" + table + "_" + num.to_string(),
    table,
    unique: true,
    auto_num: num,
    conflict,
    cols: cols.mapi((k, i) => {
      expr: Column(None, columns[i].name, false),
      collate: None,
      desc: descs[k],
    }),
    where_: None,
    col_idx: cols,
    colls,
    descs,
    keys: cols.map(i => BCol(i, columns[i].affinity, columns[i].coll)),
    pred: None,
    tree: SortedChunks::new(),
    seq: 0,
    sql: None,
  }
}

///|
/// Validates a table definition and builds an empty table (not registered).
fn Database::build_table(
  self : Database,
  ct : CreateTable,
  sql : String?,
) -> Table raise SqlError {
  let seen : Set[String] = Set([])
  let columns = []
  if ct.columns.length() == 0 {
    raise err("no columns")
  }
  for cd in ct.columns {
    if !seen.add_and_check(fold_name(cd.name)) {
      raise err("duplicate column name: " + cd.name)
    }
    columns.push({
      name: cd.name,
      type_name: cd.type_name,
      affinity: affinity_of_type(cd.type_name),
      coll: match cd.collate {
        Some(c) => check_coll(coll_of_name(c))
        None => CBinary
      },
      def: cd,
    })
  }
  let col_index = (n : String) => {
    let f = fold_name(n)
    for i, c in columns {
      if fold_name(c.name) == f {
        return i
      }
    }
    raise err("no such column: " + n)
  }
  let mut pk_count = 0
  let mut ipk = -1
  let mut ipk_conflict : String? = None
  let mut autoinc = false
  let uniques : Array[Index] = []
  let add_unique = (
    cols : Array[Int],
    colls : Array[Coll],
    descs : Array[Bool],
    conflict : String?,
  ) => {
    for u in uniques {
      if u.col_idx == cols && u.colls == colls {
        return
      }
    }
    uniques.push(
      auto_index(
        ct.name,
        columns,
        cols,
        colls,
        descs,
        conflict,
        uniques.length() + 1,
      ),
    )
  }
  let is_integer_type = (i : Int) => {
    columns[i].type_name.to_upper() == "INTEGER"
  }
  for i, cd in ct.columns {
    if cd.primary_key {
      pk_count += 1
      if is_integer_type(i) && !cd.pk_desc {
        ipk = i
        ipk_conflict = cd.pk_conflict
        autoinc = cd.autoincrement
      } else {
        if cd.autoincrement {
          raise err("AUTOINCREMENT is only allowed on an INTEGER PRIMARY KEY")
        }
        add_unique([i], [columns[i].coll], [cd.pk_desc], cd.pk_conflict)
      }
    }
    if cd.unique {
      add_unique([i], [columns[i].coll], [false], cd.unique_conflict)
    }
  }
  let key_colls = (idx : Array[Int], cols : Array[(String, String?, Bool)]) => {
    let out = []
    for k, c in cols {
      out.push(
        match c.1 {
          Some(n) => check_coll(coll_of_name(n))
          None => columns[idx[k]].coll
        },
      )
    }
    out
  }
  for tc in ct.constraints {
    match tc {
      PrimaryKey(cols, conflict) => {
        pk_count += 1
        let idx = cols.map(c => col_index(c.0))
        if idx.length() == 1 && is_integer_type(idx[0]) {
          ipk = idx[0]
          ipk_conflict = conflict
        } else {
          add_unique(idx, key_colls(idx, cols), cols.map(c => c.2), conflict)
        }
      }
      Unique(cols, conflict) => {
        let idx = cols.map(c => col_index(c.0))
        add_unique(idx, key_colls(idx, cols), cols.map(c => c.2), conflict)
      }
      Check(_) | ForeignKey(_, _, _) => ()
    }
  }
  if pk_count > 1 {
    raise err("table \"" + ct.name + "\" has more than one primary key")
  }
  let indexes = uniques.copy()
  // SQLite checks unique indexes in reverse order of creation.
  uniques.rev_in_place()
  let st = ScopeTable::new(ct.name, columns, 0, columns.length())
  let scope = Scope::new([st], columns.length() + 1)
  let checks = []
  for cd in ct.columns {
    for e in cd.checks {
      checks.push((cd.name, bind_expr(self, scope, e)))
    }
  }
  for tc in ct.constraints {
    if tc is Check(e) {
      checks.push(("", bind_expr(self, scope, e)))
    }
  }
  let defaults = []
  for cd in ct.columns {
    match cd.default {
      Some(e) => {
        if !is_constant_expr(e) {
          raise err("default value of column [" + cd.name + "] is not constant")
        }
        defaults.push(Some(bind_expr(self, Scope::empty(), e)))
      }
      None => defaults.push(None)
    }
  }
  {
    name: ct.name,
    columns,
    def: ct,
    rows: SortedChunks::new(),
    max_rowid: 0L,
    max_dirty: false,
    ipk,
    ipk_conflict,
    autoinc,
    seq: 0L,
    uniques,
    indexes,
    checks,
    defaults,
    version: 0,
    schema_seq: 0,
    sql,
  }
}
