// Rewriting the stored CREATE statements of schema objects for ALTER
// TABLE, working on the token stream so the rest of the text is kept.

use crate::lexer::{tokenize, Tok, Token};

fn ident(t: &Token) -> Option<&str> {
    match &t.tok {
        Tok::Word(s) | Tok::QIdent(s, _) => Some(s),
        _ => None,
    }
}

fn is_name(t: &Token, name: &str) -> bool {
    ident(t).is_some_and(|s| s.eq_ignore_ascii_case(name))
}

fn kw(t: &Token, k: &str) -> bool {
    matches!(&t.tok, Tok::Word(s) if s.eq_ignore_ascii_case(k))
}

fn op(t: &Token, o: &str) -> bool {
    matches!(&t.tok, Tok::Op(x) if *x == o)
}

fn is_plain(name: &str) -> bool {
    let mut cs = name.chars();
    matches!(cs.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && cs.all(|c| c.is_ascii_alphanumeric() || c == '_')
        && !KEYWORDS.iter().any(|k| k.eq_ignore_ascii_case(name))
}

const KEYWORDS: &[&str] = &[
    "ABORT", "ACTION", "ADD", "AFTER", "ALL", "ALTER", "AND", "AS", "ASC", "BETWEEN", "BY",
    "CASCADE", "CASE", "CAST", "CHECK", "COLLATE", "COLUMN", "COMMIT", "CONFLICT", "CONSTRAINT",
    "CREATE", "CROSS", "DEFAULT", "DEFERRABLE", "DELETE", "DESC", "DISTINCT", "DROP", "ELSE",
    "END", "ESCAPE", "EXCEPT", "EXISTS", "FAIL", "FILTER", "FOREIGN", "FROM", "FULL", "GLOB",
    "GROUP", "HAVING", "IF", "IGNORE", "IN", "INDEX", "INDEXED", "INNER", "INSERT", "INTERSECT",
    "INTO", "IS", "ISNULL", "JOIN", "KEY", "LEFT", "LIKE", "LIMIT", "MATCH", "NATURAL", "NO",
    "NOT", "NOTNULL", "NULL", "OF", "OFFSET", "ON", "OR", "ORDER", "OUTER", "OVER", "PARTITION",
    "PRIMARY", "RAISE", "RANGE", "RECURSIVE", "REFERENCES", "REGEXP", "REPLACE", "RESTRICT",
    "RIGHT", "ROLLBACK", "ROW", "ROWS", "SELECT", "SET", "TABLE", "THEN", "TO", "TRANSACTION",
    "UNION", "UNIQUE", "UPDATE", "USING", "VALUES", "VIEW", "WHEN", "WHERE", "WINDOW", "WITH",
    "WITHOUT",
];

/// The replacement text for an identifier token.
fn quoted(orig: &Token, new: &str) -> String {
    if matches!(orig.tok, Tok::Word(_)) && is_plain(new) {
        new.to_string()
    } else {
        format!("\"{}\"", new.replace('"', "\"\""))
    }
}

fn apply(sql: &str, mut edits: Vec<(usize, usize, String)>) -> String {
    edits.sort_by_key(|e| e.0);
    edits.dedup_by_key(|e| e.0);
    let mut out = String::new();
    let mut pos = 0;
    for (a, b, s) in edits {
        if a < pos {
            continue;
        }
        out.push_str(&sql[pos..a]);
        out.push_str(&s);
        pos = b;
    }
    out.push_str(&sql[pos..]);
    out
}

fn toks(sql: &str) -> Vec<Token> {
    let mut t = tokenize(sql).unwrap_or_default();
    t.retain(|t| !matches!(t.tok, Tok::Eof));
    t
}

fn end(t: &Token) -> usize {
    t.start + t.text.len()
}

/// Positions of tokens naming table `name` (FROM/JOIN items, ON of an
/// index, REFERENCES targets, qualifiers), plus aliases given to it.
fn table_refs(ts: &[Token], name: &str) -> (Vec<usize>, Vec<String>) {
    let mut out = Vec::new();
    let mut aliases = Vec::new();
    let mut from_stack = vec![false];
    for i in 0..ts.len() {
        let t = &ts[i];
        if op(t, "(") {
            from_stack.push(false);
            continue;
        }
        if op(t, ")") {
            from_stack.pop();
            if from_stack.is_empty() {
                from_stack.push(false);
            }
            continue;
        }
        if let Tok::Word(w) = &t.tok {
            let w = w.to_ascii_uppercase();
            match w.as_str() {
                "FROM" | "JOIN" => *from_stack.last_mut().unwrap() = true,
                "WHERE" | "GROUP" | "ORDER" | "HAVING" | "LIMIT" | "WINDOW" | "UNION"
                | "INTERSECT" | "EXCEPT" | "SELECT" | "VALUES" | "ON" | "USING" => {
                    *from_stack.last_mut().unwrap() = false
                }
                _ => {}
            }
        }
        if !is_name(t, name) {
            continue;
        }
        let prev = if i > 0 { Some(&ts[i - 1]) } else { None };
        let next = ts.get(i + 1);
        let is_ref = if prev.is_some_and(|p| op(p, ".")) {
            // schema.table
            i >= 2 && (is_name(&ts[i - 2], "main") || is_name(&ts[i - 2], "temp"))
        } else if next.is_some_and(|n| op(n, ".")) {
            true
        } else if let Some(p) = prev {
            kw(p, "TABLE")
                || kw(p, "FROM")
                || kw(p, "JOIN")
                || kw(p, "REFERENCES")
                || (kw(p, "ON") && next.is_some_and(|n| op(n, "(")))
                || (op(p, ",") && *from_stack.last().unwrap())
        } else {
            false
        };
        if is_ref {
            out.push(i);
            if !next.is_some_and(|n| op(n, ".")) {
                let mut j = i + 1;
                if ts.get(j).is_some_and(|t| kw(t, "AS")) {
                    j += 1;
                }
                if let Some(a) = ts.get(j) {
                    if let Some(s) = ident(a) {
                        if !KEYWORDS.iter().any(|k| k.eq_ignore_ascii_case(s))
                            || matches!(a.tok, Tok::QIdent(..))
                        {
                            aliases.push(s.to_string());
                        }
                    }
                }
            }
        }
    }
    (out, aliases)
}

/// Rename table `old` to `new` wherever `sql` refers to it.
pub fn rename_table(sql: &str, old: &str, new: &str) -> String {
    let ts = toks(sql);
    let (refs, _) = table_refs(&ts, old);
    let edits = refs
        .into_iter()
        .map(|i| (ts[i].start, end(&ts[i]), format!("\"{}\"", new.replace('"', "\"\""))))
        .collect();
    apply(sql, edits)
}

const CONSTRAINT_KWS: &[&str] = &[
    "CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT", "COLLATE",
    "REFERENCES", "GENERATED", "AS", "FOREIGN",
];

fn is_constraint_kw(t: &Token) -> bool {
    CONSTRAINT_KWS.iter().any(|k| kw(t, k))
}

/// Segments of the parenthesized definition list of a CREATE TABLE:
/// token index ranges.
fn table_segments(ts: &[Token]) -> Vec<(usize, usize)> {
    let Some(open) = ts.iter().position(|t| op(t, "(")) else {
        return Vec::new();
    };
    let mut segs = Vec::new();
    let mut depth = 0;
    let mut start = open + 1;
    for i in open..ts.len() {
        if op(&ts[i], "(") {
            depth += 1;
        } else if op(&ts[i], ")") {
            depth -= 1;
            if depth == 0 {
                segs.push((start, i));
                break;
            }
        } else if op(&ts[i], ",") && depth == 1 {
            segs.push((start, i));
            start = i + 1;
        }
    }
    segs
}

/// Whether token `i` is a reference to column `col` (of a table known by
/// the names in `quals` when qualified).
fn col_ref(ts: &[Token], i: usize, col: &str, quals: &[String]) -> bool {
    if !is_name(&ts[i], col) {
        return false;
    }
    if ts.get(i + 1).is_some_and(|n| op(n, "(") || op(n, ".")) {
        return false;
    }
    if i > 0 {
        let p = &ts[i - 1];
        if kw(p, "COLLATE") || kw(p, "AS") {
            return false;
        }
        if op(p, ".") {
            return i >= 2
                && ident(&ts[i - 2]).is_some_and(|q| quals.iter().any(|x| x.eq_ignore_ascii_case(q)));
        }
    }
    true
}

/// Rename column `old` of `table` to `new` in the table's own CREATE
/// TABLE statement.
pub fn rename_column_in_table(sql: &str, table: &str, old: &str, new: &str) -> String {
    let ts = toks(sql);
    let quals = vec![table.to_string()];
    let mut edits = Vec::new();
    for (a, b) in table_segments(&ts) {
        if a >= b {
            continue;
        }
        let mut i = a;
        let is_col = !is_table_constraint(&ts[a]);
        if is_col {
            if is_name(&ts[a], old) {
                edits.push((ts[a].start, end(&ts[a]), quoted(&ts[a], new)));
            }
            i += 1;
            // Type name.
            while i < b && matches!(ts[i].tok, Tok::Word(_)) && !is_constraint_kw(&ts[i]) {
                i += 1;
            }
            if i < b && op(&ts[i], "(") {
                while i < b && !op(&ts[i], ")") {
                    i += 1;
                }
                i += 1;
            }
        }
        let mut in_refs = false;
        let mut self_ref = false;
        while i < b {
            if kw(&ts[i], "REFERENCES") {
                in_refs = true;
                self_ref = ts.get(i + 1).is_some_and(|t| is_name(t, table));
                i += 1;
                continue;
            }
            if (!in_refs || self_ref) && col_ref(&ts, i, old, &quals) {
                edits.push((ts[i].start, end(&ts[i]), quoted(&ts[i], new)));
            }
            i += 1;
        }
    }
    apply(sql, edits)
}

/// Rename column `old` of `table` in an index on that table.
pub fn rename_column_in_index(sql: &str, table: &str, old: &str, new: &str) -> String {
    let ts = toks(sql);
    let quals = vec![table.to_string()];
    let Some(on) = ts.iter().position(|t| kw(t, "ON")) else {
        return sql.to_string();
    };
    let edits = (on + 2..ts.len())
        .filter(|&i| col_ref(&ts, i, old, &quals))
        .map(|i| (ts[i].start, end(&ts[i]), quoted(&ts[i], new)))
        .collect();
    apply(sql, edits)
}

/// Rename column `old` of `table` in a view or another table's REFERENCES
/// clauses.
pub fn rename_column_elsewhere(sql: &str, is_view: bool, table: &str, old: &str, new: &str) -> String {
    let ts = toks(sql);
    let mut edits = Vec::new();
    // REFERENCES table(col, ...)
    for i in 0..ts.len() {
        if kw(&ts[i], "REFERENCES") && ts.get(i + 1).is_some_and(|t| is_name(t, table)) {
            let mut j = i + 2;
            if ts.get(j).is_some_and(|t| op(t, "(")) {
                while j < ts.len() && !op(&ts[j], ")") {
                    if is_name(&ts[j], old) {
                        edits.push((ts[j].start, end(&ts[j]), quoted(&ts[j], new)));
                    }
                    j += 1;
                }
            }
        }
    }
    if is_view {
        let (refs, mut quals) = table_refs(&ts, table);
        if !refs.is_empty() {
            quals.push(table.to_string());
            let start = ts.iter().position(|t| kw(t, "AS")).map_or(0, |p| p + 1);
            for i in start..ts.len() {
                if col_ref(&ts, i, old, &quals) {
                    edits.push((ts[i].start, end(&ts[i]), quoted(&ts[i], new)));
                }
            }
        }
    }
    apply(sql, edits)
}

/// Where ALTER TABLE ADD COLUMN inserts a definition: before the comma
/// that starts the table constraints, or else the closing parenthesis.
fn add_col_offset(ts: &[Token], segs: &[(usize, usize)]) -> Option<usize> {
    let last = segs.last()?;
    for &(a, b) in segs.iter().skip(1) {
        if a < b && is_table_constraint(&ts[a]) {
            return Some(ts[a - 1].start);
        }
    }
    Some(ts[last.1].start)
}

fn is_table_constraint(t: &Token) -> bool {
    ["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"]
        .iter()
        .any(|k| kw(t, k))
}

/// ALTER TABLE ADD COLUMN: append the definition to the column list.
pub fn add_column(sql: &str, def: &str) -> String {
    let def = def.trim_end_matches(|c: char| c == ';' || c.is_whitespace());
    let ts = toks(sql);
    match add_col_offset(&ts, &table_segments(&ts)) {
        Some(p) => format!("{}, {}{}", &sql[..p], def, &sql[p..]),
        None => sql.to_string(),
    }
}

/// ALTER TABLE DROP COLUMN: remove the column's definition.
pub fn drop_column(sql: &str, col: &str) -> String {
    let ts = toks(sql);
    let segs = table_segments(&ts);
    let cols: Vec<(usize, usize)> = segs
        .iter()
        .copied()
        .take_while(|&(a, b)| a < b && !is_table_constraint(&ts[a]))
        .collect();
    let Some(k) = cols.iter().position(|&(a, _)| is_name(&ts[a], col)) else {
        return sql.to_string();
    };
    let a = cols[k].0;
    if k + 1 < cols.len() {
        let next = ts[cols[k + 1].0].start;
        format!("{}{}", &sql[..ts[a].start], &sql[next..])
    } else {
        // From the preceding comma to the end of the column list.
        let from = ts[a - 1].start;
        let to = add_col_offset(&ts, &segs).unwrap_or(sql.len());
        format!("{}{}", &sql[..from], &sql[to..])
    }
}
