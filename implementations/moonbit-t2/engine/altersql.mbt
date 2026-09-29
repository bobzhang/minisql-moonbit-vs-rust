// Rewriting the stored CREATE statements after ALTER TABLE, the way SQLite
// edits the text in sqlite_schema.

///|
let sqlite_keywords : Set[String] = Set([
  "ABORT", "ACTION", "ADD", "AFTER", "ALL", "ALTER", "ALWAYS", "ANALYZE", "AND",
  "AS", "ASC", "ATTACH", "AUTOINCREMENT", "BEFORE", "BEGIN", "BETWEEN", "BY", "CASCADE",
  "CASE", "CAST", "CHECK", "COLLATE", "COLUMN", "COMMIT", "CONFLICT", "CONSTRAINT",
  "CREATE", "CROSS", "CURRENT", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
  "DATABASE", "DEFAULT", "DEFERRABLE", "DEFERRED", "DELETE", "DESC", "DETACH", "DISTINCT",
  "DO", "DROP", "EACH", "ELSE", "END", "ESCAPE", "EXCEPT", "EXCLUDE", "EXCLUSIVE",
  "EXISTS", "EXPLAIN", "FAIL", "FILTER", "FIRST", "FOLLOWING", "FOR", "FOREIGN",
  "FROM", "FULL", "GENERATED", "GLOB", "GROUP", "GROUPS", "HAVING", "IF", "IGNORE",
  "IMMEDIATE", "IN", "INDEX", "INDEXED", "INITIALLY", "INNER", "INSERT", "INSTEAD",
  "INTERSECT", "INTO", "IS", "ISNULL", "JOIN", "KEY", "LAST", "LEFT", "LIKE", "LIMIT",
  "MATCH", "MATERIALIZED", "NATURAL", "NO", "NOT", "NOTHING", "NOTNULL", "NULL",
  "NULLS", "OF", "OFFSET", "ON", "OR", "ORDER", "OTHERS", "OUTER", "OVER", "PARTITION",
  "PLAN", "PRAGMA", "PRECEDING", "PRIMARY", "QUERY", "RAISE", "RANGE", "RECURSIVE",
  "REFERENCES", "REGEXP", "REINDEX", "RELEASE", "RENAME", "REPLACE", "RESTRICT",
  "RETURNING", "RIGHT", "ROLLBACK", "ROW", "ROWS", "SAVEPOINT", "SELECT", "SET",
  "TABLE", "TEMP", "TEMPORARY", "THEN", "TIES", "TO", "TRANSACTION", "TRIGGER", "UNBOUNDED",
  "UNION", "UNIQUE", "UPDATE", "USING", "VACUUM", "VALUES", "VIEW", "VIRTUAL", "WHEN",
  "WHERE", "WINDOW", "WITH", "WITHOUT",
])

///|
/// The identifier as SQLite writes it: bare when possible, else quoted.
fn ident_text(name : String) -> String {
  let mut plain = name.length() > 0 &&
    !sqlite_keywords.contains(name.to_upper())
  for i, c in name {
    let ok = c.is_ascii_alphabetic() ||
      c == '_' ||
      (i > 0 && c.is_ascii_digit()) ||
      c.to_int() >= 0x80
    if !ok {
      plain = false
    }
  }
  if plain {
    name
  } else {
    quoted_ident(name)
  }
}

///|
fn quoted_ident(name : String) -> String {
  "\"" + name.replace_all(old="\"", new="\"\"") + "\""
}

///|
/// End offset of a token in its source text.
fn token_end(s : String, t : Token) -> Int {
  match t.kind {
    TQuoted | TString =>
      match lex_quoted(s, t.pos, s[t.pos]) {
        Some((_, e)) => e
        None => s.length()
      }
    TBracket =>
      if s[t.pos] == '[' {
        t.pos + t.text.length() + 2
      } else {
        match lex_quoted(s, t.pos, s[t.pos]) {
          Some((_, e)) => e
          None => s.length()
        }
      }
    TBlob =>
      match lex_quoted(s, t.pos + 1, '\'') {
        Some((_, e)) => e
        None => s.length()
      }
    TEof => t.pos
    _ => t.pos + t.text.length()
  }
}

///|
fn is_name_tok(t : Token) -> Bool {
  t.kind is (TIdent | TQuoted | TBracket | TString)
}

///|
/// Replaces the given token spans of `s` with new texts.
fn splice_tokens(s : String, edits : Array[(Int, Int, String)]) -> String {
  edits.sort_by((a, b) => a.0 - b.0)
  let sb = StringBuilder()
  let mut last = 0
  for e in edits {
    sb.write_view(s[last:e.0])
    sb.write_string(e.2)
    last = e.1
  }
  sb.write_view(s[last:])
  sb.to_string()
}

///|
/// Index of the name token of a CREATE TABLE/INDEX/VIEW statement.
fn create_name_index(toks : Array[Token]) -> Int {
  let mut i = 0
  while i < toks.length() &&
        toks[i].kind == TIdent &&
        (
          tok_is_kw(toks[i], "CREATE") ||
          tok_is_kw(toks[i], "TABLE") ||
          tok_is_kw(toks[i], "UNIQUE") ||
          tok_is_kw(toks[i], "INDEX") ||
          tok_is_kw(toks[i], "VIEW") ||
          tok_is_kw(toks[i], "TEMP") ||
          tok_is_kw(toks[i], "TEMPORARY") ||
          tok_is_kw(toks[i], "IF") ||
          tok_is_kw(toks[i], "NOT") ||
          tok_is_kw(toks[i], "EXISTS")
        ) {
    i += 1
  }
  // schema-qualified name: point at the last part
  if i + 2 < toks.length() && toks[i + 1].kind == TOp && toks[i + 1].text == "." {
    i += 2
  }
  i
}

///|
/// CREATE TABLE text with the table renamed.
fn sql_rename_table_def(sql : String, new_name : String) -> String {
  let toks = tokenize(sql) catch { _ => return sql }
  let i = create_name_index(toks)
  if i >= toks.length() || !is_name_tok(toks[i]) {
    return sql
  }
  splice_tokens(sql, [
    (toks[i].pos, token_end(sql, toks[i]), quoted_ident(new_name)),
  ])
}

///|
/// Replaces references to table `old` (not function names) in the text of
/// an index or view definition; the object's own name is kept.
fn sql_rename_table_refs(
  sql : String,
  old : String,
  new_name : String,
) -> String {
  let toks = tokenize(sql) catch { _ => return sql }
  let own = create_name_index(toks)
  let edits : Array[(Int, Int, String)] = []
  for i, t in toks {
    if i == own || !(t.kind is (TIdent | TQuoted | TBracket)) {
      continue
    }
    if !t.text.equal_ignore_ascii_case(old) {
      continue
    }
    if i + 1 < toks.length() &&
      toks[i + 1].kind == TOp &&
      toks[i + 1].text == "(" {
      // a function call, except `ON t(...)` in an index
      if !(i > 0 && tok_is_kw(toks[i - 1], "ON")) {
        continue
      }
    }
    edits.push((t.pos, token_end(sql, t), quoted_ident(new_name)))
  }
  if edits.length() == 0 {
    return sql
  }
  splice_tokens(sql, edits)
}

///|
/// Replaces references to column `old` in a definition's text.
fn sql_rename_column(sql : String, old : String, new_name : String) -> String {
  let toks = tokenize(sql) catch { _ => return sql }
  let own = create_name_index(toks)
  let edits : Array[(Int, Int, String)] = []
  for i, t in toks {
    if i <= own || !(t.kind is (TIdent | TQuoted | TBracket)) {
      continue
    }
    if !t.text.equal_ignore_ascii_case(old) {
      continue
    }
    if i + 1 < toks.length() &&
      toks[i + 1].kind == TOp &&
      (toks[i + 1].text == "(" || toks[i + 1].text == ".") {
      continue
    }
    edits.push((t.pos, token_end(sql, t), ident_text(new_name)))
  }
  if edits.length() == 0 {
    return sql
  }
  splice_tokens(sql, edits)
}

///|
/// Top-level elements of a CREATE TABLE body: (start, end, is_column).
fn table_def_elements(
  sql : String,
  toks : Array[Token],
) -> Array[(Int, Int, Bool)] {
  let out : Array[(Int, Int, Bool)] = []
  let mut i = create_name_index(toks) + 1
  while i < toks.length() && !(toks[i].kind == TOp && toks[i].text == "(") {
    i += 1
  }
  i += 1
  let mut depth = 0
  let mut start = -1
  let mut end = -1
  let mut first_tok : Token? = None
  while i < toks.length() {
    let t = toks[i]
    if t.kind == TOp && t.text == "(" {
      depth += 1
    } else if t.kind == TOp && t.text == ")" {
      if depth == 0 {
        break
      }
      depth -= 1
    } else if t.kind == TOp && t.text == "," && depth == 0 {
      if first_tok is Some(ft) {
        out.push((start, end, !is_table_constraint_tok(ft)))
      }
      first_tok = None
      i += 1
      continue
    }
    if first_tok is None {
      first_tok = Some(t)
      start = t.pos
    }
    end = token_end(sql, t)
    i += 1
  }
  if first_tok is Some(ft) {
    out.push((start, end, !is_table_constraint_tok(ft)))
  }
  out
}

///|
fn is_table_constraint_tok(t : Token) -> Bool {
  t.kind == TIdent &&
  (
    tok_is_kw(t, "CONSTRAINT") ||
    tok_is_kw(t, "PRIMARY") ||
    tok_is_kw(t, "UNIQUE") ||
    tok_is_kw(t, "CHECK") ||
    tok_is_kw(t, "FOREIGN")
  )
}

///|
/// CREATE TABLE text with a column definition appended after the last
/// column.
fn sql_add_column(sql : String, coldef : String) -> String {
  let toks = tokenize(sql) catch { _ => return sql }
  let els = table_def_elements(sql, toks)
  let mut at = -1
  for e in els {
    if e.2 {
      at = e.1
    }
  }
  if at < 0 {
    return sql
  }
  sql[:at].to_owned() + ", " + coldef + sql[at:].to_owned()
}

///|
/// CREATE TABLE text without the definition of column `k` (by position).
fn sql_drop_column(sql : String, k : Int) -> String {
  let toks = tokenize(sql) catch { _ => return sql }
  let els = table_def_elements(sql, toks)
  let mut ci = 0
  for j, e in els {
    if !e.2 {
      continue
    }
    if ci == k {
      if j == 0 {
        if els.length() > 1 {
          return sql[:e.0].to_owned() + sql[els[1].0:].to_owned()
        }
        return sql
      }
      return sql[:els[j - 1].1].to_owned() + sql[e.1:].to_owned()
    }
    ci += 1
  }
  sql
}

///|
/// Trailing whitespace and semicolons removed (as SQLite does for the
/// column text of ADD COLUMN).
fn trim_coldef(s : String) -> String {
  let mut e = s.length()
  while e > 0 && (s[e - 1] == ';' || is_space_cu(s[e - 1])) {
    e -= 1
  }
  s[:e].to_owned()
}

///|
/// Whether a definition's text refers to the named table.
fn sql_mentions(sql : String, name : String) -> Bool {
  let toks = tokenize(sql) catch { _ => return false }
  toks.any(t => {
    t.kind is (TIdent | TQuoted | TBracket) &&
    t.text.equal_ignore_ascii_case(name)
  })
}
