///|
/// Maintenance of the `sql` text stored in sqlite_schema, following the
/// edits SQLite itself makes on CREATE and ALTER TABLE.

///|
fn tok_ident(t : Tok) -> String? {
  match t {
    Word(w) | DqIdent(w) | QIdent(w) => Some(w)
    _ => None
  }
}

///|
fn tok_is_op(t : Tok, op : String) -> Bool {
  t is Op(o) && o == op
}

///|
/// Index of the last real token (not Eof, not a trailing `;`).
fn last_token(toks : Array[Token]) -> Int {
  let mut k = toks.length() - 2
  while k > 0 && tok_is_op(toks[k].tok, ";") {
    k -= 1
  }
  k
}

///|
fn quote_ident(name : String) -> String {
  "\"" + name.replace_all(old="\"", new="\"\"") + "\""
}

///|
/// A bare identifier when that is unambiguous, else a quoted one.
fn ident_text(name : String) -> String {
  let plain = name.length() > 0 &&
    is_ident_start(name[0].to_int()) &&
    name.iter().all(c => c.to_int() < 0x80 && is_ident_char(c.to_int()))
  if plain && !is_keyword(name) {
    name
  } else {
    quote_ident(name)
  }
}

///|
let sql_keywords : Set[String] = Set([
  "ABORT", "ACTION", "ADD", "AFTER", "ALL", "ALTER", "ALWAYS", "ANALYZE", "AND",
  "AS", "ASC", "ATTACH", "AUTOINCREMENT", "BEFORE", "BEGIN", "BETWEEN", "BY",
  "CASCADE", "CASE", "CAST", "CHECK", "COLLATE", "COLUMN", "COMMIT", "CONFLICT",
  "CONSTRAINT", "CREATE", "CROSS", "CURRENT", "CURRENT_DATE", "CURRENT_TIME",
  "CURRENT_TIMESTAMP", "DATABASE", "DEFAULT", "DEFERRABLE", "DEFERRED", "DELETE",
  "DESC", "DETACH", "DISTINCT", "DO", "DROP", "EACH", "ELSE", "END", "ESCAPE",
  "EXCEPT", "EXCLUDE", "EXCLUSIVE", "EXISTS", "EXPLAIN", "FAIL", "FILTER", "FIRST",
  "FOLLOWING", "FOR", "FOREIGN", "FROM", "FULL", "GENERATED", "GLOB", "GROUP",
  "GROUPS", "HAVING", "IF", "IGNORE", "IMMEDIATE", "IN", "INDEX", "INDEXED",
  "INITIALLY", "INNER", "INSERT", "INSTEAD", "INTERSECT", "INTO", "IS", "ISNULL",
  "JOIN", "KEY", "LAST", "LEFT", "LIKE", "LIMIT", "MATCH", "MATERIALIZED",
  "NATURAL", "NO", "NOT", "NOTHING", "NOTNULL", "NULL", "NULLS", "OF", "OFFSET",
  "ON", "OR", "ORDER", "OTHERS", "OUTER", "OVER", "PARTITION", "PLAN", "PRAGMA",
  "PRECEDING", "PRIMARY", "QUERY", "RAISE", "RANGE", "RECURSIVE", "REFERENCES",
  "REGEXP", "REINDEX", "RELEASE", "RENAME", "REPLACE", "RESTRICT", "RETURNING",
  "RIGHT", "ROLLBACK", "ROW", "ROWS", "SAVEPOINT", "SELECT", "SET", "TABLE",
  "TEMP", "TEMPORARY", "THEN", "TIES", "TO", "TRANSACTION", "TRIGGER", "UNBOUNDED",
  "UNION", "UNIQUE", "UPDATE", "USING", "VACUUM", "VALUES", "VIEW", "VIRTUAL",
  "WHEN", "WHERE", "WINDOW", "WITH", "WITHOUT",
])

///|
fn is_keyword(name : String) -> Bool {
  sql_keywords.contains(name.to_upper())
}

///|
/// Index of the name token of a CREATE statement, and the object kind
/// ("TABLE", "INDEX", "VIEW"; with "UNIQUE " prefixed for unique indexes).
fn create_name_token(toks : Array[Token]) -> (Int, String)? {
  guard toks.length() > 2 && tok_is_kw(toks[0].tok, "CREATE") else {
    return None
  }
  let mut i = 1
  while tok_is_kw(toks[i].tok, "TEMP") || tok_is_kw(toks[i].tok, "TEMPORARY") {
    i += 1
  }
  let mut kind = ""
  if tok_is_kw(toks[i].tok, "UNIQUE") {
    kind = "UNIQUE "
    i += 1
  }
  if tok_is_kw(toks[i].tok, "TABLE") {
    kind = kind + "TABLE"
  } else if tok_is_kw(toks[i].tok, "INDEX") {
    kind = kind + "INDEX"
  } else if tok_is_kw(toks[i].tok, "VIEW") {
    kind = kind + "VIEW"
  } else {
    return None
  }
  i += 1
  if tok_is_kw(toks[i].tok, "IF") {
    i += 3
  }
  if i + 1 < toks.length() && tok_is_op(toks[i + 1].tok, ".") {
    i += 2
  }
  if i >= toks.length() - 1 {
    return None
  }
  Some((i, kind))
}

///|
/// The text SQLite stores for a CREATE statement: "CREATE <kind> " followed
/// by the statement text from the object name on.
fn normalize_create_sql(sql : String) -> String {
  let (toks, ends) = tokenize_spans(sql) catch { _ => return sql }
  guard create_name_token(toks) is Some((i, kind)) else { return sql }
  let end = if kind == "TABLE" {
    ends[last_token(toks)]
  } else {
    let mut e = sql.length()
    while e > 0 && (sql[e - 1] == ';' || sql[e - 1] == ' ' || sql[e - 1] == '\n') {
      e -= 1
    }
    e
  }
  if end <= toks[i].pos {
    return sql
  }
  "CREATE " + kind + " " + sql[toks[i].pos:end].to_owned()
}

///|
/// Offsets (start, end) of each column definition of a CREATE TABLE text.
fn column_spans(sql : String) -> Array[(Int, Int)] {
  let (toks, ends) = tokenize_spans(sql) catch { _ => return [] }
  guard create_name_token(toks) is Some((name, _)) else { return [] }
  let mut i = name + 1
  guard i < toks.length() && tok_is_op(toks[i].tok, "(") else { return [] }
  i += 1
  let out = []
  let mut depth = 0
  let mut seg_start = i
  let mut in_constraints = false
  while i < toks.length() - 1 {
    let t = toks[i].tok
    if depth == 0 && (tok_is_op(t, ",") || tok_is_op(t, ")")) {
      if seg_start < i && !in_constraints {
        let first = toks[seg_start].tok
        if tok_is_kw(first, "CONSTRAINT") ||
          tok_is_kw(first, "PRIMARY") ||
          tok_is_kw(first, "UNIQUE") ||
          tok_is_kw(first, "CHECK") ||
          tok_is_kw(first, "FOREIGN") {
          in_constraints = true
        } else {
          out.push((toks[seg_start].pos, ends[i - 1]))
        }
      }
      if tok_is_op(t, ")") {
        break
      }
      seg_start = i + 1
    } else if tok_is_op(t, "(") {
      depth += 1
    } else if tok_is_op(t, ")") {
      depth -= 1
    }
    i += 1
  }
  out
}

///|
/// Table text after ALTER TABLE ... ADD COLUMN (`alter` is that statement).
fn add_column_sql(sql : String, alter : String) -> String {
  let (toks, ends) = tokenize_spans(alter) catch { _ => return sql }
  let mut k = 0
  while k < toks.length() - 1 && !tok_is_kw(toks[k].tok, "ADD") {
    k += 1
  }
  k += 1
  if tok_is_kw(toks[k].tok, "COLUMN") {
    k += 1
  }
  let last = last_token(toks)
  let spans = column_spans(sql)
  guard spans.last() is Some((_, at)) && k <= last else { return sql }
  sql[:at].to_owned() +
  ", " +
  alter[toks[k].pos:ends[last]].to_owned() +
  sql[at:].to_owned()
}

///|
/// Table text after dropping column `ci`.
fn drop_column_sql(sql : String, ci : Int) -> String {
  let spans = column_spans(sql)
  if ci >= spans.length() || spans.length() < 2 {
    return sql
  }
  if ci + 1 < spans.length() {
    sql[:spans[ci].0].to_owned() + sql[spans[ci + 1].0:].to_owned()
  } else {
    sql[:spans[ci - 1].1].to_owned() + sql[spans[ci].1:].to_owned()
  }
}

///|
/// Replaces the tokens at the given indexes of `sql` by `text`.
fn replace_tokens(
  sql : String,
  toks : Array[Token],
  ends : Array[Int],
  which : Array[Int],
  text : (Tok) -> String,
) -> String {
  if which.length() == 0 {
    return sql
  }
  let sb = StringBuilder()
  let mut at = 0
  for k in which {
    sb.write_view(sql[at:toks[k].pos])
    sb.write_string(text(toks[k].tok))
    at = ends[k]
  }
  sb.write_view(sql[at:])
  sb.to_string()
}

///|
/// Renames references to table `old` (folded) in schema text.
fn rename_table_sql(sql : String, old : String, new_name : String) -> String {
  let (toks, ends) = tokenize_spans(sql) catch { _ => return sql }
  let which = []
  let mut in_from = false
  for k in 0..<(toks.length() - 1) {
    let t = toks[k].tok
    if tok_is_kw(t, "FROM") || tok_is_kw(t, "JOIN") {
      in_from = true
      continue
    }
    if t is Word(w) &&
      [
        "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "WINDOW", "SELECT", "UNION",
        "EXCEPT", "INTERSECT", "VALUES", "ON", "USING",
      ].contains(w.to_upper()) {
      in_from = false
    }
    if tok_is_op(t, ")") {
      in_from = false
    }
    guard tok_ident(t) is Some(n) && fold_name(n) == old else { continue }
    let prev = if k > 0 { toks[k - 1].tok } else { Eof }
    let next = toks[k + 1].tok
    if tok_is_op(next, ".") ||
      tok_is_kw(prev, "FROM") ||
      tok_is_kw(prev, "JOIN") ||
      tok_is_kw(prev, "REFERENCES") ||
      tok_is_kw(prev, "ON") ||
      tok_is_kw(prev, "TABLE") ||
      (tok_is_op(prev, ",") && in_from) {
      which.push(k)
    }
  }
  replace_tokens(sql, toks, ends, which, _ => quote_ident(new_name))
}

///|
/// Renames column `old` (folded) in schema text, from token `from` on.
fn rename_column_sql(
  sql : String,
  old : String,
  new_name : String,
  from~ : (Array[Token]) -> Int,
) -> String {
  let (toks, ends) = tokenize_spans(sql) catch { _ => return sql }
  let which = []
  for k in from(toks)..<(toks.length() - 1) {
    if tok_ident(toks[k].tok) is Some(n) && fold_name(n) == old {
      which.push(k)
    }
  }
  replace_tokens(sql, toks, ends, which, t => match t {
    Word(_) => ident_text(new_name)
    _ => quote_ident(new_name)
  })
}

///|
/// First token after the object name of a CREATE statement.
fn after_create_name(toks : Array[Token]) -> Int {
  match create_name_token(toks) {
    Some((i, _)) => i + 1
    None => toks.length()
  }
}

///|
/// First token after `ON <table>` of a CREATE INDEX statement.
fn after_index_table(toks : Array[Token]) -> Int {
  for k in 0..<toks.length() {
    if tok_is_kw(toks[k].tok, "ON") {
      return k + 2
    }
  }
  toks.length()
}

///|
/// First token after `AS` of a CREATE VIEW statement.
fn after_view_as(toks : Array[Token]) -> Int {
  for k in 0..<toks.length() {
    if tok_is_kw(toks[k].tok, "AS") {
      return k + 1
    }
  }
  toks.length()
}

///|
/// Whether schema text mentions identifier `name` (folded).
fn sql_mentions(sql : String, name : String) -> Bool {
  let toks = tokenize(sql) catch { _ => return false }
  toks.any(t => tok_ident(t.tok) is Some(n) && fold_name(n) == name)
}
