// Maintaining the CREATE statement text stored in sqlite_schema.sql:
// normalization at creation and token-level rewrites for ALTER TABLE.

use crate::lexer::{tokenize, Tok, Token};

fn toks(sql: &str) -> Vec<Token> {
    let mut t = tokenize(sql).unwrap_or_default();
    if matches!(t.last(), Some(Token { tok: Tok::Eof, .. })) {
        t.pop();
    }
    t
}

fn is_kw(t: &Token, kw: &str) -> bool {
    matches!(&t.tok, Tok::Id(s) if s.eq_ignore_ascii_case(kw))
}

fn is_op(t: &Token, op: &str) -> bool {
    matches!(&t.tok, Tok::Op(o) if *o == op)
}

/// Identifier text of a token that can name something.
fn ident(t: &Token) -> Option<&str> {
    match &t.tok {
        Tok::Id(s) | Tok::DqId(s) | Tok::QId(s) => Some(s),
        Tok::Str(s) => Some(s),
        _ => None,
    }
}

fn names(t: &Token, name: &str) -> bool {
    ident(t).is_some_and(|s| s.eq_ignore_ascii_case(name))
}

pub fn quote(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

/// Normalize a CREATE statement the way SQLite stores it: "CREATE TABLE ",
/// "CREATE [UNIQUE] INDEX " or "CREATE VIEW " followed by the text from the
/// object name on (dropping TEMP, IF NOT EXISTS, and surrounding comments).
pub fn normalize_create(sql: &str) -> String {
    let t = toks(sql);
    if t.is_empty() {
        return sql.trim().to_string();
    }
    let end = t.last().unwrap().end;
    let mut i = 0;
    if !is_kw(&t[0], "CREATE") {
        return sql[t[0].pos..end].to_string();
    }
    i += 1;
    let mut unique = false;
    while i < t.len() && (is_kw(&t[i], "TEMP") || is_kw(&t[i], "TEMPORARY") || is_kw(&t[i], "UNIQUE")) {
        unique |= is_kw(&t[i], "UNIQUE");
        i += 1;
    }
    if i >= t.len() {
        return sql[t[0].pos..end].to_string();
    }
    let kind = if is_kw(&t[i], "TABLE") {
        "TABLE"
    } else if is_kw(&t[i], "INDEX") {
        "INDEX"
    } else if is_kw(&t[i], "VIEW") {
        "VIEW"
    } else {
        return sql[t[0].pos..end].to_string();
    };
    i += 1;
    if i + 2 < t.len() && is_kw(&t[i], "IF") && is_kw(&t[i + 1], "NOT") && is_kw(&t[i + 2], "EXISTS") {
        i += 3;
    }
    if i >= t.len() {
        return sql[t[0].pos..end].to_string();
    }
    format!("CREATE {}{} {}", if unique { "UNIQUE " } else { "" }, kind, &sql[t[i].pos..end])
}

/// Apply replacements (byte range, text) to `sql`.
fn apply(sql: &str, mut edits: Vec<(usize, usize, String)>) -> String {
    edits.sort_by_key(|e| e.0);
    let mut out = String::new();
    let mut at = 0;
    for (s, e, r) in edits {
        if s < at {
            continue;
        }
        out.push_str(&sql[at..s]);
        out.push_str(&r);
        at = e;
    }
    out.push_str(&sql[at..]);
    out
}

/// Index of the object-name token of a normalized CREATE statement.
fn name_pos(t: &[Token]) -> usize {
    let mut i = 1;
    while i < t.len() && !(is_kw(&t[i], "TABLE") || is_kw(&t[i], "INDEX") || is_kw(&t[i], "VIEW")) {
        i += 1;
    }
    i += 1;
    if i + 2 < t.len() && is_kw(&t[i], "IF") && is_kw(&t[i + 1], "NOT") && is_kw(&t[i + 2], "EXISTS") {
        i += 3;
    }
    i
}

/// Rename table `old` to `new` in a stored CREATE TABLE / INDEX / VIEW:
/// the object name (tables), the ON target (indexes), FROM/JOIN targets and
/// `old.` qualifiers.
pub fn rename_table(sql: &str, old: &str, new: &str, is_table: bool) -> String {
    let t = toks(sql);
    let np = name_pos(&t);
    let mut edits = Vec::new();
    for i in 0..t.len() {
        if !names(&t[i], old) || matches!(t[i].tok, Tok::Str(_)) && i != np {
            continue;
        }
        let prev = if i > 0 { Some(&t[i - 1]) } else { None };
        let next = t.get(i + 1);
        if prev.is_some_and(|p| is_op(p, ".")) {
            continue;
        }
        let hit = (is_table && i == np)
            || next.is_some_and(|n| is_op(n, "."))
            || prev.is_some_and(|p| is_kw(p, "ON") || is_kw(p, "FROM") || is_kw(p, "JOIN") || is_kw(p, "REFERENCES"))
            || (!is_table && prev.is_some_and(|p| is_op(p, ",")) && !next.is_some_and(|n| is_op(n, "(")));
        if hit {
            edits.push((t[i].pos, t[i].end, quote(new)));
        }
    }
    apply(sql, edits)
}

/// Rename column `old` to `new` in a stored CREATE TABLE statement: column
/// definition names and identifiers inside parentheses (constraints).
pub fn rename_column_in_table(sql: &str, old: &str, new: &str) -> String {
    let t = toks(sql);
    let mut edits = Vec::new();
    let mut depth = 0;
    let mut item_start = false;
    for i in 0..t.len() {
        if is_op(&t[i], "(") {
            depth += 1;
            item_start = depth == 1;
            continue;
        }
        if is_op(&t[i], ")") {
            depth -= 1;
            continue;
        }
        if is_op(&t[i], ",") {
            item_start = depth == 1;
            continue;
        }
        let first = item_start;
        item_start = false;
        if !names(&t[i], old) || matches!(t[i].tok, Tok::Str(_)) {
            continue;
        }
        let hit = (depth == 1 && first) || (depth >= 2 && is_ref(&t, i));
        if hit {
            edits.push((t[i].pos, t[i].end, quote(new)));
        }
    }
    apply(sql, edits)
}

/// Whether token `i` looks like a column reference (not a function name,
/// collation, alias or qualified name of something else).
fn is_ref(t: &[Token], i: usize) -> bool {
    let next = t.get(i + 1);
    let prev = if i > 0 { Some(&t[i - 1]) } else { None };
    !next.is_some_and(|n| is_op(n, "(") || is_op(n, "."))
        && !prev.is_some_and(|p| is_kw(p, "COLLATE") || is_kw(p, "AS"))
}

/// Rename column `old` to `new` in a stored CREATE INDEX or CREATE VIEW:
/// every identifier that looks like a column reference, after the name.
pub fn rename_column_refs(sql: &str, old: &str, new: &str) -> String {
    let t = toks(sql);
    let np = name_pos(&t);
    let mut edits = Vec::new();
    for i in np + 1..t.len() {
        if names(&t[i], old) && !matches!(t[i].tok, Tok::Str(_)) && is_ref(&t, i) {
            let prev = &t[i - 1];
            if is_kw(prev, "ON") || is_kw(prev, "FROM") || is_kw(prev, "JOIN") {
                continue;
            }
            edits.push((t[i].pos, t[i].end, quote(new)));
        }
    }
    apply(sql, edits)
}

/// Text of the column definition in an ALTER TABLE ... ADD [COLUMN] statement.
pub fn added_column_text(alter_sql: &str) -> Option<String> {
    let t = toks(alter_sql);
    let mut i = t.iter().position(|x| is_kw(x, "ADD"))? + 1;
    if i < t.len() && is_kw(&t[i], "COLUMN") {
        i += 1;
    }
    let end = t.last()?.end;
    (i < t.len()).then(|| alter_sql[t[i].pos..end].to_string())
}

/// Append a column definition to a CREATE TABLE statement, after the last
/// column definition (before any table constraints).
pub fn add_column(sql: &str, coldef: &str) -> String {
    let t = toks(sql);
    let mut at = None;
    let mut depth = 0;
    for i in 0..t.len() {
        if is_op(&t[i], "(") {
            depth += 1;
        } else if is_op(&t[i], ")") {
            depth -= 1;
            if depth == 0 {
                at = Some(t[i].pos);
                break;
            }
        } else if depth == 1 && is_op(&t[i], ",") {
            let starts_constraint = t.get(i + 1).is_some_and(|n| {
                ["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"].iter().any(|k| is_kw(n, k))
            });
            if starts_constraint {
                at = Some(t[i].pos);
                break;
            }
        }
    }
    match at {
        Some(p) => format!("{}, {}{}", &sql[..p], coldef, &sql[p..]),
        None => sql.to_string(),
    }
}

/// Remove the definition of column `col` from a CREATE TABLE statement.
pub fn drop_column(sql: &str, col: &str) -> String {
    let t = toks(sql);
    let Some(open) = t.iter().position(|x| is_op(x, "(")) else {
        return sql.to_string();
    };
    // Top-level items: (first token, last token) index ranges, and the
    // comma tokens separating them.
    let mut items: Vec<(usize, usize)> = Vec::new();
    let mut depth = 0;
    let mut start = open + 1;
    for i in open..t.len() {
        if is_op(&t[i], "(") {
            depth += 1;
        } else if is_op(&t[i], ")") {
            depth -= 1;
            if depth == 0 {
                if i > start {
                    items.push((start, i - 1));
                }
                break;
            }
        } else if is_op(&t[i], ",") && depth == 1 {
            items.push((start, i - 1));
            start = i + 1;
        }
    }
    let Some(k) = items.iter().position(|&(s, _)| names(&t[s], col)) else {
        return sql.to_string();
    };
    let (s, e) = items[k];
    let (from, to) = if k + 1 < items.len() {
        (t[s].pos, t[items[k + 1].0].pos)
    } else if k > 0 {
        (t[items[k - 1].1].end, t[e].end)
    } else {
        (t[s].pos, t[e].end)
    };
    format!("{}{}", &sql[..from], &sql[to..])
}
