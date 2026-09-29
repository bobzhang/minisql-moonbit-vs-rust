///|
/// A SQL value (one of SQLite's five storage classes).
pub(all) enum Value {
  Null
  Int(Int64)
  Real(Double)
  Text(String)
  Blob(Bytes)
} derive(Debug)

///|
/// Column affinity.
pub(all) enum Affinity {
  AffNone // BLOB affinity / no affinity
  /// No affinity at all: an expression column of a subquery or view
  /// (behaves like an expression in comparisons).
  AffUnset
  AffText
  AffNumeric
  AffInteger
  AffReal
} derive(Eq, Debug)

///|
pub fn affinity_of_type(decl : String) -> Affinity {
  let t = decl.to_upper()
  if t.contains("INT") {
    AffInteger
  } else if t.contains("CHAR") || t.contains("CLOB") || t.contains("TEXT") {
    AffText
  } else if t.contains("BLOB") || t.trim().length() == 0 {
    AffNone
  } else if t.contains("REAL") || t.contains("FLOA") || t.contains("DOUB") {
    AffReal
  } else {
    AffNumeric
  }
}

///|
pub fn Value::type_name(self : Value) -> String {
  match self {
    Null => "null"
    Int(_) => "integer"
    Real(_) => "real"
    Text(_) => "text"
    Blob(_) => "blob"
  }
}

///|
pub fn Value::is_null(self : Value) -> Bool {
  self is Null
}

///|
const HEX_DIGITS : String = "0123456789ABCDEF"

///|
pub fn blob_to_hex(b : Bytes) -> String {
  let sb = StringBuilder()
  for i in 0..<b.length() {
    let v = b[i].to_int()
    sb.write_char(HEX_DIGITS.get_char(v >> 4).unwrap())
    sb.write_char(HEX_DIGITS.get_char(v & 15).unwrap())
  }
  sb.to_string()
}

///|
/// Text rendering used for output.
pub fn Value::to_output(self : Value) -> String {
  match self {
    Null => "NULL"
    Int(i) => i.to_string()
    Real(d) => format_real(d)
    Text(s) => s
    Blob(b) => "X'" + blob_to_hex(b) + "'"
  }
}

///|
/// Converts a value to text as SQL does (NULL stays out: caller handles).
pub fn Value::to_text(self : Value) -> String {
  match self {
    Null => ""
    Int(i) => i.to_string()
    Real(d) => format_real(d)
    Text(s) => s
    Blob(b) => @utf8.decode_lossy(b)
  }
}

///|
pub fn Value::to_blob(self : Value) -> Bytes {
  match self {
    Null => Bytes::new(0)
    Blob(b) => b
    _ => @utf8.encode(self.to_text())
  }
}

///|
/// Formats a double per SPEC §2.3.
pub fn format_real(d : Double) -> String {
  if d.is_nan() {
    return "NULL"
  }
  if d.is_inf() {
    return if d > 0.0 { "Inf" } else { "-Inf" }
  }
  if d == 0.0 {
    return "0.0"
  }
  let neg = d < 0.0
  let (digits, e) = shortest_digits(d.abs())
  let sb = StringBuilder()
  if neg {
    sb.write_char('-')
  }
  let n = digits.length()
  if e > -5 && e < 16 {
    if e < 0 {
      sb.write_string("0.")
      for _ in 0..<(-e - 1) {
        sb.write_char('0')
      }
      sb.write_string(digits)
    } else if e + 1 >= n {
      sb.write_string(digits)
      for _ in 0..<(e + 1 - n) {
        sb.write_char('0')
      }
      sb.write_string(".0")
    } else {
      sb.write_view(digits[0:e + 1])
      sb.write_char('.')
      sb.write_view(digits[e + 1:])
    }
  } else {
    sb.write_view(digits[0:1])
    sb.write_char('.')
    if n > 1 {
      sb.write_view(digits[1:])
    } else {
      sb.write_char('0')
    }
    sb.write_char('e')
    sb.write_char(if e < 0 { '-' } else { '+' })
    let ae = if e < 0 { -e } else { e }
    if ae < 10 {
      sb.write_char('0')
    }
    sb.write_string(ae.to_string())
  }
  sb.to_string()
}

///|
/// Shortest round-trip digits of a positive finite double, and the decimal
/// exponent of the first digit.
fn shortest_digits(d : Double) -> (String, Int) {
  let s = d.to_string()
  let (mant, exp) = match s.find("e") {
    Some(i) => {
      let es = s[i + 1:]
      let ev = @string.parse_int(es) catch { _ => 0 }
      (s[0:i].to_owned(), ev)
    }
    None => (s, 0)
  }
  // mant is like "123.456" or "0.00123" or "123"
  let (ip, fp) = match mant.find(".") {
    Some(i) => (mant[0:i].to_owned(), mant[i + 1:].to_owned())
    None => (mant, "")
  }
  let all = ip + fp
  // strip leading zeros
  let mut lead = 0
  while lead < all.length() && all[lead] == '0' {
    lead += 1
  }
  let mut end = all.length()
  while end > lead && all[end - 1] == '0' {
    end -= 1
  }
  let digits = all[lead:end].to_owned()
  // position of first significant digit relative to decimal point
  let e = ip.length() - 1 - lead + exp
  (if digits.length() == 0 { "0" } else { digits }, e)
}

///|
/// Compare two strings by their UTF-8 byte order.
pub fn text_compare(a : String, b : String) -> Int {
  let la = a.length()
  let lb = b.length()
  let n = if la < lb { la } else { lb }
  for i in 0..<n {
    let ca = a[i].to_int()
    let cb = b[i].to_int()
    if ca != cb {
      return utf16_fix(ca) - utf16_fix(cb)
    }
  }
  la - lb
}

///|
fn utf16_fix(c : Int) -> Int {
  if c >= 0xD800 {
    if c >= 0xE000 {
      c - 0x800
    } else {
      c + 0x2000
    }
  } else {
    c
  }
}

///|
/// Exact comparison between an integer and a double.
fn int_real_compare(i : Int64, d : Double) -> Int {
  if d.is_nan() {
    return 1
  }
  if d >= 9223372036854775808.0 {
    return -1
  }
  if d < -9223372036854775808.0 {
    return 1
  }
  let t = d.to_int64() // truncates toward zero
  if i < t {
    return -1
  }
  if i > t {
    return 1
  }
  let frac = d - t.to_double()
  if frac > 0.0 {
    -1
  } else if frac < 0.0 {
    1
  } else {
    0
  }
}

///|
fn class_rank(v : Value) -> Int {
  match v {
    Null => 0
    Int(_) | Real(_) => 1
    Text(_) => 2
    Blob(_) => 3
  }
}

///|
/// SQLite's default ordering (BINARY collation).
pub fn value_compare(a : Value, b : Value) -> Int {
  match (a, b) {
    (Null, Null) => 0
    (Int(x), Int(y)) => if x < y { -1 } else if x > y { 1 } else { 0 }
    (Real(x), Real(y)) => if x < y { -1 } else if x > y { 1 } else { 0 }
    (Int(x), Real(y)) => int_real_compare(x, y)
    (Real(x), Int(y)) => -int_real_compare(y, x)
    (Text(x), Text(y)) => text_compare(x, y)
    (Blob(x), Blob(y)) => x.lexical_compare(y)
    _ => class_rank(a) - class_rank(b)
  }
}
