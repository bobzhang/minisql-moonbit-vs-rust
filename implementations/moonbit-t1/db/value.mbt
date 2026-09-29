///|
pub(all) enum Value {
  Null
  Int(Int64)
  Real(Double)
  Text(String)
  Blob(Bytes)
} derive(Debug)

///|
pub suberror SqlError {
  SqlError(String)
}

///|
fn sql_err(msg : String) -> SqlError {
  SqlError(msg)
}

///|
pub(all) enum Affinity {
  AffNone // BLOB affinity / no affinity
  AffText
  AffNumeric
  AffInteger
  AffReal
} derive(Eq, Debug)

///|
/// Determine column affinity from the declared type name (SQLite rules).
fn affinity_of_type(t : String) -> Affinity {
  let u = t.to_upper()
  if u.contains("INT") {
    AffInteger
  } else if u.contains("CHAR") || u.contains("CLOB") || u.contains("TEXT") {
    AffText
  } else if u.contains("BLOB") || u.trim().length() == 0 {
    AffNone
  } else if u.contains("REAL") || u.contains("FLOA") || u.contains("DOUB") {
    AffReal
  } else {
    AffNumeric
  }
}

///|
fn Value::type_name(self : Value) -> String {
  match self {
    Null => "null"
    Int(_) => "integer"
    Real(_) => "real"
    Text(_) => "text"
    Blob(_) => "blob"
  }
}

///|
fn Value::is_null(self : Value) -> Bool {
  self is Null
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

///|
/// Format a double as SQLite would print it (SPEC §2.3).
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
  let s = "\{d.abs()}"
  // split mantissa / exponent
  let (mant, exp10) = match s.find("e") {
    Some(i) => {
      let es = s[i + 1:].to_owned()
      let ev = @string.parse_int(
        if es.has_prefix("+") {
          es[1:]
        } else {
          es[:]
        },
      ) catch {
        _ => 0
      }
      (s[:i].to_owned(), ev)
    }
    None => (s, 0)
  }
  let (ip, fp) = match mant.find(".") {
    Some(i) => (mant[:i].to_owned(), mant[i + 1:].to_owned())
    None => (mant, "")
  }
  let all = ip + fp
  let mut z = 0
  while z < all.length() && all[z] == '0' {
    z += 1
  }
  let mut digits = all[z:].to_owned()
  let mut e = ip.length() - 1 - z + exp10
  // strip trailing zeros
  let mut end = digits.length()
  while end > 1 && digits[end - 1] == '0' {
    end -= 1
  }
  digits = digits[:end].to_owned()
  if digits.length() == 0 {
    return "0.0"
  }
  let sb = StringBuilder()
  if neg {
    sb.write_char('-')
  }
  if e > -5 && e < 16 {
    if e >= 0 {
      if digits.length() <= e + 1 {
        sb.write_string(digits)
        for _ in 0..<(e + 1 - digits.length()) {
          sb.write_char('0')
        }
        sb.write_string(".0")
      } else {
        sb.write_view(digits[:e + 1])
        sb.write_char('.')
        sb.write_view(digits[e + 1:])
      }
    } else {
      sb.write_string("0.")
      for _ in 0..<(-e - 1) {
        sb.write_char('0')
      }
      sb.write_string(digits)
    }
  } else {
    sb.write_view(digits[:1])
    sb.write_char('.')
    if digits.length() > 1 {
      sb.write_view(digits[1:])
    } else {
      sb.write_char('0')
    }
    sb.write_char('e')
    if e < 0 {
      sb.write_char('-')
      e = -e
    } else {
      sb.write_char('+')
    }
    if e < 10 {
      sb.write_char('0')
    }
    sb.write_string(e.to_string())
  }
  sb.to_string()
}

///|
let hex_digits : String = "0123456789ABCDEF"

///|
fn blob_hex(b : Bytes) -> String {
  let sb = StringBuilder()
  for i in 0..<b.length() {
    let v = b[i].to_int()
    sb.write_char(hex_digits.get_char(v >> 4).unwrap())
    sb.write_char(hex_digits.get_char(v & 15).unwrap())
  }
  sb.to_string()
}

///|
/// Output representation of a value (SPEC §2.3).
pub fn Value::display(self : Value) -> String {
  match self {
    Null => "NULL"
    Int(i) => i.to_string()
    Real(d) => format_real(d)
    Text(s) => s
    Blob(b) => "X'" + blob_hex(b) + "'"
  }
}

///|
/// Text conversion as used by CAST(x AS TEXT) and `||`. None for NULL.
fn Value::to_text(self : Value) -> String? {
  match self {
    Null => None
    Int(i) => Some(i.to_string())
    Real(d) => Some(format_real(d))
    Text(s) => Some(s)
    Blob(b) => Some(@utf8.decode_lossy(b[:]))
  }
}

// ---------------------------------------------------------------------------
// Text -> number
// ---------------------------------------------------------------------------

///|
priv struct NumScan {
  has_num : Bool // a numeric prefix exists
  whole : Bool // the whole string (modulo surrounding spaces) is numeric
  is_int : Bool // the prefix has no '.' or exponent
  int_ok : Bool // is_int and fits in Int64
  ival : Int64
  rval : Double
}

///|
fn is_space_cu(c : UInt16) -> Bool {
  c == ' ' ||
  c == '\t' ||
  c == '\n' ||
  c == '\r' ||
  c.to_int() == 12 ||
  c.to_int() == 11
}

///|
fn is_digit_cu(c : UInt16) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn scan_number(s : String) -> NumScan {
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
  let int_start = i
  while i < n && is_digit_cu(s[i]) {
    i += 1
  }
  let int_digits = s[int_start:i].to_owned()
  let mut frac_digits = ""
  let mut is_int = true
  if i < n && s[i] == '.' {
    let fs = i + 1
    let mut j = fs
    while j < n && is_digit_cu(s[j]) {
      j += 1
    }
    if int_digits.length() > 0 || j > fs {
      frac_digits = s[fs:j].to_owned()
      is_int = false
      i = j
    }
  }
  if int_digits.length() == 0 && frac_digits.length() == 0 {
    return {
      has_num: false,
      whole: false,
      is_int: true,
      int_ok: true,
      ival: 0L,
      rval: 0.0,
    }
  }
  let mut exp = 0
  if i < n && (s[i] == 'e' || s[i] == 'E') {
    let mut j = i + 1
    let mut eneg = false
    if j < n && (s[j] == '+' || s[j] == '-') {
      eneg = s[j] == '-'
      j += 1
    }
    if j < n && is_digit_cu(s[j]) {
      let mut ev = 0
      while j < n && is_digit_cu(s[j]) {
        if ev < 100000 {
          ev = ev * 10 + (s[j].to_int() - '0'.to_int())
        }
        j += 1
      }
      exp = if eneg { -ev } else { ev }
      is_int = false
      i = j
    }
  }
  let end = i
  while i < n && is_space_cu(s[i]) {
    i += 1
  }
  let whole = i == n
  ignore(end)
  // integer value
  let mut ival = 0L
  let mut int_ok = is_int
  if is_int {
    // accumulate as negative to cover MIN
    let mut acc = 0L
    for k in 0..<int_digits.length() {
      let dg = (int_digits[k].to_int() - '0'.to_int()).to_int64()
      if acc < (@int64.MIN_VALUE + dg) / 10L {
        int_ok = false
        break
      }
      acc = acc * 10L - dg
    }
    if int_ok {
      if neg {
        ival = acc
      } else if acc == @int64.MIN_VALUE {
        int_ok = false
      } else {
        ival = -acc
      }
    }
  }
  let txt = (if neg { "-" } else { "" }) +
    (if int_digits.length() == 0 { "0" } else { int_digits }) +
    "." +
    (if frac_digits.length() == 0 { "0" } else { frac_digits }) +
    "e" +
    exp.to_string()
  let rval = @string.parse_double(txt) catch {
    _ =>
      if exp > 0 {
        if neg {
          @double.neg_infinity
        } else {
          @double.infinity
        }
      } else if neg {
        -0.0
      } else {
        0.0
      }
  }
  { has_num: true, whole, is_int, int_ok, ival, rval, }
}

///|
/// Numeric value of text for arithmetic (longest numeric prefix; 0 if none).
fn text_to_numeric(s : String) -> Value {
  let r = scan_number(s)
  if !r.has_num {
    Int(0L)
  } else if r.int_ok {
    Int(r.ival)
  } else {
    Real(r.rval)
  }
}

///|
fn real_to_int_exact(d : Double) -> Int64? {
  // exact integral value strictly inside the Int64 range
  if d > -9223372036854775808.0 && d < 9223372036854775808.0 {
    let i = d.to_int64()
    if i.to_double() == d && i != @int64.MIN_VALUE && i != @int64.MAX_VALUE {
      return Some(i)
    }
  }
  None
}

///|
/// Numeric affinity applied to text: converts only when the whole text is a number.
fn text_numeric_affinity(s : String) -> Value? {
  let r = scan_number(s)
  if !r.has_num || !r.whole {
    return None
  }
  if r.int_ok {
    return Some(Int(r.ival))
  }
  match real_to_int_exact(r.rval) {
    Some(i) => Some(Int(i))
    None => Some(Real(r.rval))
  }
}

///|
/// Apply column affinity for storage.
fn apply_affinity(v : Value, aff : Affinity) -> Value {
  match aff {
    AffNone => v
    AffText =>
      match v {
        Int(_) | Real(_) => Text(v.to_text().unwrap())
        _ => v
      }
    AffNumeric | AffInteger =>
      match v {
        Text(s) =>
          match text_numeric_affinity(s) {
            Some(nv) => nv
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
          match text_numeric_affinity(s) {
            Some(Int(i)) => Real(i.to_double())
            Some(nv) => nv
            None => v
          }
        Int(i) => Real(i.to_double())
        _ => v
      }
  }
}

///|
/// Numeric affinity as used in comparisons (does not turn reals into ints).
fn apply_numeric_cmp(v : Value) -> Value {
  match v {
    Text(s) =>
      match text_numeric_affinity(s) {
        Some(nv) => nv
        None => v
      }
    _ => v
  }
}

///|
/// Convert to a number for arithmetic.
fn Value::to_number(self : Value) -> Value {
  match self {
    Int(_) | Real(_) | Null => self
    Text(s) => text_to_numeric(s)
    Blob(b) => text_to_numeric(@utf8.decode_lossy(b[:]))
  }
}

///|
fn Value::to_double(self : Value) -> Double {
  match self.to_number() {
    Int(i) => i.to_double()
    Real(d) => d
    _ => 0.0
  }
}

///|
fn Value::to_int64(self : Value) -> Int64 {
  match self {
    Int(i) => i
    Real(d) => real_to_int64(d)
    Text(s) => text_to_int64(s)
    Blob(b) => text_to_int64(@utf8.decode_lossy(b[:]))
    Null => 0L
  }
}

///|
/// Integer prefix of a text value (like sqlite3Atoi64), saturating.
fn text_to_int64(s : String) -> Int64 {
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
  while i < n && is_digit_cu(s[i]) {
    let dg = (s[i].to_int() - '0'.to_int()).to_int64()
    if acc < (@int64.MIN_VALUE + dg) / 10L {
      return if neg { @int64.MIN_VALUE } else { @int64.MAX_VALUE }
    }
    acc = acc * 10L - dg
    i += 1
  }
  if neg {
    acc
  } else if acc == @int64.MIN_VALUE {
    @int64.MAX_VALUE
  } else {
    -acc
  }
}

///|
fn real_to_int64(d : Double) -> Int64 {
  if d.is_nan() {
    0L
  } else {
    d.to_int64()
  }
}

///|
/// Truth value: None for NULL.
fn Value::truth(self : Value) -> Bool? {
  match self {
    Null => None
    Int(i) => Some(i != 0L)
    Real(d) => Some(d != 0.0)
    Text(s) => Some(scan_number(s).rval != 0.0)
    Blob(b) => Some(scan_number(@utf8.decode_lossy(b[:])).rval != 0.0)
  }
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

///|
/// Compare strings by code point (equivalent to UTF-8 byte order).
fn compare_text(a : String, b : String) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = a[i].to_int()
    let y = b[i].to_int()
    if x != y {
      return fix_cu(x) - fix_cu(y)
    }
  }
  a.length() - b.length()
}

///|
fn fix_cu(c : Int) -> Int {
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
fn compare_bytes(a : Bytes, b : Bytes) -> Int {
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
  let t = r.to_int64()
  if i < t {
    -1
  } else if i > t {
    1
  } else {
    let f = r - t.to_double()
    if f > 0.0 {
      -1
    } else if f < 0.0 {
      1
    } else {
      0
    }
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
/// Total order used for sorting and comparisons (NULL < numbers < text < blob).
pub fn compare_values(a : Value, b : Value) -> Int {
  match (a, b) {
    (Int(x), Int(y)) => if x < y { -1 } else if x > y { 1 } else { 0 }
    (Real(x), Real(y)) => if x < y { -1 } else if x > y { 1 } else { 0 }
    (Int(x), Real(y)) => compare_int_real(x, y)
    (Real(x), Int(y)) => -compare_int_real(y, x)
    (Text(x), Text(y)) => compare_text(x, y)
    (Blob(x), Blob(y)) => compare_bytes(x, y)
    _ => class_rank(a) - class_rank(b)
  }
}
