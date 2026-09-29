///|
pub(all) enum Tok {
  /// Bare word: identifier or keyword (original spelling).
  Word(String)
  /// "..." quoted identifier (may fall back to a string literal).
  DqIdent(String)
  /// [...] or `...` quoted identifier.
  QIdent(String)
  Str(String)
  BlobLit(Bytes)
  /// Numeric literal text.
  Num(String)
  /// Bind parameter (?, ?NNN, :name, @name, $name).
  Param(String)
  /// Operator or punctuation.
  Op(String)
  Eof
} derive(Debug, Eq)

///|
pub(all) struct Token {
  tok : Tok
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
fn is_digit(c : Int) -> Bool {
  c >= '0'.to_int() && c <= '9'.to_int()
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
/// Reads a quoted token starting at `i` (the opening quote) and closing with
/// `close`; doubled closing quotes are unescaped. Returns (content, next index).
fn read_quoted(
  s : String,
  i : Int,
  close : Int,
) -> (String, Int) raise SqlError {
  let n = s.length()
  let sb = StringBuilder()
  let mut j = i + 1
  let mut seg = j
  while j < n {
    if s[j].to_int() == close {
      if close != ']'.to_int() && j + 1 < n && s[j + 1].to_int() == close {
        sb.write_view(s[seg:j + 1])
        j += 2
        seg = j
        continue
      }
      sb.write_view(s[seg:j])
      return (sb.to_string(), j + 1)
    }
    j += 1
  }
  raise err("unrecognized token: \"" + s[i:].to_owned() + "\"")
}

///|
pub fn tokenize(s : String) -> Array[Token] raise SqlError {
  tokenize_spans(s).0
}

///|
/// Tokenizes `s`, also returning the end offset of each token.
pub fn tokenize_spans(s : String) -> (Array[Token], Array[Int]) raise SqlError {
  let toks : Array[Token] = []
  let ends : Array[Int] = []
  let n = s.length()
  let mut i = 0
  while i < n {
    while ends.length() < toks.length() {
      ends.push(i)
    }
    let c = s[i].to_int()
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 0x0B || c == 0x0C {
      i += 1
      continue
    }
    // comments
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
    let start = i
    // blob literal
    if (c == 'x' || c == 'X') && i + 1 < n && s[i + 1] == '\'' {
      let (content, next) = read_quoted(s, i + 1, '\''.to_int())
      if content.length() % 2 != 0 {
        raise err("unrecognized token: \"" + s[start:next].to_owned() + "\"")
      }
      let bytes = FixedArray::make(content.length() / 2, b'\x00')
      for k in 0..<(content.length() / 2) {
        let h = hex_val(content[2 * k].to_int())
        let l = hex_val(content[2 * k + 1].to_int())
        if h < 0 || l < 0 {
          raise err("unrecognized token: \"" + s[start:next].to_owned() + "\"")
        }
        bytes[k] = (h * 16 + l).to_byte()
      }
      toks.push({ tok: BlobLit(Bytes::from_array(bytes[:])), pos: start, })
      i = next
      continue
    }
    if is_ident_start(c) {
      let mut j = i + 1
      while j < n && is_ident_char(s[j].to_int()) {
        j += 1
      }
      toks.push({ tok: Word(s[i:j].to_owned()), pos: start, })
      i = j
      continue
    }
    if is_digit(c) || (c == '.' && i + 1 < n && is_digit(s[i + 1].to_int())) {
      let mut j = i
      if c == '0' && i + 1 < n && (s[i + 1] == 'x' || s[i + 1] == 'X') {
        j = i + 2
        while j < n && hex_val(s[j].to_int()) >= 0 {
          j += 1
        }
        if j == i + 2 {
          raise err("unrecognized token: \"" + s[i:j].to_owned() + "\"")
        }
      } else {
        while j < n && is_digit(s[j].to_int()) {
          j += 1
        }
        if j < n && s[j] == '.' {
          j += 1
          while j < n && is_digit(s[j].to_int()) {
            j += 1
          }
        }
        if j < n && (s[j] == 'e' || s[j] == 'E') {
          let mut k = j + 1
          if k < n && (s[k] == '+' || s[k] == '-') {
            k += 1
          }
          if k < n && is_digit(s[k].to_int()) {
            while k < n && is_digit(s[k].to_int()) {
              k += 1
            }
            j = k
          } else {
            raise err("unrecognized token: \"" + s[i:k].to_owned() + "\"")
          }
        }
      }
      if j < n && is_ident_char(s[j].to_int()) {
        let mut k = j
        while k < n && is_ident_char(s[k].to_int()) {
          k += 1
        }
        raise err("unrecognized token: \"" + s[i:k].to_owned() + "\"")
      }
      toks.push({ tok: Num(s[i:j].to_owned()), pos: start, })
      i = j
      continue
    }
    match c {
      '\'' => {
        let (content, next) = read_quoted(s, i, c)
        toks.push({ tok: Str(content), pos: start, })
        i = next
      }
      '"' => {
        let (content, next) = read_quoted(s, i, c)
        toks.push({ tok: DqIdent(content), pos: start, })
        i = next
      }
      '`' => {
        let (content, next) = read_quoted(s, i, c)
        toks.push({ tok: QIdent(content), pos: start, })
        i = next
      }
      '[' => {
        let (content, next) = read_quoted(s, i, ']'.to_int())
        toks.push({ tok: QIdent(content), pos: start, })
        i = next
      }
      '?' => {
        let mut j = i + 1
        while j < n && is_digit(s[j].to_int()) {
          j += 1
        }
        toks.push({ tok: Param(s[i:j].to_owned()), pos: start, })
        i = j
      }
      ':' | '@' | '$' => {
        let mut j = i + 1
        while j < n && is_ident_char(s[j].to_int()) {
          j += 1
        }
        if j == i + 1 {
          raise err("unrecognized token: \"" + s[i:j].to_owned() + "\"")
        }
        toks.push({ tok: Param(s[i:j].to_owned()), pos: start, })
        i = j
      }
      _ => {
        let two = if i + 1 < n { s[i:i + 2].to_owned() } else { "" }
        let three = if i + 2 < n { s[i:i + 3].to_owned() } else { "" }
        if three == "->>" {
          toks.push({ tok: Op(three), pos: start, })
          i += 3
        } else if two == "||" ||
          two == "<=" ||
          two == ">=" ||
          two == "==" ||
          two == "!=" ||
          two == "<>" ||
          two == "<<" ||
          two == ">>" ||
          two == "->" {
          toks.push({ tok: Op(two), pos: start, })
          i += 2
        } else if "+-*/%&|~<>=(),.;".contains_char(s.get_char(i).unwrap()) {
          toks.push({ tok: Op(s[i:i + 1].to_owned()), pos: start, })
          i += 1
        } else {
          raise err("unrecognized token: \"" + s[i:i + 1].to_owned() + "\"")
        }
      }
    }
  }
  while ends.length() < toks.length() {
    ends.push(i)
  }
  toks.push({ tok: Eof, pos: n, })
  ends.push(n)
  (toks, ends)
}
