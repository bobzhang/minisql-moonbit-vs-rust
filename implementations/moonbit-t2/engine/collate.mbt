// Collations, expression collation rules, LIKE and GLOB.

///|
/// Canonical (upper-case) collation name, or an error if unknown.
pub fn check_collation(name : String) -> String raise SqlError {
  let u = name.to_upper()
  match u {
    "BINARY" | "NOCASE" | "RTRIM" => u
    _ => raise SqlError("no such collation sequence: \{name}")
  }
}

///|
fn fold_ascii(c : Int) -> Int {
  if c >= 'A'.to_int() && c <= 'Z'.to_int() {
    c + 32
  } else {
    c
  }
}

///|
fn nocase_compare(a : String, b : String) -> Int {
  let la = a.length()
  let lb = b.length()
  let n = if la < lb { la } else { lb }
  for i in 0..<n {
    let ca = fold_ascii(a[i].to_int())
    let cb = fold_ascii(b[i].to_int())
    if ca != cb {
      return utf16_fix(ca) - utf16_fix(cb)
    }
  }
  la - lb
}

///|
fn rtrim_spaces(s : String) -> StringView {
  let mut e = s.length()
  while e > 0 && s[e - 1] == ' ' {
    e -= 1
  }
  s[0:e]
}

///|
pub fn coll_compare(a : String, b : String, coll : String) -> Int {
  match coll {
    "NOCASE" => nocase_compare(a, b)
    "RTRIM" =>
      text_compare(rtrim_spaces(a).to_owned(), rtrim_spaces(b).to_owned())
    _ => text_compare(a, b)
  }
}

///|
/// Value comparison using a collation for TEXT operands.
pub fn value_compare_coll(a : Value, b : Value, coll : String) -> Int {
  match (a, b) {
    (Text(x), Text(y)) => coll_compare(x, y, coll)
    _ => value_compare(a, b)
  }
}

///|
/// The first explicit COLLATE found in the expression tree (SQLite's
/// EP_Collate propagation).
fn explicit_coll(e : Expr) -> String? {
  match e {
    Collate(_, c) => Some(c)
    Lit(_) | Col(..) | Slot(..) | WinFunc(_, _) => None
    Subquery(_) | Exists(_) | ScalarQ(_) | ExistsQ(_) => None
    InSelect(x, _, _) | InQ(x, _, _) => explicit_coll(x)
    AggRef(coll~, ..) => coll
    Unary(_, x) | Cast(x, _) | IsNull(x, _) => explicit_coll(x)
    Binary(_, l, r) | Is(l, r, _) => first_explicit([l, r])
    Between(x, lo, hi, _) => first_explicit([x, lo, hi])
    InList(x, items, _) => {
      if explicit_coll(x) is Some(c) {
        return Some(c)
      }
      first_explicit(items)
    }
    Like(_, x, p, esc, _) => {
      if explicit_coll(p) is Some(c) {
        return Some(c)
      }
      if explicit_coll(x) is Some(c) {
        return Some(c)
      }
      match esc {
        Some(z) => explicit_coll(z)
        None => None
      }
    }
    Func(args~, ..) => first_explicit(args)
    Case(base, whens, els) => {
      if base is Some(b) && explicit_coll(b) is Some(c) {
        return Some(c)
      }
      for w in whens {
        if explicit_coll(w.0) is Some(c) {
          return Some(c)
        }
        if explicit_coll(w.1) is Some(c) {
          return Some(c)
        }
      }
      match els {
        Some(x) => explicit_coll(x)
        None => None
      }
    }
  }
}

///|
fn first_explicit(es : Array[Expr]) -> String? {
  for x in es {
    if explicit_coll(x) is Some(c) {
      return Some(c)
    }
  }
  None
}

///|
/// Collation of an expression and whether it was given explicitly.
pub fn expr_coll(e : Expr) -> (String, Bool)? {
  match e {
    Collate(_, c) => Some((c, true))
    Slot(coll~, ..) => Some((coll.unwrap_or("BINARY"), false))
    Unary(Pos, x) | Cast(x, _) => expr_coll(x)
    _ =>
      match explicit_coll(e) {
        Some(c) => Some((c, true))
        None => None
      }
  }
}

///|
/// Collation used by a binary comparison `l op r`.
pub fn binary_coll(l : Expr, r : Expr) -> String {
  binary_coll_opt(expr_coll(l), expr_coll(r))
}

///|
fn binary_coll_opt(cl : (String, Bool)?, cr : (String, Bool)?) -> String {
  if cl is Some((c, true)) {
    return c
  }
  if cr is Some((c, true)) {
    return c
  }
  if cl is Some((c, _)) {
    return c
  }
  if cr is Some((c, _)) {
    return c
  }
  "BINARY"
}

///|
/// Collation used by functions such as max(), min() and nullif(): the first
/// argument that has one.
pub fn args_coll(args : Array[Expr]) -> String {
  for a in args {
    if explicit_coll(a) is Some(c) {
      return c
    }
    if expr_coll(a) is Some((c, _)) {
      return c
    }
  }
  "BINARY"
}

// ---------------------------------------------------------------------------
// LIKE / GLOB
// ---------------------------------------------------------------------------

///|
fn lower_ascii_char(c : Char) -> Char {
  if c >= 'A' && c <= 'Z' {
    c.to_ascii_lowercase()
  } else {
    c
  }
}

///|
/// SQL LIKE matching (ASCII case-insensitive).
pub fn like_match(pat : Array[Char], s : Array[Char], esc : Char?) -> Bool {
  like_at(pat, 0, s, 0, esc)
}

///|
fn like_at(
  pat : Array[Char],
  pi : Int,
  s : Array[Char],
  si : Int,
  esc : Char?,
) -> Bool {
  let mut p = pi
  let mut i = si
  while p < pat.length() {
    let c = pat[p]
    if esc is Some(e) && c == e {
      p += 1
      if p >= pat.length() {
        return false
      }
      if i >= s.length() || lower_ascii_char(s[i]) != lower_ascii_char(pat[p]) {
        return false
      }
      p += 1
      i += 1
      continue
    }
    if c == '%' {
      while p < pat.length() && (pat[p] == '%' || pat[p] == '_') {
        if pat[p] == '_' {
          if i >= s.length() {
            return false
          }
          i += 1
        }
        p += 1
      }
      if p >= pat.length() {
        return true
      }
      for k in i..<=s.length() {
        if like_at(pat, p, s, k, esc) {
          return true
        }
      }
      return false
    }
    if i >= s.length() {
      return false
    }
    if c == '_' {
      p += 1
      i += 1
      continue
    }
    if lower_ascii_char(c) != lower_ascii_char(s[i]) {
      return false
    }
    p += 1
    i += 1
  }
  i == s.length()
}

///|
/// SQL GLOB matching (case-sensitive, `*`, `?`, `[...]`).
pub fn glob_match(pat : Array[Char], s : Array[Char]) -> Bool {
  glob_at(pat, 0, s, 0)
}

///|
fn glob_at(pat : Array[Char], pi : Int, s : Array[Char], si : Int) -> Bool {
  let mut p = pi
  let mut i = si
  while p < pat.length() {
    let c = pat[p]
    if c == '*' {
      while p < pat.length() && (pat[p] == '*' || pat[p] == '?') {
        if pat[p] == '?' {
          if i >= s.length() {
            return false
          }
          i += 1
        }
        p += 1
      }
      if p >= pat.length() {
        return true
      }
      for k in i..<=s.length() {
        if glob_at(pat, p, s, k) {
          return true
        }
      }
      return false
    }
    if i >= s.length() {
      return false
    }
    if c == '?' {
      p += 1
      i += 1
      continue
    }
    if c == '[' {
      match glob_class(pat, p + 1, s[i]) {
        Some((matched, next)) => {
          if !matched {
            return false
          }
          p = next
          i += 1
          continue
        }
        None => return false
      }
    }
    if c != s[i] {
      return false
    }
    p += 1
    i += 1
  }
  i == s.length()
}

///|
/// Matches `ch` against a `[...]` class starting after the `[`. Returns
/// whether it matched and the index after the closing `]`; None if the
/// class is unterminated.
fn glob_class(pat : Array[Char], start : Int, ch : Char) -> (Bool, Int)? {
  let mut p = start
  let mut invert = false
  if p < pat.length() && pat[p] == '^' {
    invert = true
    p += 1
  }
  let mut seen = false
  let mut prev : Char? = None
  if p < pat.length() && pat[p] == ']' {
    if ch == ']' {
      seen = true
    }
    prev = Some(']')
    p += 1
  }
  while p < pat.length() && pat[p] != ']' {
    let c = pat[p]
    if c == '-' && prev is Some(lo) && p + 1 < pat.length() && pat[p + 1] != ']' {
      let hi = pat[p + 1]
      if ch >= lo && ch <= hi {
        seen = true
      }
      prev = None
      p += 2
      continue
    }
    if c == ch {
      seen = true
    }
    prev = Some(c)
    p += 1
  }
  if p >= pat.length() {
    return None
  }
  Some((seen != invert, p + 1))
}

///|
/// Evaluates `x LIKE/GLOB pattern [ESCAPE esc]`; returns 0/1 or NULL.
pub fn eval_like(
  op : String,
  pattern : Value,
  x : Value,
  esc : Value?,
) -> Value raise SqlError {
  if op != "LIKE" && op != "GLOB" {
    raise SqlError("no such function: \{op}")
  }
  if pattern is Null || x is Null {
    return Null
  }
  let mut esc_char : Char? = None
  match esc {
    Some(Null) => return Null
    Some(e) => {
      let chars = e.to_text().to_array()
      if chars.length() != 1 {
        raise SqlError("ESCAPE expression must be a single character")
      }
      esc_char = Some(chars[0])
    }
    None => ()
  }
  let p = pattern.to_text().to_array()
  let s = x.to_text().to_array()
  let r = if op == "LIKE" {
    like_match(p, s, esc_char)
  } else {
    glob_match(p, s)
  }
  Int(if r { 1L } else { 0L })
}
