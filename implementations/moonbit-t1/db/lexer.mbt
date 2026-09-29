///|
pub(all) enum TokKind {
  TIdent // unquoted identifier or keyword
  TQuoted // "..." identifier (may be a string)
  TBracket // [..] or `..` identifier
  TString
  TBlob
  TInteger
  TFloat
  TParam
  TOp
  TEof
} derive(Eq, Debug)

///|
pub(all) struct Token {
  kind : TokKind
  text : String // identifier name / decoded string / operator / number text
  upper : String // uppercased text for keyword checks (identifiers only)
  pos : Int
} derive(Debug)

///|
fn is_ident_start(c : Int) -> Bool {
  (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
  (c >= 'A'.to_int() && c <= 'Z'.to_int()) ||
  c == '_'.to_int() ||
  c >= 0x80
}

///|
fn is_ident_char(c : Int) -> Bool {
  is_ident_start(c) ||
  (c >= '0'.to_int() && c <= '9'.to_int()) ||
  c == '$'.to_int()
}

///|
fn hex_val(c : Int) -> Int {
  if c >= '0'.to_int() && c <= '9'.to_int() {
    c - '0'.to_int()
  } else if c >= 'a'.to_int() && c <= 'f'.to_int() {
    c - 'a'.to_int() + 10
  } else if c >= 'A'.to_int() && c <= 'F'.to_int() {
    c - 'A'.to_int() + 10
  } else {
    -1
  }
}

///|
fn mk_tok(kind : TokKind, text : String, pos : Int) -> Token {
  { kind, text, upper: "", pos, }
}

///|
/// Read a quoted token starting at `i` (the opening quote). Returns the
/// decoded contents and the index after the closing quote, or None.
fn read_quoted(s : String, i : Int, close : Int) -> (String, Int)? {
  let n = s.length()
  let sb = StringBuilder()
  let mut j = i + 1
  let mut start = j
  while j < n {
    let c = s[j].to_int()
    if c == close {
      if close != ']'.to_int() && j + 1 < n && s[j + 1].to_int() == close {
        sb.write_view(s[start:j + 1])
        j += 2
        start = j
        continue
      }
      sb.write_view(s[start:j])
      return Some((sb.to_string(), j + 1))
    }
    j += 1
  }
  None
}

///|
/// Consume digits (hex digits if `hex`) with single '_' separators between them.
fn scan_digits(s : String, start : Int, hex : Bool) -> Int {
  let n = s.length()
  let is_d = (c : UInt16) => {
    if hex {
      hex_val(c.to_int()) >= 0
    } else {
      is_digit_cu(c)
    }
  }
  let mut i = start
  while i < n {
    if is_d(s[i]) {
      i += 1
    } else if s[i] == '_' &&
      i > start &&
      is_d(s[i - 1]) &&
      i + 1 < n &&
      is_d(s[i + 1]) {
      i += 1
    } else {
      break
    }
  }
  i
}

///|
pub fn tokenize(s : String) -> Array[Token] raise SqlError {
  let toks : Array[Token] = []
  let n = s.length()
  let mut i = 0
  while i < n {
    let c = s[i].to_int()
    if is_space_cu(s[i]) {
      i += 1
      continue
    }
    if c == '-'.to_int() && i + 1 < n && s[i + 1] == '-' {
      while i < n && s[i] != '\n' {
        i += 1
      }
      continue
    }
    if c == '/'.to_int() && i + 1 < n && s[i + 1] == '*' {
      i += 2
      while i < n && !(s[i] == '*' && i + 1 < n && s[i + 1] == '/') {
        i += 1
      }
      i = if i < n { i + 2 } else { n }
      continue
    }
    let start = i
    if (c == 'x'.to_int() || c == 'X'.to_int()) && i + 1 < n && s[i + 1] == '\'' {
      match read_quoted(s, i + 1, '\''.to_int()) {
        Some((body, next)) => {
          if body.length() % 2 != 0 {
            raise sql_err("unrecognized token: \"\{s[start:next]}\"")
          }
          let buf = @buffer.Buffer()
          let mut k = 0
          while k < body.length() {
            let h = hex_val(body[k].to_int())
            let l = hex_val(body[k + 1].to_int())
            if h < 0 || l < 0 {
              raise sql_err("unrecognized token: \"\{s[start:next]}\"")
            }
            buf.write_byte((h * 16 + l).to_byte())
            k += 2
          }
          toks.push(mk_tok(TBlob, blob_hex(buf.to_bytes()), start))
          i = next
          continue
        }
        None => raise sql_err("unrecognized token: \"\{s[start:]}\"")
      }
    }
    if is_ident_start(c) {
      while i < n && is_ident_char(s[i].to_int()) {
        i += 1
      }
      let t = s[start:i].to_owned()
      toks.push({ kind: TIdent, text: t, upper: t.to_upper(), pos: start, })
      continue
    }
    if (c >= '0'.to_int() && c <= '9'.to_int()) ||
      (c == '.'.to_int() && i + 1 < n && is_digit_cu(s[i + 1])) {
      // hex
      if c == '0'.to_int() &&
        i + 1 < n &&
        (s[i + 1] == 'x' || s[i + 1] == 'X') &&
        i + 2 < n &&
        hex_val(s[i + 2].to_int()) >= 0 {
        i = scan_digits(s, i + 2, true)
        if i < n && is_ident_char(s[i].to_int()) {
          raise sql_err("unrecognized token: \"\{s[start:i + 1]}\"")
        }
        toks.push(
          mk_tok(
            TInteger,
            s[start:i].to_owned().replace_all(old="_", new=""),
            start,
          ),
        )
        continue
      }
      let mut is_float = false
      i = scan_digits(s, i, false)
      if i < n && s[i] == '.' {
        is_float = true
        i = scan_digits(s, i + 1, false)
      }
      if i < n && (s[i] == 'e' || s[i] == 'E') {
        let mut j = i + 1
        if j < n && (s[j] == '+' || s[j] == '-') {
          j += 1
        }
        if j < n && is_digit_cu(s[j]) {
          is_float = true
          i = scan_digits(s, j, false)
        } else {
          raise sql_err("unrecognized token: \"\{s[start:j]}\"")
        }
      }
      if i < n && is_ident_char(s[i].to_int()) {
        raise sql_err("unrecognized token: \"\{s[start:i + 1]}\"")
      }
      toks.push(
        mk_tok(
          if is_float {
            TFloat
          } else {
            TInteger
          },
          s[start:i].to_owned().replace_all(old="_", new=""),
          start,
        ),
      )
      continue
    }
    if c == '\''.to_int() {
      match read_quoted(s, i, c) {
        Some((body, next)) => {
          toks.push(mk_tok(TString, body, start))
          i = next
          continue
        }
        None => raise sql_err("unrecognized token: \"\{s[start:]}\"")
      }
    }
    if c == '"'.to_int() || c == '`'.to_int() || c == '['.to_int() {
      let close = if c == '['.to_int() { ']'.to_int() } else { c }
      match read_quoted(s, i, close) {
        Some((body, next)) => {
          let kind = if c == '"'.to_int() { TQuoted } else { TBracket }
          toks.push({ kind, text: body, upper: body.to_upper(), pos: start, })
          i = next
          continue
        }
        None => raise sql_err("unrecognized token: \"\{s[start:]}\"")
      }
    }
    if c == '?'.to_int() {
      i += 1
      while i < n && is_digit_cu(s[i]) {
        i += 1
      }
      toks.push(mk_tok(TParam, s[start:i].to_owned(), start))
      continue
    }
    if (c == ':'.to_int() || c == '@'.to_int() || c == '$'.to_int()) &&
      i + 1 < n &&
      is_ident_char(s[i + 1].to_int()) {
      i += 1
      while i < n && is_ident_char(s[i].to_int()) {
        i += 1
      }
      toks.push(mk_tok(TParam, s[start:i].to_owned(), start))
      continue
    }
    // operators
    let two = if i + 1 < n { s[i:i + 2].to_owned() } else { "" }
    let three = if i + 2 < n { s[i:i + 3].to_owned() } else { "" }
    if three == "->>" {
      toks.push(mk_tok(TOp, three, start))
      i += 3
      continue
    }
    match two {
      "||" | "<=" | ">=" | "==" | "!=" | "<>" | "<<" | ">>" | "->" => {
        toks.push(mk_tok(TOp, two, start))
        i += 2
        continue
      }
      _ => ()
    }
    match s[i:i + 1] {
      "("
      | ")"
      | ","
      | ";"
      | "+"
      | "-"
      | "*"
      | "/"
      | "%"
      | "="
      | "<"
      | ">"
      | "&"
      | "|"
      | "~"
      | "." => {
        toks.push(mk_tok(TOp, s[i:i + 1].to_owned(), start))
        i += 1
      }
      _ => raise sql_err("unrecognized token: \"\{s[i:i + 1]}\"")
    }
  }
  toks.push(mk_tok(TEof, "", n))
  toks
}

///|
/// Split a script into statements (SPEC §2.2). Pieces with only whitespace
/// and comments are dropped.
pub fn split_statements(s : String) -> Array[String] {
  let out : Array[String] = []
  let n = s.length()
  let mut i = 0
  let mut start = 0
  let mut has_content = false
  while i < n {
    let c = s[i]
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
      i = if i < n { i + 2 } else { n }
      continue
    }
    if c == '\'' || c == '"' || c == '`' || c == '[' {
      has_content = true
      let close = if c == '[' { ']'.to_int() } else { c.to_int() }
      i += 1
      while i < n {
        if s[i].to_int() == close {
          if close != ']'.to_int() && i + 1 < n && s[i + 1].to_int() == close {
            i += 2
            continue
          }
          break
        }
        i += 1
      }
      i += 1
      continue
    }
    if c == ';' {
      if has_content {
        out.push(s[start:i].to_owned())
      }
      i += 1
      start = i
      has_content = false
      continue
    }
    if !is_space_cu(c) {
      has_content = true
    }
    i += 1
  }
  if has_content && start < n {
    out.push(s[start:].to_owned())
  }
  out
}
