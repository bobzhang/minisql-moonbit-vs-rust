///|
priv struct Parser {
  src : String
  toks : Array[Token]
  mut pos : Int
}

///|
let reserved_words : Set[String] = Set([
  "ALL", "ALTER", "AND", "AS", "AUTOINCREMENT", "BETWEEN", "CASE", "CHECK", "COLLATE",
  "COMMIT", "CONSTRAINT", "CREATE", "CROSS", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
  "DEFAULT", "DEFERRABLE", "DELETE", "DISTINCT", "DROP", "ELSE", "ESCAPE", "EXCEPT",
  "EXISTS", "FOREIGN", "FROM", "FULL", "GROUP", "HAVING", "IN", "INDEX", "INNER",
  "INSERT", "INTERSECT", "INTO", "IS", "ISNULL", "JOIN", "LEFT", "LIMIT", "NATURAL",
  "NOT", "NOTNULL", "NULL", "ON", "OR", "ORDER", "OUTER", "PRIMARY", "REFERENCES",
  "RETURNING", "RIGHT", "ROLLBACK", "SELECT", "SET", "TABLE", "THEN", "TO", "TRANSACTION",
  "UNION", "UNIQUE", "UPDATE", "USING", "VALUES", "WHEN", "WHERE", "WINDOW", "FILTER",
  "OVER", "LIKE", "GLOB", "REGEXP", "MATCH", "END", "WITH",
])

///|
pub fn parse_statement(sql : String) -> Stmt raise SqlError {
  let toks = tokenize(sql)
  let p : Parser = { src: sql, toks, pos: 0, }
  // skip leading/trailing ';' pieces are handled by the splitter
  let st = p.statement()
  if p.peek().kind != TEof {
    raise p.syntax_error()
  }
  st
}

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
fn Parser::syntax_error(self : Parser) -> SqlError {
  let t = self.peek()
  if t.kind == TEof {
    SqlError("incomplete input")
  } else {
    let txt = match t.kind {
      TString => "'" + t.text + "'"
      TQuoted => "\"" + t.text + "\""
      TBlob => "x'" + t.text + "'"
      _ => t.text
    }
    SqlError("near \"\{txt}\": syntax error")
  }
}

///|
fn tok_is_kw(t : Token, kw : String) -> Bool {
  t.kind == TIdent && t.text.equal_ignore_ascii_case(kw)
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
    raise self.syntax_error()
  }
}

///|
fn is_reserved(t : Token) -> Bool {
  t.kind == TIdent && reserved_words.contains(t.text.to_upper())
}

///|
/// A name token: identifier (non-reserved), quoted identifier or string.
fn Parser::is_name(self : Parser) -> Bool {
  let t = self.peek()
  match t.kind {
    TIdent => !is_reserved(t)
    TQuoted | TBracket | TString => true
    _ => false
  }
}

///|
fn Parser::name(self : Parser) -> String raise SqlError {
  if self.is_name() {
    self.advance().text
  } else {
    raise self.syntax_error()
  }
}

///|
fn Parser::statement(self : Parser) -> Stmt raise SqlError {
  if self.is_kw("SELECT") || self.is_kw("VALUES") {
    return SelectStmt(self.select())
  }
  if self.is_kw("WITH") {
    let save = self.pos
    ignore(self.advance())
    let ctes = self.with_clause()
    if self.is_kw("SELECT") || self.is_kw("VALUES") {
      self.pos = save
      return SelectStmt(self.select())
    }
    if self.is_kw("INSERT") ||
      self.is_kw("REPLACE") ||
      self.is_kw("UPDATE") ||
      self.is_kw("DELETE") {
      return WithStmt(ctes, self.statement())
    }
    raise self.syntax_error()
  }
  if self.eat_kw("CREATE") {
    if self.eat_kw("TABLE") {
      return CreateTableStmt(self.create_table())
    }
    if self.eat_kw("UNIQUE") {
      self.expect_kw("INDEX")
      return CreateIndexStmt(self.create_index(true))
    }
    if self.eat_kw("INDEX") {
      return CreateIndexStmt(self.create_index(false))
    }
    if self.eat_kw("VIEW") {
      return CreateViewStmt(self.create_view())
    }
    raise self.syntax_error()
  }
  if self.eat_kw("DROP") {
    let kind = if self.eat_kw("TABLE") {
      0
    } else if self.eat_kw("INDEX") {
      1
    } else if self.eat_kw("VIEW") {
      2
    } else {
      raise self.syntax_error()
    }
    let mut if_exists = false
    if self.eat_kw("IF") {
      self.expect_kw("EXISTS")
      if_exists = true
    }
    let name = self.qualified_name()
    return match kind {
      0 => DropTableStmt(name, if_exists)
      1 => DropIndexStmt(name, if_exists)
      _ => DropViewStmt(name, if_exists)
    }
  }
  if self.eat_kw("ALTER") {
    self.expect_kw("TABLE")
    let name = self.qualified_name()
    if self.eat_kw("RENAME") {
      if self.eat_kw("TO") {
        return AlterStmt(name, RenameTo(self.name()))
      }
      ignore(self.eat_kw("COLUMN"))
      let old = self.name()
      self.expect_kw("TO")
      return AlterStmt(name, RenameColumn(old, self.name()))
    }
    if self.eat_kw("ADD") {
      ignore(self.eat_kw("COLUMN"))
      let start = self.peek().pos
      let cd = self.column_def()
      let text = trim_coldef(self.src[start:self.peek().pos].to_owned())
      return AlterStmt(name, AddColumn(cd, text))
    }
    if self.eat_kw("DROP") {
      ignore(self.eat_kw("COLUMN"))
      return AlterStmt(name, DropColumn(self.name()))
    }
    raise self.syntax_error()
  }
  if self.eat_kw("BEGIN") {
    if !self.eat_kw("DEFERRED") && !self.eat_kw("IMMEDIATE") {
      ignore(self.eat_kw("EXCLUSIVE"))
    }
    if self.eat_kw("TRANSACTION") && self.is_name() {
      ignore(self.advance())
    }
    return BeginStmt
  }
  if self.eat_kw("COMMIT") || self.eat_kw("END") {
    if self.eat_kw("TRANSACTION") && self.is_name() {
      ignore(self.advance())
    }
    return CommitStmt
  }
  if self.eat_kw("ROLLBACK") {
    if self.eat_kw("TRANSACTION") && self.is_name() && !self.is_kw("TO") {
      ignore(self.advance())
    }
    if self.eat_kw("TO") {
      ignore(self.eat_kw("SAVEPOINT"))
      return RollbackStmt(Some(self.name()))
    }
    return RollbackStmt(None)
  }
  if self.eat_kw("SAVEPOINT") {
    return SavepointStmt(self.name())
  }
  if self.eat_kw("RELEASE") {
    ignore(self.eat_kw("SAVEPOINT"))
    return ReleaseStmt(self.name())
  }
  if self.eat_kw("INSERT") {
    let mut oc = CDefault
    if self.eat_kw("OR") {
      oc = self.conflict_algo()
    }
    return InsertStmt(self.insert(oc))
  }
  if self.eat_kw("REPLACE") {
    return InsertStmt(self.insert(CReplace))
  }
  if self.eat_kw("UPDATE") {
    return UpdateStmt(self.update())
  }
  if self.eat_kw("DELETE") {
    return DeleteStmt(self.delete())
  }
  raise self.syntax_error()
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
fn Parser::create_index(
  self : Parser,
  unique : Bool,
) -> CreateIndex raise SqlError {
  let if_not_exists = self.if_not_exists()
  let name_pos = self.peek().pos
  let name = self.qualified_name()
  self.expect_kw("ON")
  let table = self.name()
  self.expect_op("(")
  let parts : Array[IndexPart] = []
  while true {
    let mut e = self.expr()
    let mut coll : String? = None
    while e is Collate(inner, c) {
      if coll is None {
        coll = Some(c)
      }
      e = inner
    }
    let mut desc = false
    if self.eat_kw("DESC") {
      desc = true
    } else {
      ignore(self.eat_kw("ASC"))
    }
    parts.push({ expr: e, coll, desc, })
    if !self.eat_op(",") {
      break
    }
  }
  self.expect_op(")")
  let where_ = if self.eat_kw("WHERE") { Some(self.expr()) } else { None }
  let sql = (if unique { "CREATE UNIQUE INDEX " } else { "CREATE INDEX " }) +
    self.src[name_pos:].to_owned()
  { name, table, unique, if_not_exists, parts, where_, sql, }
}

///|
fn Parser::create_view(self : Parser) -> CreateView raise SqlError {
  let if_not_exists = self.if_not_exists()
  let name_pos = self.peek().pos
  let name = self.qualified_name()
  let cols = if self.is_op("(") { Some(self.name_list()) } else { None }
  self.expect_kw("AS")
  let query = self.select()
  let sql = "CREATE VIEW " + self.src[name_pos:].to_owned()
  { name, if_not_exists, cols, query, sql, }
}

///|
/// `[schema.]name`; the schema is ignored.
fn Parser::qualified_name(self : Parser) -> String raise SqlError {
  let n = self.name()
  if self.eat_op(".") {
    self.name()
  } else {
    n
  }
}

///|
fn Parser::create_table(self : Parser) -> CreateTable raise SqlError {
  let mut if_not_exists = false
  if self.eat_kw("IF") {
    self.expect_kw("NOT")
    self.expect_kw("EXISTS")
    if_not_exists = true
  }
  let name_pos = self.peek().pos
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
      // table constraints (possibly several, comma separated)
      constraints.push(self.table_constraint())
    } else {
      if constraints.length() > 0 {
        raise self.syntax_error()
      }
      columns.push(self.column_def())
    }
    if self.eat_op(",") {
      continue
    }
    self.expect_op(")")
    break
  }
  // table options (WITHOUT ROWID, STRICT)
  while self.is_name() {
    ignore(self.advance())
    ignore(self.eat_op(","))
  }
  {
    name,
    if_not_exists,
    columns,
    constraints,
    sql: "CREATE TABLE " + self.src[name_pos:].to_owned(),
  }
}

///|
fn is_constraint_start(t : Token) -> Bool {
  tok_is_kw(t, "CONSTRAINT") ||
  tok_is_kw(t, "PRIMARY") ||
  tok_is_kw(t, "NOT") ||
  tok_is_kw(t, "NULL") ||
  tok_is_kw(t, "UNIQUE") ||
  tok_is_kw(t, "CHECK") ||
  tok_is_kw(t, "DEFAULT") ||
  tok_is_kw(t, "COLLATE") ||
  tok_is_kw(t, "REFERENCES") ||
  tok_is_kw(t, "GENERATED") ||
  tok_is_kw(t, "AS")
}

///|
fn Parser::signed_number_text(self : Parser) -> String raise SqlError {
  let mut s = ""
  if self.is_op("+") || self.is_op("-") {
    s = self.advance().text
  }
  let t = self.peek()
  if t.kind == TInteger || t.kind == TFloat {
    ignore(self.advance())
    s + t.text
  } else if t.kind == TIdent && s == "" {
    ignore(self.advance())
    t.text
  } else {
    raise self.syntax_error()
  }
}

///|
fn Parser::column_def(self : Parser) -> ColumnDef raise SqlError {
  let name = self.name()
  // type name
  let words : Array[String] = []
  while true {
    let t = self.peek()
    if (t.kind == TIdent || t.kind == TQuoted || t.kind == TString) &&
      !is_constraint_start(t) {
      words.push(self.advance().text)
    } else {
      break
    }
  }
  let mut decl_type = words.join(" ")
  if words.length() > 0 && self.eat_op("(") {
    let a = self.signed_number_text()
    if self.eat_op(",") {
      let b = self.signed_number_text()
      decl_type = decl_type + "(" + a + "," + b + ")"
    } else {
      decl_type = decl_type + "(" + a + ")"
    }
    self.expect_op(")")
  }
  let col : ColumnDef = {
    name,
    decl_type,
    primary_key: false,
    pk_desc: false,
    pk_conflict: CDefault,
    autoincrement: false,
    not_null: false,
    nn_conflict: CDefault,
    unique: false,
    unique_conflict: CDefault,
    default: None,
    checks: [],
    collate: None,
  }
  let mut cname : String? = None
  while true {
    if self.eat_kw("CONSTRAINT") {
      cname = Some(self.name())
      continue
    }
    if self.eat_kw("PRIMARY") {
      self.expect_kw("KEY")
      if col.primary_key {
        raise SqlError("table has more than one primary key")
      }
      col.primary_key = true
      if self.eat_kw("DESC") {
        col.pk_desc = true
      } else {
        ignore(self.eat_kw("ASC"))
      }
      col.pk_conflict = self.conflict_clause()
      if self.eat_kw("AUTOINCREMENT") {
        col.autoincrement = true
      }
      continue
    }
    if self.eat_kw("NOT") {
      self.expect_kw("NULL")
      col.not_null = true
      col.nn_conflict = self.conflict_clause()
      cname = None
      continue
    }
    if self.eat_kw("NULL") {
      ignore(self.conflict_clause())
      continue
    }
    if self.eat_kw("UNIQUE") {
      col.unique = true
      col.unique_conflict = self.conflict_clause()
      cname = None
      continue
    }
    if self.eat_kw("CHECK") {
      col.checks.push(self.check_body(cname))
      cname = None
      continue
    }
    if self.eat_kw("DEFAULT") {
      col.default = Some(self.default_value())
      continue
    }
    if self.eat_kw("COLLATE") {
      col.collate = Some(self.name())
      continue
    }
    if self.is_kw("REFERENCES") {
      self.foreign_key_clause()
      continue
    }
    if self.is_kw("GENERATED") || self.is_kw("AS") {
      if self.eat_kw("GENERATED") {
        self.expect_kw("ALWAYS")
      }
      self.expect_kw("AS")
      self.expect_op("(")
      ignore(self.expr())
      self.expect_op(")")
      if !self.eat_kw("STORED") {
        ignore(self.eat_kw("VIRTUAL"))
      }
      continue
    }
    break
  }
  col
}

///|
fn Parser::default_value(self : Parser) -> Expr raise SqlError {
  if self.eat_op("(") {
    let e = self.expr()
    self.expect_op(")")
    return e
  }
  if self.eat_op("-") {
    let e = self.primary()
    return Unary(Neg, e)
  }
  if self.eat_op("+") {
    return self.primary()
  }
  let t = self.peek()
  match t.kind {
    TString | TInteger | TFloat | TBlob => self.primary()
    TIdent => {
      ignore(self.advance())
      if tok_is_kw(t, "NULL") {
        Lit(Null)
      } else if tok_is_kw(t, "TRUE") {
        Lit(Int(1L))
      } else if tok_is_kw(t, "FALSE") {
        Lit(Int(0L))
      } else {
        // bare identifiers are allowed as string defaults
        Lit(Text(t.text))
      }
    }
    TQuoted => {
      ignore(self.advance())
      Lit(Text(t.text))
    }
    _ => raise self.syntax_error()
  }
}

///|
fn Parser::conflict_clause(self : Parser) -> Conflict raise SqlError {
  if self.is_kw("ON") && self.is_kw_at(1, "CONFLICT") {
    self.pos += 2
    self.conflict_algo()
  } else {
    CDefault
  }
}

///|
fn Parser::conflict_algo(self : Parser) -> Conflict raise SqlError {
  let t = self.peek()
  let c = if tok_is_kw(t, "ROLLBACK") {
    CRollback
  } else if tok_is_kw(t, "ABORT") {
    CAbort
  } else if tok_is_kw(t, "FAIL") {
    CFail
  } else if tok_is_kw(t, "IGNORE") {
    CIgnore
  } else if tok_is_kw(t, "REPLACE") {
    CReplace
  } else {
    raise self.syntax_error()
  }
  ignore(self.advance())
  c
}

///|
/// `( expr )` after CHECK, remembering the expression's source text.
fn Parser::check_body(self : Parser, name : String?) -> CheckDef raise SqlError {
  self.expect_op("(")
  let start = self.peek().pos
  let e = self.expr()
  let end = self.peek().pos
  self.expect_op(")")
  { expr: e, name, text: self.src[start:end].trim_end().to_owned(), }
}

///|
fn Parser::name_list(self : Parser) -> Array[String] raise SqlError {
  self.expect_op("(")
  let names : Array[String] = []
  while true {
    names.push(self.name())
    if !self.eat_op(",") {
      break
    }
  }
  self.expect_op(")")
  names
}

///|
/// `(col [COLLATE c] [ASC|DESC] [AUTOINCREMENT], ...)` returning the column
/// names and whether AUTOINCREMENT was given.
fn Parser::indexed_columns(
  self : Parser,
) -> (Array[String], Bool) raise SqlError {
  self.expect_op("(")
  let names : Array[String] = []
  let mut autoinc = false
  while true {
    names.push(self.name())
    if self.eat_kw("COLLATE") {
      ignore(self.name())
    }
    if !self.eat_kw("ASC") {
      ignore(self.eat_kw("DESC"))
    }
    if self.eat_kw("AUTOINCREMENT") {
      autoinc = true
    }
    if !self.eat_op(",") {
      break
    }
  }
  self.expect_op(")")
  (names, autoinc)
}

///|
fn Parser::foreign_key_clause(self : Parser) -> Unit raise SqlError {
  self.expect_kw("REFERENCES")
  ignore(self.name())
  if self.is_op("(") {
    ignore(self.name_list())
  }
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
      } else {
        self.expect_kw("NO")
        self.expect_kw("ACTION")
      }
      continue
    }
    if self.eat_kw("MATCH") {
      ignore(self.name())
      continue
    }
    if self.is_kw("DEFERRABLE") ||
      (self.is_kw("NOT") && self.is_kw_at(1, "DEFERRABLE")) {
      ignore(self.eat_kw("NOT"))
      self.expect_kw("DEFERRABLE")
      if self.eat_kw("INITIALLY") {
        if !self.eat_kw("DEFERRED") {
          self.expect_kw("IMMEDIATE")
        }
      }
      continue
    }
    break
  }
}

///|
fn Parser::table_constraint(self : Parser) -> TableConstraint raise SqlError {
  let mut cname = None
  if self.eat_kw("CONSTRAINT") {
    cname = Some(self.name())
  }
  if self.eat_kw("PRIMARY") {
    self.expect_kw("KEY")
    let (cols, autoinc) = self.indexed_columns()
    let c = self.conflict_clause()
    return PrimaryKey(cols, c, autoinc)
  }
  if self.eat_kw("UNIQUE") {
    let (cols, _) = self.indexed_columns()
    let c = self.conflict_clause()
    return Unique(cols, c)
  }
  if self.eat_kw("CHECK") {
    return Check(self.check_body(cname))
  }
  if self.eat_kw("FOREIGN") {
    self.expect_kw("KEY")
    ignore(self.name_list())
    self.foreign_key_clause()
    return ForeignKey
  }
  raise self.syntax_error()
}

///|
fn Parser::insert(
  self : Parser,
  or_conflict : Conflict,
) -> Insert raise SqlError {
  self.expect_kw("INTO")
  let table = self.qualified_name()
  let as_name = if self.eat_kw("AS") { Some(self.name()) } else { None }
  let columns = if self.is_op("(") { Some(self.name_list()) } else { None }
  let source = if self.eat_kw("DEFAULT") {
    self.expect_kw("VALUES")
    DefaultValues
  } else if self.is_kw("VALUES") && self.peek_at(1).text == "(" {
    ignore(self.advance())
    Values(self.values_rows())
  } else if self.is_query_start() {
    FromSelect(self.select())
  } else {
    raise self.syntax_error()
  }
  let upsert : Array[Upsert] = []
  while self.is_kw("ON") && self.is_kw_at(1, "CONFLICT") {
    self.pos += 2
    let mut target = None
    let mut target_where = None
    if self.is_op("(") {
      target = Some(self.indexed_columns().0)
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
    upsert.push({ target, target_where, action, })
  }
  let returning = self.returning_clause()
  { or_conflict, table, as_name, columns, source, upsert, returning, }
}

///|
fn Parser::set_list(self : Parser) -> Array[(String, Expr)] raise SqlError {
  let sets : Array[(String, Expr)] = []
  while true {
    if self.is_op("(") {
      let names = self.name_list()
      self.expect_op("=")
      self.expect_op("(")
      let vals : Array[Expr] = []
      while true {
        vals.push(self.expr())
        if !self.eat_op(",") {
          break
        }
      }
      self.expect_op(")")
      if vals.length() != names.length() {
        raise SqlError(
          "\{names.length()} columns assigned \{vals.length()} values",
        )
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
  let cols : Array[ResultCol] = []
  if self.eat_kw("RETURNING") {
    while true {
      cols.push(self.result_col())
      if !self.eat_op(",") {
        break
      }
    }
  }
  cols
}

///|
fn Parser::update(self : Parser) -> Update raise SqlError {
  let mut or_conflict = CDefault
  if self.eat_kw("OR") {
    or_conflict = self.conflict_algo()
  }
  let table = self.qualified_name()
  let as_name = if self.eat_kw("AS") {
    Some(self.name())
  } else if self.is_name() && !self.is_kw("SET") {
    Some(self.name())
  } else {
    None
  }
  self.expect_kw("SET")
  let sets = self.set_list()
  let where_ = if self.eat_kw("WHERE") { Some(self.expr()) } else { None }
  let returning = self.returning_clause()
  { or_conflict, table, as_name, sets, where_, returning, }
}

///|
fn Parser::delete(self : Parser) -> Delete raise SqlError {
  self.expect_kw("FROM")
  let table = self.qualified_name()
  let as_name = if self.eat_kw("AS") { Some(self.name()) } else { None }
  let where_ = if self.eat_kw("WHERE") { Some(self.expr()) } else { None }
  let returning = self.returning_clause()
  { table, as_name, where_, returning, }
}

///|
fn Parser::values_rows(self : Parser) -> Array[Array[Expr]] raise SqlError {
  let rows : Array[Array[Expr]] = []
  while true {
    self.expect_op("(")
    let row : Array[Expr] = []
    while true {
      row.push(self.expr())
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

///|
fn Parser::is_query_start(self : Parser) -> Bool {
  self.is_kw("SELECT") || self.is_kw("VALUES") || self.is_kw("WITH")
}

///|
/// `SELECT * FROM name`.
fn table_select(name : String) -> Select {
  {
    distinct: false,
    columns: [Star],
    from: Some(TableRef(name~, as_name=None)),
    where_: None,
    group_by: [],
    having: None,
    values: None,
    compound: [],
    order_by: [],
    limit: None,
    offset: None,
    with_: [],
    windows: [],
  }
}

///|
/// The common table expressions of a WITH clause (after `WITH`).
fn Parser::with_clause(self : Parser) -> Array[CteDecl] raise SqlError {
  ignore(self.eat_kw("RECURSIVE"))
  let ctes : Array[CteDecl] = []
  while true {
    let name = self.name()
    let cols = if self.is_op("(") { Some(self.name_list()) } else { None }
    self.expect_kw("AS")
    if self.eat_kw("NOT") {
      self.expect_kw("MATERIALIZED")
    } else {
      ignore(self.eat_kw("MATERIALIZED"))
    }
    self.expect_op("(")
    let query = self.select()
    self.expect_op(")")
    ctes.push({ name, cols, query, })
    if !self.eat_op(",") {
      break
    }
  }
  ctes
}

///|
/// A window definition inside parentheses (after `(`, up to `)`).
fn Parser::window_spec(self : Parser) -> WindowSpec raise SqlError {
  let mut base : String? = None
  if self.is_name() &&
    !self.is_kw("PARTITION") &&
    !self.is_kw("ORDER") &&
    !self.is_kw("ROWS") &&
    !self.is_kw("RANGE") &&
    !self.is_kw("GROUPS") {
    base = Some(self.name())
  }
  let partition : Array[Expr] = []
  if self.eat_kw("PARTITION") {
    self.expect_kw("BY")
    while true {
      partition.push(self.expr())
      if !self.eat_op(",") {
        break
      }
    }
  }
  let order = if self.is_kw("ORDER") { self.order_by_clause() } else { [] }
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
      let a = self.frame_bound(true)
      self.expect_kw("AND")
      (a, self.frame_bound(false))
    } else {
      (self.frame_bound(true), CurrentRow)
    }
    let mut exclude = ExNoOthers
    if self.eat_kw("EXCLUDE") {
      if self.eat_kw("NO") {
        self.expect_kw("OTHERS")
      } else if self.eat_kw("CURRENT") {
        self.expect_kw("ROW")
        exclude = ExCurrentRow
      } else if self.eat_kw("GROUP") {
        exclude = ExGroup
      } else {
        self.expect_kw("TIES")
        exclude = ExTies
      }
    }
    frame = Some({ unit: u, start, end, exclude, })
  }
  { base, partition, order, frame, named_only: false, }
}

///|
fn Parser::frame_bound(
  self : Parser,
  is_start : Bool,
) -> FrameBound raise SqlError {
  if self.is_kw("UNBOUNDED") {
    ignore(self.advance())
    if is_start {
      self.expect_kw("PRECEDING")
      return UnboundedPreceding
    }
    self.expect_kw("FOLLOWING")
    return UnboundedFollowing
  }
  if self.is_kw("CURRENT") && self.is_kw_at(1, "ROW") {
    self.pos += 2
    return CurrentRow
  }
  let e = self.expr()
  if self.eat_kw("PRECEDING") {
    Preceding(e)
  } else {
    self.expect_kw("FOLLOWING")
    Following(e)
  }
}

///|
/// A full query: compound of cores, then ORDER BY / LIMIT.
fn Parser::select(self : Parser) -> Select raise SqlError {
  let with_ = if self.eat_kw("WITH") { self.with_clause() } else { [] }
  let first = self.select_core()
  let compound : Array[(CompoundOp, Select)] = []
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
    compound.push((op, self.select_core()))
  }
  let order_by = self.order_by_clause()
  let mut limit = None
  let mut offset = None
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
  { ..first, compound, order_by, limit, offset, with_, }
}

///|
fn Parser::select_core(self : Parser) -> Select raise SqlError {
  if self.eat_kw("VALUES") {
    let rows = self.values_rows()
    return {
      distinct: false,
      columns: [],
      from: None,
      where_: None,
      group_by: [],
      having: None,
      values: Some(rows),
      compound: [],
      order_by: [],
      limit: None,
      offset: None,
      with_: [],
      windows: [],
    }
  }
  self.expect_kw("SELECT")
  let mut distinct = false
  if self.eat_kw("DISTINCT") {
    distinct = true
  } else {
    ignore(self.eat_kw("ALL"))
  }
  let columns : Array[ResultCol] = []
  while true {
    columns.push(self.result_col())
    if !self.eat_op(",") {
      break
    }
  }
  let mut from = None
  if self.eat_kw("FROM") {
    from = Some(self.from_clause())
  }
  let where_ = if self.eat_kw("WHERE") { Some(self.expr()) } else { None }
  let group_by : Array[Expr] = []
  let mut having = None
  if self.eat_kw("GROUP") {
    self.expect_kw("BY")
    while true {
      group_by.push(self.expr())
      if !self.eat_op(",") {
        break
      }
    }
  }
  if self.eat_kw("HAVING") {
    having = Some(self.expr())
  }
  let windows : Array[(String, WindowSpec)] = []
  if self.eat_kw("WINDOW") {
    while true {
      let name = self.name()
      self.expect_kw("AS")
      self.expect_op("(")
      windows.push((name, self.window_spec()))
      self.expect_op(")")
      if !self.eat_op(",") {
        break
      }
    }
  }
  {
    distinct,
    columns,
    from,
    where_,
    group_by,
    having,
    values: None,
    compound: [],
    order_by: [],
    limit: None,
    offset: None,
    with_: [],
    windows,
  }
}

///|
fn Parser::order_by_clause(self : Parser) -> Array[OrderTerm] raise SqlError {
  let terms : Array[OrderTerm] = []
  if self.eat_kw("ORDER") {
    self.expect_kw("BY")
    while true {
      let e = self.expr()
      let mut desc = false
      if self.eat_kw("DESC") {
        desc = true
      } else {
        ignore(self.eat_kw("ASC"))
      }
      let mut nulls = 0
      if self.eat_kw("NULLS") {
        if self.eat_kw("FIRST") {
          nulls = 1
        } else {
          self.expect_kw("LAST")
          nulls = 2
        }
      }
      terms.push({ expr: e, desc, nulls, })
      if !self.eat_op(",") {
        break
      }
    }
  }
  terms
}

///|
fn Parser::result_col(self : Parser) -> ResultCol raise SqlError {
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
  let e = self.expr()
  let end = self.peek().pos
  let text = self.src[start:end].trim_end().to_owned()
  let as_name = self.opt_alias()
  ExprCol(e, as_name, text)
}

///|
fn Parser::opt_alias(self : Parser) -> String? raise SqlError {
  if self.eat_kw("AS") {
    return Some(self.name())
  }
  if self.is_name() {
    return Some(self.advance().text)
  }
  None
}

///|
/// A FROM clause: table-or-subquery items connected by joins.
fn Parser::from_clause(self : Parser) -> FromItem raise SqlError {
  let mut left = self.from_item()
  while true {
    if self.eat_op(",") {
      let right = self.from_item()
      left = Join(
        left~,
        right~,
        kind=JInner,
        natural=false,
        on=None,
        using_cols=None,
      )
      continue
    }
    let natural = self.eat_kw("NATURAL")
    let mut explicit = natural
    let kind = if self.eat_kw("LEFT") {
      ignore(self.eat_kw("OUTER"))
      JLeft
    } else if self.eat_kw("RIGHT") {
      ignore(self.eat_kw("OUTER"))
      JRight
    } else if self.eat_kw("FULL") {
      ignore(self.eat_kw("OUTER"))
      JFull
    } else {
      if self.eat_kw("INNER") || self.eat_kw("CROSS") {
        explicit = true
      }
      JInner
    }
    if !self.eat_kw("JOIN") {
      if explicit || kind != JInner {
        raise self.syntax_error()
      }
      break
    }
    let right = self.from_item()
    let mut on = None
    let mut using_cols = None
    if self.eat_kw("ON") {
      on = Some(self.expr())
    } else if self.eat_kw("USING") {
      using_cols = Some(self.name_list())
    }
    if natural && (on is Some(_) || using_cols is Some(_)) {
      raise SqlError("a NATURAL join may not have an ON or USING clause")
    }
    left = Join(left~, right~, kind~, natural~, on~, using_cols~)
  }
  left
}

///|
fn Parser::from_item(self : Parser) -> FromItem raise SqlError {
  if self.eat_op("(") {
    if self.is_query_start() {
      let q = self.select()
      self.expect_op(")")
      let as_name = self.opt_alias()
      return SubqueryRef(query=q, as_name~)
    }
    let inner = self.from_clause()
    self.expect_op(")")
    return inner
  }
  let name = self.qualified_name()
  let as_name = self.opt_alias()
  TableRef(name~, as_name~)
}

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

///|
fn Parser::expr(self : Parser) -> Expr raise SqlError {
  self.parse_or()
}

///|
fn Parser::parse_or(self : Parser) -> Expr raise SqlError {
  let mut e = self.parse_and()
  while self.eat_kw("OR") {
    e = Binary(Or, e, self.parse_and())
  }
  e
}

///|
fn Parser::parse_and(self : Parser) -> Expr raise SqlError {
  let mut e = self.parse_not()
  while self.eat_kw("AND") {
    e = Binary(And, e, self.parse_not())
  }
  e
}

///|
fn Parser::parse_not(self : Parser) -> Expr raise SqlError {
  if self.eat_kw("NOT") {
    return Unary(Not, self.parse_not())
  }
  self.parse_equality()
}

///|
fn Parser::parse_equality(self : Parser) -> Expr raise SqlError {
  let mut e = self.parse_comparison()
  while true {
    let t = self.peek()
    if t.kind == TOp {
      match t.text {
        "=" | "==" => {
          ignore(self.advance())
          e = Binary(Eq, e, self.parse_comparison())
          continue
        }
        "!=" | "<>" => {
          ignore(self.advance())
          e = Binary(Ne, e, self.parse_comparison())
          continue
        }
        _ => break
      }
    }
    if t.kind != TIdent {
      break
    }
    if self.eat_kw("ISNULL") {
      e = IsNull(e, false)
      continue
    }
    if self.eat_kw("NOTNULL") {
      e = IsNull(e, true)
      continue
    }
    if self.is_kw("NOT") && self.is_kw_at(1, "NULL") {
      self.pos += 2
      e = IsNull(e, true)
      continue
    }
    if self.eat_kw("IS") {
      let neg = self.eat_kw("NOT")
      if self.eat_kw("DISTINCT") {
        self.expect_kw("FROM")
        e = Is(e, self.parse_comparison(), !neg)
      } else {
        e = Is(e, self.parse_comparison(), neg)
      }
      continue
    }
    let mut neg = false
    let save = self.pos
    if self.eat_kw("NOT") {
      neg = true
    }
    if self.eat_kw("BETWEEN") {
      let lo = self.parse_comparison()
      self.expect_kw("AND")
      let hi = self.parse_comparison()
      e = Between(e, lo, hi, neg)
      continue
    }
    if self.eat_kw("IN") {
      if !self.is_op("(") && self.is_name() {
        // `x IN table`
        let name = self.qualified_name()
        e = InSelect(e, table_select(name), neg)
        continue
      }
      self.expect_op("(")
      if self.is_query_start() {
        let q = self.select()
        self.expect_op(")")
        e = InSelect(e, q, neg)
        continue
      }
      let items : Array[Expr] = []
      if !self.is_op(")") {
        while true {
          items.push(self.expr())
          if !self.eat_op(",") {
            break
          }
        }
      }
      self.expect_op(")")
      e = InList(e, items, neg)
      continue
    }
    if self.is_kw("LIKE") ||
      self.is_kw("GLOB") ||
      self.is_kw("REGEXP") ||
      self.is_kw("MATCH") {
      let op = self.advance().text.to_upper()
      let pat = self.parse_comparison()
      let esc = if self.eat_kw("ESCAPE") {
        Some(self.parse_comparison())
      } else {
        None
      }
      e = Like(op, e, pat, esc, neg)
      continue
    }
    self.pos = save
    break
  }
  e
}

///|
fn Parser::parse_comparison(self : Parser) -> Expr raise SqlError {
  let mut e = self.parse_bitwise()
  while true {
    let t = self.peek()
    if t.kind != TOp {
      break
    }
    let op = match t.text {
      "<" => Lt
      "<=" => Le
      ">" => Gt
      ">=" => Ge
      _ => break
    }
    ignore(self.advance())
    e = Binary(op, e, self.parse_bitwise())
  }
  e
}

///|
fn Parser::parse_bitwise(self : Parser) -> Expr raise SqlError {
  let mut e = self.parse_additive()
  while true {
    let t = self.peek()
    if t.kind != TOp {
      break
    }
    let op = match t.text {
      "&" => BitAnd
      "|" => BitOr
      "<<" => Shl
      ">>" => Shr
      _ => break
    }
    ignore(self.advance())
    e = Binary(op, e, self.parse_additive())
  }
  e
}

///|
fn Parser::parse_additive(self : Parser) -> Expr raise SqlError {
  let mut e = self.parse_multiplicative()
  while true {
    let t = self.peek()
    if t.kind != TOp {
      break
    }
    let op = match t.text {
      "+" => Add
      "-" => Sub
      _ => break
    }
    ignore(self.advance())
    e = Binary(op, e, self.parse_multiplicative())
  }
  e
}

///|
fn Parser::parse_multiplicative(self : Parser) -> Expr raise SqlError {
  let mut e = self.parse_concat()
  while true {
    let t = self.peek()
    if t.kind != TOp {
      break
    }
    let op = match t.text {
      "*" => Mul
      "/" => Div
      "%" => Rem
      _ => break
    }
    ignore(self.advance())
    e = Binary(op, e, self.parse_concat())
  }
  e
}

///|
fn Parser::parse_concat(self : Parser) -> Expr raise SqlError {
  let mut e = self.parse_collate()
  while self.eat_op("||") {
    e = Binary(Concat, e, self.parse_collate())
  }
  e
}

///|
fn Parser::parse_collate(self : Parser) -> Expr raise SqlError {
  let mut e = self.parse_unary()
  while self.eat_kw("COLLATE") {
    e = Collate(e, self.name())
  }
  e
}

///|
fn Parser::parse_unary(self : Parser) -> Expr raise SqlError {
  let t = self.peek()
  if t.kind == TOp {
    match t.text {
      "-" => {
        ignore(self.advance())
        let n = self.peek()
        if n.kind == TInteger &&
          n.text == "9223372036854775808" &&
          !self.is_collate_at(1) {
          ignore(self.advance())
          return Lit(Int(@int64.MIN_VALUE))
        }
        return Unary(Neg, self.parse_unary())
      }
      "+" => {
        ignore(self.advance())
        return Unary(Pos, self.parse_unary())
      }
      "~" => {
        ignore(self.advance())
        return Unary(BitNot, self.parse_unary())
      }
      _ => ()
    }
  }
  self.primary()
}

///|
fn Parser::is_collate_at(self : Parser, k : Int) -> Bool {
  self.is_kw_at(k, "COLLATE")
}

///|
fn integer_literal(text : String) -> Value raise SqlError {
  if text.length() > 2 && (text[1] == 'x' || text[1] == 'X') {
    let hex = text[2:]
    let mut v = 0L
    let mut sig = 0
    for i in 0..<hex.length() {
      let c = hex[i].to_int()
      let d = if c >= '0'.to_int() && c <= '9'.to_int() {
        c - '0'.to_int()
      } else if c >= 'a'.to_int() && c <= 'f'.to_int() {
        c - 'a'.to_int() + 10
      } else {
        c - 'A'.to_int() + 10
      }
      if sig > 0 || d != 0 {
        sig += 1
      }
      v = (v << 4) | d.to_int64()
    }
    if sig > 16 {
      raise SqlError("hex literal too big: \{text}")
    }
    return Int(v)
  }
  match parse_int_text(text) {
    Some(v) => Int(v)
    None => Real(parse_real_text(text))
  }
}

///|
fn hex_to_bytes(hex : String) -> Bytes {
  let n = hex.length() / 2
  let arr = FixedArray::make(n, b'\x00')
  fn hv(c : Int) -> Int {
    if c >= '0'.to_int() && c <= '9'.to_int() {
      c - '0'.to_int()
    } else if c >= 'a'.to_int() && c <= 'f'.to_int() {
      c - 'a'.to_int() + 10
    } else {
      c - 'A'.to_int() + 10
    }
  }
  for i in 0..<n {
    arr[i] = ((hv(hex[2 * i].to_int()) << 4) | hv(hex[2 * i + 1].to_int())).to_byte()
  }
  Bytes::from_array(arr[:])
}

///|
fn Parser::primary(self : Parser) -> Expr raise SqlError {
  let t = self.peek()
  match t.kind {
    TInteger => {
      ignore(self.advance())
      Lit(integer_literal(t.text))
    }
    TFloat => {
      ignore(self.advance())
      Lit(Real(parse_real_text(t.text)))
    }
    TString => {
      ignore(self.advance())
      Lit(Text(t.text))
    }
    TBlob => {
      ignore(self.advance())
      Lit(Blob(hex_to_bytes(t.text)))
    }
    TOp =>
      if t.text == "(" {
        ignore(self.advance())
        if self.is_query_start() {
          let q = self.select()
          self.expect_op(")")
          return Subquery(q)
        }
        let e = self.expr()
        self.expect_op(")")
        e
      } else {
        raise self.syntax_error()
      }
    TEof => raise self.syntax_error()
    TIdent | TQuoted | TBracket => {
      if t.kind == TIdent {
        if tok_is_kw(t, "NULL") {
          ignore(self.advance())
          return Lit(Null)
        }
        if tok_is_kw(t, "TRUE") {
          ignore(self.advance())
          return Lit(Int(1L))
        }
        if tok_is_kw(t, "FALSE") {
          ignore(self.advance())
          return Lit(Int(0L))
        }
        if tok_is_kw(t, "CASE") {
          ignore(self.advance())
          return self.case_expr()
        }
        if tok_is_kw(t, "EXISTS") && self.peek_at(1).text == "(" {
          ignore(self.advance())
          self.expect_op("(")
          let q = self.select()
          self.expect_op(")")
          return Exists(q)
        }
        if tok_is_kw(t, "CAST") && self.peek_at(1).text == "(" {
          ignore(self.advance())
          self.expect_op("(")
          let e = self.expr()
          self.expect_kw("AS")
          let words : Array[String] = []
          while self.peek().kind == TIdent ||
                self.peek().kind == TQuoted ||
                self.peek().kind == TString {
            words.push(self.advance().text)
          }
          let mut ty = words.join(" ")
          if self.eat_op("(") {
            let a = self.signed_number_text()
            if self.eat_op(",") {
              let b = self.signed_number_text()
              ty = ty + "(" + a + "," + b + ")"
            } else {
              ty = ty + "(" + a + ")"
            }
            self.expect_op(")")
          }
          self.expect_op(")")
          return Cast(e, ty)
        }
        let fn_kw = (tok_is_kw(t, "LIKE") || tok_is_kw(t, "GLOB")) &&
          self.peek_at(1).kind == TOp &&
          self.peek_at(1).text == "("
        if is_reserved(t) && !fn_kw {
          raise self.syntax_error()
        }
      }
      ignore(self.advance())
      if self.is_op("(") && t.kind == TIdent {
        ignore(self.advance())
        return self.func_call(t.text)
      }
      if self.is_op(".") {
        ignore(self.advance())
        let n2 = self.name()
        if self.eat_op(".") {
          let n3 = self.name()
          return Col(tbl=Some(n2), name=n3, dq=false)
        }
        return Col(tbl=Some(t.text), name=n2, dq=false)
      }
      Col(tbl=None, name=t.text, dq=t.kind == TQuoted)
    }
  }
}

///|
fn Parser::func_call(self : Parser, name : String) -> Expr raise SqlError {
  let args : Array[Expr] = []
  let mut distinct = false
  let mut star = false
  if self.eat_op("*") {
    star = true
  } else if !self.is_op(")") {
    if self.eat_kw("DISTINCT") {
      distinct = true
    } else {
      ignore(self.eat_kw("ALL"))
    }
    while true {
      args.push(self.expr())
      if !self.eat_op(",") {
        break
      }
    }
  }
  let order = if self.is_kw("ORDER") { self.order_by_clause() } else { [] }
  self.expect_op(")")
  let mut filter = None
  if self.eat_kw("FILTER") {
    self.expect_op("(")
    self.expect_kw("WHERE")
    filter = Some(self.expr())
    self.expect_op(")")
  }
  let f = Func(name=name.to_lower(), args~, distinct~, star~, filter~, order~)
  if self.eat_kw("OVER") {
    if self.eat_op("(") {
      let spec = self.window_spec()
      self.expect_op(")")
      return WinFunc(f, spec)
    }
    let w = self.name()
    return WinFunc(f, {
      base: Some(w),
      partition: [],
      order: [],
      frame: None,
      named_only: true,
    })
  }
  f
}

///|
fn Parser::case_expr(self : Parser) -> Expr raise SqlError {
  let base = if self.is_kw("WHEN") { None } else { Some(self.expr()) }
  let whens : Array[(Expr, Expr)] = []
  while self.eat_kw("WHEN") {
    let c = self.expr()
    self.expect_kw("THEN")
    let r = self.expr()
    whens.push((c, r))
  }
  if whens.length() == 0 {
    raise self.syntax_error()
  }
  let els = if self.eat_kw("ELSE") { Some(self.expr()) } else { None }
  self.expect_kw("END")
  Case(base, whens, els)
}
