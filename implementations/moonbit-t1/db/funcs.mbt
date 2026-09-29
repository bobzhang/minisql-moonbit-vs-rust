// Scalar SQL functions.

///|
/// Allowed argument counts: (min, max); max = -1 means unlimited.
fn func_arity(name : String) -> (Int, Int)? {
  let r = match name {
    "TYPEOF"
    | "ABS"
    | "HEX"
    | "LENGTH"
    | "OCTET_LENGTH"
    | "LIKELY"
    | "UNLIKELY"
    | "LOWER"
    | "UPPER"
    | "QUOTE"
    | "SIGN"
    | "UNICODE"
    | "ZEROBLOB" => (1, 1)
    "ACOS"
    | "ACOSH"
    | "ASIN"
    | "ASINH"
    | "ATAN"
    | "ATANH"
    | "CEIL"
    | "CEILING"
    | "COS"
    | "COSH"
    | "DEGREES"
    | "EXP"
    | "FLOOR"
    | "LN"
    | "LOG10"
    | "LOG2"
    | "RADIANS"
    | "SIN"
    | "SINH"
    | "SQRT"
    | "TAN"
    | "TANH"
    | "TRUNC" => (1, 1)
    "ATAN2" | "MOD" | "POW" | "POWER" => (2, 2)
    "LOG" => (1, 2)
    "PI" | "CHANGES" | "TOTAL_CHANGES" | "LAST_INSERT_ROWID" => (0, 0)
    "CHAR" => (0, -1)
    "COALESCE" => (2, -1)
    "CONCAT" => (1, -1)
    "CONCAT_WS" => (2, -1)
    "FORMAT" | "PRINTF" => (0, -1)
    "GLOB" | "IFNULL" | "INSTR" | "LIKELIHOOD" | "NULLIF" => (2, 2)
    "IIF" | "IF" => (2, -1)
    "LIKE" => (2, 3)
    "LTRIM" | "RTRIM" | "TRIM" | "ROUND" | "UNHEX" => (1, 2)
    "MAX" | "MIN" => (2, -1)
    "REPLACE" => (3, 3)
    "SUBSTR" | "SUBSTRING" => (2, 3)
    "DATE" | "TIME" | "DATETIME" | "JULIANDAY" | "UNIXEPOCH" => (0, -1)
    "STRFTIME" => (1, -1)
    "TIMEDIFF" => (2, 2)
    _ => return None
  }
  Some(r)
}

///|
/// Check that a function exists and accepts the given arguments.
fn check_function(
  name : String,
  args : Array[Expr],
  star : Bool,
) -> Unit raise SqlError {
  guard func_arity(name) is Some((lo, hi)) else {
    raise sql_err("no such function: \{name.to_lower()}")
  }
  let n = args.length()
  if star || n < lo || (hi >= 0 && n > hi) {
    raise sql_err("wrong number of arguments to function \{name.to_lower()}()")
  }
  if name == "LIKELIHOOD" {
    let ok = match args[1] {
      Lit(Real(d)) => d >= 0.0 && d <= 1.0
      _ => false
    }
    if !ok {
      raise sql_err(
        "second argument to likelihood() must be a constant between 0.0 and 1.0",
      )
    }
  }
}

///|
fn int_overflow() -> SqlError {
  sql_err("integer overflow")
}

///|
fn call_function(
  name : String,
  args : Array[Expr],
  coll : Coll,
  row : Array[Value],
) -> Value raise SqlError {
  // functions that evaluate their arguments lazily
  match name {
    "COALESCE" | "IFNULL" => {
      for a in args {
        let v = eval(a, row)
        if !(v is Null) {
          return v
        }
      }
      return Null
    }
    "IIF" | "IF" => {
      let n = args.length()
      let mut i = 0
      while i + 1 < n {
        if eval(args[i], row).truth() is Some(true) {
          return eval(args[i + 1], row)
        }
        i += 2
      }
      return if i < n { eval(args[i], row) } else { Null }
    }
    _ => ()
  }
  let vals = args.map(a => eval(a, row))
  apply_function(name, vals, coll)
}

///|
fn math1(v : Value, f : (Double) -> Double) -> Value {
  match numeric_value(v) {
    Int(i) => real_result(f(i.to_double()))
    Real(d) => real_result(f(d))
    _ => Null
  }
}

///|
/// sqlite3_value_numeric_type: numbers, or text that is entirely numeric.
fn numeric_value(v : Value) -> Value {
  match v {
    Int(_) | Real(_) => v
    Text(s) => {
      let r = scan_number(s)
      if !r.has_num || !r.whole {
        Null
      } else if r.int_ok {
        Int(r.ival)
      } else {
        Real(r.rval)
      }
    }
    _ => Null
  }
}

///|
fn ascii_case(s : String, upper : Bool) -> String {
  let sb = StringBuilder()
  for c in s {
    if upper && c >= 'a' && c <= 'z' {
      sb.write_char((c.to_int() - 32).unsafe_to_char())
    } else if !upper && c >= 'A' && c <= 'Z' {
      sb.write_char((c.to_int() + 32).unsafe_to_char())
    } else {
      sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
fn trim_value(x : Value, set : Value?, left : Bool, right : Bool) -> Value {
  guard x.to_text() is Some(s) else { return Null }
  let chars : Array[Char] = match set {
    None => [' ']
    Some(v) =>
      match v.to_text() {
        Some(t) => t.to_array()
        None => return Null
      }
  }
  let arr = s.to_array()
  let mut a = 0
  let mut b = arr.length()
  if left {
    while a < b && chars.contains(arr[a]) {
      a += 1
    }
  }
  if right {
    while b > a && chars.contains(arr[b - 1]) {
      b -= 1
    }
  }
  Text(String::from_array(arr[a:b]))
}

///|
fn text_length(s : String) -> Int {
  let mut n = 0
  for c in s {
    if c == '\u{0}' {
      break
    }
    n += 1
  }
  n
}

///|
fn quote_value(v : Value) -> String {
  match v {
    Null => "NULL"
    Int(i) => i.to_string()
    Real(d) => {
      let sp = new_spec()
      sp.alt2 = true
      sp.precision = 15
      let s = format_float(d, 'g', sp)
      let back = @string.parse_double(s) catch { _ => @double.not_a_number }
      if back == d || d.is_inf() {
        s
      } else {
        sp.precision = 20
        format_float(d, 'e', sp)
      }
    }
    Text(s) => "'" + s.replace_all(old="'", new="''") + "'"
    Blob(b) => "X'" + blob_hex(b) + "'"
  }
}

///|
fn new_spec() -> Spec {
  {
    left: false,
    prefix: None,
    alt: false,
    alt2: false,
    zeropad: false,
    thousands: false,
    width: 0,
    precision: -1,
  }
}

///|
fn round_value(x : Value, nv : Value?) -> Value {
  let mut n = 0L
  if nv is Some(v) {
    if v is Null {
      return Null
    }
    n = v.to_int64()
    if n > 30L {
      n = 30L
    }
    if n < 0L {
      n = 0L
    }
  }
  if x is Null {
    return Null
  }
  let r = x.to_double()
  if r < -4503599627370496.0 || r > 4503599627370496.0 {
    Real(r)
  } else if n == 0L {
    Real((r + (if r < 0.0 { -0.5 } else { 0.5 })).to_int64().to_double())
  } else {
    let sp = new_spec()
    sp.alt2 = true
    sp.precision = n.to_int()
    let s = format_float(r, 'f', sp)
    Real(@string.parse_double(s) catch { _ => r })
  }
}

///|
fn substr_value(x : Value, y : Value, z : Value?) -> Value {
  if x is Null || y is Null {
    return Null
  }
  if z is Some(Null) {
    return Null
  }
  let mut p1 = y.to_int64()
  let mut p2 = 0L
  let mut neg_p2 = false
  match z {
    Some(zv) => {
      p2 = zv.to_int64()
      if p2 < 0L {
        p2 = -p2
        neg_p2 = true
      }
    }
    None => p2 = 1000000000L
  }
  let (is_blob, bytes, chars) = match x {
    Blob(b) => (true, b, [])
    _ => (false, b"", x.to_text().unwrap().to_array())
  }
  let len = if is_blob {
    bytes.length().to_int64()
  } else {
    chars.length().to_int64()
  }
  if p1 < 0L {
    p1 += len
    if p1 < 0L {
      p2 += p1
      if p2 < 0L {
        p2 = 0L
      }
      p1 = 0L
    }
  } else if p1 > 0L {
    p1 -= 1L
  } else if p2 > 0L {
    p2 -= 1L
  }
  if neg_p2 {
    p1 -= p2
    if p1 < 0L {
      p2 += p1
      p1 = 0L
    }
  }
  if p1 >= len {
    return if is_blob { Blob(b"") } else { Text("") }
  }
  if p2 > len - p1 {
    p2 = len - p1
  }
  let a = p1.to_int()
  let b = (p1 + p2).to_int()
  if is_blob {
    Blob(bytes[a:b].to_owned())
  } else {
    Text(String::from_array(chars[a:b]))
  }
}

///|
fn[T : Eq] find_sub(hay : ArrayView[T], needle : ArrayView[T]) -> Int {
  let n = needle.length()
  if n == 0 {
    return 1
  }
  for i = 0; i + n <= hay.length(); i = i + 1 {
    let mut ok = true
    for j in 0..<n {
      if hay[i + j] != needle[j] {
        ok = false
        break
      }
    }
    if ok {
      return i + 1
    }
  }
  0
}

///|
fn unhex_value(x : Value, ignore_set : Value?) -> Value {
  guard x.to_text() is Some(s) else { return Null }
  let ign : Array[Char] = match ignore_set {
    Some(v) =>
      match v.to_text() {
        Some(t) => t.to_array()
        None => return Null
      }
    None => []
  }
  let arr = s.to_array()
  let buf = @buffer.Buffer()
  let mut i = 0
  while i < arr.length() {
    let c = arr[i]
    if ign.contains(c) {
      i += 1
      continue
    }
    if i + 1 >= arr.length() {
      return Null
    }
    let h1 = hex_val(c.to_int())
    let h2 = hex_val(arr[i + 1].to_int())
    if h1 < 0 || h2 < 0 {
      return Null
    }
    buf.write_byte((h1 * 16 + h2).to_byte())
    i += 2
  }
  Blob(buf.to_bytes())
}

///|
fn apply_function(
  name : String,
  v : Array[Value],
  coll : Coll,
) -> Value raise SqlError {
  if datetime_function(name, v) is Some(r) {
    return r
  }
  match name {
    "TYPEOF" => Text(v[0].type_name())
    "CHANGES" => Int(conn.changes)
    "TOTAL_CHANGES" => Int(conn.total_changes)
    "LAST_INSERT_ROWID" => Int(conn.last_rowid)
    "LIKELY" | "UNLIKELY" | "LIKELIHOOD" => v[0]
    "ABS" =>
      match v[0] {
        Null => Null
        Int(i) =>
          if i == @int64.MIN_VALUE {
            raise int_overflow()
          } else if i < 0L {
            Int(-i)
          } else {
            Int(i)
          }
        Real(d) => Real(d.abs())
        other => Real(other.to_double().abs())
      }
    "CHAR" => {
      let sb = StringBuilder()
      for x in v {
        let c = x.to_int64()
        let cp = if c < 0L || c > 0x10ffffL { 0xfffd } else { c.to_int() }
        match cp.to_char() {
          Some(ch) => sb.write_char(ch)
          None => sb.write_char('\u{fffd}')
        }
      }
      Text(sb.to_string())
    }
    "CONCAT" => {
      let sb = StringBuilder()
      for x in v {
        if x.to_text() is Some(t) {
          sb.write_string(t)
        }
      }
      Text(sb.to_string())
    }
    "CONCAT_WS" => {
      guard v[0].to_text() is Some(sep) else { return Null }
      let sb = StringBuilder()
      let mut first = true
      for x in v[1:] {
        if x.to_text() is Some(t) {
          if !first {
            sb.write_string(sep)
          }
          first = false
          sb.write_string(t)
        }
      }
      Text(sb.to_string())
    }
    "FORMAT" | "PRINTF" => {
      if v.length() == 0 {
        return Null
      }
      guard v[0].to_text() is Some(f) else { return Null }
      let r = sql_printf(f, v[1:])
      if r.length() == 0 {
        Null
      } else {
        Text(r)
      }
    }
    "GLOB" => like_values(true, v[0], v[1], None)
    "LIKE" =>
      like_values(
        false,
        v[0],
        v[1],
        if v.length() > 2 {
          Some(v[2])
        } else {
          None
        },
      )
    "HEX" =>
      match v[0].to_bytes() {
        Some(b) => Text(blob_hex(b))
        None => Text("")
      }
    "INSTR" => {
      if v[0] is Null || v[1] is Null {
        return Null
      }
      match (v[0], v[1]) {
        (Blob(h), Blob(n)) =>
          Int(find_sub(h.to_array()[:], n.to_array()[:]).to_int64())
        _ => {
          let h = v[0].to_text().unwrap().to_array()
          let n = v[1].to_text().unwrap().to_array()
          Int(find_sub(h[:], n[:]).to_int64())
        }
      }
    }
    "LENGTH" =>
      match v[0] {
        Null => Null
        Blob(b) => Int(b.length().to_int64())
        other => Int(text_length(other.to_text().unwrap()).to_int64())
      }
    "OCTET_LENGTH" =>
      match v[0].to_bytes() {
        Some(b) => Int(b.length().to_int64())
        None => Null
      }
    "LOWER" | "UPPER" =>
      match v[0].to_text() {
        Some(t) => Text(ascii_case(t, name == "UPPER"))
        None => Null
      }
    "LTRIM" => trim_value(v[0], v.get(1), true, false)
    "RTRIM" => trim_value(v[0], v.get(1), false, true)
    "TRIM" => trim_value(v[0], v.get(1), true, true)
    "MAX" | "MIN" => {
      let mut best = v[0]
      for x in v {
        if x is Null {
          return Null
        }
        let c = compare_coll(best, x, coll)
        if (name == "MAX" && c < 0) || (name == "MIN" && c >= 0) {
          best = x
        }
      }
      best
    }
    "NULLIF" =>
      if !(v[0] is Null) &&
        !(v[1] is Null) &&
        compare_coll(v[0], v[1], coll) == 0 {
        Null
      } else {
        v[0]
      }
    "QUOTE" => Text(quote_value(v[0]))
    "REPLACE" => {
      guard v[0].to_text() is Some(x) else { return Null }
      guard v[1].to_text() is Some(y) else { return Null }
      guard v[2].to_text() is Some(z) else { return Null }
      if y.length() == 0 {
        Text(x)
      } else {
        Text(x.replace_all(old=y, new=z))
      }
    }
    "ROUND" => round_value(v[0], v.get(1))
    "SIGN" =>
      match numeric_value(v[0]) {
        Int(i) => Int(if i < 0L { -1L } else if i > 0L { 1L } else { 0L })
        Real(d) => Int(if d < 0.0 { -1L } else if d > 0.0 { 1L } else { 0L })
        _ => Null
      }
    "SUBSTR" | "SUBSTRING" => substr_value(v[0], v[1], v.get(2))
    "UNHEX" => unhex_value(v[0], v.get(1))
    "UNICODE" =>
      match v[0].to_text() {
        Some(t) =>
          match t.get_char(0) {
            Some(c) => Int(c.to_int().to_int64())
            None => Null
          }
        None => Null
      }
    "ZEROBLOB" => {
      let n = v[0].to_int64()
      if n <= 0L {
        Blob(b"")
      } else {
        Blob(Bytes::make(n.to_int(), b'\x00'))
      }
    }
    // math
    "PI" => Real(@math.PI)
    "ACOS" => math1(v[0], @math.acos)
    "ACOSH" => math1(v[0], @math.acosh)
    "ASIN" => math1(v[0], @math.asin)
    "ASINH" => math1(v[0], @math.asinh)
    "ATAN" => math1(v[0], @math.atan)
    "ATANH" => math1(v[0], @math.atanh)
    "COS" => math1(v[0], @math.cos)
    "COSH" => math1(v[0], @math.cosh)
    "SIN" => math1(v[0], @math.sin)
    "SINH" => math1(v[0], @math.sinh)
    "TAN" => math1(v[0], @math.tan)
    "TANH" => math1(v[0], @math.tanh)
    "EXP" => math1(v[0], @math.exp)
    "SQRT" => math1(v[0], fn(x) { x.sqrt() })
    "DEGREES" => math1(v[0], fn(x) { x * (180.0 / @math.PI) })
    "RADIANS" => math1(v[0], fn(x) { x * (@math.PI / 180.0) })
    "CEIL" | "CEILING" | "FLOOR" | "TRUNC" =>
      match numeric_value(v[0]) {
        Int(i) => Int(i)
        Real(d) =>
          Real(
            match name {
              "FLOOR" => d.floor()
              "TRUNC" => d.trunc()
              _ => d.ceil()
            },
          )
        _ => Null
      }
    "LN" | "LOG10" | "LOG2" | "LOG" => {
      let x = match numeric_value(v[0]) {
        Int(_) | Real(_) => v[0].to_double()
        _ => return Null
      }
      if x <= 0.0 {
        return Null
      }
      if v.length() == 2 {
        let b = @math.ln(x)
        if b <= 0.0 {
          return Null
        }
        let y = match numeric_value(v[1]) {
          Int(_) | Real(_) => v[1].to_double()
          _ => return Null
        }
        if y <= 0.0 {
          return Null
        }
        return real_result(@math.ln(y) / b)
      }
      real_result(
        match name {
          "LN" => @math.ln(x)
          "LOG2" => @math.log2(x)
          _ => @math.log10(x)
        },
      )
    }
    "ATAN2" | "MOD" | "POW" | "POWER" => {
      let a = match numeric_value(v[0]) {
        Int(_) | Real(_) => v[0].to_double()
        _ => return Null
      }
      let b = match numeric_value(v[1]) {
        Int(_) | Real(_) => v[1].to_double()
        _ => return Null
      }
      real_result(
        match name {
          "ATAN2" => @math.atan2(a, b)
          "MOD" => a % b
          _ => @math.pow(a, b)
        },
      )
    }
    _ => raise sql_err("no such function: \{name.to_lower()}")
  }
}
