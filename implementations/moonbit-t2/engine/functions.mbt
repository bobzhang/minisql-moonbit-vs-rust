// Scalar SQL functions.

///|
/// Allowed argument counts per function: (min, max); max < 0 = unlimited.
let function_arity : Map[String, (Int, Int)] = {
  "typeof": (1, 1),
  "abs": (1, 1),
  "char": (0, -1),
  "coalesce": (2, -1),
  "concat": (1, -1),
  "concat_ws": (2, -1),
  "format": (0, -1),
  "printf": (0, -1),
  "glob": (2, 2),
  "hex": (1, 1),
  "ifnull": (2, 2),
  "iif": (2, 3),
  "if": (2, 3),
  "instr": (2, 2),
  "length": (1, 1),
  "like": (2, 3),
  "likelihood": (2, 2),
  "likely": (1, 1),
  "unlikely": (1, 1),
  "lower": (1, 1),
  "upper": (1, 1),
  "ltrim": (1, 2),
  "rtrim": (1, 2),
  "trim": (1, 2),
  "max": (2, -1),
  "min": (2, -1),
  "nullif": (2, 2),
  "octet_length": (1, 1),
  "quote": (1, 1),
  "replace": (3, 3),
  "round": (1, 2),
  "sign": (1, 1),
  "substr": (2, 3),
  "substring": (2, 3),
  "unhex": (1, 2),
  "unicode": (1, 1),
  "zeroblob": (1, 1),
  "acos": (1, 1),
  "acosh": (1, 1),
  "asin": (1, 1),
  "asinh": (1, 1),
  "atan": (1, 1),
  "atan2": (2, 2),
  "atanh": (1, 1),
  "ceil": (1, 1),
  "ceiling": (1, 1),
  "cos": (1, 1),
  "cosh": (1, 1),
  "degrees": (1, 1),
  "exp": (1, 1),
  "floor": (1, 1),
  "ln": (1, 1),
  "log": (1, 2),
  "log10": (1, 1),
  "log2": (1, 1),
  "mod": (2, 2),
  "pi": (0, 0),
  "pow": (2, 2),
  "power": (2, 2),
  "radians": (1, 1),
  "sin": (1, 1),
  "sinh": (1, 1),
  "sqrt": (1, 1),
  "tan": (1, 1),
  "tanh": (1, 1),
  "trunc": (1, 1),
  "changes": (0, 0),
  "total_changes": (0, 0),
  "last_insert_rowid": (0, 0),
  "date": (0, -1),
  "time": (0, -1),
  "datetime": (0, -1),
  "julianday": (0, -1),
  "unixepoch": (0, -1),
  "strftime": (1, -1),
  "timediff": (2, 2),
}

///|
/// Argument counts of aggregate functions.
let aggregate_arity : Map[String, (Int, Int)] = {
  "count": (0, 1),
  "sum": (1, 1),
  "total": (1, 1),
  "avg": (1, 1),
  "min": (1, 1),
  "max": (1, 1),
  "group_concat": (1, 2),
  "string_agg": (2, 2),
}

///|
/// True if a call with `n` arguments is an aggregate (min/max are scalar
/// with two or more arguments).
fn is_aggregate_call(name : String, n : Int) -> Bool {
  match name {
    "min" | "max" => n == 1
    _ => aggregate_arity.contains(name)
  }
}

///|
/// Bind-time validation of a function call.
fn check_function_call(
  name : String,
  args : Array[Expr],
) -> Unit raise SqlError {
  let n = args.length()
  if is_aggregate_call(name, n) {
    let (lo, hi) = aggregate_arity[name]
    if n < lo || n > hi {
      raise SqlError("wrong number of arguments to function \{name}()")
    }
    raise SqlError("misuse of aggregate function \{name}()")
  }
  guard function_arity.get(name) is Some((lo, hi)) else {
    raise SqlError("no such function: \{name}")
  }
  if n < lo || (hi >= 0 && n > hi) {
    raise SqlError("wrong number of arguments to function \{name}()")
  }
  if name == "likelihood" {
    let ok = match args[1] {
      Lit(Real(d)) => d >= 0.0 && d <= 1.0
      _ => false
    }
    if !ok {
      raise SqlError(
        "second argument to likelihood() must be a constant between 0.0 and 1.0",
      )
    }
  }
}

///|
fn call_function(
  name : String,
  args : Array[Expr],
  _distinct : Bool,
  _star : Bool,
  env : Env,
) -> Value raise SqlError {
  match name {
    "coalesce" | "ifnull" => {
      for a in args {
        let v = eval(a, env)
        if !(v is Null) {
          return v
        }
      }
      Null
    }
    "iif" | "if" =>
      if truthy(eval(args[0], env)) == Some(true) {
        eval(args[1], env)
      } else if args.length() > 2 {
        eval(args[2], env)
      } else {
        Null
      }
    "max" | "min" => {
      let coll = args_coll(args)
      let vals = args.map(a => eval(a, env))
      let mut best = 0
      for i, v in vals {
        if v is Null {
          return Null
        }
        if i > 0 {
          let c = value_compare_coll(vals[best], v, coll)
          if name == "max" {
            if c < 0 {
              best = i
            }
          } else if c >= 0 {
            best = i
          }
        }
      }
      vals[best]
    }
    "nullif" => {
      let coll = args_coll(args)
      let a = eval(args[0], env)
      let b = eval(args[1], env)
      if value_compare_coll(a, b, coll) != 0 {
        a
      } else {
        Null
      }
    }
    _ => scalar_function(name, args.map(a => eval(a, env)))
  }
}

///|
fn text_or_null(v : Value, f : (String) -> Value) -> Value {
  match v {
    Null => Null
    _ => f(v.to_text())
  }
}

///|
/// The numeric value of an argument for math functions (None if the value
/// is not a number or text that looks like one).
fn num_arg(v : Value) -> Value? {
  match v {
    Int(_) | Real(_) => Some(v)
    Text(s) => parse_numeric_text(s)
    _ => None
  }
}

///|
fn math1(v : Value, f : (Double) -> Double) -> Value {
  match num_arg(v) {
    Some(x) => real_result(f(value_to_double(x)))
    None => Null
  }
}

///|
fn math2(a : Value, b : Value, f : (Double, Double) -> Double) -> Value {
  match (num_arg(a), num_arg(b)) {
    (Some(x), Some(y)) => real_result(f(value_to_double(x), value_to_double(y)))
    _ => Null
  }
}

///|
fn int_or_round(v : Value, f : (Double) -> Double) -> Value {
  match num_arg(v) {
    Some(Int(i)) => Int(i)
    Some(Real(d)) => real_result(f(d))
    _ => Null
  }
}

///|
fn sql_trim(v : Value, chars : Value?, left : Bool, right : Bool) -> Value {
  if v is Null {
    return Null
  }
  let set = match chars {
    None => [' ']
    Some(Null) => return Null
    Some(c) => c.to_text().to_array()
  }
  let cs = v.to_text().to_array()
  let mut s = 0
  let mut e = cs.length()
  if left {
    while s < e && set.contains(cs[s]) {
      s += 1
    }
  }
  if right {
    while e > s && set.contains(cs[e - 1]) {
      e -= 1
    }
  }
  Text(String::from_array(cs[s:e]))
}

///|
fn sql_substr(v : Value, start : Value, len : Value?) -> Value {
  if v is Null || start is Null {
    return Null
  }
  if len is Some(Null) {
    return Null
  }
  let mut p1 = value_to_int64(start)
  let mut neg_p2 = false
  let mut p2 = match len {
    Some(l) => {
      let x = value_to_int64(l)
      if x < 0L {
        neg_p2 = true
        if x == @int64.MIN_VALUE {
          @int64.MAX_VALUE
        } else {
          -x
        }
      } else {
        x
      }
    }
    None => 1000000000L
  }
  let is_blob = v is Blob(_)
  let bytes = match v {
    Blob(b) => b
    _ => Bytes::new(0)
  }
  let chars = if is_blob { [] } else { v.to_text().to_array() }
  let total_len = if is_blob { bytes.length() } else { chars.length() }
  let total = total_len.to_int64()
  if p1 < 0L {
    p1 += total
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
  let s = if p1 > total { total } else { p1 }
  let e0 = if p2 > total - s { total } else { s + p2 }
  let st = s.to_int()
  let en = e0.to_int()
  if is_blob {
    Blob(bytes[st:en].to_owned())
  } else {
    Text(String::from_array(chars[st:en]))
  }
}

///|
fn hex_val(c : Char) -> Int? {
  match c {
    '0'..='9' => Some(c.to_int() - '0'.to_int())
    'a'..='f' => Some(c.to_int() - 'a'.to_int() + 10)
    'A'..='F' => Some(c.to_int() - 'A'.to_int() + 10)
    _ => None
  }
}

///|
fn sql_unhex(v : Value, ignore : Value?) -> Value {
  if v is Null {
    return Null
  }
  let skip = match ignore {
    None => []
    Some(Null) => return Null
    Some(x) => x.to_text().to_array()
  }
  let cs = v.to_text().to_array()
  let buf = @buffer.Buffer()
  let mut i = 0
  while i < cs.length() {
    match hex_val(cs[i]) {
      Some(h) => {
        if i + 1 >= cs.length() {
          return Null
        }
        match hex_val(cs[i + 1]) {
          Some(l) => buf.write_byte(((h << 4) | l).to_byte())
          None => return Null
        }
        i += 2
      }
      None => {
        if !skip.contains(cs[i]) {
          return Null
        }
        i += 1
      }
    }
  }
  Blob(buf.to_bytes())
}

///|
fn sql_quote(v : Value) -> String {
  match v {
    Null => "NULL"
    Int(i) => i.to_string()
    Real(d) => {
      let (digits, _) = shortest_digits(d.abs())
      if d.is_inf() || d == 0.0 || digits.length() <= 15 {
        format_real(d)
      } else {
        sql_printf("%!.20e", [v][:])
      }
    }
    Text(s) => "'" + s.replace_all(old="'", new="''") + "'"
    Blob(b) => "X'" + blob_to_hex(b) + "'"
  }
}

///|
fn sql_round(v : Value, digits : Value?) -> Value {
  if v is Null {
    return Null
  }
  let mut n = match digits {
    None => 0L
    Some(Null) => return Null
    Some(d) => value_to_int64(d)
  }
  if n > 30L {
    n = 30L
  }
  if n < 0L {
    n = 0L
  }
  let r = value_to_double(v)
  if r < -4503599627370496.0 || r > 4503599627370496.0 {
    Real(r)
  } else if n == 0L {
    Real((r + (if r < 0.0 { -0.5 } else { 0.5 })).to_int64().to_double())
  } else {
    let s = format_float(r, 'f', n.to_int(), 0, None, false, true, false, false)
    Real(parse_real_text(s))
  }
}

///|
fn sql_instr(h : Value, n : Value) -> Value {
  if h is Null || n is Null {
    return Null
  }
  match (h, n) {
    (Blob(a), Blob(b)) => {
      if b.length() == 0 {
        return Int(1L)
      }
      for i in 0..<=(a.length() - b.length()) {
        if a[i:i + b.length()] == b[:] {
          return Int((i + 1).to_int64())
        }
      }
      Int(0L)
    }
    _ => {
      let hs = h.to_text()
      let ns = n.to_text()
      match hs.find(ns) {
        Some(idx) => Int((hs[0:idx].char_length() + 1).to_int64())
        None => Int(0L)
      }
    }
  }
}

///|
fn ascii_case(s : String, upper : Bool) -> String {
  let sb = StringBuilder()
  for c in s {
    if upper && c >= 'a' && c <= 'z' {
      sb.write_char(c.to_ascii_uppercase())
    } else if !upper && c >= 'A' && c <= 'Z' {
      sb.write_char(c.to_ascii_lowercase())
    } else {
      sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
fn scalar_function(name : String, v : Array[Value]) -> Value raise SqlError {
  if datetime_function(name, v) is Some(r) {
    return r
  }
  match name {
    "typeof" => Text(v[0].type_name())
    "changes" => Int(conn.changes)
    "total_changes" => Int(conn.total_changes)
    "last_insert_rowid" => Int(conn.last_rowid)
    "abs" =>
      match v[0] {
        Null => Null
        Int(i) =>
          if i < 0L {
            if i == @int64.MIN_VALUE {
              raise SqlError("integer overflow")
            }
            Int(-i)
          } else {
            Int(i)
          }
        x => Real(value_to_double(x).abs())
      }
    "char" => {
      let sb = StringBuilder()
      for x in v {
        let c = value_to_int64(x)
        let ch = if c < 0L || c > 0x10FFFFL || (c >= 0xD800L && c <= 0xDFFFL) {
          0xFFFD
        } else {
          c.to_int()
        }
        sb.write_char(ch.unsafe_to_char())
      }
      Text(sb.to_string())
    }
    "concat" => {
      let sb = StringBuilder()
      for x in v {
        if !(x is Null) {
          sb.write_string(x.to_text())
        }
      }
      Text(sb.to_string())
    }
    "concat_ws" => {
      if v[0] is Null {
        return Null
      }
      let sep = v[0].to_text()
      let parts : Array[String] = []
      for i in 1..<v.length() {
        if !(v[i] is Null) {
          parts.push(v[i].to_text())
        }
      }
      Text(parts.join(sep))
    }
    "format" | "printf" => {
      if v.length() == 0 || v[0] is Null {
        return Null
      }
      Text(sql_printf(v[0].to_text(), v[1:]))
    }
    "like" =>
      eval_like(
        "LIKE",
        v[0],
        v[1],
        if v.length() > 2 {
          Some(v[2])
        } else {
          None
        },
      )
    "glob" => eval_like("GLOB", v[0], v[1], None)
    "hex" => Text(blob_to_hex(v[0].to_blob()))
    "instr" => sql_instr(v[0], v[1])
    "length" =>
      match v[0] {
        Null => Null
        Blob(b) => Int(b.length().to_int64())
        x => {
          let mut n = 0L
          for c in x.to_text() {
            if c == '\u{0}' {
              break
            }
            n += 1L
          }
          Int(n)
        }
      }
    "octet_length" =>
      match v[0] {
        Null => Null
        Blob(b) => Int(b.length().to_int64())
        x => Int(utf8_len(x.to_text()).to_int64())
      }
    "likely" | "unlikely" | "likelihood" => v[0]
    "lower" => text_or_null(v[0], s => Text(ascii_case(s, false)))
    "upper" => text_or_null(v[0], s => Text(ascii_case(s, true)))
    "ltrim" => sql_trim(v[0], v.get(1), true, false)
    "rtrim" => sql_trim(v[0], v.get(1), false, true)
    "trim" => sql_trim(v[0], v.get(1), true, true)
    "quote" => Text(sql_quote(v[0]))
    "replace" => {
      if v[0] is Null || v[1] is Null || v[2] is Null {
        return Null
      }
      let pat = v[1].to_text()
      if pat.length() == 0 {
        return Text(v[0].to_text())
      }
      Text(v[0].to_text().replace_all(old=pat, new=v[2].to_text()))
    }
    "round" => sql_round(v[0], v.get(1))
    "sign" =>
      match num_arg(v[0]) {
        Some(Int(i)) => Int(if i > 0L { 1L } else if i < 0L { -1L } else { 0L })
        Some(Real(d)) =>
          Int(if d > 0.0 { 1L } else if d < 0.0 { -1L } else { 0L })
        _ => Null
      }
    "substr" | "substring" => sql_substr(v[0], v[1], v.get(2))
    "unhex" => sql_unhex(v[0], v.get(1))
    "unicode" =>
      match v[0] {
        Null => Null
        x =>
          match x.to_text().get_char(0) {
            Some(c) => Int(c.to_int().to_int64())
            None => Null
          }
      }
    "zeroblob" => {
      let n = value_to_int64(v[0])
      if n > 1000000000L {
        raise SqlError("string or blob too big")
      }
      Blob(Bytes::make(if n < 0L { 0 } else { n.to_int() }, b'\x00'))
    }
    "acos" => math1(v[0], @math.acos)
    "acosh" => math1(v[0], @math.acosh)
    "asin" => math1(v[0], @math.asin)
    "asinh" => math1(v[0], @math.asinh)
    "atan" => math1(v[0], @math.atan)
    "atan2" => math2(v[0], v[1], @math.atan2)
    "atanh" => math1(v[0], @math.atanh)
    "ceil" | "ceiling" => int_or_round(v[0], x => x.ceil())
    "floor" => int_or_round(v[0], x => x.floor())
    "trunc" => int_or_round(v[0], x => x.trunc())
    "cos" => math1(v[0], @math.cos)
    "cosh" => math1(v[0], @math.cosh)
    "sin" => math1(v[0], @math.sin)
    "sinh" => math1(v[0], @math.sinh)
    "tan" => math1(v[0], @math.tan)
    "tanh" => math1(v[0], @math.tanh)
    "sqrt" => math1(v[0], x => x.sqrt())
    "exp" => math1(v[0], @math.exp)
    "degrees" => math1(v[0], x => x * 180.0 / @math.PI)
    "radians" => math1(v[0], x => x * @math.PI / 180.0)
    "pi" => Real(@math.PI)
    "pow" | "power" => math2(v[0], v[1], @math.pow)
    "mod" => math2(v[0], v[1], (x, y) => x % y)
    "ln" | "log10" | "log2" =>
      match num_arg(v[0]) {
        Some(x) => {
          let d = value_to_double(x)
          if d <= 0.0 {
            return Null
          }
          real_result(
            match name {
              "ln" => @math.ln(d)
              "log10" => @math.log10(d)
              _ => @math.log2(d)
            },
          )
        }
        None => Null
      }
    "log" =>
      if v.length() == 1 {
        match num_arg(v[0]) {
          Some(x) => {
            let d = value_to_double(x)
            if d <= 0.0 {
              Null
            } else {
              real_result(@math.log10(d))
            }
          }
          None => Null
        }
      } else {
        match (num_arg(v[0]), num_arg(v[1])) {
          (Some(b), Some(x)) => {
            let bd = value_to_double(b)
            if bd <= 0.0 {
              return Null
            }
            let lb = @math.ln(bd)
            if lb <= 0.0 {
              return Null
            }
            let xd = value_to_double(x)
            if xd <= 0.0 {
              return Null
            }
            real_result(@math.ln(xd) / lb)
          }
          _ => Null
        }
      }
    _ => raise SqlError("no such function: \{name}")
  }
}
