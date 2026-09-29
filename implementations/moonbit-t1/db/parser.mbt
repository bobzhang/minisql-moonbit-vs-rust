///|
priv struct Parser {
  toks : Array[Token]
  mut pos : Int
  src : String
}

///|
let reserved_words : Set[String] = Set([
  "ADD", "ALL", "ALTER", "AND", "AS", "AUTOINCREMENT", "BETWEEN", "BY", "CASE", "CHECK",
  "COLLATE", "COMMIT", "CONSTRAINT", "CREATE", "CROSS", "DEFAULT", "DEFERRABLE",
  "DELETE", "DISTINCT", "DROP", "ELSE", "ESCAPE", "EXCEPT", "EXISTS", "FOREIGN",
  "FROM", "FULL", "GROUP", "HAVING", "IN", "INDEX", "INNER", "INSERT", "INTERSECT",
  "INTO", "IS", "ISNULL", "JOIN", "LEFT", "LIMIT", "NATURAL", "NOT", "NOTNULL", "NULL",
  "ON", "OR", "ORDER", "OUTER", "PRIMARY", "REFERENCES", "RETURNING", "RIGHT", "SELECT",
  "SET", "TABLE", "THEN", "TO", "TRANSACTION", "UNION", "UNIQUE", "UPDATE", "USING",
  "VALUES", "WHEN", "WHERE", "WINDOW", "OFFSET", "GLOB", "LIKE", "REGEXP", "MATCH",
  "END", "CAST",
])

///|
fn Parser::peek(self : Parser) -> Token {
  self.toks[self.pos]
}

///|
fn Parser::peek_at(self : Parser, k : Int) -> Token {
  let i = self.pos + k
  if i < self.toks.length() {
    self.toks[i]
  } else {
    self.toks[self.toks.length() - 1]
  }
}

///|
fn Parser::advance(self : Parser) -> Token {
  let t = self.toks[self.pos]
  if t.kind != TEof {
    self.pos += 1
  }
  t
}

///|
fn Parser::error_at(self : Parser, t : Token) -> SqlError {
  ignore(self)
  if t.kind == TEof {
    sql_err("incomplete input")
  } else {
    let txt = match t.kind {
      TString => "'" + t.text + "'"
      TQuoted => "\"" + t.text + "\""
      _ => t.text
    }
    sql_err("near \"\{txt}\": syntax error")
  }
}

///|
fn Parser::fail(self : Parser) -> SqlError {
  self.error_at(self.peek())
}

///|
fn Parser::is_kw(self : Parser, kw : String) -> Bool {
  let t = self.peek()
  t.kind == TIdent && t.upper == kw
}

///|
fn Parser::is_kw_at(self : Parser, k : Int, kw : String) -> Bool {
  let t = self.peek_at(k)
  t.kind == TIdent && t.upper == kw
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
    raise self.fail()
  }
}

///|
fn Parser::is_op(self : Parser, op : String) -> Bool {
  let t = self.peek()
  t.kind == TOp && t.text == op
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
    raise self.fail()
  }
}

///|
/// An identifier: unquoted non-reserved word, or any quoted identifier.
fn Parser::parse_name(self : Parser) -> String raise SqlError {
  let t = self.peek()
  match t.kind {
    TIdent if !reserved_words.contains(t.upper) => {
      self.pos += 1
      t.text
    }
    TQuoted | TBracket => {
      self.pos += 1
      t.text
    }
    TString => {
      self.pos += 1
      t.text
    }
    _ => raise self.fail()
  }
}

///|
fn Parser::at_name(self : Parser) -> Bool {
  let t = self.peek()
  match t.kind {
    TIdent => !reserved_words.contains(t.upper)
    TQuoted | TBracket => true
    _ => false
  }
}

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

///|
fn parse_statement(sql : String) -> Stmt raise SqlError {
  let toks = tokenize(sql)
  let p : Parser = { toks, pos: 0, src: sql, }
  let st = p.parse_stmt()
  if p.peek().kind != TEof {
    raise p.fail()
  }
  st
}

///|
fn Parser::parse_stmt(self : Parser) -> Stmt raise SqlError {
  if self.is_kw("WITH") {
    let ctes = self.parse_with()
    if self.is_kw("SELECT") || self.is_kw("VALUES") {
      SelectStmt(QWith(ctes~, body=self.parse_query()))
    } else if self.is_kw("INSERT") ||
      self.is_kw("REPLACE") ||
      self.is_kw("UPDATE") ||
      self.is_kw("DELETE") {
      WithDml(ctes, self.parse_stmt())
    } else {
      raise self.fail()
    }
  } else if self.is_kw("SELECT") || self.is_kw("VALUES") {
    SelectStmt(self.parse_query())
  } else if self.is_kw("CREATE") {
    self.parse_create()
  } else if self.is_kw("DROP") {
    self.parse_drop()
  } else if self.is_kw("INSERT") || self.is_kw("REPLACE") {
    self.parse_insert()
  } else if self.is_kw("UPDATE") {
    self.parse_update()
  } else if self.is_kw("DELETE") {
    self.parse_delete()
  } else if self.is_kw("ALTER") {
    self.parse_alter()
  } else if self.eat_kw("BEGIN") {
    let _ = self.eat_kw("DEFERRED") ||
      self.eat_kw("IMMEDIATE") ||
      self.eat_kw("EXCLUSIVE")
    let _ = self.eat_kw("TRANSACTION")
    Begin
  } else if self.eat_kw("COMMIT") || self.eat_kw("END") {
    let _ = self.eat_kw("TRANSACTION")
    Commit
  } else if self.eat_kw("ROLLBACK") {
    let _ = self.eat_kw("TRANSACTION")
    if self.eat_kw("TO") {
      let _ = self.eat_kw("SAVEPOINT")
      Rollback(Some(self.parse_name()))
    } else {
      Rollback(None)
    }
  } else if self.eat_kw("SAVEPOINT") {
    Savepoint(self.parse_name())
  } else if self.eat_kw("RELEASE") {
    let _ = self.eat_kw("SAVEPOINT")
    Release(self.parse_name())
  } else {
    raise self.fail()
  }
}

///|
fn Parser::parse_alter(self : Parser) -> Stmt raise SqlError {
  self.expect_kw("ALTER")
  self.expect_kw("TABLE")
  let table = self.parse_qualified_name()
  if self.eat_kw("RENAME") {
    if self.eat_kw("TO") {
      return AlterRename(table~, new_name=self.parse_name())
    }
    let _ = self.eat_kw("COLUMN")
    let old = self.parse_name()
    self.expect_kw("TO")
    let new_name = self.parse_name()
    AlterRenameCol(table~, old~, new_name~)
  } else if self.eat_kw("ADD") {
    let _ = self.eat_kw("COLUMN")
    let start = self.peek().pos
    let col = self.parse_column_def()
    let end = self.peek().pos
    let sql = self.src[start:end].to_owned().trim_end().to_owned()
    AlterAdd(table~, col~, sql~)
  } else if self.eat_kw("DROP") {
    let _ = self.eat_kw("COLUMN")
    AlterDrop(table~, col=self.parse_name())
  } else {
    raise self.fail()
  }
}

///|
fn Parser::parse_if_not_exists(self : Parser) -> Bool raise SqlError {
  if self.eat_kw("IF") {
    self.expect_kw("NOT")
    self.expect_kw("EXISTS")
    true
  } else {
    false
  }
}

///|
fn Parser::parse_create_index(
  self : Parser,
  start : Int,
  unique : Bool,
) -> Stmt raise SqlError {
  self.expect_kw("INDEX")
  let if_not_exists = self.parse_if_not_exists()
  let name = self.parse_qualified_name()
  self.expect_kw("ON")
  let table = self.parse_name()
  self.expect_op("(")
  let cols : Array[IndexCol] = []
  while true {
    let e = self.parse_expr()
    let (expr, coll) = match e {
      Collate(x, c) => (x, Some(c))
      _ => (e, None)
    }
    let desc = if self.eat_kw("DESC") {
      true
    } else {
      let _ = self.eat_kw("ASC")
      false
    }
    cols.push({ expr, coll, desc, })
    if !self.eat_op(",") {
      break
    }
  }
  self.expect_op(")")
  let where_ = if self.eat_kw("WHERE") { Some(self.parse_expr()) } else { None }
  let end = self.peek().pos
  let sql = self.src[start:end].to_owned().trim_end().to_owned()
  CreateIndex(name~, table~, unique~, if_not_exists~, cols~, where_~, sql~)
}

///|
fn Parser::parse_create_view(self : Parser, start : Int) -> Stmt raise SqlError {
  self.expect_kw("VIEW")
  let if_not_exists = self.parse_if_not_exists()
  let name = self.parse_qualified_name()
  let cols = if self.is_op("(") { Some(self.parse_name_list()) } else { None }
  self.expect_kw("AS")
  if !self.at_query_start() {
    raise self.fail()
  }
  let query = self.parse_query()
  let end = self.peek().pos
  let sql = self.src[start:end].to_owned().trim_end().to_owned()
  CreateView(name~, if_not_exists~, cols~, query~, sql~)
}

///|
fn Parser::parse_drop(self : Parser) -> Stmt raise SqlError {
  self.expect_kw("DROP")
  let kind = if self.eat_kw("TABLE") {
    0
  } else if self.eat_kw("INDEX") {
    1
  } else {
    self.expect_kw("VIEW")
    2
  }
  let mut if_exists = false
  if self.eat_kw("IF") {
    self.expect_kw("EXISTS")
    if_exists = true
  }
  let name = self.parse_qualified_name()
  match kind {
    0 => DropTable(name~, if_exists~)
    1 => DropIndex(name~, if_exists~)
    _ => DropView(name~, if_exists~)
  }
}

///|
/// [schema.]name — the schema part is ignored.
fn Parser::parse_qualified_name(self : Parser) -> String raise SqlError {
  let n = self.parse_name()
  if self.eat_op(".") {
    self.parse_name()
  } else {
    n
  }
}

///|
fn Parser::parse_conflict_clause(self : Parser) -> Conflict? raise SqlError {
  if self.is_kw("ON") && self.is_kw_at(1, "CONFLICT") {
    self.pos += 2
    Some(self.parse_conflict_kind())
  } else {
    None
  }
}

///|
fn Parser::parse_conflict_kind(self : Parser) -> Conflict raise SqlError {
  if self.eat_kw("ROLLBACK") {
    CRollback
  } else if self.eat_kw("ABORT") {
    CAbort
  } else if self.eat_kw("FAIL") {
    CFail
  } else if self.eat_kw("IGNORE") {
    CIgnore
  } else if self.eat_kw("REPLACE") {
    CReplace
  } else {
    raise self.fail()
  }
}

///|
fn Parser::parse_create(self : Parser) -> Stmt raise SqlError {
  let start = self.peek().pos
  self.expect_kw("CREATE")
  let _ = self.eat_kw("TEMP") || self.eat_kw("TEMPORARY")
  if self.eat_kw("UNIQUE") {
    return self.parse_create_index(start, true)
  }
  if self.is_kw("INDEX") {
    return self.parse_create_index(start, false)
  }
  if self.is_kw("VIEW") {
    return self.parse_create_view(start)
  }
  self.expect_kw("TABLE")
  let mut if_not_exists = false
  if self.eat_kw("IF") {
    self.expect_kw("NOT")
    self.expect_kw("EXISTS")
    if_not_exists = true
  }
  let name = self.parse_qualified_name()
  self.expect_op("(")
  let cols : Array[ColumnDef] = []
  let constraints : Array[TableConstraint] = []
  // column definitions
  while true {
    if self.is_table_constraint_start() {
      break
    }
    cols.push(self.parse_column_def())
    if self.eat_op(",") {
      continue
    }
    break
  }
  // table constraints
  if cols.length() > 0 && !self.is_op(")") {
    while true {
      constraints.push(self.parse_table_constraint())
      if self.eat_op(",") {
        continue
      }
      if self.is_op(")") {
        break
      }
    }
  }
  if cols.length() == 0 {
    raise self.fail()
  }
  self.expect_op(")")
  let mut npk = 0
  for c in cols {
    if c.primary_key {
      npk += 1
    }
  }
  for tc in constraints {
    if tc is TPrimaryKey(_, _) {
      npk += 1
    }
  }
  if npk > 1 {
    raise sql_err("table \"\{name}\" has more than one primary key")
  }
  // table options
  while true {
    if self.eat_kw("WITHOUT") {
      let _ = self.parse_name()
      if npk == 0 {
        raise sql_err("PRIMARY KEY missing on table \{name}")
      }
    } else if self.eat_kw("STRICT") {
      ()
    } else {
      break
    }
    if !self.eat_op(",") {
      break
    }
  }
  let end = self.peek().pos
  let sql = self.src[start:end].to_owned().trim_end().to_owned()
  CreateTable(name~, if_not_exists~, cols~, constraints~, sql~)
}

///|
fn Parser::is_table_constraint_start(self : Parser) -> Bool {
  self.is_kw("CONSTRAINT") ||
  self.is_kw("PRIMARY") ||
  self.is_kw("UNIQUE") ||
  self.is_kw("CHECK") ||
  self.is_kw("FOREIGN")
}

///|
let column_constraint_words : Set[String] = Set([
  "CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT", "COLLATE",
  "REFERENCES", "GENERATED", "AS",
])

///|
fn Parser::parse_signed_number_text(self : Parser) -> String raise SqlError {
  let mut s = ""
  if self.is_op("+") || self.is_op("-") {
    s = self.advance().text
  }
  let t = self.peek()
  match t.kind {
    TInteger | TFloat => {
      self.pos += 1
      s + t.text
    }
    _ => raise self.fail()
  }
}

///|
fn Parser::parse_column_def(self : Parser) -> ColumnDef raise SqlError {
  let name = self.parse_name()
  // type name
  let words : Array[String] = []
  while true {
    let t = self.peek()
    match t.kind {
      TIdent if !column_constraint_words.contains(t.upper) => {
        self.pos += 1
        words.push(t.text)
      }
      TQuoted | TBracket if words.length() == 0 => {
        self.pos += 1
        words.push(t.text)
      }
      _ => break
    }
  }
  let mut type_name = words.join(" ")
  if words.length() > 0 && self.eat_op("(") {
    let a = self.parse_signed_number_text()
    type_name = type_name + "(" + a
    if self.eat_op(",") {
      let b = self.parse_signed_number_text()
      type_name = type_name + "," + b
    }
    self.expect_op(")")
    type_name = type_name + ")"
  }
  let col : ColumnDef = {
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
  // constraints
  while true {
    if self.eat_kw("CONSTRAINT") {
      let _ = self.parse_name()
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
      col.pk_conflict = self.parse_conflict_clause()
      if self.eat_kw("AUTOINCREMENT") {
        col.autoincrement = true
      }
      continue
    }
    if self.is_kw("NOT") && self.is_kw_at(1, "NULL") {
      self.pos += 2
      col.not_null = true
      col.nn_conflict = self.parse_conflict_clause()
      continue
    }
    if self.eat_kw("NULL") {
      let _ = self.parse_conflict_clause()
      continue
    }
    if self.eat_kw("UNIQUE") {
      col.unique = true
      col.unique_conflict = self.parse_conflict_clause()
      continue
    }
    if self.eat_kw("CHECK") {
      self.expect_op("(")
      col.checks.push(self.parse_expr())
      self.expect_op(")")
      continue
    }
    if self.eat_kw("DEFAULT") {
      col.default_ = Some(self.parse_default_value())
      continue
    }
    if self.eat_kw("COLLATE") {
      let cn = self.parse_name()
      let _ = coll_of_name(cn)
      col.collate = Some(cn)
      continue
    }
    if self.is_kw("REFERENCES") {
      self.parse_references()
      continue
    }
    if self.is_kw("GENERATED") || self.is_kw("AS") {
      if self.eat_kw("GENERATED") {
        self.expect_kw("ALWAYS")
      }
      self.expect_kw("AS")
      self.expect_op("(")
      let _ = self.parse_expr()
      self.expect_op(")")
      let _ = self.eat_kw("STORED") || self.eat_kw("VIRTUAL")
      continue
    }
    break
  }
  col
}

///|
fn Parser::parse_default_value(self : Parser) -> Expr raise SqlError {
  if self.eat_op("(") {
    let e = self.parse_expr()
    self.expect_op(")")
    return e
  }
  if self.is_op("+") || self.is_op("-") {
    let neg = self.advance().text == "-"
    let t = self.peek()
    match t.kind {
      TInteger | TFloat => {
        let e = self.parse_primary()
        return if neg { Unary(Neg, e) } else { e }
      }
      _ => raise self.fail()
    }
  }
  let t = self.peek()
  match t.kind {
    TInteger | TFloat | TString | TBlob => self.parse_primary()
    TIdent =>
      match t.upper {
        "NULL"
        | "TRUE"
        | "FALSE"
        | "CURRENT_TIME"
        | "CURRENT_DATE"
        | "CURRENT_TIMESTAMP" => self.parse_primary()
        _ => {
          self.pos += 1
          Lit(Text(t.text))
        }
      }
    TQuoted => {
      self.pos += 1
      Lit(Text(t.text))
    }
    _ => raise self.fail()
  }
}

///|
fn Parser::parse_name_list(self : Parser) -> Array[String] raise SqlError {
  self.expect_op("(")
  let names : Array[String] = []
  while true {
    names.push(self.parse_name())
    if !self.eat_op(",") {
      break
    }
  }
  self.expect_op(")")
  names
}

///|
fn Parser::parse_references(self : Parser) -> Unit raise SqlError {
  self.expect_kw("REFERENCES")
  let _ = self.parse_name()
  if self.is_op("(") {
    let _ = self.parse_name_list()
  }
  while true {
    if self.eat_kw("ON") {
      if !(self.eat_kw("DELETE") || self.eat_kw("UPDATE")) {
        raise self.fail()
      }
      if self.eat_kw("SET") {
        if !(self.eat_kw("NULL") || self.eat_kw("DEFAULT")) {
          raise self.fail()
        }
      } else if self.eat_kw("CASCADE") || self.eat_kw("RESTRICT") {
        ()
      } else if self.eat_kw("NO") {
        self.expect_kw("ACTION")
      } else {
        raise self.fail()
      }
      continue
    }
    if self.eat_kw("MATCH") {
      let _ = self.advance()
      continue
    }
    if self.is_kw("DEFERRABLE") ||
      (self.is_kw("NOT") && self.is_kw_at(1, "DEFERRABLE")) {
      let _ = self.eat_kw("NOT")
      self.expect_kw("DEFERRABLE")
      if self.eat_kw("INITIALLY") {
        if !(self.eat_kw("DEFERRED") || self.eat_kw("IMMEDIATE")) {
          raise self.fail()
        }
      }
      continue
    }
    break
  }
}

///|
fn Parser::parse_indexed_columns(self : Parser) -> Array[String] raise SqlError {
  self.expect_op("(")
  let names : Array[String] = []
  while true {
    let e = self.parse_expr()
    match e {
      Column(name~, ..) => names.push(name)
      _ => names.push("")
    }
    let _ = self.eat_kw("ASC") || self.eat_kw("DESC")
    if !self.eat_op(",") {
      break
    }
  }
  self.expect_op(")")
  names
}

///|
fn Parser::parse_table_constraint(
  self : Parser,
) -> TableConstraint raise SqlError {
  if self.eat_kw("CONSTRAINT") {
    let _ = self.parse_name()
  }
  if self.eat_kw("PRIMARY") {
    self.expect_kw("KEY")
    let cols = self.parse_indexed_columns()
    let c = self.parse_conflict_clause()
    TPrimaryKey(cols, c)
  } else if self.eat_kw("UNIQUE") {
    let cols = self.parse_indexed_columns()
    let c = self.parse_conflict_clause()
    TUnique(cols, c)
  } else if self.eat_kw("CHECK") {
    self.expect_op("(")
    let e = self.parse_expr()
    self.expect_op(")")
    TCheck(e)
  } else if self.eat_kw("FOREIGN") {
    self.expect_kw("KEY")
    let _ = self.parse_name_list()
    self.parse_references()
    TForeignKey
  } else {
    raise self.fail()
  }
}

///|
fn Parser::parse_insert(self : Parser) -> Stmt raise SqlError {
  let mut or_ : Conflict? = None
  if self.eat_kw("REPLACE") {
    or_ = Some(CReplace)
  } else {
    self.expect_kw("INSERT")
    if self.eat_kw("OR") {
      or_ = Some(self.parse_conflict_kind())
    }
  }
  self.expect_kw("INTO")
  let table = self.parse_qualified_name()
  let as_name = if self.eat_kw("AS") { Some(self.parse_name()) } else { None }
  let mut cols : Array[String]? = None
  if self.is_op("(") {
    cols = Some(self.parse_name_list())
  }
  let src = if self.eat_kw("VALUES") {
    Values(self.parse_values_rows())
  } else if self.is_kw("SELECT") || self.is_kw("WITH") {
    SelectSrc(self.parse_query())
  } else if self.eat_kw("DEFAULT") {
    self.expect_kw("VALUES")
    DefaultValues
  } else {
    raise self.fail()
  }
  let upserts : Array[Upsert] = []
  while self.is_kw("ON") && self.is_kw_at(1, "CONFLICT") {
    if src is DefaultValues {
      raise self.fail()
    }
    self.pos += 2
    let mut target : Array[String]? = None
    if self.is_op("(") {
      target = Some(self.parse_indexed_columns())
      if self.eat_kw("WHERE") {
        let _ = self.parse_expr()
      }
    } else if upserts.length() > 0 &&
      upserts[upserts.length() - 1].target is None {
      raise self.fail()
    }
    self.expect_kw("DO")
    if self.eat_kw("NOTHING") {
      upserts.push({ target, sets: None, where_: None, })
    } else {
      self.expect_kw("UPDATE")
      self.expect_kw("SET")
      let sets = self.parse_set_list()
      let where_ = if self.eat_kw("WHERE") {
        Some(self.parse_expr())
      } else {
        None
      }
      upserts.push({ target, sets: Some(sets), where_, })
    }
  }
  for i, u in upserts {
    if u.target is None && i != upserts.length() - 1 {
      raise sql_err(
        "ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint",
      )
    }
  }
  let returning = self.parse_returning()
  Insert(table~, as_name~, cols~, src~, or_~, upserts~, returning~)
}

///|
fn Parser::parse_returning(self : Parser) -> Array[ResultCol]? raise SqlError {
  if !self.eat_kw("RETURNING") {
    return None
  }
  let cols : Array[ResultCol] = []
  while true {
    cols.push(self.parse_result_col())
    if !self.eat_op(",") {
      break
    }
  }
  Some(cols)
}

///|
/// SET assignments: `col = expr` or `(c1, c2) = (e1, e2)`.
fn Parser::parse_set_list(
  self : Parser,
) -> Array[(String, Expr)] raise SqlError {
  let sets : Array[(String, Expr)] = []
  while true {
    if self.is_op("(") {
      let names = self.parse_name_list()
      self.expect_op("=")
      self.expect_op("(")
      let exprs : Array[Expr] = []
      while true {
        exprs.push(self.parse_expr())
        if !self.eat_op(",") {
          break
        }
      }
      self.expect_op(")")
      if exprs.length() != names.length() {
        raise sql_err(
          "\{names.length()} columns assigned \{exprs.length()} values",
        )
      }
      for i, n in names {
        sets.push((n, exprs[i]))
      }
    } else {
      let n = self.parse_name()
      self.expect_op("=")
      sets.push((n, self.parse_expr()))
    }
    if !self.eat_op(",") {
      break
    }
  }
  sets
}

///|
fn Parser::parse_update(self : Parser) -> Stmt raise SqlError {
  self.expect_kw("UPDATE")
  let or_ = if self.eat_kw("OR") {
    Some(self.parse_conflict_kind())
  } else {
    None
  }
  let table = self.parse_qualified_name()
  let as_name = if self.eat_kw("AS") {
    Some(self.parse_name())
  } else if self.at_name() {
    Some(self.parse_name())
  } else {
    None
  }
  self.expect_kw("SET")
  let sets = self.parse_set_list()
  let where_ = if self.eat_kw("WHERE") { Some(self.parse_expr()) } else { None }
  let returning = self.parse_returning()
  Update(table~, as_name~, or_~, sets~, where_~, returning~)
}

///|
fn Parser::parse_delete(self : Parser) -> Stmt raise SqlError {
  self.expect_kw("DELETE")
  self.expect_kw("FROM")
  let table = self.parse_qualified_name()
  let as_name = if self.eat_kw("AS") {
    Some(self.parse_name())
  } else if self.at_name() {
    Some(self.parse_name())
  } else {
    None
  }
  let where_ = if self.eat_kw("WHERE") { Some(self.parse_expr()) } else { None }
  let returning = self.parse_returning()
  Delete(table~, as_name~, where_~, returning~)
}

///|
fn Parser::parse_values_rows(
  self : Parser,
) -> Array[Array[Expr]] raise SqlError {
  let rows : Array[Array[Expr]] = []
  while true {
    self.expect_op("(")
    let row : Array[Expr] = []
    while true {
      row.push(self.parse_expr())
      if !self.eat_op(",") {
        break
      }
    }
    self.expect_op(")")
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
fn Parser::at_query_start(self : Parser) -> Bool {
  self.is_kw("SELECT") || self.is_kw("VALUES") || self.is_kw("WITH")
}

///|
/// `WITH [RECURSIVE] name [(cols)] AS [NOT] [MATERIALIZED] (query), ...`
fn Parser::parse_with(self : Parser) -> Array[CteDef] raise SqlError {
  self.expect_kw("WITH")
  let _ = self.eat_kw("RECURSIVE")
  let ctes : Array[CteDef] = []
  while true {
    let name = self.parse_name()
    let cols = if self.is_op("(") { Some(self.parse_name_list()) } else { None }
    self.expect_kw("AS")
    if self.eat_kw("NOT") {
      self.expect_kw("MATERIALIZED")
    } else {
      let _ = self.eat_kw("MATERIALIZED")
    }
    self.expect_op("(")
    let query = self.parse_query()
    self.expect_op(")")
    for c in ctes {
      if same_name(c.name, name) {
        raise sql_err("duplicate WITH table name: \{name}")
      }
    }
    ctes.push({ name, cols, query, })
    if !self.eat_op(",") {
      break
    }
  }
  ctes
}

///|
/// A full query: compound of SELECT / VALUES cores with ORDER BY and LIMIT.
fn Parser::parse_query(self : Parser) -> Query raise SqlError {
  if self.is_kw("WITH") {
    let ctes = self.parse_with()
    return QWith(ctes~, body=self.parse_query())
  }
  let first = self.parse_query_core()
  let rest : Array[(CompoundOp, Query)] = []
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
    rest.push((op, self.parse_query_core()))
  }
  let order_by = self.parse_order_by()
  let (limit, offset) = self.parse_limit()
  match first {
    QSelect(sel) if rest.length() == 0 =>
      QSelect({ ..sel, order_by, limit, offset, })
    QValues(_) if rest.length() == 0 =>
      if order_by.length() == 0 && limit is None {
        first
      } else {
        raise sql_err("near \"ORDER\": syntax error")
      }
    _ => QCompound(first~, rest~, order_by~, limit~, offset~)
  }
}

///|
fn Parser::parse_query_core(self : Parser) -> Query raise SqlError {
  if self.eat_kw("VALUES") {
    let rows = self.parse_values_rows()
    let w = rows[0].length()
    for r in rows {
      if r.length() != w {
        raise sql_err("all VALUES must have the same number of terms")
      }
    }
    QValues(rows)
  } else {
    QSelect(self.parse_select_core())
  }
}

///|
fn Parser::parse_limit(self : Parser) -> (Expr?, Expr?) raise SqlError {
  let mut limit : Expr? = None
  let mut offset : Expr? = None
  if self.eat_kw("LIMIT") {
    let a = self.parse_expr()
    if self.eat_kw("OFFSET") {
      limit = Some(a)
      offset = Some(self.parse_expr())
    } else if self.eat_op(",") {
      offset = Some(a)
      limit = Some(self.parse_expr())
    } else {
      limit = Some(a)
    }
  }
  (limit, offset)
}

///|
fn Parser::parse_select_core(self : Parser) -> Select raise SqlError {
  self.expect_kw("SELECT")
  let mut distinct = false
  if self.eat_kw("DISTINCT") {
    distinct = true
  } else {
    let _ = self.eat_kw("ALL")
  }
  let cols : Array[ResultCol] = []
  while true {
    cols.push(self.parse_result_col())
    if !self.eat_op(",") {
      break
    }
  }
  let from : Array[FromItem] = []
  if self.eat_kw("FROM") {
    self.parse_from(from)
  }
  let mut where_ : Expr? = None
  if self.eat_kw("WHERE") {
    where_ = Some(self.parse_expr())
  }
  let group_by : Array[Expr] = []
  let mut having : Expr? = None
  if self.is_kw("GROUP") {
    self.pos += 1
    self.expect_kw("BY")
    while true {
      group_by.push(self.parse_expr())
      if !self.eat_op(",") {
        break
      }
    }
  }
  if self.eat_kw("HAVING") {
    having = Some(self.parse_expr())
  }
  let windows : Array[(String, WinDef)] = []
  if self.eat_kw("WINDOW") {
    while true {
      let name = self.parse_name()
      self.expect_kw("AS")
      self.expect_op("(")
      let def = self.parse_window_def()
      self.expect_op(")")
      windows.push((name, def))
      if !self.eat_op(",") {
        break
      }
    }
  }
  {
    distinct,
    cols,
    from,
    where_,
    group_by,
    having,
    order_by: [],
    limit: None,
    offset: None,
    windows,
  }
}

///|
/// FROM clause: table-or-subquery items separated by commas or joins.
fn Parser::parse_from(
  self : Parser,
  from : Array[FromItem],
) -> Unit raise SqlError {
  let mut join = JInner
  let mut natural = false
  while true {
    let src = if self.is_op("(") {
      self.pos += 1
      if !self.at_query_start() {
        raise self.fail()
      }
      let q = self.parse_query()
      self.expect_op(")")
      FSub(q)
    } else {
      FTable(self.parse_qualified_name())
    }
    let mut as_name : String? = None
    if self.eat_kw("AS") {
      as_name = Some(self.parse_name())
    } else if self.at_name() {
      as_name = Some(self.parse_name())
    }
    let mut on : Expr? = None
    let mut using_ : Array[String]? = None
    if from.length() > 0 {
      if self.eat_kw("ON") {
        on = Some(self.parse_expr())
      } else if self.eat_kw("USING") {
        using_ = Some(self.parse_name_list())
      }
      if natural && (on is Some(_) || using_ is Some(_)) {
        raise sql_err("a NATURAL join may not have an ON or USING clause")
      }
    }
    from.push({ src, as_name, join, natural, on, using_, })
    // separator
    natural = false
    if self.eat_op(",") {
      join = JInner
      continue
    }
    if self.eat_kw("NATURAL") {
      natural = true
    }
    if self.eat_kw("LEFT") {
      let _ = self.eat_kw("OUTER")
      join = JLeft
    } else if self.eat_kw("RIGHT") {
      let _ = self.eat_kw("OUTER")
      join = JRight
    } else if self.eat_kw("FULL") {
      let _ = self.eat_kw("OUTER")
      join = JFull
    } else if self.eat_kw("INNER") || self.eat_kw("CROSS") {
      join = JInner
    } else if self.is_kw("JOIN") {
      join = JInner
    } else if natural {
      raise self.fail()
    } else {
      break
    }
    self.expect_kw("JOIN")
  }
}

///|
/// Optional `ORDER BY term, ...`.
fn Parser::parse_order_by(self : Parser) -> Array[OrderTerm] raise SqlError {
  let order_by : Array[OrderTerm] = []
  if self.is_kw("ORDER") {
    self.pos += 1
    self.expect_kw("BY")
    while true {
      let start = self.peek().pos
      let e = self.parse_expr()
      let text = self.src[start:self.peek().pos].trim_end().to_owned()
      let mut desc = false
      if self.eat_kw("DESC") {
        desc = true
      } else {
        let _ = self.eat_kw("ASC")
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
      order_by.push({ expr: e, desc, nulls_first, text, })
      if !self.eat_op(",") {
        break
      }
    }
  }
  order_by
}

///|
fn Parser::parse_result_col(self : Parser) -> ResultCol raise SqlError {
  if self.eat_op("*") {
    return Star
  }
  let t = self.peek()
  if (t.kind == TIdent || t.kind == TQuoted || t.kind == TBracket) &&
    self.peek_at(1).kind == TOp &&
    self.peek_at(1).text == "." &&
    self.peek_at(2).kind == TOp &&
    self.peek_at(2).text == "*" {
    self.pos += 3
    return TableStar(t.text)
  }
  let start = self.peek().pos
  let e = self.parse_expr()
  let text = self.src[start:self.peek().pos].trim_end().to_owned()
  let mut as_name : String? = None
  if self.eat_kw("AS") {
    as_name = Some(self.parse_name())
  } else if self.at_name() || self.peek().kind == TString {
    as_name = Some(self.parse_name())
  }
  ExprCol(e, as_name, text)
}

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

///|
fn Parser::parse_expr(self : Parser) -> Expr raise SqlError {
  self.parse_or()
}

///|
fn Parser::parse_or(self : Parser) -> Expr raise SqlError {
  let mut l = self.parse_and()
  while self.eat_kw("OR") {
    let r = self.parse_and()
    l = Binary(Or, l, r)
  }
  l
}

///|
fn Parser::parse_and(self : Parser) -> Expr raise SqlError {
  let mut l = self.parse_not()
  while self.eat_kw("AND") {
    let r = self.parse_not()
    l = Binary(And, l, r)
  }
  l
}

///|
fn Parser::parse_not(self : Parser) -> Expr raise SqlError {
  if self.eat_kw("NOT") {
    Unary(Not, self.parse_not())
  } else {
    self.parse_equality()
  }
}

///|
fn Parser::parse_equality(self : Parser) -> Expr raise SqlError {
  let mut l = self.parse_comparison()
  while true {
    let t = self.peek()
    if t.kind == TOp {
      match t.text {
        "=" | "==" => {
          self.pos += 1
          l = Binary(Eq, l, self.parse_comparison())
          continue
        }
        "!=" | "<>" => {
          self.pos += 1
          l = Binary(Ne, l, self.parse_comparison())
          continue
        }
        _ => break
      }
    }
    if t.kind != TIdent {
      break
    }
    match t.upper {
      "IS" => {
        self.pos += 1
        let neg = self.eat_kw("NOT")
        if self.eat_kw("DISTINCT") {
          self.expect_kw("FROM")
          let r = self.parse_comparison()
          l = Binary(if neg { Is } else { IsNot }, l, r)
        } else {
          let r = self.parse_comparison()
          l = Binary(if neg { IsNot } else { Is }, l, r)
        }
      }
      "ISNULL" => {
        self.pos += 1
        l = IsNull(l, false)
      }
      "NOTNULL" => {
        self.pos += 1
        l = IsNull(l, true)
      }
      "NOT" if self.is_kw_at(1, "NULL") => {
        self.pos += 2
        l = IsNull(l, true)
      }
      "NOT" if self.is_kw_at(1, "IN") ||
        self.is_kw_at(1, "LIKE") ||
        self.is_kw_at(1, "GLOB") ||
        self.is_kw_at(1, "BETWEEN") ||
        self.is_kw_at(1, "MATCH") ||
        self.is_kw_at(1, "REGEXP") => {
        self.pos += 1
        l = self.parse_postfix_op(l, true)
      }
      "IN" | "LIKE" | "GLOB" | "BETWEEN" | "MATCH" | "REGEXP" =>
        l = self.parse_postfix_op(l, false)
      _ => break
    }
  }
  l
}

///|
/// IN / LIKE / GLOB / BETWEEN after the left operand (and optional NOT).
fn Parser::parse_postfix_op(
  self : Parser,
  l : Expr,
  neg : Bool,
) -> Expr raise SqlError {
  let t = self.advance()
  match t.upper {
    "IN" => {
      if !self.is_op("(") {
        let name = self.parse_qualified_name()
        let sel : Select = {
          distinct: false,
          cols: [Star],
          from: [
            {
              src: FTable(name),
              as_name: None,
              join: JInner,
              natural: false,
              on: None,
              using_: None,
            },
          ],
          where_: None,
          group_by: [],
          having: None,
          order_by: [],
          limit: None,
          offset: None,
          windows: [],
        }
        return InQ(l, QSelect(sel), neg)
      }
      self.expect_op("(")
      if self.at_query_start() {
        let q = self.parse_query()
        self.expect_op(")")
        return InQ(l, q, neg)
      }
      let items : Array[Expr] = []
      if !self.is_op(")") {
        while true {
          items.push(self.parse_expr())
          if !self.eat_op(",") {
            break
          }
        }
      }
      self.expect_op(")")
      InList(l, items, neg, default_info)
    }
    "BETWEEN" => {
      let lo = self.parse_comparison()
      self.expect_kw("AND")
      let hi = self.parse_comparison()
      Between(l, lo, hi, neg, default_info, default_info)
    }
    "LIKE" | "GLOB" => {
      let pat = self.parse_comparison()
      let esc = if t.upper == "LIKE" && self.eat_kw("ESCAPE") {
        Some(self.parse_comparison())
      } else {
        None
      }
      Like(glob=t.upper == "GLOB", lhs=l, pat~, esc~, neg~)
    }
    _ => {
      let _ = self.parse_comparison()
      raise sql_err("no such function: \{t.upper}")
    }
  }
}

///|
fn coll_of_name(name : String) -> Coll raise SqlError {
  match name.to_upper() {
    "BINARY" => CBinary
    "NOCASE" => CNoCase
    "RTRIM" => CRTrim
    _ => raise sql_err("no such collation sequence: \{name}")
  }
}

///|
fn Parser::parse_comparison(self : Parser) -> Expr raise SqlError {
  let mut l = self.parse_bitops()
  while true {
    let op = match self.peek() {
      { kind: TOp, text: "<", .. } => Lt
      { kind: TOp, text: "<=", .. } => Le
      { kind: TOp, text: ">", .. } => Gt
      { kind: TOp, text: ">=", .. } => Ge
      _ => break
    }
    self.pos += 1
    l = Binary(op, l, self.parse_bitops())
  }
  l
}

///|
fn Parser::parse_bitops(self : Parser) -> Expr raise SqlError {
  let mut l = self.parse_additive()
  while true {
    let op = match self.peek() {
      { kind: TOp, text: "&", .. } => BitAnd
      { kind: TOp, text: "|", .. } => BitOr
      { kind: TOp, text: "<<", .. } => Shl
      { kind: TOp, text: ">>", .. } => Shr
      _ => break
    }
    self.pos += 1
    l = Binary(op, l, self.parse_additive())
  }
  l
}

///|
fn Parser::parse_additive(self : Parser) -> Expr raise SqlError {
  let mut l = self.parse_mult()
  while true {
    let op = match self.peek() {
      { kind: TOp, text: "+", .. } => Add
      { kind: TOp, text: "-", .. } => Sub
      _ => break
    }
    self.pos += 1
    l = Binary(op, l, self.parse_mult())
  }
  l
}

///|
fn Parser::parse_mult(self : Parser) -> Expr raise SqlError {
  let mut l = self.parse_concat()
  while true {
    let op = match self.peek() {
      { kind: TOp, text: "*", .. } => Mul
      { kind: TOp, text: "/", .. } => Div
      { kind: TOp, text: "%", .. } => Mod
      _ => break
    }
    self.pos += 1
    l = Binary(op, l, self.parse_concat())
  }
  l
}

///|
fn Parser::parse_concat(self : Parser) -> Expr raise SqlError {
  let mut l = self.parse_unary()
  while self.eat_op("||") {
    l = Binary(Concat, l, self.parse_unary())
  }
  l
}

///|
fn Parser::parse_unary(self : Parser) -> Expr raise SqlError {
  if self.eat_op("-") {
    let t = self.peek()
    if t.kind == TInteger &&
      parse_int_literal(t.text) is Lit(Int(v)) &&
      v == @int64.MIN_VALUE {
      raise sql_err("hex literal too big: -\{t.text}")
    }
    Unary(Neg, self.parse_unary())
  } else if self.eat_op("+") {
    Unary(Pos, self.parse_unary())
  } else if self.eat_op("~") {
    Unary(BitNot, self.parse_unary())
  } else {
    let mut e = self.parse_primary()
    while self.eat_kw("COLLATE") {
      e = Collate(e, coll_of_name(self.parse_name()))
    }
    e
  }
}

///|
fn parse_int_literal(text : String) -> Expr raise SqlError {
  if text.length() > 2 && (text[1] == 'x' || text[1] == 'X') {
    let digits = text[2:]
    let mut z = 0
    while z < digits.length() && digits[z] == '0' {
      z += 1
    }
    if digits.length() - z > 16 {
      raise sql_err("hex literal too big: \{text}")
    }
    let mut v = 0L
    for i in z..<digits.length() {
      v = (v << 4) | hex_val(digits[i].to_int()).to_int64()
    }
    return Lit(Int(v))
  }
  let r = scan_number(text)
  if r.int_ok {
    Lit(Int(r.ival))
  } else {
    let mut z = 0
    while z < text.length() - 1 && text[z] == '0' {
      z += 1
    }
    if text[z:] == "9223372036854775808" {
      BigIntLit
    } else {
      Lit(Real(r.rval))
    }
  }
}

///|
fn decode_blob_hex(h : String) -> Bytes {
  let buf = @buffer.Buffer()
  let mut k = 0
  while k + 1 < h.length() {
    buf.write_byte(
      (hex_val(h[k].to_int()) * 16 + hex_val(h[k + 1].to_int())).to_byte(),
    )
    k += 2
  }
  buf.to_bytes()
}

///|
fn Parser::parse_primary(self : Parser) -> Expr raise SqlError {
  let t = self.peek()
  match t.kind {
    TInteger => {
      self.pos += 1
      parse_int_literal(t.text)
    }
    TFloat => {
      self.pos += 1
      Lit(Real(scan_number(t.text).rval))
    }
    TString => {
      self.pos += 1
      Lit(Text(t.text))
    }
    TBlob => {
      self.pos += 1
      Lit(Blob(decode_blob_hex(t.text)))
    }
    TOp if t.text == "(" => {
      self.pos += 1
      if self.at_query_start() {
        let q = self.parse_query()
        self.expect_op(")")
        return SubQ(q)
      }
      let e = self.parse_expr()
      self.expect_op(")")
      e
    }
    TQuoted | TBracket => {
      self.pos += 1
      if self.is_op(".") {
        self.pos += 1
        let col = self.parse_name()
        if self.eat_op(".") {
          let col2 = self.parse_name()
          Column(tbl=Some(col), name=col2, dq=false)
        } else {
          Column(tbl=Some(t.text), name=col, dq=false)
        }
      } else {
        Column(tbl=None, name=t.text, dq=t.kind == TQuoted)
      }
    }
    TIdent => {
      match t.upper {
        "CASE" => {
          self.pos += 1
          return self.parse_case()
        }
        "CAST" => {
          self.pos += 1
          self.expect_op("(")
          let e = self.parse_expr()
          self.expect_kw("AS")
          let tn = self.parse_type_name()
          self.expect_op(")")
          return Cast(
            e,
            if tn.length() == 0 {
              AffNumeric
            } else {
              affinity_of_type(tn)
            },
          )
        }
        "NULL" => {
          self.pos += 1
          return Lit(Null)
        }
        "EXISTS" if self.peek_at(1).kind == TOp && self.peek_at(1).text == "(" => {
          self.pos += 2
          let q = self.parse_query()
          self.expect_op(")")
          return ExistsQ(q)
        }
        "TRUE" => {
          self.pos += 1
          return Lit(Int(1L))
        }
        "FALSE" => {
          self.pos += 1
          return Lit(Int(0L))
        }
        _ => ()
      }
      let callable = t.upper is ("LIKE" | "GLOB" | "REGEXP" | "MATCH") &&
        self.peek_at(1).kind == TOp &&
        self.peek_at(1).text == "("
      if reserved_words.contains(t.upper) && !callable {
        raise self.fail()
      }
      self.pos += 1
      if self.is_op("(") {
        self.pos += 1
        let args : Array[Expr] = []
        let mut star = false
        let mut distinct = false
        if self.eat_op("*") {
          star = true
        } else if !self.is_op(")") {
          if self.eat_kw("DISTINCT") {
            distinct = true
          } else {
            let _ = self.eat_kw("ALL")
          }
          while true {
            args.push(self.parse_expr())
            if !self.eat_op(",") {
              break
            }
          }
        }
        let order = self.parse_order_by()
        self.expect_op(")")
        let mut filter : Expr? = None
        if self.is_kw("FILTER") &&
          self.peek_at(1).kind == TOp &&
          self.peek_at(1).text == "(" {
          self.pos += 2
          self.expect_kw("WHERE")
          filter = Some(self.parse_expr())
          self.expect_op(")")
        }
        if self.eat_kw("OVER") {
          let over = if self.eat_op("(") {
            let def = self.parse_window_def()
            self.expect_op(")")
            OverDef(def)
          } else {
            OverName(self.parse_name())
          }
          return WinCall({
            name: t.upper,
            args,
            star,
            distinct,
            filter,
            order,
            over,
          })
        }
        return Func(
          name=t.upper,
          args~,
          star~,
          distinct~,
          coll=CBinary,
          filter~,
          order~,
        )
      }
      if self.is_op(".") {
        self.pos += 1
        let col = self.parse_name()
        if self.eat_op(".") {
          let col2 = self.parse_name()
          return Column(tbl=Some(col), name=col2, dq=false)
        }
        return Column(tbl=Some(t.text), name=col, dq=false)
      }
      Column(tbl=None, name=t.text, dq=false)
    }
    _ => raise self.fail()
  }
}

///|
fn Parser::parse_case(self : Parser) -> Expr raise SqlError {
  let base = if self.is_kw("WHEN") { None } else { Some(self.parse_expr()) }
  let whens : Array[(Expr, Expr)] = []
  while self.eat_kw("WHEN") {
    let c = self.parse_expr()
    self.expect_kw("THEN")
    let v = self.parse_expr()
    whens.push((c, v))
  }
  if whens.length() == 0 {
    raise self.fail()
  }
  let else_ = if self.eat_kw("ELSE") { Some(self.parse_expr()) } else { None }
  self.expect_kw("END")
  Case(base~, whens~, else_~, infos=[])
}

///|
/// Type name as in a column definition: words plus optional (n [, m]).
fn Parser::parse_type_name(self : Parser) -> String raise SqlError {
  let words : Array[String] = []
  while true {
    let t = self.peek()
    match t.kind {
      TIdent if !(t.upper == "AS" && words.length() > 0) => {
        self.pos += 1
        words.push(t.text)
      }
      TQuoted | TBracket if words.length() == 0 => {
        self.pos += 1
        words.push(t.text)
      }
      _ => break
    }
  }
  let mut type_name = words.join(" ")
  if words.length() > 0 && self.eat_op("(") {
    let a = self.parse_signed_number_text()
    type_name = type_name + "(" + a
    if self.eat_op(",") {
      let b = self.parse_signed_number_text()
      type_name = type_name + "," + b
    }
    self.expect_op(")")
    type_name = type_name + ")"
  }
  type_name
}

///|
/// Inside `OVER (...)` or `WINDOW name AS (...)`.
fn Parser::parse_window_def(self : Parser) -> WinDef raise SqlError {
  let mut base : String? = None
  if self.at_name() &&
    !(self.is_kw("PARTITION") ||
    self.is_kw("ORDER") ||
    self.is_kw("ROWS") ||
    self.is_kw("RANGE") ||
    self.is_kw("GROUPS")) {
    base = Some(self.parse_name())
  }
  let partition : Array[Expr] = []
  if self.eat_kw("PARTITION") {
    self.expect_kw("BY")
    while true {
      partition.push(self.parse_expr())
      if !self.eat_op(",") {
        break
      }
    }
  }
  let order = self.parse_order_by()
  let mut frame : Frame? = None
  let unit = if self.eat_kw("ROWS") {
    Some(FRows)
  } else if self.eat_kw("RANGE") {
    Some(FRange)
  } else if self.eat_kw("GROUPS") {
    Some(FGroups)
  } else {
    None
  }
  if unit is Some(u) {
    let (start, end) = if self.eat_kw("BETWEEN") {
      let s = self.parse_frame_bound(true)
      self.expect_kw("AND")
      (s, self.parse_frame_bound(false))
    } else {
      (self.parse_frame_bound(true), CurRow)
    }
    let bad = match (start, end) {
      (CurRow, Pre(_)) => true
      (Fol(_), Pre(_) | CurRow) => true
      _ => false
    }
    if bad {
      raise sql_err("unsupported frame specification")
    }
    let mut exclude = ExNone
    if self.eat_kw("EXCLUDE") {
      if self.eat_kw("NO") {
        self.expect_kw("OTHERS")
      } else if self.eat_kw("CURRENT") {
        self.expect_kw("ROW")
        exclude = ExCurrent
      } else if self.eat_kw("GROUP") {
        exclude = ExGroup
      } else if self.eat_kw("TIES") {
        exclude = ExTies
      } else {
        raise self.fail()
      }
    }
    frame = Some({ unit: u, start, end, exclude, })
  }
  { base, partition, order, frame, }
}

///|
fn Parser::parse_frame_bound(
  self : Parser,
  is_start : Bool,
) -> FrameBound raise SqlError {
  if self.is_kw("UNBOUNDED") {
    self.pos += 1
    if is_start {
      self.expect_kw("PRECEDING")
      UnbPre
    } else {
      self.expect_kw("FOLLOWING")
      UnbFol
    }
  } else if self.is_kw("CURRENT") && self.is_kw_at(1, "ROW") {
    self.pos += 2
    CurRow
  } else {
    let e = self.parse_expr()
    if self.eat_kw("PRECEDING") {
      Pre(e)
    } else if self.eat_kw("FOLLOWING") {
      Fol(e)
    } else {
      raise self.fail()
    }
  }
}
