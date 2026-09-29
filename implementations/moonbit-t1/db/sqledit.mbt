// Editing the text of CREATE statements for ALTER TABLE, so the schema
// written to a database file matches the altered definitions.

///|
fn quote_ident(name : String) -> String {
  "\"" + name.replace_all(old="\"", new="\"\"") + "\""
}

///|
fn is_ident_tok(t : Token) -> Bool {
  t.kind is (TIdent | TQuoted | TBracket)
}

///|
fn is_op_tok(t : Token, op : String) -> Bool {
  t.kind is TOp && t.text == op
}

///|
/// Offset just past an identifier token.
fn ident_end(src : String, t : Token) -> Int {
  match t.kind {
    TIdent => {
      let mut i = t.pos
      while i < src.length() && is_ident_char(src[i].to_int()) {
        i += 1
      }
      i
    }
    _ => {
      let open = src[t.pos].to_int()
      let close = if open == '['.to_int() { ']'.to_int() } else { open }
      match read_quoted(src, t.pos, close) {
        Some((_, e)) => e
        None => src.length()
      }
    }
  }
}

///|
/// Apply (start, end, replacement) edits to `src`.
fn apply_edits(src : String, edits : Array[(Int, Int, String)]) -> String {
  edits.sort_by((a, b) => a.0 - b.0)
  let sb = StringBuilder()
  let mut at = 0
  for e in edits {
    if e.0 < at {
      continue
    }
    sb.write_view(src[at:e.0])
    sb.write_string(e.2)
    at = e.1
  }
  sb.write_view(src[at:])
  sb.to_string()
}

///|
fn tokens_of(sql : String) -> Array[Token] {
  tokenize(sql) catch {
    _ => []
  }
}

///|
/// Top-level parts of a CREATE TABLE body: (first token, separator token)
/// indexes, where the separator is the ',' or ')' ending the part.
fn table_parts(toks : Array[Token]) -> Array[(Int, Int)] {
  let parts : Array[(Int, Int)] = []
  let mut i = 0
  while i < toks.length() && !is_op_tok(toks[i], "(") {
    i += 1
  }
  let mut depth = 0
  let mut start = i + 1
  while i < toks.length() {
    let t = toks[i]
    if is_op_tok(t, "(") {
      depth += 1
    } else if is_op_tok(t, ")") {
      depth -= 1
      if depth == 0 {
        parts.push((start, i))
        break
      }
    } else if depth == 1 && is_op_tok(t, ",") {
      parts.push((start, i))
      start = i + 1
    }
    i += 1
  }
  parts
}

///|
fn is_constraint_part(t : Token) -> Bool {
  t.kind is TIdent &&
  (
    t.upper == "CONSTRAINT" ||
    t.upper == "PRIMARY" ||
    t.upper == "UNIQUE" ||
    t.upper == "CHECK" ||
    t.upper == "FOREIGN"
  )
}

///|
/// End of the text before token `i` (trailing whitespace excluded).
fn text_end_before(src : String, toks : Array[Token], i : Int) -> Int {
  let mut e = toks[i].pos
  while e > 0 && is_space_cu(src[e - 1]) {
    e -= 1
  }
  e
}

///|
/// CREATE TABLE text with a column definition appended after the last column.
fn sql_add_column(sql : String, coldef : String) -> String {
  let toks = tokens_of(sql)
  let parts = table_parts(toks)
  let mut last = -1
  for p in parts {
    if p.0 < p.1 && !is_constraint_part(toks[p.0]) {
      last = p.1
    }
  }
  if last < 0 {
    return sql
  }
  let at = text_end_before(sql, toks, last)
  sql[:at].to_owned() + ", " + coldef + sql[at:].to_owned()
}

///|
/// CREATE TABLE text without the definition of column `col`.
fn sql_drop_column(sql : String, col : String) -> String {
  let toks = tokens_of(sql)
  let parts = table_parts(toks)
  for k, p in parts {
    guard p.0 < p.1 && is_ident_tok(toks[p.0]) && same_name(toks[p.0].text, col) else {
      continue
    }
    let end = text_end_before(sql, toks, p.1)
    if k > 0 {
      let prev_sep = toks[parts[k - 1].1]
      return apply_edits(sql, [(prev_sep.pos, end, "")])
    }
    if parts.length() > 1 {
      return apply_edits(sql, [(toks[p.0].pos, toks[parts[1].0].pos, "")])
    }
    return sql
  }
  sql
}

///|
/// Replace the name token of a CREATE TABLE statement.
fn sql_rename_create_table(sql : String, new_name : String) -> String {
  let toks = tokens_of(sql)
  for i, t in toks {
    if t.kind is TIdent && t.upper == "TABLE" {
      let mut j = i + 1
      if j + 2 < toks.length() && toks[j].upper == "IF" {
        j += 3
      }
      if j + 2 < toks.length() && is_op_tok(toks[j + 1], ".") {
        j += 2
      }
      if j < toks.length() && is_ident_tok(toks[j]) {
        let tk = toks[j]
        return apply_edits(sql, [
          (tk.pos, ident_end(sql, tk), quote_ident(new_name)),
        ])
      }
      break
    }
  }
  sql
}

///|
/// Replace the table name after ON in a CREATE INDEX statement.
fn sql_rename_index_table(sql : String, new_name : String) -> String {
  let toks = tokens_of(sql)
  for i, t in toks {
    if t.kind is TIdent && t.upper == "ON" && i + 1 < toks.length() {
      let mut j = i + 1
      if j + 2 < toks.length() && is_op_tok(toks[j + 1], ".") {
        j += 2
      }
      let tk = toks[j]
      if is_ident_tok(tk) {
        return apply_edits(sql, [
          (tk.pos, ident_end(sql, tk), quote_ident(new_name)),
        ])
      }
      break
    }
  }
  sql
}

///|
/// Rename references to table `old` in a view's text: names in FROM
/// lists and after JOIN, and qualifiers of column references.
fn sql_rename_table_refs(
  sql : String,
  old : String,
  new_name : String,
) -> String {
  let toks = tokens_of(sql)
  let edits : Array[(Int, Int, String)] = []
  let in_from : Array[Bool] = [false]
  for i, t in toks {
    if is_op_tok(t, "(") {
      in_from.push(false)
      continue
    }
    if is_op_tok(t, ")") {
      if in_from.length() > 1 {
        ignore(in_from.pop())
      }
      continue
    }
    if t.kind is TIdent {
      match t.upper {
        "FROM" | "JOIN" => {
          in_from[in_from.length() - 1] = true
          continue
        }
        "WHERE"
        | "GROUP"
        | "ORDER"
        | "LIMIT"
        | "HAVING"
        | "WINDOW"
        | "SELECT"
        | "ON"
        | "USING"
        | "UNION"
        | "EXCEPT"
        | "INTERSECT"
        | "VALUES" => {
          in_from[in_from.length() - 1] = false
          continue
        }
        _ => ()
      }
    }
    guard is_ident_tok(t) && same_name(t.text, old) else { continue }
    let prev_dot = i > 0 && is_op_tok(toks[i - 1], ".")
    let next_dot = i + 1 < toks.length() && is_op_tok(toks[i + 1], ".")
    let prev = if i > 0 { Some(toks[i - 1]) } else { None }
    let table_pos = in_from[in_from.length() - 1] &&
      !prev_dot &&
      prev is Some(p) &&
      (
        is_op_tok(p, ",") ||
        (p.kind is TIdent && (p.upper == "FROM" || p.upper == "JOIN"))
      )
    if table_pos || (next_dot && !prev_dot) {
      edits.push((t.pos, ident_end(sql, t), quote_ident(new_name)))
    }
  }
  apply_edits(sql, edits)
}

///|
/// Rename column `old` in a CREATE TABLE text: the column's own definition
/// and references inside parenthesised constraint parts.
fn sql_rename_column_in_table(
  sql : String,
  old : String,
  new_name : String,
) -> String {
  let toks = tokens_of(sql)
  let parts = table_parts(toks)
  let edits : Array[(Int, Int, String)] = []
  let q = quote_ident(new_name)
  for p in parts {
    let mut depth = 0
    let mut skip_refs = false
    for i in p.0..<p.1 {
      let t = toks[i]
      if is_op_tok(t, "(") {
        depth += 1
      } else if is_op_tok(t, ")") {
        depth -= 1
        if depth == 0 {
          skip_refs = false
        }
      } else if t.kind is TIdent && t.upper == "REFERENCES" {
        skip_refs = true
      } else if is_ident_tok(t) && same_name(t.text, old) {
        let is_name = i == p.0 && !is_constraint_part(t)
        let in_expr = depth > 0 && !skip_refs
        if is_name || in_expr {
          edits.push((t.pos, ident_end(sql, t), q))
        }
      }
    }
  }
  apply_edits(sql, edits)
}

///|
/// Rename column references in a CREATE INDEX text (after ON table).
fn sql_rename_column_in_index(
  sql : String,
  old : String,
  new_name : String,
) -> String {
  let toks = tokens_of(sql)
  let edits : Array[(Int, Int, String)] = []
  let mut started = false
  for i, t in toks {
    if !started {
      if is_op_tok(t, "(") {
        started = true
      }
      continue
    }
    let after_collate = i > 0 &&
      toks[i - 1].kind is TIdent &&
      toks[i - 1].upper == "COLLATE"
    let is_call = i + 1 < toks.length() && is_op_tok(toks[i + 1], "(")
    if is_ident_tok(t) && same_name(t.text, old) && !after_collate && !is_call {
      edits.push((t.pos, ident_end(sql, t), quote_ident(new_name)))
    }
  }
  apply_edits(sql, edits)
}

///|
/// Rename column references in a view's text, when the view mentions
/// `table`: unqualified names and names qualified by the table name.
fn sql_rename_column_in_view(
  sql : String,
  table : String,
  old : String,
  new_name : String,
) -> String {
  let toks = tokens_of(sql)
  if !toks.any(t => is_ident_tok(t) && same_name(t.text, table)) {
    return sql
  }
  let edits : Array[(Int, Int, String)] = []
  for i, t in toks {
    guard is_ident_tok(t) && same_name(t.text, old) else { continue }
    if i + 1 < toks.length() &&
      (is_op_tok(toks[i + 1], "(") || is_op_tok(toks[i + 1], ".")) {
      continue
    }
    if i > 0 && toks[i - 1].kind is TIdent && toks[i - 1].upper == "AS" {
      continue
    }
    if i > 1 &&
      is_op_tok(toks[i - 1], ".") &&
      !same_name(toks[i - 2].text, table) {
      continue
    }
    edits.push((t.pos, ident_end(sql, t), quote_ident(new_name)))
  }
  apply_edits(sql, edits)
}
