///|
/// Result of scanning a number at the start of `s[pos:]`.
priv struct NumScan {
  end : Int // index just past the number (== start if none)
  is_int : Bool // no '.' and no exponent
}

///|
fn is_space_cu(c : UInt16) -> Bool {
  c == ' ' ||
  c == '\t' ||
  c == '\n' ||
  c == '\r' ||
  c == '\u{0C}' ||
  c == '\u{0B}'
}

///|
fn is_digit_cu(c : UInt16) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// Scans `[sign] digits [. digits] [e [sign] digits]` starting at `pos`.
fn scan_number(s : String, pos : Int) -> NumScan {
  let n = s.length()
  let mut i = pos
  if i < n && (s[i] == '+' || s[i] == '-') {
    i += 1
  }
  let mut digits = 0
  while i < n && is_digit_cu(s[i]) {
    i += 1
    digits += 1
  }
  let mut is_int = true
  if i < n && s[i] == '.' {
    let save = i
    i += 1
    let mut fd = 0
    while i < n && is_digit_cu(s[i]) {
      i += 1
      fd += 1
    }
    if digits + fd == 0 {
      i = save
    } else {
      digits += fd
      is_int = false
    }
  }
  if digits == 0 {
    return { end: pos, is_int: true, }
  }
  if i < n && (s[i] == 'e' || s[i] == 'E') {
    let mut j = i + 1
    if j < n && (s[j] == '+' || s[j] == '-') {
      j += 1
    }
    if j < n && is_digit_cu(s[j]) {
      while j < n && is_digit_cu(s[j]) {
        j += 1
      }
      i = j
      is_int = false
    }
  }
  { end: i, is_int, }
}

///|
/// Parses a syntactically valid decimal number string to a double.
pub fn parse_real_text(s : StringView) -> Double {
  @string.parse_double(s) catch {
    _ => {
      // overflow or underflow
      let neg = s.length() > 0 && s[0] == '-'
      let mut exp_neg = false
      match s.find("e") {
        Some(i) => exp_neg = s[i + 1:].has_prefix("-")
        None =>
          match s.find("E") {
            Some(i) => exp_neg = s[i + 1:].has_prefix("-")
            None => ()
          }
      }
      if exp_neg {
        if neg {
          -0.0
        } else {
          0.0
        }
      } else if neg {
        @double.neg_infinity
      } else {
        @double.infinity
      }
    }
  }
}

///|
/// Parses a syntactically valid integer string; None on overflow.
fn parse_int_text(s : StringView) -> Int64? {
  let n = s.length()
  let mut i = 0
  let mut neg = false
  if i < n && (s[i] == '+' || s[i] == '-') {
    neg = s[i] == '-'
    i += 1
  }
  // accumulate as negative to cover MIN
  let mut acc = 0L
  while i < n {
    let d = (s[i].to_int() - '0'.to_int()).to_int64()
    if acc < (@int64.MIN_VALUE + d) / 10L {
      return None
    }
    acc = acc * 10L - d
    i += 1
  }
  if neg {
    Some(acc)
  } else if acc == @int64.MIN_VALUE {
    None
  } else {
    Some(-acc)
  }
}

///|
/// If the whole text (ignoring surrounding whitespace) is a number, returns
/// it as Int (if integer-looking and in range) or Real.
pub fn parse_numeric_text(s : String) -> Value? {
  let n = s.length()
  let mut i = 0
  while i < n && is_space_cu(s[i]) {
    i += 1
  }
  let sc = scan_number(s, i)
  if sc.end == i {
    return None
  }
  let mut j = sc.end
  while j < n && is_space_cu(s[j]) {
    j += 1
  }
  if j != n {
    return None
  }
  let text = s[i:sc.end]
  if sc.is_int {
    match parse_int_text(text) {
      Some(v) => return Some(Int(v))
      None => ()
    }
  }
  Some(Real(parse_real_text(text)))
}

///|
/// Numeric value of the longest numeric prefix of `s` (0 if none).
pub fn numeric_prefix(s : String) -> Value {
  let n = s.length()
  let mut i = 0
  while i < n && is_space_cu(s[i]) {
    i += 1
  }
  let sc = scan_number(s, i)
  if sc.end == i {
    return Int(0L)
  }
  let text = s[i:sc.end]
  if sc.is_int {
    match parse_int_text(text) {
      Some(v) => return Int(v)
      None => ()
    }
  }
  Real(parse_real_text(text))
}

///|
/// Double -> Int64 when the conversion is exact (SQLite's integer affinity).
pub fn real_to_int_exact(d : Double) -> Int64? {
  if d > -9223372036854775808.0 && d < 9223372036854775808.0 {
    let i = d.to_int64()
    if i.to_double() == d {
      return Some(i)
    }
  }
  None
}

///|
pub fn apply_affinity(v : Value, aff : Affinity) -> Value {
  match aff {
    AffNone | AffUnset => v
    AffText =>
      match v {
        Int(_) | Real(_) => Text(v.to_text())
        _ => v
      }
    AffNumeric | AffInteger =>
      match v {
        Text(s) =>
          match parse_numeric_text(s) {
            Some(Real(d)) =>
              match real_to_int_exact(d) {
                Some(i) => Int(i)
                None => Real(d)
              }
            Some(x) => x
            None => v
          }
        Real(d) =>
          match real_to_int_exact(d) {
            Some(i) => Int(i)
            None => v
          }
        _ => v
      }
    AffReal =>
      match v {
        Text(s) =>
          match parse_numeric_text(s) {
            Some(Int(i)) => Real(i.to_double())
            Some(x) => x
            None => v
          }
        Int(i) => Real(i.to_double())
        _ => v
      }
  }
}

///|
/// Converts a value to a number for arithmetic (NULL stays NULL).
pub fn to_numeric(v : Value) -> Value {
  match v {
    Null | Int(_) | Real(_) => v
    Text(s) => numeric_prefix(s)
    Blob(b) => numeric_prefix(@utf8.decode_lossy(b))
  }
}

///|
pub fn double_to_int64(d : Double) -> Int64 {
  if d.is_nan() {
    0L
  } else {
    d.to_int64()
  }
}

///|
pub fn value_to_int64(v : Value) -> Int64 {
  match v {
    Int(i) => i
    Real(d) => double_to_int64(d)
    Text(s) => text_to_int64(s)
    Blob(b) => text_to_int64(@utf8.decode_lossy(b))
    Null => 0L
  }
}

///|
/// Integer value of the longest integer prefix of `s` (after leading
/// whitespace), saturating at the 64-bit limits; 0 if there is none.
pub fn text_to_int64(s : String) -> Int64 {
  let n = s.length()
  let mut i = 0
  while i < n && is_space_cu(s[i]) {
    i += 1
  }
  let mut neg = false
  if i < n && (s[i] == '+' || s[i] == '-') {
    neg = s[i] == '-'
    i += 1
  }
  let mut acc = 0L // accumulated as a negative number
  let mut overflow = false
  while i < n && is_digit_cu(s[i]) {
    let d = (s[i].to_int() - '0'.to_int()).to_int64()
    if !overflow {
      if acc < (@int64.MIN_VALUE + d) / 10L {
        overflow = true
      } else {
        acc = acc * 10L - d
      }
    }
    i += 1
  }
  if overflow {
    if neg {
      @int64.MIN_VALUE
    } else {
      @int64.MAX_VALUE
    }
  } else if neg {
    acc
  } else if acc == @int64.MIN_VALUE {
    @int64.MAX_VALUE
  } else {
    -acc
  }
}

///|
pub fn value_to_double(v : Value) -> Double {
  match to_numeric(v) {
    Int(i) => i.to_double()
    Real(d) => d
    _ => 0.0
  }
}

///|
/// Truth value of a condition: None for NULL.
pub fn truthy(v : Value) -> Bool? {
  match v {
    Null => None
    Int(i) => Some(i != 0L)
    Real(d) => Some(d != 0.0)
    _ => Some(value_to_double(v) != 0.0)
  }
}
