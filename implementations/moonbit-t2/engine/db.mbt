///|
pub(all) struct Column {
  name : String
  decl_type : String
  aff : Affinity
  coll : String?
  def : ColumnDef
}

///|
/// An index over a table: explicit (CREATE INDEX) or automatic (UNIQUE and
/// non-rowid PRIMARY KEY constraints). Entries are the key values followed
/// by the rowid, ordered by the key parts' collations and directions.
pub(all) struct Index {
  name : String
  unique : Bool
  /// 0 = CREATE INDEX, 1 = UNIQUE constraint, 2 = PRIMARY KEY.
  origin : Int
  conflict : Conflict
  /// Unbound definition, kept for re-binding after ALTER TABLE.
  parts : Array[IndexPart]
  where_src : Expr?
  sql : String?
  seq : Int
  /// Bound key parts: column index (or -1 for an expression), expression
  /// over the table row (column values then rowid), collation, direction
  /// and affinity.
  cols : Array[Int]
  exprs : Array[Expr]
  colls : Array[String]
  descs : Array[Bool]
  affs : Array[Affinity]
  where_ : Expr?
  /// Root page in the database file (0 when not loaded from a file).
  mut rootpage : Int
  /// Entry values are the rows themselves (row arrays are never mutated).
  mut entries : OrdMap[Array[Value], Array[Value]]
}

///|
pub(all) struct CheckCons {
  expr : Expr // bound against the table's own row
  label : String
  def : CheckDef
}

///|
pub(all) struct Table {
  mut name : String
  mut columns : Array[Column]
  mut rows : OrdMap[Int64, Array[Value]]
  /// Index of the INTEGER PRIMARY KEY column (rowid alias), or -1.
  mut ipk : Int
  ipk_conflict : Conflict
  autoinc : Bool
  mut seq : Int64
  mut indexes : Array[Index]
  mut checks : Array[CheckCons]
  /// Position in sqlite_schema.
  schema_seq : Int
  /// Root page in the database file (0 when not loaded from a file).
  mut rootpage : Int
  /// Changes whenever the rows change (for caches of transient indexes).
  mut version : Int
  mut sql : String
}

///|
pub(all) struct View {
  name : String
  cols : Array[String]?
  query : Select
  sql : String
  schema_seq : Int
}

///|
priv struct TableSnap {
  t : Table
  name : String
  columns : Array[Column]
  rows : OrdMap[Int64, Array[Value]]
  ipk : Int
  seq : Int64
  indexes : Array[Index]
  entries : Array[OrdMap[Array[Value], Array[Value]]]
  checks : Array[CheckCons]
  sql : String
}

///|
priv struct DbSnap {
  tables : Array[(String, Table)]
  views : Array[(String, View)]
  tsnaps : Array[TableSnap]
  sequence_seq : Int
}

///|
pub(all) struct Database {
  mut tables : Map[String, Table]
  mut views : Map[String, View]
  /// Set when a FAIL conflict aborts a statement: its changes are kept.
  mut keep_on_error : Bool
  /// Set when a ROLLBACK conflict aborts a statement: the whole transaction
  /// is rolled back.
  mut rollback_txn : Bool
  /// Rows changed by the current statement.
  mut stmt_changes : Int64
  /// The current DML statement got past preparation.
  mut exec_started : Bool
  mut in_txn : Bool
  /// Schema position of sqlite_sequence (0 until an AUTOINCREMENT table
  /// is created).
  mut sequence_seq : Int
  /// Root page of sqlite_sequence in the database file.
  mut sequence_root : Int
  /// The transaction was opened by SAVEPOINT (RELEASE of the outermost
  /// savepoint commits it).
  mut txn_by_savepoint : Bool
  priv mut txn_snap : DbSnap?
  /// Header of the database file this database was loaded from.
  mut file_header : Bytes?
  /// Schema rows as loaded from the file (to detect schema changes).
  mut file_schema_sig : String
  /// A statement that may modify the database has run.
  mut dirty : Bool
  /// The database file could not be read; it is never written.
  mut load_failed : Bool
  priv savepoints : Array[(String, DbSnap)]
}

///|
priv struct ConnState {
  mut last_rowid : Int64
  mut changes : Int64
  mut total_changes : Int64
}

///|
let conn : ConnState = { last_rowid: 0L, changes: 0L, total_changes: 0L, }

///|
let counters : Array[Int] = [0, 0] // schema sequence, row version

///|
fn next_schema_seq() -> Int {
  counters[0] += 1
  counters[0]
}

///|
fn next_version() -> Int {
  counters[1] += 1
  counters[1]
}

///|
pub fn Database::new() -> Database {
  {
    tables: Map([]),
    views: Map([]),
    keep_on_error: false,
    rollback_txn: false,
    stmt_changes: 0L,
    exec_started: false,
    in_txn: false,
    sequence_seq: 0,
    sequence_root: 0,
    txn_by_savepoint: false,
    txn_snap: None,
    file_header: None,
    file_schema_sig: "",
    dirty: false,
    load_failed: false,
    savepoints: [],
  }
}

///|
pub fn name_key(s : String) -> String {
  s.to_lower()
}

///|
pub fn Database::find_table(self : Database, name : String) -> Table? {
  self.tables.get(name_key(name))
}

///|
pub fn Table::find_column(self : Table, name : String) -> Int? {
  for i, c in self.columns {
    if c.name.equal_ignore_ascii_case(name) {
      return Some(i)
    }
  }
  None
}

///|
fn int64_cmp(a : Int64, b : Int64) -> Int {
  if a < b {
    -1
  } else if a > b {
    1
  } else {
    0
  }
}

///|
fn new_rows() -> OrdMap[Int64, Array[Value]] {
  OrdMap::new(int64_cmp)
}

// ---------------------------------------------------------------------------
// Unique keys
// ---------------------------------------------------------------------------

///|
/// Canonical text of a value for equality under a collation; numerically
/// equal INTEGER and REAL values get the same key.
fn value_key(sb : StringBuilder, v : Value, coll : String) -> Unit {
  match v {
    Null => sb.write_string("N")
    Int(i) => sb.write_string("I\{i}")
    Real(d) =>
      match real_to_int_exact(d) {
        Some(i) => sb.write_string("I\{i}")
        None => sb.write_string("R\{d.reinterpret_as_uint64()}")
      }
    Text(s) => {
      let t = match coll {
        "NOCASE" => {
          let b = StringBuilder()
          for c in s {
            b.write_char(lower_ascii_char(c))
          }
          b.to_string()
        }
        "RTRIM" => rtrim_spaces(s).to_owned()
        _ => s
      }
      sb.write_string("T\{t.length()}:")
      sb.write_string(t)
    }
    Blob(b) => sb.write_string("B" + blob_to_hex(b))
  }
  sb.write_char('|')
}
