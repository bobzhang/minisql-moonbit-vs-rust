///|
struct Parser {
  toks : Array[Token]
  src : String
  mut pos : Int
}

///|
let reserved_words : Set[String] = Set([
  "ADD", "ALL", "ALTER", "AND", "AS", "AUTOINCREMENT", "BETWEEN", "CASE", "CHECK",
  "COLLATE", "COMMIT", "CONSTRAINT", "CREATE", "CROSS", "DEFAULT", "DEFERRABLE",
  "DELETE", "DISTINCT", "DROP", "ELSE", "ESCAPE", "EXCEPT", "EXISTS", "FILTER", "FOREIGN",
  "FROM", "FULL", "GLOB", "GROUP", "HAVING", "IN", "INDEX", "INNER", "INSERT", "INTERSECT",
  "INTO", "IS", "ISNULL", "JOIN", "LEFT", "LIKE", "LIMIT", "MATCH", "NATURAL", "NOT",
  "NOTNULL", "NULL", "ON", "OR", "ORDER", "OUTER", "OVER", "PRIMARY", "REFERENCES",
  "REGEXP", "RETURNING", "RIGHT", "ROLLBACK", "SELECT", "SET", "TABLE", "THEN", "TO",
  "TRANSACTION", "UNION", "UNIQUE", "UPDATE", "USING", "VALUES", "WHEN", "WHERE",
  "WINDOW", "WITH", "OFFSET", "ASC", "DESC", "NULLS", "END",
])

///|
/// Words that cannot be used as bare column/table names.
let non_name_words : Set[String] = Set([
  "ADD", "ALL", "ALTER", "AND", "AS", "AUTOINCREMENT", "BETWEEN", "CASE", "CHECK",
  "COLLATE", "COMMIT", "CONSTRAINT", "CREATE", "DEFAULT", "DEFERRABLE", "DELETE",
  "DISTINCT", "DROP", "ELSE", "ESCAPE", "EXCEPT", "EXISTS", "FOREIGN", "FROM", "GROUP",
  "HAVING", "IN", "INDEX", "INSERT", "INTERSECT", "INTO", "IS", "ISNULL", "JOIN",
  "LIMIT", "NOT", "NOTNULL", "NULL", "ON", "OR", "ORDER", "PRIMARY", "REFERENCES",
  "RETURNING", "SELECT", "SET", "TABLE", "THEN", "TO", "TRANSACTION", "UNION", "UNIQUE",
  "UPDATE", "USING", "VALUES", "WHEN", "WHERE",
])

///|
pub fn parse_statement(sql : String) -> Stmt raise SqlError {
  let p = { toks: tokenize(sql), src: sql, pos: 0, }
  let st = p.statement()
  p.eat_op(";") |> ignore
  if !(p.peek() is Eof) {
    raise p.syntax_error()
  }
  st
}

///|
fn Parser::peek(self : Parser) -> Tok {
  self.toks[self.pos].tok
}

///|
fn Parser::peek_at(self : Parser, k : Int) -> Tok {
  let i = self.pos + k
  if i < self.toks.length() {
    self.toks[i].tok
  } else {
    Eof
  }
}

///|
fn Parser::advance(self : Parser) -> Tok {
  let t = self.toks[self.pos].tok
  if !(t is Eof) {
    self.pos += 1
  }
  t
}

///|
fn Parser::syntax_error(self : Parser) -> SqlError {
  let t = self.toks[self.pos]
  match t.tok {
    Eof => err("incomplete input")
    _ => {
      let end = if self.pos + 1 < self.toks.length() {
        self.toks[self.pos + 1].pos
      } else {
        self.src.length()
      }
      let text = self.src[t.pos:end].to_owned().trim_end().to_owned()
      err("near \"" + text + "\": syntax error")
    }
  }
}

///|
fn tok_is_kw(t : Tok, kw : String) -> Bool {
  match t {
    Word(w) => w.length() == kw.length() && w.to_upper() == kw
    _ => false
  }
}

///|
fn Parser::is_kw(self : Parser, kw : String) -> Bool {
  tok_is_kw(self.peek(), kw)
}

///|
fn Parser::is_kw_at(self : Parser, k : Int, kw : String) -> Bool {
  tok_is_kw(self.peek_at(k), kw)
}

///|
fn Parser::eat_kw(self : Parser, kw : String) -> Bool {
  if self.is_kw(kw) {
    self.pos += 1
    true
  } else {
    false
  }
}

///|
fn Parser::expect_kw(self : Parser, kw : String) -> Unit raise SqlError {
  if !self.eat_kw(kw) {
    raise self.syntax_error()
  }
}

///|
fn Parser::is_op(self : Parser, op : String) -> Bool {
  self.peek() is Op(o) && o == op
}

///|
fn Parser::eat_op(self : Parser, op : String) -> Bool {
  if self.is_op(op) {
    self.pos += 1
    true
  } else {
    false
  }
}

///|
fn Parser::expect_op(self : Parser, op : String) -> Unit raise SqlError {
  if !self.eat_op(op) {
    raise self.syntax_error()
  }
}

///|
/// Parses an identifier (bare word that is not a reserved keyword, or a
/// quoted identifier).
fn Parser::name(self : Parser) -> String raise SqlError {
  match self.peek() {
    Word(w) if !non_name_words.contains(w.to_upper()) => {
      self.pos += 1
      w
    }
    DqIdent(s) | QIdent(s) => {
      self.pos += 1
      s
    }
    Str(s) => {
      self.pos += 1
      s
    }
    _ => raise self.syntax_error()
  }
}

///|
/// Possibly-qualified object name (schema.name); the schema is ignored.
fn Parser::qualified_name(self : Parser) -> String raise SqlError {
  let n = self.name()
  if self.eat_op(".") {
    self.name()
  } else {
    n
  }
}

///|
/// An alias after an expression or table (without AS).
fn Parser::opt_alias(self : Parser) -> String? raise SqlError {
  if self.eat_kw("AS") {
    return Some(self.name())
  }
  match self.peek() {
    Word(w) if !reserved_words.contains(w.to_upper()) => {
      self.pos += 1
      Some(w)
    }
    DqIdent(s) | QIdent(s) | Str(s) => {
      self.pos += 1
      Some(s)
    }
    _ => None
  }
}

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

///|
fn Parser::statement(self : Parser) -> Stmt raise SqlError {
  if self.is_kw("CREATE") {
    self.create()
  } else if self.is_kw("DROP") {
    self.drop()
  } else if self.is_kw("INSERT") || self.is_kw("REPLACE") {
    InsertStmt(self.insert())
  } else if self.is_kw("UPDATE") {
    UpdateStmt(self.update())
  } else if self.is_kw("DELETE") {
    DeleteStmt(self.delete())
  } else if self.is_kw("WITH") {
    let (with_, recursive) = self.with_clause()
    if self.is_kw("INSERT") ||
      self.is_kw("REPLACE") ||
      self.is_kw("UPDATE") ||
      self.is_kw("DELETE") {
      WithStmt(with_, self.statement())
    } else {
      SelectStmt(self.select_body(with_, recursive))
    }
  } else if self.is_kw("SELECT") || self.is_kw("VALUES") {
    SelectStmt(self.select())
  } else if self.eat_kw("ALTER") {
    self.alter()
  } else if self.eat_kw("BEGIN") {
    if !self.eat_kw("DEFERRED") && !self.eat_kw("IMMEDIATE") {
      let _ = self.eat_kw("EXCLUSIVE")
    }
    let _ = self.eat_kw("TRANSACTION")
    BeginStmt
  } else if self.eat_kw("COMMIT") || self.eat_kw("END") {
    let _ = self.eat_kw("TRANSACTION")
    CommitStmt
  } else if self.eat_kw("ROLLBACK") {
    let _ = self.eat_kw("TRANSACTION")
    if self.eat_kw("TO") {
      let _ = self.eat_kw("SAVEPOINT")
      RollbackStmt(Some(self.name()))
    } else {
      RollbackStmt(None)
    }
  } else if self.eat_kw("SAVEPOINT") {
    SavepointStmt(self.name())
  } else if self.eat_kw("RELEASE") {
    let _ = self.eat_kw("SAVEPOINT")
    ReleaseStmt(self.name())
  } else {
    raise self.syntax_error()
  }
}

///|
fn Parser::if_not_exists(self : Parser) -> Bool raise SqlError {
  if self.eat_kw("IF") {
    self.expect_kw("NOT")
    self.expect_kw("EXISTS")
    true
  } else {
    false
  }
}

///|
fn Parser::if_exists(self : Parser) -> Bool raise SqlError {
  if self.eat_kw("IF") {
    self.expect_kw("EXISTS")
    true
  } else {
    false
  }
}

///|
fn Parser::alter(self : Parser) -> Stmt raise SqlError {
  self.expect_kw("TABLE")
  let table = self.qualified_name()
  if self.eat_kw("RENAME") {
    if self.eat_kw("TO") {
      return AlterStmt(table, RenameTable(self.name()))
    }
    if self.is_kw("COLUMN") && !self.is_kw_at(1, "TO") {
      self.pos += 1
    }
    let old = self.name()
    self.expect_kw("TO")
    AlterStmt(table, RenameColumn(old, self.name()))
  } else if self.eat_kw("ADD") {
    if self.is_kw("COLUMN") && !self.is_kw_at(1, "TO") {
      self.pos += 1
    }
    AlterStmt(table, AddColumn(self.column_def()))
  } else if self.eat_kw("DROP") {
    if self.is_kw("COLUMN") && !(self.peek_at(1) is Eof) {
      self.pos += 1
    }
    AlterStmt(table, DropColumn(self.name()))
  } else {
    raise self.syntax_error()
  }
}

///|
fn Parser::create_index(self : Parser, unique : Bool) -> Stmt raise SqlError {
  let if_not_exists = self.if_not_exists()
  let name = self.qualified_name()
  self.expect_kw("ON")
  let table = self.name()
  self.expect_op("(")
  let cols = []
  while true {
    let mut e = self.expr()
    let mut collate : String? = None
    if e is Collate(inner, c) {
      e = inner
      collate = Some(c)
    }
    let desc = if self.eat_kw("DESC") {
      true
    } else {
      let _ = self.eat_kw("ASC")
      false
    }
    cols.push({ expr: e, collate, desc, })
    if !self.eat_op(",") {
      break
    }
  }
  self.expect_op(")")
  let where_ = if self.eat_kw("WHERE") { Some(self.expr()) } else { None }
  CreateIndexStmt({ name, table, unique, if_not_exists, cols, where_, })
}

///|
fn Parser::create(self : Parser) -> Stmt raise SqlError {
  self.expect_kw("CREATE")
  let temp = self.eat_kw("TEMP") || self.eat_kw("TEMPORARY")
  if self.eat_kw("UNIQUE") {
    self.expect_kw("INDEX")
    return self.create_index(true)
  }
  if self.eat_kw("INDEX") {
    return self.create_index(false)
  }
  if self.eat_kw("VIEW") {
    let if_not_exists = self.if_not_exists()
    let name = self.qualified_name()
    let columns = if self.is_op("(") { self.name_list() } else { [] }
    self.expect_kw("AS")
    let select = self.select()
    return CreateViewStmt({ name, if_not_exists, temp, columns, select, })
  }
  if self.eat_kw("TABLE") {
    let mut if_not_exists = false
    if self.eat_kw("IF") {
      self.expect_kw("NOT")
      self.expect_kw("EXISTS")
      if_not_exists = true
    }
    let name = self.qualified_name()
    self.expect_op("(")
    let columns : Array[ColumnDef] = []
    let constraints : Array[TableConstraint] = []
    while true {
      if self.is_kw("CONSTRAINT") ||
        self.is_kw("PRIMARY") ||
        self.is_kw("UNIQUE") ||
        self.is_kw("CHECK") ||
        self.is_kw("FOREIGN") {
        if columns.length() == 0 {
          raise self.syntax_error()
        }
        constraints.push(self.table_constraint())
      } else {
        if constraints.length() > 0 {
          raise self.syntax_error()
        }
        columns.push(self.column_def())
      }
      if !self.eat_op(",") {
        break
      }
    }
    self.expect_op(")")
    // table options
    while self.is_kw("WITHOUT") || self.is_kw("STRICT") {
      if self.eat_kw("WITHOUT") {
        let _ = self.name()
      } else {
        self.pos += 1
      }
      if !self.eat_op(",") {
        break
      }
    }
    CreateTableStmt({ name, if_not_exists, temp, columns, constraints, })
  } else {
    raise self.syntax_error()
  }
}

///|
let constraint_start_words : Set[String] = Set([
  "CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT", "COLLATE",
  "REFERENCES", "GENERATED", "AS",
])

///|
fn Parser::signed_number_text(self : Parser) -> String raise SqlError {
  let mut sign = ""
  if self.eat_op("-") {
    sign = "-"
  } else if self.eat_op("+") {
    sign = "+"
  }
  match self.peek() {
    Num(n) => {
      self.pos += 1
      sign + n
    }
    _ => raise self.syntax_error()
  }
}

///|
fn Parser::type_name(self : Parser) -> String raise SqlError {
  let words : Array[String] = []
  while true {
    match self.peek() {
      Word(w) if !constraint_start_words.contains(w.to_upper()) => {
        self.pos += 1
        words.push(w)
      }
      DqIdent(s) | QIdent(s) | Str(s) => {
        self.pos += 1
        words.push(s)
      }
      _ => break
    }
  }
  let mut t = words.join(" ")
  if words.length() > 0 && self.eat_op("(") {
    let a = self.signed_number_text()
    if self.eat_op(",") {
      let b = self.signed_number_text()
      t = t + "(" + a + "," + b + ")"
    } else {
      t = t + "(" + a + ")"
    }
    self.expect_op(")")
  }
  t
}

///|
fn Parser::conflict_clause(self : Parser) -> String? raise SqlError {
  if self.is_kw("ON") && self.is_kw_at(1, "CONFLICT") {
    self.pos += 2
    match self.peek() {
      Word(w) => {
        let u = w.to_upper()
        if u == "ROLLBACK" ||
          u == "ABORT" ||
          u == "FAIL" ||
          u == "IGNORE" ||
          u == "REPLACE" {
          self.pos += 1
          return Some(u)
        }
        raise self.syntax_error()
      }
      _ => raise self.syntax_error()
    }
  }
  None
}

///|
fn Parser::column_def(self : Parser) -> ColumnDef raise SqlError {
  let name = self.name()
  let type_name = self.type_name()
  let col : ColumnDef = {
    name,
    type_name,
    primary_key: false,
    pk_desc: false,
    autoincrement: false,
    not_null: false,
    unique: false,
    default: None,
    checks: [],
    collate: None,
    pk_conflict: None,
    nn_conflict: None,
    unique_conflict: None,
  }
  while true {
    if self.eat_kw("CONSTRAINT") {
      let _ = self.name()
      continue
    }
    if self.eat_kw("PRIMARY") {
      self.expect_kw("KEY")
      col.primary_key = true
      if self.eat_kw("DESC") {
        col.pk_desc = true
      } else {
        let _ = self.eat_kw("ASC")
      }
      col.pk_conflict = self.conflict_clause()
      if self.eat_kw("AUTOINCREMENT") {
        col.autoincrement = true
      }
    } else if self.eat_kw("NOT") {
      self.expect_kw("NULL")
      col.not_null = true
      col.nn_conflict = self.conflict_clause()
    } else if self.eat_kw("NULL") {
      let _ = self.conflict_clause()
    } else if self.eat_kw("UNIQUE") {
      col.unique = true
      col.unique_conflict = self.conflict_clause()
    } else if self.eat_kw("CHECK") {
      self.expect_op("(")
      col.checks.push(self.expr())
      self.expect_op(")")
    } else if self.eat_kw("DEFAULT") {
      if self.eat_op("(") {
        col.default = Some(self.expr())
        self.expect_op(")")
      } else if self.is_op("-") || self.is_op("+") {
        let neg = self.is_op("-")
        self.pos += 1
        let e = self.primary()
        col.default = Some(if neg { Unary(Neg, e) } else { e })
      } else {
        match self.peek() {
          Num(_) | Str(_) | BlobLit(_) => col.default = Some(self.primary())
          Word(w) => {
            self.pos += 1
            let u = w.to_upper()
            col.default = Some(
              if u == "NULL" {
                Lit(Null)
              } else if u == "TRUE" {
                Lit(Int(1L))
              } else if u == "FALSE" {
                Lit(Int(0L))
              } else if u == "CURRENT_TIME" ||
                u == "CURRENT_DATE" ||
                u == "CURRENT_TIMESTAMP" {
                Func({
                  name: u,
                  args: [],
                  distinct: false,
                  star: false,
                  filter: None,
                  order_by: [],
                  over: None,
                })
              } else {
                Lit(Text(w))
              },
            )
          }
          DqIdent(s) | QIdent(s) => {
            self.pos += 1
            col.default = Some(Lit(Text(s)))
          }
          _ => raise self.syntax_error()
        }
      }
    } else if self.eat_kw("COLLATE") {
      col.collate = Some(self.name())
    } else if self.is_kw("REFERENCES") {
      self.foreign_key_clause() |> ignore
    } else if self.is_kw("GENERATED") || self.is_kw("AS") {
      if self.eat_kw("GENERATED") {
        self.expect_kw("ALWAYS")
      }
      self.expect_kw("AS")
      self.expect_op("(")
      let _ = self.expr()
      self.expect_op(")")
      if !self.eat_kw("STORED") {
        let _ = self.eat_kw("VIRTUAL")
      }
    } else {
      break
    }
  }
  col
}

///|
fn Parser::name_list(self : Parser) -> Array[String] raise SqlError {
  self.expect_op("(")
  let names = [self.name()]
  while self.eat_op(",") {
    names.push(self.name())
  }
  self.expect_op(")")
  names
}

///|
fn Parser::foreign_key_clause(
  self : Parser,
) -> (String, Array[String]) raise SqlError {
  self.expect_kw("REFERENCES")
  let table = self.name()
  let cols = if self.is_op("(") { self.name_list() } else { [] }
  while true {
    if self.eat_kw("ON") {
      if !self.eat_kw("DELETE") {
        self.expect_kw("UPDATE")
      }
      if self.eat_kw("SET") {
        if !self.eat_kw("NULL") {
          self.expect_kw("DEFAULT")
        }
      } else if self.eat_kw("CASCADE") || self.eat_kw("RESTRICT") {
        ()
      } else if self.eat_kw("NO") {
        self.expect_kw("ACTION")
      } else {
        raise self.syntax_error()
      }
    } else if self.eat_kw("MATCH") {
      let _ = self.name()
    } else if self.is_kw("NOT") && self.is_kw_at(1, "DEFERRABLE") {
      self.pos += 2
      self.deferrable_tail()
    } else if self.eat_kw("DEFERRABLE") {
      self.deferrable_tail()
    } else {
      break
    }
  }
  (table, cols)
}

///|
fn Parser::deferrable_tail(self : Parser) -> Unit raise SqlError {
  if self.eat_kw("INITIALLY") {
    if !self.eat_kw("DEFERRED") {
      self.expect_kw("IMMEDIATE")
    }
  }
}

///|
fn Parser::indexed_columns(
  self : Parser,
) -> Array[(String, String?, Bool)] raise SqlError {
  self.expect_op("(")
  let cols = []
  while true {
    let n = self.name()
    let coll = if self.eat_kw("COLLATE") { Some(self.name()) } else { None }
    let desc = if self.eat_kw("DESC") {
      true
    } else {
      let _ = self.eat_kw("ASC")
      false
    }
    cols.push((n, coll, desc))
    if !self.eat_op(",") {
      break
    }
  }
  self.expect_op(")")
  cols
}

///|
fn Parser::table_constraint(self : Parser) -> TableConstraint raise SqlError {
  if self.eat_kw("CONSTRAINT") {
    let _ = self.name()
  }
  if self.eat_kw("PRIMARY") {
    self.expect_kw("KEY")
    let cols = self.indexed_columns()
    let _ = self.eat_kw("AUTOINCREMENT")
    PrimaryKey(cols, self.conflict_clause())
  } else if self.eat_kw("UNIQUE") {
    let cols = self.indexed_columns()
    Unique(cols, self.conflict_clause())
  } else if self.eat_kw("CHECK") {
    self.expect_op("(")
    let e = self.expr()
    self.expect_op(")")
    Check(e)
  } else if self.eat_kw("FOREIGN") {
    self.expect_kw("KEY")
    let cols = self.name_list()
    let (t, rcols) = self.foreign_key_clause()
    ForeignKey(cols, t, rcols)
  } else {
    raise self.syntax_error()
  }
}

///|
fn Parser::drop(self : Parser) -> Stmt raise SqlError {
  self.expect_kw("DROP")
  if self.eat_kw("TABLE") {
    let mut if_exists = false
    if self.eat_kw("IF") {
      self.expect_kw("EXISTS")
      if_exists = true
    }
    DropTableStmt(self.qualified_name(), if_exists)
  } else if self.eat_kw("INDEX") {
    let if_exists = self.if_exists()
    DropIndexStmt(self.qualified_name(), if_exists)
  } else if self.eat_kw("VIEW") {
    let if_exists = self.if_exists()
    DropViewStmt(self.qualified_name(), if_exists)
  } else {
    raise self.syntax_error()
  }
}

///|
fn Parser::insert(self : Parser) -> Insert raise SqlError {
  let mut or_action : String? = None
  if self.eat_kw("REPLACE") {
    or_action = Some("REPLACE")
  } else {
    self.expect_kw("INSERT")
    or_action = self.or_clause()
  }
  self.expect_kw("INTO")
  let table = self.qualified_name()
  let alias = if self.eat_kw("AS") { Some(self.name()) } else { None }
  let columns = if self.is_op("(") { Some(self.name_list()) } else { None }
  let source = if self.eat_kw("DEFAULT") {
    self.expect_kw("VALUES")
    InsDefault
  } else if self.is_kw("VALUES") && !self.values_followed_by_compound() {
    self.pos += 1
    InsValues(self.values_rows())
  } else if self.is_kw("SELECT") || self.is_kw("WITH") || self.is_kw("VALUES") {
    InsSelect(self.select())
  } else {
    raise self.syntax_error()
  }
  let upserts = []
  while self.is_kw("ON") && self.is_kw_at(1, "CONFLICT") {
    if source is InsDefault {
      raise self.syntax_error()
    }
    self.pos += 2
    let mut target : Array[String]? = None
    let mut target_where : Expr? = None
    if self.eat_op("(") {
      let cols = []
      while true {
        let e = self.expr()
        match e {
          Column(None, n, _) => cols.push(n)
          Collate(Column(None, n, _), _) => cols.push(n)
          _ => raise err("unsupported ON CONFLICT target")
        }
        if self.eat_kw("COLLATE") {
          let _ = self.name()
        }
        if !self.eat_kw("ASC") {
          let _ = self.eat_kw("DESC")
        }
        if !self.eat_op(",") {
          break
        }
      }
      self.expect_op(")")
      target = Some(cols)
      if self.eat_kw("WHERE") {
        target_where = Some(self.expr())
      }
    }
    self.expect_kw("DO")
    let action = if self.eat_kw("NOTHING") {
      DoNothing
    } else {
      self.expect_kw("UPDATE")
      self.expect_kw("SET")
      let sets = self.set_list()
      let w = if self.eat_kw("WHERE") { Some(self.expr()) } else { None }
      DoUpdate(sets, w)
    }
    upserts.push({ target, target_where, action, })
  }
  let returning = self.returning_clause()
  { table, alias, columns, source, or_action, upserts, returning, }
}

///|
fn Parser::or_clause(self : Parser) -> String? raise SqlError {
  if !self.eat_kw("OR") {
    return None
  }
  match self.advance() {
    Word(w) => {
      let u = w.to_upper()
      if u == "REPLACE" ||
        u == "IGNORE" ||
        u == "ABORT" ||
        u == "FAIL" ||
        u == "ROLLBACK" {
        Some(u)
      } else {
        self.pos -= 1
        raise self.syntax_error()
      }
    }
    _ => {
      self.pos -= 1
      raise self.syntax_error()
    }
  }
}

///|
fn Parser::set_list(self : Parser) -> Array[(String, Expr)] raise SqlError {
  let sets = []
  while true {
    if self.eat_op("(") {
      let names = [self.name()]
      while self.eat_op(",") {
        names.push(self.name())
      }
      self.expect_op(")")
      self.expect_op("=")
      self.expect_op("(")
      let vals = [self.expr()]
      while self.eat_op(",") {
        vals.push(self.expr())
      }
      self.expect_op(")")
      if vals.length() != names.length() {
        raise err("\{names.length()} columns assigned \{vals.length()} values")
      }
      for i, n in names {
        sets.push((n, vals[i]))
      }
    } else {
      let n = self.name()
      self.expect_op("=")
      sets.push((n, self.expr()))
    }
    if !self.eat_op(",") {
      break
    }
  }
  sets
}

///|
fn Parser::returning_clause(self : Parser) -> Array[ResultCol] raise SqlError {
  let cols = []
  if self.eat_kw("RETURNING") {
    cols.push(self.result_col())
    while self.eat_op(",") {
      cols.push(self.result_col())
    }
  }
  cols
}

///|
fn Parser::update(self : Parser) -> Update raise SqlError {
  self.expect_kw("UPDATE")
  let or_action = self.or_clause()
  let table = self.qualified_name()
  let alias = if self.eat_kw("AS") { Some(self.name()) } else { None }
  if self.eat_kw("INDEXED") {
    self.expect_kw("BY")
    let _ = self.name()
  } else if self.is_kw("NOT") && self.is_kw_at(1, "INDEXED") {
    self.pos += 2
  }
  self.expect_kw("SET")
  let sets = self.set_list()
  let where_ = if self.eat_kw("WHERE") { Some(self.expr()) } else { None }
  let returning = self.returning_clause()
  { table, alias, or_action, sets, where_, returning, }
}

///|
fn Parser::delete(self : Parser) -> Delete raise SqlError {
  self.expect_kw("DELETE")
  self.expect_kw("FROM")
  let table = self.qualified_name()
  let alias = if self.eat_kw("AS") { Some(self.name()) } else { None }
  if self.eat_kw("INDEXED") {
    self.expect_kw("BY")
    let _ = self.name()
  } else if self.is_kw("NOT") && self.is_kw_at(1, "INDEXED") {
    self.pos += 2
  }
  let where_ = if self.eat_kw("WHERE") { Some(self.expr()) } else { None }
  let returning = self.returning_clause()
  { table, alias, where_, returning, }
}

///|
/// Looks ahead past a VALUES list to see whether a compound operator,
/// ORDER BY or LIMIT follows (then it is a full SELECT).
fn Parser::values_followed_by_compound(self : Parser) -> Bool {
  let mut depth = 0
  let mut i = self.pos
  while i < self.toks.length() {
    match self.toks[i].tok {
      Op("(") => depth += 1
      Op(")") => depth -= 1
      Eof => return false
      t =>
        if depth == 0 &&
          (
            tok_is_kw(t, "UNION") ||
            tok_is_kw(t, "INTERSECT") ||
            tok_is_kw(t, "EXCEPT") ||
            tok_is_kw(t, "ORDER") ||
            tok_is_kw(t, "LIMIT")
          ) {
          return true
        } else if depth == 0 &&
          (tok_is_kw(t, "ON") || tok_is_kw(t, "RETURNING")) {
          return false
        }
    }
    i += 1
  }
  false
}

///|
fn Parser::values_rows(self : Parser) -> Array[Array[Expr]] raise SqlError {
  let rows : Array[Array[Expr]] = []
  while true {
    self.expect_op("(")
    let row = [self.expr()]
    while self.eat_op(",") {
      row.push(self.expr())
    }
    self.expect_op(")")
    if rows.length() > 0 && rows[0].length() != row.length() {
      raise err("all VALUES must have the same number of terms")
    }
    rows.push(row)
    if !self.eat_op(",") {
      break
    }
  }
  rows
}

// ---------------------------------------------------------------------------
// SELECT
// ---------------------------------------------------------------------------

///|
fn Parser::select(self : Parser) -> Select raise SqlError {
  let (with_, recursive) = self.with_clause()
  self.select_body(with_, recursive)
}

///|
fn Parser::with_clause(self : Parser) -> (Array[Cte], Bool) raise SqlError {
  let with_ : Array[Cte] = []
  let mut recursive = false
  if self.eat_kw("WITH") {
    if self.eat_kw("RECURSIVE") {
      recursive = true
    }
    while true {
      let name = self.name()
      let columns = if self.is_op("(") { self.name_list() } else { [] }
      self.expect_kw("AS")
      let mut materialized : Bool? = None
      if self.eat_kw("NOT") {
        self.expect_kw("MATERIALIZED")
        materialized = Some(false)
      } else if self.eat_kw("MATERIALIZED") {
        materialized = Some(true)
      }
      self.expect_op("(")
      let select = self.select()
      self.expect_op(")")
      with_.push({ name, columns, select, materialized, })
      if !self.eat_op(",") {
        break
      }
    }
  }
  (with_, recursive)
}

///|
fn Parser::select_body(
  self : Parser,
  with_ : Array[Cte],
  recursive : Bool,
) -> Select raise SqlError {
  let first = self.select_core()
  let rest = []
  while true {
    let op = if self.eat_kw("UNION") {
      if self.eat_kw("ALL") {
        UnionAll
      } else {
        Union
      }
    } else if self.eat_kw("INTERSECT") {
      Intersect
    } else if self.eat_kw("EXCEPT") {
      Except
    } else {
      break
    }
    rest.push((op, self.select_core()))
  }
  let last_is_values = match rest.last() {
    Some((_, core)) => core is Values(_)
    None => first is Values(_)
  }
  if last_is_values && (self.is_kw("ORDER") || self.is_kw("LIMIT")) {
    raise self.syntax_error()
  }
  let order_by = if self.is_kw("ORDER") {
    self.pos += 1
    self.expect_kw("BY")
    self.order_terms()
  } else {
    []
  }
  let mut limit : Expr? = None
  let mut offset : Expr? = None
  if self.eat_kw("LIMIT") {
    let a = self.expr()
    if self.eat_kw("OFFSET") {
      limit = Some(a)
      offset = Some(self.expr())
    } else if self.eat_op(",") {
      offset = Some(a)
      limit = Some(self.expr())
    } else {
      limit = Some(a)
    }
  }
  { with_, recursive, first, rest, order_by, limit, offset, }
}

///|
fn Parser::order_terms(self : Parser) -> Array[OrderTerm] raise SqlError {
  let terms = []
  while true {
    let e = self.expr()
    let desc = if self.eat_kw("DESC") {
      true
    } else {
      let _ = self.eat_kw("ASC")
      false
    }
    let mut nulls_first : Bool? = None
    if self.eat_kw("NULLS") {
      if self.eat_kw("FIRST") {
        nulls_first = Some(true)
      } else {
        self.expect_kw("LAST")
        nulls_first = Some(false)
      }
    }
    terms.push({ expr: e, desc, nulls_first, })
    if !self.eat_op(",") {
      break
    }
  }
  terms
}

///|
fn Parser::select_core(self : Parser) -> SelectCore raise SqlError {
  if self.eat_kw("VALUES") {
    return Values(self.values_rows())
  }
  self.expect_kw("SELECT")
  let mut distinct = false
  if self.eat_kw("DISTINCT") {
    distinct = true
  } else {
    let _ = self.eat_kw("ALL")
  }
  let columns = [self.result_col()]
  while self.eat_op(",") {
    columns.push(self.result_col())
  }
  let from = if self.eat_kw("FROM") { Some(self.from_clause()) } else { None }
  let where_ = if self.eat_kw("WHERE") { Some(self.expr()) } else { None }
  let group_by = []
  let mut having : Expr? = None
  if self.is_kw("GROUP") {
    self.pos += 1
    self.expect_kw("BY")
    group_by.push(self.expr())
    while self.eat_op(",") {
      group_by.push(self.expr())
    }
  }
  if self.eat_kw("HAVING") {
    having = Some(self.expr())
  }
  let windows = []
  if self.eat_kw("WINDOW") {
    while true {
      let n = self.name()
      self.expect_kw("AS")
      windows.push((n, self.window_spec()))
      if !self.eat_op(",") {
        break
      }
    }
  }
  Simple({ distinct, columns, from, where_, group_by, having, windows, })
}

///|
fn Parser::result_col(self : Parser) -> ResultCol raise SqlError {
  if self.eat_op("*") {
    return Star
  }
  // table.*
  match (self.peek(), self.peek_at(1), self.peek_at(2)) {
    (Word(n) | DqIdent(n) | QIdent(n), Op("."), Op("*")) => {
      self.pos += 3
      return TableStar(n)
    }
    _ => ()
  }
  let e = self.expr()
  ExprCol(e, self.opt_alias())
}

///|
fn Parser::from_clause(self : Parser) -> FromItem raise SqlError {
  let mut left = self.table_or_subquery()
  while true {
    if self.eat_op(",") {
      let right = self.table_or_subquery()
      left = Join(left, right, Cross, false, None, None)
      continue
    }
    let mut natural = false
    if self.eat_kw("NATURAL") {
      natural = true
    }
    let kind = if self.eat_kw("LEFT") {
      let _ = self.eat_kw("OUTER")
      Some(Left)
    } else if self.eat_kw("RIGHT") {
      let _ = self.eat_kw("OUTER")
      Some(Right)
    } else if self.eat_kw("FULL") {
      let _ = self.eat_kw("OUTER")
      Some(Full)
    } else if self.eat_kw("INNER") {
      Some(Inner)
    } else if self.eat_kw("CROSS") {
      Some(Cross)
    } else {
      None
    }
    if kind is None && !natural && !self.is_kw("JOIN") {
      break
    }
    self.expect_kw("JOIN")
    let right = self.table_or_subquery()
    let mut on : Expr? = None
    let mut using_cols : Array[String]? = None
    if self.eat_kw("ON") {
      on = Some(self.expr())
    } else if self.eat_kw("USING") {
      using_cols = Some(self.name_list())
    }
    left = Join(left, right, kind.unwrap_or(Inner), natural, on, using_cols)
  }
  left
}

///|
fn Parser::table_or_subquery(self : Parser) -> FromItem raise SqlError {
  if self.eat_op("(") {
    if self.is_kw("SELECT") || self.is_kw("VALUES") || self.is_kw("WITH") {
      let s = self.select()
      self.expect_op(")")
      return SubqueryRef(s, self.opt_alias())
    }
    let f = self.from_clause()
    self.expect_op(")")
    return f
  }
  let name = self.qualified_name()
  TableRef(name, self.opt_alias())
}

///|
fn Parser::window_spec(self : Parser) -> WindowSpec raise SqlError {
  self.expect_op("(")
  let mut base : String? = None
  match self.peek() {
    Word(w) if !reserved_words.contains(w.to_upper()) &&
      !(w.to_upper() == "ROWS" ||
      w.to_upper() == "PARTITION" ||
      w.to_upper() == "RANGE" ||
      w.to_upper() == "GROUPS") => {
      self.pos += 1
      base = Some(w)
    }
    _ => ()
  }
  let partition_by = []
  if self.eat_kw("PARTITION") {
    self.expect_kw("BY")
    partition_by.push(self.expr())
    while self.eat_op(",") {
      partition_by.push(self.expr())
    }
  }
  let order_by = if self.is_kw("ORDER") {
    self.pos += 1
    self.expect_kw("BY")
    self.order_terms()
  } else {
    []
  }
  let mut frame : FrameSpec? = None
  if self.is_kw("ROWS") || self.is_kw("RANGE") || self.is_kw("GROUPS") {
    let unit = match self.advance() {
      Word(w) => w.to_upper()
      _ => ""
    }
    let (start, end) = if self.eat_kw("BETWEEN") {
      let s = self.frame_bound()
      self.expect_kw("AND")
      let e = self.frame_bound()
      (s, e)
    } else {
      (self.frame_bound(), CurrentRow)
    }
    let mut exclude = "NO OTHERS"
    if self.eat_kw("EXCLUDE") {
      if self.eat_kw("NO") {
        self.expect_kw("OTHERS")
      } else if self.eat_kw("CURRENT") {
        self.expect_kw("ROW")
        exclude = "CURRENT ROW"
      } else if self.eat_kw("GROUP") {
        exclude = "GROUP"
      } else {
        self.expect_kw("TIES")
        exclude = "TIES"
      }
    }
    frame = Some({ unit, start, end, exclude, })
  }
  self.expect_op(")")
  { base, partition_by, order_by, frame, }
}

///|
fn Parser::frame_bound(self : Parser) -> FrameBound raise SqlError {
  if self.eat_kw("UNBOUNDED") {
    if self.eat_kw("PRECEDING") {
      UnboundedPreceding
    } else {
      self.expect_kw("FOLLOWING")
      UnboundedFollowing
    }
  } else if self.eat_kw("CURRENT") {
    self.expect_kw("ROW")
    CurrentRow
  } else {
    let e = self.expr()
    if self.eat_kw("PRECEDING") {
      Preceding(e)
    } else {
      self.expect_kw("FOLLOWING")
      Following(e)
    }
  }
}

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

///|
pub fn Parser::expr(self : Parser) -> Expr raise SqlError {
  self.or_expr()
}

///|
fn Parser::or_expr(self : Parser) -> Expr raise SqlError {
  let mut e = self.and_expr()
  while self.eat_kw("OR") {
    e = Binary(Or, e, self.and_expr())
  }
  e
}

///|
fn Parser::and_expr(self : Parser) -> Expr raise SqlError {
  let mut e = self.not_expr()
  while self.eat_kw("AND") {
    e = Binary(And, e, self.not_expr())
  }
  e
}

///|
fn Parser::not_expr(self : Parser) -> Expr raise SqlError {
  if self.eat_kw("NOT") {
    Unary(Not, self.not_expr())
  } else {
    self.equality()
  }
}

///|
fn Parser::equality(self : Parser) -> Expr raise SqlError {
  let mut e = self.comparison()
  while true {
    match self.peek() {
      Op("=") | Op("==") => {
        self.pos += 1
        e = Binary(Eq, e, self.comparison())
      }
      Op("!=") | Op("<>") => {
        self.pos += 1
        e = Binary(Ne, e, self.comparison())
      }
      Word(w) => {
        let u = w.to_upper()
        if u == "IS" {
          self.pos += 1
          let neg = self.eat_kw("NOT")
          if self.eat_kw("DISTINCT") {
            self.expect_kw("FROM")
            let r = self.comparison()
            e = Binary(if neg { Is } else { IsNot }, e, r)
          } else {
            let r = self.comparison()
            e = match r {
              Lit(Null) => IsNull(e, neg)
              _ => Binary(if neg { IsNot } else { Is }, e, r)
            }
          }
        } else if u == "ISNULL" {
          self.pos += 1
          e = IsNull(e, false)
        } else if u == "NOTNULL" {
          self.pos += 1
          e = IsNull(e, true)
        } else if u == "NOT" {
          if self.is_kw_at(1, "NULL") {
            self.pos += 2
            e = IsNull(e, true)
          } else if self.is_kw_at(1, "IN") ||
            self.is_kw_at(1, "LIKE") ||
            self.is_kw_at(1, "GLOB") ||
            self.is_kw_at(1, "REGEXP") ||
            self.is_kw_at(1, "MATCH") ||
            self.is_kw_at(1, "BETWEEN") {
            self.pos += 1
            e = self.equality_suffix(e, true)
          } else {
            break
          }
        } else if u == "IN" ||
          u == "LIKE" ||
          u == "GLOB" ||
          u == "REGEXP" ||
          u == "MATCH" ||
          u == "BETWEEN" {
          e = self.equality_suffix(e, false)
        } else {
          break
        }
      }
      _ => break
    }
  }
  e
}

///|
fn Parser::equality_suffix(
  self : Parser,
  e : Expr,
  neg : Bool,
) -> Expr raise SqlError {
  let u = match self.advance() {
    Word(w) => w.to_upper()
    _ => ""
  }
  if u == "BETWEEN" {
    let lo = self.comparison()
    self.expect_kw("AND")
    let hi = self.comparison()
    Between(e, lo, hi, neg)
  } else if u == "IN" {
    if self.eat_op("(") {
      if self.is_kw("SELECT") || self.is_kw("VALUES") || self.is_kw("WITH") {
        let s = self.select()
        self.expect_op(")")
        InSelect(e, s, neg)
      } else if self.eat_op(")") {
        InList(e, [], neg)
      } else {
        let items = [self.expr()]
        while self.eat_op(",") {
          items.push(self.expr())
        }
        self.expect_op(")")
        InList(e, items, neg)
      }
    } else {
      // IN table-name
      let name = self.qualified_name()
      let s : Select = {
        with_: [],
        recursive: false,
        first: Simple({
          distinct: false,
          columns: [Star],
          from: Some(TableRef(name, None)),
          where_: None,
          group_by: [],
          having: None,
          windows: [],
        }),
        rest: [],
        order_by: [],
        limit: None,
        offset: None,
      }
      InSelect(e, s, neg)
    }
  } else {
    let pat = self.comparison()
    let esc = if self.eat_kw("ESCAPE") { Some(self.comparison()) } else { None }
    Like(u, e, pat, esc, neg)
  }
}

///|
fn Parser::comparison(self : Parser) -> Expr raise SqlError {
  let mut e = self.bitwise()
  while true {
    let op = match self.peek() {
      Op("<") => Lt
      Op("<=") => Le
      Op(">") => Gt
      Op(">=") => Ge
      _ => break
    }
    self.pos += 1
    e = Binary(op, e, self.bitwise())
  }
  e
}

///|
fn Parser::bitwise(self : Parser) -> Expr raise SqlError {
  let mut e = self.additive()
  while true {
    let op = match self.peek() {
      Op("&") => BitAnd
      Op("|") => BitOr
      Op("<<") => Shl
      Op(">>") => Shr
      _ => break
    }
    self.pos += 1
    e = Binary(op, e, self.additive())
  }
  e
}

///|
fn Parser::additive(self : Parser) -> Expr raise SqlError {
  let mut e = self.multiplicative()
  while true {
    let op = match self.peek() {
      Op("+") => Add
      Op("-") => Sub
      _ => break
    }
    self.pos += 1
    e = Binary(op, e, self.multiplicative())
  }
  e
}

///|
fn Parser::multiplicative(self : Parser) -> Expr raise SqlError {
  let mut e = self.concat()
  while true {
    let op = match self.peek() {
      Op("*") => Mul
      Op("/") => Div
      Op("%") => Mod
      _ => break
    }
    self.pos += 1
    e = Binary(op, e, self.concat())
  }
  e
}

///|
fn Parser::concat(self : Parser) -> Expr raise SqlError {
  let mut e = self.unary()
  while true {
    match self.peek() {
      Op("||") => {
        self.pos += 1
        e = Binary(Concat, e, self.unary())
      }
      Op("->") | Op("->>") => raise self.syntax_error()
      _ => break
    }
  }
  e
}

///|
fn Parser::unary(self : Parser) -> Expr raise SqlError {
  match self.peek() {
    Op("-") => {
      self.pos += 1
      // -9223372036854775808 is an integer literal
      match self.peek() {
        Num(n) if is_min_int_literal(n) => {
          self.pos += 1
          return self.postfix(Lit(Int(@int64.MIN_VALUE)))
        }
        Num(n) if n.has_prefix("0x") || n.has_prefix("0X") =>
          if number_literal(n) is Int(v) && v == @int64.MIN_VALUE {
            raise err("hex literal too big: -" + n)
          }
        _ => ()
      }
      Unary(Neg, self.unary())
    }
    Op("+") => {
      self.pos += 1
      Unary(Pos, self.unary())
    }
    Op("~") => {
      self.pos += 1
      Unary(BitNot, self.unary())
    }
    _ => self.postfix(self.primary())
  }
}

///|
fn is_min_int_literal(n : String) -> Bool {
  let mut i = 0
  while i < n.length() - 1 && n[i] == '0' {
    i += 1
  }
  n[i:] == "9223372036854775808"
}

///|
fn Parser::postfix(self : Parser, e : Expr) -> Expr raise SqlError {
  let mut e = e
  while self.eat_kw("COLLATE") {
    e = Collate(e, self.name())
  }
  e
}

///|
fn number_literal(n : String) -> Value raise SqlError {
  if n.length() > 2 && n[0] == '0' && (n[1] == 'x' || n[1] == 'X') {
    let digits = n[2:]
    let mut k = 0
    while k < digits.length() - 1 && digits[k] == '0' {
      k += 1
    }
    if digits.length() - k > 16 {
      raise err("hex literal too big: " + n)
    }
    let mut acc : UInt64 = 0UL
    for c in digits {
      acc = (acc << 4) | hex_val(c.to_int()).to_uint64()
    }
    return Int(acc.reinterpret_as_int64())
  }
  if n.contains(".") || n.contains("e") || n.contains("E") {
    return Real(text_to_double(normalize_real_literal(n)))
  }
  match parse_int_digits(false, n) {
    Some(v) => Int(v)
    None => Real(text_to_double(n))
  }
}

///|
fn Parser::primary(self : Parser) -> Expr raise SqlError {
  match self.peek() {
    Num(n) => {
      self.pos += 1
      Lit(number_literal(n))
    }
    Str(s) => {
      self.pos += 1
      Lit(Text(s))
    }
    BlobLit(b) => {
      self.pos += 1
      Lit(Blob(b))
    }
    Param(p) => {
      self.pos += 1
      Param(p)
    }
    Op("(") => {
      self.pos += 1
      if self.is_kw("SELECT") || self.is_kw("VALUES") || self.is_kw("WITH") {
        let s = self.select()
        self.expect_op(")")
        return Subquery(s)
      }
      let e = self.expr()
      if self.is_op(",") {
        raise err("row value misused")
      }
      self.expect_op(")")
      e
    }
    DqIdent(s) | QIdent(s) => {
      let dq = self.peek() is DqIdent(_)
      self.pos += 1
      self.identifier_expr(s, dq)
    }
    Word(w) => {
      let u = w.to_upper()
      if u == "NULL" {
        self.pos += 1
        Lit(Null)
      } else if u == "TRUE" && !self.peek_at(1).is_dot() {
        self.pos += 1
        Lit(Int(1L))
      } else if u == "FALSE" && !self.peek_at(1).is_dot() {
        self.pos += 1
        Lit(Int(0L))
      } else if u == "CASE" {
        self.pos += 1
        self.case_expr()
      } else if u == "CAST" && self.peek_at(1) == Op("(") {
        self.pos += 2
        let e = self.expr()
        self.expect_kw("AS")
        let t = self.type_name()
        self.expect_op(")")
        Cast(e, t)
      } else if u == "EXISTS" && self.peek_at(1) == Op("(") {
        self.pos += 2
        let s = self.select()
        self.expect_op(")")
        Exists(s, false)
      } else if u == "NOT" && self.is_kw_at(1, "EXISTS") {
        self.pos += 3
        self.expect_op("(") |> ignore
        let s = self.select()
        self.expect_op(")")
        Exists(s, true)
      } else if u == "CURRENT_TIME" ||
        u == "CURRENT_DATE" ||
        u == "CURRENT_TIMESTAMP" {
        self.pos += 1
        Func({
          name: u,
          args: [],
          distinct: false,
          star: false,
          filter: None,
          order_by: [],
          over: None,
        })
      } else if u == "RAISE" && self.peek_at(1) == Op("(") {
        raise self.syntax_error()
      } else if non_name_words.contains(u) {
        raise self.syntax_error()
      } else {
        self.pos += 1
        self.identifier_expr(w, false)
      }
    }
    _ => raise self.syntax_error()
  }
}

///|
fn Tok::is_dot(self : Tok) -> Bool {
  self is Op(".")
}

///|
fn Parser::case_expr(self : Parser) -> Expr raise SqlError {
  let base = if self.is_kw("WHEN") { None } else { Some(self.expr()) }
  let whens = []
  while self.eat_kw("WHEN") {
    let c = self.expr()
    self.expect_kw("THEN")
    whens.push((c, self.expr()))
  }
  if whens.length() == 0 {
    raise self.syntax_error()
  }
  let els = if self.eat_kw("ELSE") { Some(self.expr()) } else { None }
  self.expect_kw("END")
  Case(base, whens, els)
}

///|
fn Parser::identifier_expr(
  self : Parser,
  name : String,
  dq : Bool,
) -> Expr raise SqlError {
  if self.is_op("(") {
    self.pos += 1
    return self.func_call(name)
  }
  if self.is_op(".") {
    self.pos += 1
    let col = self.name()
    if self.is_op(".") {
      // schema.table.column
      self.pos += 1
      let c2 = self.name()
      return Column(Some(col), c2, false)
    }
    return Column(Some(name), col, false)
  }
  Column(None, name, dq)
}

///|
fn Parser::func_call(self : Parser, name : String) -> Expr raise SqlError {
  let mut distinct = false
  let mut star = false
  let args = []
  let mut order_by = []
  if self.eat_op("*") {
    star = true
  } else if !self.is_op(")") {
    if self.eat_kw("DISTINCT") {
      distinct = true
    } else {
      let _ = self.eat_kw("ALL")
    }
    args.push(self.expr())
    while self.eat_op(",") {
      args.push(self.expr())
    }
    if self.is_kw("ORDER") {
      self.pos += 1
      self.expect_kw("BY")
      order_by = self.order_terms()
    }
  }
  self.expect_op(")")
  let mut filter : Expr? = None
  if self.eat_kw("FILTER") {
    self.expect_op("(")
    self.expect_kw("WHERE")
    filter = Some(self.expr())
    self.expect_op(")")
  }
  let mut over : WindowSpec? = None
  if self.eat_kw("OVER") {
    if self.is_op("(") {
      over = Some(self.window_spec())
    } else {
      let n = self.name()
      over = Some({
        base: Some(n),
        partition_by: [],
        order_by: [],
        frame: None,
      })
    }
  }
  Func({ name, args, distinct, star, filter, order_by, over, })
}
