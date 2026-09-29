///|
pub(all) enum TokKind {
  TIdent // bare identifier or keyword
  TQuoted // "..." (identifier, or string if unresolved)
  TBracket // [...] or `...` (always identifier)
  TString
  TInteger
  TFloat
  TBlob
  TOp
  TEof
} derive(Eq, Debug)

///|
pub(all) struct Token {
  kind : TokKind
  text : String
  pos : Int
} derive(Debug)

///|
pub suberror SqlError {
  SqlError(String)
} derive(Debug)

///|
pub fn sql_err(msg : String) -> SqlError {
  SqlError(msg)
}

///|
fn is_ident_start(c : UInt16) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  c == '_' ||
  c.to_int() >= 0x80
}

///|
fn is_ident_char(c : UInt16) -> Bool {
  is_ident_start(c) || is_digit_cu(c) || c == '$'
}

///|
fn is_hex_cu(c : UInt16) -> Bool {
  is_digit_cu(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

///|
/// Reads a quoted token starting at `i` (the opening quote) with closing
/// quote `q`; doubled quotes are escapes. Returns (content, end index).
fn lex_quoted(s : String, i : Int, q : UInt16) -> (String, Int)? {
  let n = s.length()
  let sb = StringBuilder()
  let mut j = i + 1
  while j < n {
    if s[j] == q {
      if j + 1 < n && s[j + 1] == q {
        sb.write_view(s[j:j + 1])
        j += 2
        continue
      }
      return Some((sb.to_string(), j + 1))
    }
    // copy one code unit (surrogates are copied pairwise below)
    let start = j
    j += 1
    if s[start].to_int() >= 0xD800 && s[start].to_int() < 0xDC00 && j < n {
      j += 1
    }
    sb.write_view(s[start:j])
  }
  None
}

///|
pub fn tokenize(s : String) -> Array[Token] raise SqlError {
  let toks : Array[Token] = []
  let n = s.length()
  let mut i = 0
  while i < n {
    let c = s[i]
    if is_space_cu(c) {
      i += 1
      continue
    }
    if c == '-' && i + 1 < n && s[i + 1] == '-' {
      while i < n && s[i] != '\n' {
        i += 1
      }
      continue
    }
    if c == '/' && i + 1 < n && s[i + 1] == '*' {
      i += 2
      while i < n && !(s[i] == '*' && i + 1 < n && s[i + 1] == '/') {
        i += 1
      }
      i = if i + 2 > n { n } else { i + 2 }
      continue
    }
    let start = i
    if is_digit_cu(c) || (c == '.' && i + 1 < n && is_digit_cu(s[i + 1])) {
      if c == '0' && i + 1 < n && (s[i + 1] == 'x' || s[i + 1] == 'X') {
        let mut j = i + 2
        while j < n && is_hex_cu(s[j]) {
          j += 1
        }
        if j == i + 2 || (j < n && is_ident_char(s[j])) {
          raise SqlError("unrecognized token: \"\{s[start:j + 1]}\"")
        }
        toks.push({ kind: TInteger, text: s[start:j].to_owned(), pos: start, })
        i = j
        continue
      }
      let sc = scan_number(s, i)
      let j = sc.end
      if j < n && is_ident_char(s[j]) {
        raise SqlError("unrecognized token: \"\{s[start:j + 1]}\"")
      }
      toks.push({
        kind: if sc.is_int {
          TInteger
        } else {
          TFloat
        },
        text: s[start:j].to_owned(),
        pos: start,
      })
      i = j
      continue
    }
    if (c == 'x' || c == 'X') && i + 1 < n && s[i + 1] == '\'' {
      match lex_quoted(s, i + 1, '\'') {
        Some((hex, end)) => {
          let mut ok = hex.length() % 2 == 0
          for k in 0..<hex.length() {
            if !is_hex_cu(hex[k]) {
              ok = false
            }
          }
          if !ok {
            raise SqlError("unrecognized token: \"\{s[start:end]}\"")
          }
          toks.push({ kind: TBlob, text: hex, pos: start, })
          i = end
          continue
        }
        None => raise SqlError("unrecognized token: \"\{s[start:]}\"")
      }
    }
    if is_ident_start(c) {
      let mut j = i + 1
      while j < n && is_ident_char(s[j]) {
        j += 1
      }
      toks.push({ kind: TIdent, text: s[start:j].to_owned(), pos: start, })
      i = j
      continue
    }
    if c == '\'' || c == '"' || c == '`' {
      match lex_quoted(s, i, c) {
        Some((text, end)) => {
          let kind = if c == '\'' {
            TString
          } else if c == '"' {
            TQuoted
          } else {
            TBracket
          }
          toks.push({ kind, text, pos: start, })
          i = end
          continue
        }
        None => raise SqlError("unrecognized token: \"\{s[start:]}\"")
      }
    }
    if c == '[' {
      let mut j = i + 1
      while j < n && s[j] != ']' {
        j += 1
      }
      if j >= n {
        raise SqlError("unrecognized token: \"\{s[start:]}\"")
      }
      toks.push({ kind: TBracket, text: s[i + 1:j].to_owned(), pos: start, })
      i = j + 1
      continue
    }
    let two = if i + 1 < n { s[i:i + 2].to_owned() } else { "" }
    let three = if i + 2 < n { s[i:i + 3].to_owned() } else { "" }
    if three == "->>" {
      toks.push({ kind: TOp, text: three, pos: start, })
      i += 3
      continue
    }
    match two {
      "||" | "->" | "==" | "!=" | "<>" | "<=" | ">=" | "<<" | ">>" => {
        toks.push({ kind: TOp, text: two, pos: start, })
        i += 2
        continue
      }
      _ => ()
    }
    match c {
      '('
      | ')'
      | ','
      | ';'
      | '+'
      | '-'
      | '*'
      | '/'
      | '%'
      | '='
      | '<'
      | '>'
      | '&'
      | '|'
      | '~'
      | '.'
      | '?' => {
        toks.push({ kind: TOp, text: s[i:i + 1].to_owned(), pos: start, })
        i += 1
      }
      _ => raise SqlError("unrecognized token: \"\{s[i:i + 1]}\"")
    }
  }
  toks.push({ kind: TEof, text: "", pos: n, })
  toks
}

///|
/// Splits a script into statements (SPEC §2.2). Pieces with only whitespace
/// and comments are dropped.
pub fn split_statements(s : String) -> Array[String] {
  let out : Array[String] = []
  let n = s.length()
  let mut i = 0
  let mut start = 0
  let mut has_content = false
  while i < n {
    let c = s[i]
    if c == '\'' || c == '"' || c == '`' {
      has_content = true
      let mut j = i + 1
      while j < n {
        if s[j] == c {
          if j + 1 < n && s[j + 1] == c {
            j += 2
            continue
          }
          break
        }
        j += 1
      }
      i = j + 1
    } else if c == '[' {
      has_content = true
      let mut j = i + 1
      while j < n && s[j] != ']' {
        j += 1
      }
      i = j + 1
    } else if c == '-' && i + 1 < n && s[i + 1] == '-' {
      while i < n && s[i] != '\n' {
        i += 1
      }
    } else if c == '/' && i + 1 < n && s[i + 1] == '*' {
      let mut j = i + 2
      while j < n && !(s[j] == '*' && j + 1 < n && s[j + 1] == '/') {
        j += 1
      }
      i = if j >= n { n } else { j + 2 }
    } else if c == ';' {
      if has_content {
        out.push(s[start:i].to_owned())
      }
      has_content = false
      i += 1
      start = i
    } else {
      if !is_space_cu(c) {
        has_content = true
      }
      i += 1
    }
  }
  if has_content && start < n {
    out.push(s[start:n].to_owned())
  }
  out
}
