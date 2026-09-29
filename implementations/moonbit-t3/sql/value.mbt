///|
/// A SQL value in one of SQLite's five storage classes.
pub(all) enum Value {
  Null
  Int(Int64)
  Real(Double)
  Text(String)
  Blob(Bytes)
} derive(Debug)

///|
pub(all) enum Affinity {
  AffNone // "BLOB" affinity / no affinity
  AffText
  AffNumeric
  AffInteger
  AffReal
} derive(Eq, Debug)

///|
pub suberror SqlError {
  SqlError(String)
} derive(Debug)

///|
pub fn err(msg : String) -> SqlError {
  SqlError(msg)
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
/// Determines column affinity from a declared type name (SQLite rules).
pub fn affinity_of_type(type_name : String) -> Affinity {
  let t = type_name.to_upper()
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

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

///|
/// Decomposes a finite, non-zero, positive double into its shortest
/// round-trip digit string and decimal exponent E (x = d.ddd * 10^E).
fn decompose_double(x : Double) -> (String, Int) {
  let s = x.to_string()
  let (mant, exp) = match s.find("e") {
    Some(i) => {
      let es = s[i + 1:].to_owned()
      let es = if es.has_prefix("+") { es[1:].to_owned() } else { es }
      let e = try! @string.parse_int(es)
      (s[:i].to_owned(), e)
    }
    None => (s, 0)
  }
  let point = match mant.find(".") {
    Some(p) => p
    None => mant.length()
  }
  let all = mant.replace_all(old=".", new="")
  let mut k = 0
  while k < all.length() && all[k] == '0' {
    k += 1
  }
  let mut end = all.length()
  while end > k + 1 && all[end - 1] == '0' {
    end -= 1
  }
  let digits = all[k:end].to_owned()
  (digits, point - k - 1 + exp)
}

///|
pub fn format_real(x : Double) -> String {
  if x.is_nan() {
    return "NULL"
  }
  if x.is_inf() {
    return if x > 0.0 { "Inf" } else { "-Inf" }
  }
  if x == 0.0 {
    return "0.0"
  }
  let neg = x < 0.0
  let (digits, e) = decompose_double(x.abs())
  let sb = StringBuilder()
  if neg {
    sb.write_char('-')
  }
  if e > -5 && e < 16 {
    if e >= 0 {
      for i in 0..<=e {
        sb.write_char(
          if i < digits.length() {
            digits.get_char(i).unwrap()
          } else {
            '0'
          },
        )
      }
      sb.write_char('.')
      if digits.length() > e + 1 {
        sb.write_view(digits[e + 1:])
      } else {
        sb.write_char('0')
      }
    } else {
      sb.write_string("0.")
      for _ in 0..<(-e - 1) {
        sb.write_char('0')
      }
      sb.write_string(digits)
    }
  } else {
    sb.write_view(digits[0:1])
    sb.write_char('.')
    if digits.length() > 1 {
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
let hex_digits : String = "0123456789ABCDEF"

///|
pub fn blob_to_hex(b : Bytes) -> String {
  let sb = StringBuilder()
  for byte in b {
    let v = byte.to_int()
    sb.write_char(hex_digits.get_char(v >> 4).unwrap())
    sb.write_char(hex_digits.get_char(v & 15).unwrap())
  }
  sb.to_string()
}

///|
/// Output-protocol rendering of a value.
pub fn Value::to_output(self : Value) -> String {
  match self {
    Null => "NULL"
    Int(i) => i.to_string()
    Real(r) => format_real(r)
    Text(s) => s
    Blob(b) => "X'" + blob_to_hex(b) + "'"
  }
}

///|
/// Text conversion as used by `||` and CAST(x AS TEXT). NULL stays NULL.
pub fn Value::to_text(self : Value) -> String {
  match self {
    Null => ""
    Int(i) => i.to_string()
    Real(r) => format_real(r)
    Text(s) => s
    Blob(b) => @utf8.decode_lossy(b)
  }
}

// ---------------------------------------------------------------------------
// Numeric conversions
// ---------------------------------------------------------------------------

///|
fn is_space_code(c : UInt16) -> Bool {
  c == ' ' ||
  c == '\t' ||
  c == '\n' ||
  c == '\r' ||
  c.to_int() == 0x0B ||
  c.to_int() == 0x0C
}

///|
/// Parses a decimal integer digit string (optionally signed) to Int64,
/// returning None on overflow.
fn parse_int_digits(neg : Bool, s : StringView) -> Int64? {
  let mut acc : UInt64 = 0UL
  for c in s {
    let d = (c.to_int() - '0'.to_int()).to_uint64()
    if acc > (18446744073709551615UL - d) / 10UL {
      return None
    }
    acc = acc * 10UL + d
  }
  if neg {
    if acc > 9223372036854775808UL {
      None
    } else {
      Some((0UL - acc).reinterpret_as_int64())
    }
  } else if acc > 9223372036854775807UL {
    None
  } else {
    Some(acc.reinterpret_as_int64())
  }
}

///|
/// Converts a validated real literal (digits, '.', exponent) to a double,
/// mapping overflow to infinity and underflow to zero.
pub fn text_to_double(s : String) -> Double {
  @string.parse_double(s) catch {
    _ => {
      // Determine whether it overflowed or underflowed.
      let lower = s.to_lower()
      let neg = s.has_prefix("-")
      let mut exp_neg = false
      match lower.find("e") {
        Some(i) => exp_neg = lower[i + 1:].has_prefix("-")
        None => ()
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
/// Scans the longest numeric prefix of `s` starting at `start`
/// (after leading whitespace). Returns (value, end index, is_integer_form).
/// If no digits are present returns None.
fn scan_number(s : String) -> (Value, Int)? {
  let n = s.length()
  let mut i = 0
  while i < n && is_space_code(s[i]) {
    i += 1
  }
  let start = i
  let mut neg = false
  if i < n && (s[i] == '+' || s[i] == '-') {
    neg = s[i] == '-'
    i += 1
  }
  let int_start = i
  while i < n && s[i] >= '0' && s[i] <= '9' {
    i += 1
  }
  let int_end = i
  let mut digits = int_end - int_start
  let mut is_int = true
  if i < n && s[i] == '.' {
    let mut j = i + 1
    while j < n && s[j] >= '0' && s[j] <= '9' {
      j += 1
    }
    let frac = j - i - 1
    if digits + frac > 0 {
      digits += frac
      is_int = false
      i = j
    }
  }
  if digits == 0 {
    return None
  }
  if i < n && (s[i] == 'e' || s[i] == 'E') {
    let mut j = i + 1
    if j < n && (s[j] == '+' || s[j] == '-') {
      j += 1
    }
    let es = j
    while j < n && s[j] >= '0' && s[j] <= '9' {
      j += 1
    }
    if j > es {
      is_int = false
      i = j
    }
  }
  if is_int {
    match parse_int_digits(neg, s[int_start:int_end]) {
      Some(v) => return Some((Int(v), i))
      None => ()
    }
  }
  let text = s[start:i].to_owned()
  let text = if text.has_prefix("+") { text[1:].to_owned() } else { text }
  // parse_double does not accept forms like "5." or ".5" reliably; normalise.
  Some((Real(text_to_double(normalize_real_literal(text))), i))
}

///|
/// Makes a real literal acceptable to parse_double: "5." -> "5.0", ".5" -> "0.5".
fn normalize_real_literal(t : String) -> String {
  let sb = StringBuilder()
  let n = t.length()
  let mut i = 0
  if i < n && (t[i] == '-' || t[i] == '+') {
    sb.write_char(t.get_char(i).unwrap())
    i += 1
  }
  if i < n && t[i] == '.' {
    sb.write_char('0')
  }
  while i < n {
    let c = t.get_char(i).unwrap()
    sb.write_char(c)
    if c == '.' && (i + 1 >= n || !(t[i + 1] >= '0' && t[i + 1] <= '9')) {
      sb.write_char('0')
    }
    i += 1
  }
  sb.to_string()
}

///|
/// Strict conversion used by numeric affinity: the whole text (ignoring
/// surrounding whitespace) must be a number.
pub fn text_to_numeric_strict(s : String) -> Value? {
  match scan_number(s) {
    Some((v, end)) => {
      let mut i = end
      while i < s.length() && is_space_code(s[i]) {
        i += 1
      }
      if i == s.length() {
        Some(v)
      } else {
        None
      }
    }
    None => None
  }
}

///|
/// Lenient conversion used by arithmetic: the longest numeric prefix, or 0.
pub fn text_to_numeric_lenient(s : String) -> Value {
  match scan_number(s) {
    Some((v, _)) => v
    None => Int(0L)
  }
}

///|
/// Converts any value to a number (INTEGER or REAL) for arithmetic.
/// NULL stays NULL.
pub fn Value::to_numeric(self : Value) -> Value {
  match self {
    Null | Int(_) | Real(_) => self
    Text(s) => text_to_numeric_lenient(s)
    Blob(b) => text_to_numeric_lenient(@utf8.decode_lossy(b))
  }
}

///|
/// Real value of a number (after to_numeric).
pub fn Value::as_double(self : Value) -> Double {
  match self.to_numeric() {
    Int(i) => i.to_double()
    Real(r) => r
    _ => 0.0
  }
}

///|
/// Converts a double to Int64 like SQLite (saturating, NaN -> 0).
pub fn double_to_int64(r : Double) -> Int64 {
  if r.is_nan() {
    0L
  } else if r >= 9223372036854775807.0 {
    @int64.MAX_VALUE
  } else if r <= -9223372036854775808.0 {
    @int64.MIN_VALUE
  } else {
    r.to_int64()
  }
}

///|
pub fn Value::as_int64(self : Value) -> Int64 {
  match self.to_numeric() {
    Int(i) => i
    Real(r) => double_to_int64(r)
    _ => 0L
  }
}

///|
/// Truth value: None for NULL.
pub fn Value::truth(self : Value) -> Bool? {
  match self {
    Null => None
    Int(i) => Some(i != 0L)
    Real(r) => Some(r != 0.0)
    Text(_) | Blob(_) => Some(self.as_double() != 0.0)
  }
}

///|
/// If a real holds an exact integer value within Int64 range, returns it.
fn real_to_exact_int(r : Double) -> Int64? {
  if r >= -9223372036854775808.0 && r < 9223372036854775808.0 && r == r.floor() {
    let i = r.to_int64()
    if i.to_double() == r {
      Some(i)
    } else {
      None
    }
  } else {
    None
  }
}

///|
/// Applies a column affinity to a value being stored.
pub fn Value::apply_affinity(self : Value, aff : Affinity) -> Value {
  match aff {
    AffNone => self
    AffText =>
      match self {
        Int(_) | Real(_) => Text(self.to_text())
        _ => self
      }
    AffNumeric | AffInteger =>
      match self {
        Text(s) =>
          match text_to_numeric_strict(s) {
            Some(Real(r)) =>
              match real_to_exact_int(r) {
                Some(i) => Int(i)
                None => Real(r)
              }
            Some(v) => v
            None => self
          }
        Real(r) =>
          match real_to_exact_int(r) {
            Some(i) => Int(i)
            None => self
          }
        _ => self
      }
    AffReal =>
      match self {
        Text(s) =>
          match text_to_numeric_strict(s) {
            Some(Int(i)) => Real(i.to_double())
            Some(v) => v
            None => self
          }
        Int(i) => Real(i.to_double())
        _ => self
      }
  }
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

///|
fn map_code_unit(u : Int) -> Int {
  if u >= 0xD800 && u <= 0xDFFF {
    u + 0x2000
  } else if u >= 0xE000 {
    u - 0x800
  } else {
    u
  }
}

///|
/// Compares strings in UTF-8 byte (code point) order.
pub fn compare_text(a : String, b : String) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = a[i].to_int()
    let y = b[i].to_int()
    if x != y {
      return map_code_unit(x) - map_code_unit(y)
    }
  }
  a.length() - b.length()
}

///|
pub fn compare_bytes(a : Bytes, b : Bytes) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = a[i].to_int()
    let y = b[i].to_int()
    if x != y {
      return x - y
    }
  }
  a.length() - b.length()
}

///|
fn compare_int_real(i : Int64, r : Double) -> Int {
  if r.is_nan() {
    return 1
  }
  if r < -9223372036854775808.0 {
    return 1
  }
  if r >= 9223372036854775808.0 {
    return -1
  }
  let y = r.to_int64()
  if i < y {
    return -1
  }
  if i > y {
    return 1
  }
  let s = i.to_double()
  if s < r {
    -1
  } else if s > r {
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
/// Total order used for sorting and comparisons (BINARY collation).
pub fn compare_values(a : Value, b : Value) -> Int {
  let ra = class_rank(a)
  let rb = class_rank(b)
  if ra != rb {
    return ra - rb
  }
  match (a, b) {
    (Int(x), Int(y)) => if x < y { -1 } else if x > y { 1 } else { 0 }
    (Real(x), Real(y)) => if x < y { -1 } else if x > y { 1 } else { 0 }
    (Int(x), Real(y)) => compare_int_real(x, y)
    (Real(x), Int(y)) => -compare_int_real(y, x)
    (Text(x), Text(y)) => compare_text(x, y)
    (Blob(x), Blob(y)) => compare_bytes(x, y)
    _ => 0
  }
}

///|
/// Longest integer prefix of a text (after leading whitespace), saturating
/// at the 64-bit limits; 0 if there are no digits.
pub fn text_int_prefix(s : String) -> Int64 {
  let n = s.length()
  let mut i = 0
  while i < n && is_space_code(s[i]) {
    i += 1
  }
  let mut neg = false
  if i < n && (s[i] == '+' || s[i] == '-') {
    neg = s[i] == '-'
    i += 1
  }
  let start = i
  while i < n && s[i] >= '0' && s[i] <= '9' {
    i += 1
  }
  if i == start {
    return 0L
  }
  match parse_int_digits(neg, s[start:i]) {
    Some(v) => v
    None => if neg { @int64.MIN_VALUE } else { @int64.MAX_VALUE }
  }
}

///|
/// sqlite3_value_int64 semantics (used by CAST AS INTEGER, bitwise
/// operators and integer function arguments).
pub fn Value::to_int64_cast(self : Value) -> Int64 {
  match self {
    Null => 0L
    Int(i) => i
    Real(r) => double_to_int64(r)
    Text(s) => text_int_prefix(s)
    Blob(b) => text_int_prefix(@utf8.decode_lossy(b))
  }
}

///|
/// Strict numeric conversion used by math functions: numbers pass
/// through, text that is entirely a number converts, anything else is None.
pub fn Value::numeric_strict(self : Value) -> Value? {
  match self {
    Int(_) | Real(_) => Some(self)
    Text(s) => text_to_numeric_strict(s)
    _ => None
  }
}
