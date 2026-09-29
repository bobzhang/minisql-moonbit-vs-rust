// SQL tokenizer.

#[derive(Debug, Clone, PartialEq)]
pub enum Tok {
    /// Unquoted identifier or keyword.
    Id(String),
    /// Identifier quoted with [] or ``.
    QId(String),
    /// "..." token: an identifier that may fall back to a string literal.
    DqId(String),
    Str(String),
    Blob(Vec<u8>),
    /// Integer literal (decimal or hex), already converted; `None` if a decimal
    /// literal is too big for i64 (then it is a REAL).
    Int(Option<i64>),
    Float(f64),
    Var(String),
    Op(&'static str),
    Eof,
}

#[derive(Debug, Clone)]
pub struct Token {
    pub tok: Tok,
    pub start: usize,
    pub end: usize,
}

fn is_id_start(c: u8) -> bool {
    c.is_ascii_alphabetic() || c == b'_' || c >= 0x80
}

fn is_id_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'$' || c >= 0x80
}

const OPS: [&str; 28] = [
    "->>", "||", "<=", "<>", "<<", ">=", ">>", "==", "!=", "->", "(", ")", ";", "+", "-", "*", "/",
    "%", "=", "<", ">", ",", "&", "~", "|", ".", "?", "!",
];

pub fn tokenize(src: &str) -> Result<Vec<Token>, String> {
    let b = src.as_bytes();
    let n = b.len();
    let mut toks = Vec::new();
    let mut i = 0;
    let unrecognized = |s: usize, e: usize| format!("unrecognized token: \"{}\"", &src[s..e]);
    while i < n {
        let c = b[i];
        let start = i;
        if c.is_ascii_whitespace() || c == 0x0c {
            i += 1;
            continue;
        }
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
        let tok = if c == b'\'' || c == b'"' || c == b'`' {
            i += 1;
            let mut s = Vec::new();
            let mut closed = false;
            while i < n {
                if b[i] == c {
                    if i + 1 < n && b[i + 1] == c {
                        s.push(c);
                        i += 2;
                        continue;
                    }
                    i += 1;
                    closed = true;
                    break;
                }
                s.push(b[i]);
                i += 1;
            }
            if !closed {
                return Err(unrecognized(start, n));
            }
            let s = String::from_utf8_lossy(&s).into_owned();
            match c {
                b'\'' => Tok::Str(s),
                b'"' => Tok::DqId(s),
                _ => Tok::QId(s),
            }
        } else if c == b'[' {
            i += 1;
            while i < n && b[i] != b']' {
                i += 1;
            }
            if i >= n {
                return Err(unrecognized(start, n));
            }
            i += 1;
            Tok::QId(src[start + 1..i - 1].to_string())
        } else if (c == b'x' || c == b'X') && i + 1 < n && b[i + 1] == b'\'' {
            i += 2;
            let hs = i;
            while i < n && b[i] != b'\'' {
                i += 1;
            }
            if i >= n {
                return Err(unrecognized(start, n));
            }
            let hex = &b[hs..i];
            i += 1;
            if hex.len() % 2 != 0 || !hex.iter().all(|h| h.is_ascii_hexdigit()) {
                return Err(unrecognized(start, i));
            }
            let bytes = hex
                .chunks(2)
                .map(|p| u8::from_str_radix(std::str::from_utf8(p).unwrap(), 16).unwrap())
                .collect();
            Tok::Blob(bytes)
        } else if c.is_ascii_digit() || (c == b'.' && i + 1 < n && b[i + 1].is_ascii_digit()) {
            if c == b'0' && i + 2 < n && (b[i + 1] == b'x' || b[i + 1] == b'X') && b[i + 2].is_ascii_hexdigit() {
                i += 2;
                let hs = i;
                while i < n && b[i].is_ascii_hexdigit() {
                    i += 1;
                }
                if i < n && is_id_char(b[i]) {
                    while i < n && is_id_char(b[i]) {
                        i += 1;
                    }
                    return Err(unrecognized(start, i));
                }
                let hex = src[hs..i].trim_start_matches('0');
                if hex.len() > 16 {
                    return Err(format!("hex literal too big: {}", &src[start..i]));
                }
                let v = if hex.is_empty() { 0 } else { u64::from_str_radix(hex, 16).unwrap() };
                Tok::Int(Some(v as i64))
            } else {
                let mut is_real = false;
                while i < n && b[i].is_ascii_digit() {
                    i += 1;
                }
                if i < n && b[i] == b'.' {
                    is_real = true;
                    i += 1;
                    while i < n && b[i].is_ascii_digit() {
                        i += 1;
                    }
                }
                if i < n && (b[i] == b'e' || b[i] == b'E') {
                    let mut j = i + 1;
                    if j < n && (b[j] == b'+' || b[j] == b'-') {
                        j += 1;
                    }
                    if j < n && b[j].is_ascii_digit() {
                        while j < n && b[j].is_ascii_digit() {
                            j += 1;
                        }
                        i = j;
                        is_real = true;
                    } else {
                        // "1e" or "1e+" is malformed
                        i = j;
                        while i < n && is_id_char(b[i]) {
                            i += 1;
                        }
                        return Err(unrecognized(start, i));
                    }
                }
                if i < n && is_id_char(b[i]) {
                    while i < n && is_id_char(b[i]) {
                        i += 1;
                    }
                    return Err(unrecognized(start, i));
                }
                let text = &src[start..i];
                if is_real {
                    let t = if text.ends_with('.') { format!("{}0", text) } else { text.to_string() };
                    let t = t.replace(".e", ".0e").replace(".E", ".0E");
                    Tok::Float(t.parse::<f64>().unwrap_or(0.0))
                } else {
                    match text.parse::<i64>() {
                        Ok(v) => Tok::Int(Some(v)),
                        Err(_) => Tok::Int(None),
                    }
                }
            }
        } else if is_id_start(c) {
            while i < n && is_id_char(b[i]) {
                i += 1;
            }
            Tok::Id(src[start..i].to_string())
        } else if c == b'?' {
            i += 1;
            while i < n && b[i].is_ascii_digit() {
                i += 1;
            }
            Tok::Var(src[start..i].to_string())
        } else if (c == b':' || c == b'@' || c == b'$') && i + 1 < n && is_id_char(b[i + 1]) {
            i += 1;
            while i < n && is_id_char(b[i]) {
                i += 1;
            }
            Tok::Var(src[start..i].to_string())
        } else {
            let mut found = None;
            for op in OPS.iter() {
                if src[i..].starts_with(op) {
                    found = Some(*op);
                    break;
                }
            }
            match found {
                Some("!") | None => {
                    // advance by one character for the message
                    let mut e = i + 1;
                    while e < n && !src.is_char_boundary(e) {
                        e += 1;
                    }
                    return Err(unrecognized(start, e));
                }
                Some(op) => {
                    i += op.len();
                    Tok::Op(op)
                }
            }
        };
        toks.push(Token { tok, start, end: i });
    }
    toks.push(Token { tok: Tok::Eof, start: n, end: n });
    Ok(toks)
}
