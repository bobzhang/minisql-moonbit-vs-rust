// Tokenizer and statement splitter.

#[derive(Debug, Clone, PartialEq)]
pub enum Tok {
    /// Unquoted word (keyword or identifier), original spelling.
    Word(String),
    /// Quoted identifier; the flag is true for "double-quoted" names, which
    /// may fall back to string literals.
    QIdent(String, bool),
    Str(String),
    Blob(Vec<u8>),
    Int(String),
    Float(String),
    Param(String),
    /// Operator or punctuation.
    Op(&'static str),
    Eof,
}

#[derive(Debug, Clone)]
pub struct Token {
    pub tok: Tok,
    pub text: String,
    /// Byte offset of the token in the source text.
    pub start: usize,
}

fn is_id_start(c: char) -> bool {
    c.is_ascii_alphabetic() || c == '_' || (c as u32) >= 0x80
}

fn is_id_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_' || c == '$' || (c as u32) >= 0x80
}

pub fn tokenize(src: &str) -> Result<Vec<Token>, String> {
    let chars: Vec<(usize, char)> = src.char_indices().collect();
    let n = chars.len();
    let byte_at = |i: usize| if i < n { chars[i].0 } else { src.len() };
    let ch = |i: usize| if i < n { chars[i].1 } else { '\0' };
    let mut toks = Vec::new();
    let mut i = 0;
    while i < n {
        let c = ch(i);
        let start = i;
        if c.is_whitespace() {
            i += 1;
            continue;
        }
        if c == '-' && ch(i + 1) == '-' {
            while i < n && ch(i) != '\n' {
                i += 1;
            }
            continue;
        }
        if c == '/' && ch(i + 1) == '*' {
            i += 2;
            while i < n && !(ch(i) == '*' && ch(i + 1) == '/') {
                i += 1;
            }
            i = (i + 2).min(n);
            continue;
        }
        let unrecognized = |from: usize| -> String {
            format!("unrecognized token: \"{}\"", &src[byte_at(from)..])
        };
        let tok = if c == '\'' || c == '"' || c == '`' {
            let q = c;
            let mut s = String::new();
            i += 1;
            loop {
                if i >= n {
                    return Err(unrecognized(start));
                }
                if ch(i) == q {
                    if ch(i + 1) == q {
                        s.push(q);
                        i += 2;
                        continue;
                    }
                    i += 1;
                    break;
                }
                s.push(ch(i));
                i += 1;
            }
            match q {
                '\'' => Tok::Str(s),
                '"' => Tok::QIdent(s, true),
                _ => Tok::QIdent(s, false),
            }
        } else if c == '[' {
            let mut s = String::new();
            i += 1;
            loop {
                if i >= n {
                    return Err(unrecognized(start));
                }
                if ch(i) == ']' {
                    i += 1;
                    break;
                }
                s.push(ch(i));
                i += 1;
            }
            Tok::QIdent(s, false)
        } else if (c == 'x' || c == 'X') && ch(i + 1) == '\'' {
            i += 2;
            let hs = i;
            while i < n && ch(i) != '\'' {
                i += 1;
            }
            if i >= n {
                return Err(unrecognized(start));
            }
            let hex: String = chars[hs..i].iter().map(|p| p.1).collect();
            i += 1;
            if hex.len() % 2 != 0 || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
                return Err(format!(
                    "unrecognized token: \"{}\"",
                    &src[byte_at(start)..byte_at(i)]
                ));
            }
            let bytes = (0..hex.len())
                .step_by(2)
                .map(|k| u8::from_str_radix(&hex[k..k + 2], 16).unwrap())
                .collect();
            Tok::Blob(bytes)
        } else if c.is_ascii_digit() || (c == '.' && ch(i + 1).is_ascii_digit()) {
            let mut is_float = false;
            if c == '0' && (ch(i + 1) == 'x' || ch(i + 1) == 'X') && ch(i + 2).is_ascii_hexdigit() {
                i += 2;
                while ch(i).is_ascii_hexdigit() {
                    i += 1;
                }
            } else {
                while ch(i).is_ascii_digit() {
                    i += 1;
                }
                if ch(i) == '.' {
                    is_float = true;
                    i += 1;
                    while ch(i).is_ascii_digit() {
                        i += 1;
                    }
                }
                if ch(i) == 'e' || ch(i) == 'E' {
                    let save = i;
                    i += 1;
                    if ch(i) == '+' || ch(i) == '-' {
                        i += 1;
                    }
                    if ch(i).is_ascii_digit() {
                        is_float = true;
                        while ch(i).is_ascii_digit() {
                            i += 1;
                        }
                    } else {
                        // "1e" followed by junk: unrecognized token
                        return Err(format!(
                            "unrecognized token: \"{}\"",
                            &src[byte_at(start)..byte_at(save + 1)]
                        ));
                    }
                }
            }
            if i < n && is_id_char(ch(i)) {
                while i < n && is_id_char(ch(i)) {
                    i += 1;
                }
                return Err(format!(
                    "unrecognized token: \"{}\"",
                    &src[byte_at(start)..byte_at(i)]
                ));
            }
            let text = src[byte_at(start)..byte_at(i)].to_string();
            if is_float {
                Tok::Float(text)
            } else {
                Tok::Int(text)
            }
        } else if is_id_start(c) {
            while i < n && is_id_char(ch(i)) {
                i += 1;
            }
            Tok::Word(src[byte_at(start)..byte_at(i)].to_string())
        } else if c == '?' || c == ':' || c == '@' || c == '$' {
            i += 1;
            while i < n && is_id_char(ch(i)) {
                i += 1;
            }
            Tok::Param(src[byte_at(start)..byte_at(i)].to_string())
        } else {
            let two: String = [c, ch(i + 1)].iter().collect();
            let three: String = [c, ch(i + 1), ch(i + 2)].iter().collect();
            let op: &'static str = if three == "->>" {
                "->>"
            } else {
                match two.as_str() {
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
                        '=' => "=",
                        '<' => "<",
                        '>' => ">",
                        '+' => "+",
                        '-' => "-",
                        '*' => "*",
                        '/' => "/",
                        '%' => "%",
                        '&' => "&",
                        '|' => "|",
                        '~' => "~",
                        '(' => "(",
                        ')' => ")",
                        ',' => ",",
                        '.' => ".",
                        ';' => ";",
                        _ => {
                            return Err(format!("unrecognized token: \"{}\"", c));
                        }
                    },
                }
            };
            i += op.chars().count();
            Tok::Op(op)
        };
        toks.push(Token {
            tok,
            text: src[byte_at(start)..byte_at(i)].to_string(),
            start: byte_at(start),
        });
    }
    toks.push(Token {
        tok: Tok::Eof,
        text: String::new(),
        start: src.len(),
    });
    Ok(toks)
}

/// Split a script into statements on ';' outside quotes and comments (SPEC §2.2).
pub fn split_statements(script: &str) -> Vec<String> {
    let b = script.as_bytes();
    let n = b.len();
    let mut out = Vec::new();
    let mut start = 0;
    let mut i = 0;
    while i < n {
        let c = b[i];
        if c == b'\'' || c == b'"' || c == b'`' {
            let mut j = i + 1;
            while j < n {
                if b[j] == c {
                    if j + 1 < n && b[j + 1] == c {
                        j += 2;
                        continue;
                    }
                    break;
                }
                j += 1;
            }
            i = (j + 1).min(n);
        } else if c == b'[' {
            let mut j = i + 1;
            while j < n && b[j] != b']' {
                j += 1;
            }
            i = (j + 1).min(n);
        } else if c == b'-' && i + 1 < n && b[i + 1] == b'-' {
            while i < n && b[i] != b'\n' {
                i += 1;
            }
        } else if c == b'/' && i + 1 < n && b[i + 1] == b'*' {
            let mut j = i + 2;
            while j + 1 < n && !(b[j] == b'*' && b[j + 1] == b'/') {
                j += 1;
            }
            i = if j + 1 < n { j + 2 } else { n };
        } else if c == b';' {
            out.push(script[start..i].to_string());
            i += 1;
            start = i;
        } else {
            i += 1;
        }
    }
    out.push(script[start..].to_string());
    out.into_iter()
        .filter(|s| !is_blank(s))
        .map(|s| s.trim().to_string())
        .collect()
}

fn is_blank(s: &str) -> bool {
    let b = s.as_bytes();
    let n = b.len();
    let mut i = 0;
    while i < n {
        if b[i].is_ascii_whitespace() {
            i += 1;
        } else if b[i] == b'-' && i + 1 < n && b[i + 1] == b'-' {
            while i < n && b[i] != b'\n' {
                i += 1;
            }
        } else if b[i] == b'/' && i + 1 < n && b[i + 1] == b'*' {
            let mut j = i + 2;
            while j + 1 < n && !(b[j] == b'*' && b[j + 1] == b'/') {
                j += 1;
            }
            i = if j + 1 < n { j + 2 } else { n };
        } else {
            return false;
        }
    }
    true
}
