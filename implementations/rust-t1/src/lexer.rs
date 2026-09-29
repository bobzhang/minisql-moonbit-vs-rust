// SQL tokenizer.

use crate::error::{Error, Result};

#[derive(Clone, Debug, PartialEq)]
pub enum Tok {
    /// Bare identifier or keyword.
    Id(String),
    /// "double-quoted" identifier (may fall back to a string literal).
    DqId(String),
    /// [bracketed] or `backticked` identifier.
    QId(String),
    Str(String),
    Blob(Vec<u8>),
    /// Integer literal (already parsed, or None if it overflows i64),
    /// with the original text.
    Int(Option<i64>, String),
    Real(f64),
    /// Bind parameter: ?, ?NNN, :name, @name, $name.
    Var(String),
    Op(&'static str),
    Eof,
}

#[derive(Clone, Debug)]
pub struct Token {
    pub tok: Tok,
    pub pos: usize,
    pub end: usize,
}

fn is_id_start(b: u8) -> bool {
    b.is_ascii_alphabetic() || b == b'_' || b >= 0x80
}

fn is_id_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b == b'$' || b >= 0x80
}

fn unrecognized(src: &str, start: usize, end: usize) -> Error {
    Error::new(format!("unrecognized token: \"{}\"", &src[start..end]))
}

/// Scan a quoted token starting at `i` (the opening quote), where `close`
/// ends it and a doubled `close` is an escaped quote. Returns the content
/// and the index after the closing quote.
fn scan_quoted(src: &str, i: usize, close: u8, doubled: bool) -> Option<(String, usize)> {
    let b = src.as_bytes();
    let mut j = i + 1;
    let mut out = String::new();
    let mut seg = j;
    while j < b.len() {
        if b[j] == close {
            if doubled && j + 1 < b.len() && b[j + 1] == close {
                out.push_str(&src[seg..j + 1]);
                j += 2;
                seg = j;
                continue;
            }
            out.push_str(&src[seg..j]);
            return Some((out, j + 1));
        }
        j += 1;
    }
    None
}

/// Scan a run of digits where single underscores may separate digits.
fn scan_digits(b: &[u8], mut j: usize, hex: bool) -> usize {
    let is_d = |c: u8| if hex { c.is_ascii_hexdigit() } else { c.is_ascii_digit() };
    while j < b.len() {
        if is_d(b[j]) {
            j += 1;
        } else if b[j] == b'_' && j > 0 && is_d(b[j - 1]) && j + 1 < b.len() && is_d(b[j + 1]) {
            j += 1;
        } else {
            break;
        }
    }
    j
}

pub fn tokenize(src: &str) -> Result<Vec<Token>> {
    let b = src.as_bytes();
    let n = b.len();
    let mut toks = Vec::new();
    let mut i = 0;
    while i < n {
        let c = b[i];
        let start = i;
        // whitespace
        if c.is_ascii_whitespace() || c == 0x0b || c == 0x0c {
            i += 1;
            continue;
        }
        // comments
        if c == b'-' && i + 1 < n && b[i + 1] == b'-' {
            while i < n && b[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        if c == b'/' && i + 1 < n && b[i + 1] == b'*' {
            i += 2;
            while i < n && !(b[i] == b'*' && i + 1 < n && b[i + 1] == b'/') {
                i += 1;
            }
            i = (i + 2).min(n);
            continue;
        }
        let tok;
        if c == b'\'' {
            match scan_quoted(src, i, b'\'', true) {
                Some((s, j)) => {
                    tok = Tok::Str(s);
                    i = j;
                }
                None => return Err(unrecognized(src, start, n)),
            }
        } else if c == b'"' || c == b'`' {
            match scan_quoted(src, i, c, true) {
                Some((s, j)) => {
                    tok = if c == b'"' { Tok::DqId(s) } else { Tok::QId(s) };
                    i = j;
                }
                None => return Err(unrecognized(src, start, n)),
            }
        } else if c == b'[' {
            match scan_quoted(src, i, b']', false) {
                Some((s, j)) => {
                    tok = Tok::QId(s);
                    i = j;
                }
                None => return Err(unrecognized(src, start, n)),
            }
        } else if (c == b'x' || c == b'X') && i + 1 < n && b[i + 1] == b'\'' {
            match scan_quoted(src, i + 1, b'\'', false) {
                Some((s, j)) => {
                    i = j;
                    let hex = s.as_bytes();
                    if hex.len() % 2 != 0 || !hex.iter().all(|h| h.is_ascii_hexdigit()) {
                        return Err(unrecognized(src, start, j));
                    }
                    let bytes = hex
                        .chunks(2)
                        .map(|p| u8::from_str_radix(std::str::from_utf8(p).unwrap(), 16).unwrap())
                        .collect();
                    tok = Tok::Blob(bytes);
                }
                None => return Err(unrecognized(src, start, n)),
            }
        } else if c.is_ascii_digit() || (c == b'.' && i + 1 < n && b[i + 1].is_ascii_digit()) {
            // number
            if c == b'0' && i + 1 < n && (b[i + 1] == b'x' || b[i + 1] == b'X') {
                let mut j = scan_digits(b, i + 2, true);
                if j == i + 2 || (j < n && is_id_char(b[j])) {
                    while j < n && is_id_char(b[j]) {
                        j += 1;
                    }
                    return Err(unrecognized(src, start, j));
                }
                let digits = src[i + 2..j].replace('_', "");
                let digits = digits.trim_start_matches('0');
                if digits.len() > 16 {
                    return Err(Error::new(format!("hex literal too big: {}", &src[start..j])));
                }
                let v = if digits.is_empty() { 0 } else { u64::from_str_radix(digits, 16).unwrap() as i64 };
                tok = Tok::Int(Some(v), src[start..j].to_string());
                i = j;
            } else {
                let mut j = scan_digits(b, i, false);
                let mut is_real = false;
                if j < n && b[j] == b'.' {
                    is_real = true;
                    j = scan_digits(b, j + 1, false);
                }
                if j < n && (b[j] == b'e' || b[j] == b'E') {
                    let mut k = j + 1;
                    if k < n && (b[k] == b'+' || b[k] == b'-') {
                        k += 1;
                    }
                    if k < n && b[k].is_ascii_digit() {
                        j = scan_digits(b, k, false);
                        is_real = true;
                    } else {
                        let mut k = j;
                        while k < n && is_id_char(b[k]) {
                            k += 1;
                        }
                        return Err(unrecognized(src, start, k));
                    }
                }
                if j < n && is_id_char(b[j]) {
                    let mut k = j;
                    while k < n && is_id_char(b[k]) {
                        k += 1;
                    }
                    return Err(unrecognized(src, start, k));
                }
                let text = &src[start..j].replace('_', "");
                if is_real {
                    tok = Tok::Real(text.parse::<f64>().unwrap_or(0.0));
                } else {
                    tok = Tok::Int(text.parse::<i64>().ok(), text.to_string());
                }
                i = j;
            }
        } else if is_id_start(c) {
            let mut j = i;
            while j < n && is_id_char(b[j]) {
                j += 1;
            }
            tok = Tok::Id(src[i..j].to_string());
            i = j;
        } else if c == b'?' {
            let mut j = i + 1;
            while j < n && b[j].is_ascii_digit() {
                j += 1;
            }
            tok = Tok::Var(src[i..j].to_string());
            i = j;
        } else if c == b':' || c == b'@' || c == b'$' {
            let mut j = i + 1;
            while j < n && is_id_char(b[j]) {
                j += 1;
            }
            if j == i + 1 {
                return Err(unrecognized(src, start, j));
            }
            tok = Tok::Var(src[i..j].to_string());
            i = j;
        } else {
            let two = if i + 1 < n && src.is_char_boundary(i + 2) { &src[i..i + 2] } else { "" };
            let three = if i + 2 < n && src.is_char_boundary(i + 3) { &src[i..i + 3] } else { "" };
            let op: &'static str = if three == "->>" {
                "->>"
            } else {
                match two {
                    "||" => "||",
                    "<<" => "<<",
                    ">>" => ">>",
                    "<=" => "<=",
                    ">=" => ">=",
                    "==" => "==",
                    "!=" => "!=",
                    "<>" => "<>",
                    "->" => "->",
                    _ => match c {
                        b'(' => "(",
                        b')' => ")",
                        b',' => ",",
                        b';' => ";",
                        b'.' => ".",
                        b'+' => "+",
                        b'-' => "-",
                        b'*' => "*",
                        b'/' => "/",
                        b'%' => "%",
                        b'|' => "|",
                        b'&' => "&",
                        b'~' => "~",
                        b'<' => "<",
                        b'>' => ">",
                        b'=' => "=",
                        _ => {
                            let mut j = i + 1;
                            while j < n && !src.is_char_boundary(j) {
                                j += 1;
                            }
                            return Err(unrecognized(src, start, j));
                        }
                    },
                }
            };
            i += op.len();
            tok = Tok::Op(op);
        }
        toks.push(Token { tok, pos: start, end: i });
    }
    toks.push(Token { tok: Tok::Eof, pos: n, end: n });
    Ok(toks)
}
