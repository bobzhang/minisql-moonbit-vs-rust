///|
pub(all) struct ScalarFunc {
  min_args : Int
  max_args : Int // -1 = variadic
  f : (Array[Value]) -> Value raise SqlError
}

///|
fn text_arg(v : Value) -> String {
  v.to_text()
}

///|
/// Bytes of a value's blob or UTF-8 text form.
fn bytes_of(v : Value) -> Bytes {
  match v {
    Blob(b) => b
    _ => @utf8.encode(v.to_text())
  }
}

///|
fn real_or_null(r : Double) -> Value {
  if r.is_nan() {
    Null
  } else {
    Real(r)
  }
}

///|
/// Wraps a one-argument math function: NULL/non-numeric give NULL.
fn math1(f : (Double) -> Double) -> ScalarFunc {
  {
    min_args: 1,
    max_args: 1,
    f: args => {
      match args[0].numeric_strict() {
        Some(v) => real_or_null(f(v.as_double()))
        None => Null
      }
    },
  }
}

///|
fn math2(f : (Double, Double) -> Double) -> ScalarFunc {
  {
    min_args: 2,
    max_args: 2,
    f: args => {
      match (args[0].numeric_strict(), args[1].numeric_strict()) {
        (Some(a), Some(b)) => real_or_null(f(a.as_double(), b.as_double()))
        _ => Null
      }
    },
  }
}

///|
/// ceil/floor/trunc: integers pass through, reals are rounded.
fn int_preserving(f : (Double) -> Double) -> ScalarFunc {
  {
    min_args: 1,
    max_args: 1,
    f: args => {
      match args[0].numeric_strict() {
        Some(Int(i)) => Int(i)
        Some(v) => real_or_null(f(v.as_double()))
        None => Null
      }
    },
  }
}

///|
fn trim_func(left : Bool, right : Bool) -> ScalarFunc {
  {
    min_args: 1,
    max_args: 2,
    f: args => {
      if args[0] is Null {
        return Null
      }
      let set : Array[Char] = if args.length() == 2 {
        if args[1] is Null {
          return Null
        }
        text_arg(args[1]).to_array()
      } else {
        [' ']
      }
      let chars = text_arg(args[0]).to_array()
      let mut a = 0
      let mut b = chars.length()
      if left {
        while a < b && set.contains(chars[a]) {
          a += 1
        }
      }
      if right {
        while b > a && set.contains(chars[b - 1]) {
          b -= 1
        }
      }
      Text(String::from_array(chars[a:b]))
    },
  }
}

///|
fn case_func(upper : Bool) -> ScalarFunc {
  {
    min_args: 1,
    max_args: 1,
    f: args => {
      if args[0] is Null {
        return Null
      }
      let s = text_arg(args[0])
      let sb = StringBuilder()
      for c in s {
        sb.write_char(
          if upper {
            if c >= 'a' && c <= 'z' {
              (c.to_int() - 32).unsafe_to_char()
            } else {
              c
            }
          } else if c >= 'A' && c <= 'Z' {
            (c.to_int() + 32).unsafe_to_char()
          } else {
            c
          },
        )
      }
      Text(sb.to_string())
    },
  }
}

///|
fn hex_value(c : Int) -> Int {
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
fn unhex_func(args : Array[Value]) -> Value {
  if args[0] is Null {
    return Null
  }
  let ignore_set : Array[Char] = if args.length() == 2 {
    if args[1] is Null {
      return Null
    }
    text_arg(args[1]).to_array()
  } else {
    []
  }
  let chars = text_arg(args[0]).to_array()
  let buf = @buffer.Buffer()
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if ignore_set.contains(c) {
      i += 1
      continue
    }
    let h = hex_value(c.to_int())
    if h < 0 || i + 1 >= chars.length() {
      return Null
    }
    let l = hex_value(chars[i + 1].to_int())
    if l < 0 {
      return Null
    }
    buf.write_byte((h * 16 + l).to_byte())
    i += 2
  }
  Blob(buf.to_bytes())
}

///|
fn substr_func(args : Array[Value]) -> Value {
  if args[0] is Null || args[1] is Null {
    return Null
  }
  if args.length() == 3 && args[2] is Null {
    return Null
  }
  let is_blob = args[0] is Blob(_)
  let blob = match args[0] {
    Blob(b) => b
    _ => b""
  }
  let chars = if is_blob { [] } else { text_arg(args[0]).to_array() }
  let len = if is_blob { blob.length() } else { chars.length() }
  let len64 = len.to_int64()
  let mut p1 = args[1].to_int64_cast()
  let mut p2 = 0L
  let mut neg_p2 = false
  if args.length() == 3 {
    p2 = args[2].to_int64_cast()
    if p2 < 0L {
      p2 = -p2
      neg_p2 = true
    }
  } else {
    p2 = 1000000000L
  }
  if p1 < 0L {
    p1 += len64
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
  if p1 > len64 {
    p1 = len64
  }
  if p1 + p2 > len64 {
    p2 = len64 - p1
  }
  if p2 < 0L {
    p2 = 0L
  }
  let a = p1.to_int()
  let b = (p1 + p2).to_int()
  if is_blob {
    Blob(blob[a:b].to_owned())
  } else {
    Text(String::from_array(chars[a:b]))
  }
}

///|
fn instr_func(args : Array[Value]) -> Value {
  if args[0] is Null || args[1] is Null {
    return Null
  }
  match (args[0], args[1]) {
    (Blob(h), Blob(n)) => {
      if n.length() == 0 {
        return Int(1L)
      }
      for i = 0; i + n.length() <= h.length(); i = i + 1 {
        if h[i:i + n.length()] == n[:] {
          return Int((i + 1).to_int64())
        }
      }
      Int(0L)
    }
    _ => {
      let h = text_arg(args[0]).to_array()
      let n = text_arg(args[1]).to_array()
      if n.length() == 0 {
        return Int(1L)
      }
      for i = 0; i + n.length() <= h.length(); i = i + 1 {
        let mut ok = true
        for k in 0..<n.length() {
          if h[i + k] != n[k] {
            ok = false
            break
          }
        }
        if ok {
          return Int((i + 1).to_int64())
        }
      }
      Int(0L)
    }
  }
}

///|
fn like_func(args : Array[Value]) -> Value raise SqlError {
  let mut esc : Char? = None
  if args.length() == 3 {
    if args[2] is Null {
      return Null
    }
    let e = text_arg(args[2])
    if e.char_length() != 1 {
      raise err("ESCAPE expression must be a single character")
    }
    esc = e.get_char(0)
  }
  if args[0] is Null || args[1] is Null {
    return Null
  }
  bool_value(like_text(text_arg(args[0]), text_arg(args[1]), esc))
}

///|
fn quote_value(v : Value) -> String {
  match v {
    Null => "NULL"
    Int(i) => i.to_string()
    Real(r) => format_real(r)
    Text(s) => "'" + s.replace_all(old="'", new="''") + "'"
    Blob(b) => "X'" + blob_to_hex(b) + "'"
  }
}

///|
fn char_of_code(x : Int64) -> Char {
  let v = if x < 0L || x > 0x10FFFFL || (x >= 0xD800L && x <= 0xDFFFL) {
    0xFFFD
  } else {
    x.to_int()
  }
  v.unsafe_to_char()
}

///|
let scalar_functions : Map[String, ScalarFunc] = {
  let m : Map[String, ScalarFunc] = Map([])
  m["typeof"] = {
    min_args: 1,
    max_args: 1,
    f: args => Text(args[0].type_name()),
  }
  m["abs"] = {
    min_args: 1,
    max_args: 1,
    f: args => {
      match args[0] {
        Null => Null
        Int(i) =>
          if i == @int64.MIN_VALUE {
            raise err("integer overflow")
          } else if i < 0L {
            Int(-i)
          } else {
            Int(i)
          }
        v => Real(v.as_double().abs())
      }
    },
  }
  m["char"] = {
    min_args: 0,
    max_args: -1,
    f: args => {
      let sb = StringBuilder()
      for a in args {
        sb.write_char(char_of_code(a.to_int64_cast()))
      }
      Text(sb.to_string())
    },
  }
  m["concat"] = {
    min_args: 1,
    max_args: -1,
    f: args => {
      let sb = StringBuilder()
      for a in args {
        if !(a is Null) {
          sb.write_string(text_arg(a))
        }
      }
      Text(sb.to_string())
    },
  }
  m["concat_ws"] = {
    min_args: 2,
    max_args: -1,
    f: args => {
      if args[0] is Null {
        return Null
      }
      let sep = text_arg(args[0])
      let sb = StringBuilder()
      let mut first = true
      for i in 1..<args.length() {
        if args[i] is Null {
          continue
        }
        if !first {
          sb.write_string(sep)
        }
        first = false
        sb.write_string(text_arg(args[i]))
      }
      Text(sb.to_string())
    },
  }
  let printf_f : ScalarFunc = {
    min_args: 1,
    max_args: -1,
    f: args => {
      if args[0] is Null {
        return Null
      }
      let s = sql_printf(text_arg(args[0]), args[1:])
      if s == "" {
        Null
      } else {
        Text(s)
      }
    },
  }
  m["printf"] = printf_f
  m["format"] = printf_f
  m["glob"] = {
    min_args: 2,
    max_args: 2,
    f: args => {
      if args[0] is Null || args[1] is Null {
        return Null
      }
      bool_value(glob_text(text_arg(args[0]), text_arg(args[1])))
    },
  }
  m["like"] = { min_args: 2, max_args: 3, f: like_func, }
  m["hex"] = {
    min_args: 1,
    max_args: 1,
    f: args => {
      match args[0] {
        Null => Text("")
        v => Text(blob_to_hex(bytes_of(v)))
      }
    },
  }
  m["instr"] = { min_args: 2, max_args: 2, f: args => instr_func(args), }
  m["length"] = {
    min_args: 1,
    max_args: 1,
    f: args => {
      match args[0] {
        Null => Null
        Blob(b) => Int(b.length().to_int64())
        v => {
          // Like SQLite, text length stops at the first NUL character.
          let t = text_arg(v)
          let t = match t.find("\u{0}") {
            Some(i) => t[:i].to_owned()
            None => t
          }
          Int(t.char_length().to_int64())
        }
      }
    },
  }
  m["octet_length"] = {
    min_args: 1,
    max_args: 1,
    f: args => {
      match args[0] {
        Null => Null
        Blob(b) => Int(b.length().to_int64())
        v => Int(utf8_length(text_arg(v)).to_int64())
      }
    },
  }
  m["lower"] = case_func(false)
  m["upper"] = case_func(true)
  m["ltrim"] = trim_func(true, false)
  m["rtrim"] = trim_func(false, true)
  m["trim"] = trim_func(true, true)
  m["quote"] = {
    min_args: 1,
    max_args: 1,
    f: args => Text(quote_value(args[0])),
  }
  m["replace"] = {
    min_args: 3,
    max_args: 3,
    f: args => {
      if args[0] is Null || args[1] is Null || args[2] is Null {
        return Null
      }
      let s = text_arg(args[0])
      let pat = text_arg(args[1])
      if pat == "" {
        return Text(s)
      }
      Text(s.replace_all(old=pat, new=text_arg(args[2])))
    },
  }
  m["round"] = {
    min_args: 1,
    max_args: 2,
    f: args => {
      let mut n = 0L
      if args.length() == 2 {
        if args[1] is Null {
          return Null
        }
        n = args[1].to_int64_cast()
        if n > 30L {
          n = 30L
        }
        if n < 0L {
          n = 0L
        }
      }
      if args[0] is Null {
        return Null
      }
      Real(sql_round(args[0].as_double(), n))
    },
  }
  m["sign"] = {
    min_args: 1,
    max_args: 1,
    f: args => {
      match args[0].numeric_strict() {
        Some(Int(i)) => Int(if i > 0L { 1L } else if i < 0L { -1L } else { 0L })
        Some(Real(r)) =>
          Int(if r > 0.0 { 1L } else if r < 0.0 { -1L } else { 0L })
        _ => Null
      }
    },
  }
  m["substr"] = { min_args: 2, max_args: 3, f: args => substr_func(args), }
  m["substring"] = { min_args: 2, max_args: 3, f: args => substr_func(args), }
  m["unhex"] = { min_args: 1, max_args: 2, f: args => unhex_func(args), }
  m["unicode"] = {
    min_args: 1,
    max_args: 1,
    f: args => {
      if args[0] is Null {
        return Null
      }
      match text_arg(args[0]).get_char(0) {
        Some(c) => Int(c.to_int().to_int64())
        None => Null
      }
    },
  }
  m["zeroblob"] = {
    min_args: 1,
    max_args: 1,
    f: args => {
      let n = args[0].to_int64_cast()
      if n > 1000000000L {
        raise err("string or blob too big")
      }
      Blob(Bytes::make(if n < 0L { 0 } else { n.to_int() }, b'\x00'))
    },
  }
  // Math functions.
  m["acos"] = math1(@math.acos)
  m["asin"] = math1(@math.asin)
  m["atan"] = math1(@math.atan)
  m["acosh"] = math1(@math.acosh)
  m["asinh"] = math1(@math.asinh)
  m["atanh"] = math1(@math.atanh)
  m["cos"] = math1(@math.cos)
  m["sin"] = math1(@math.sin)
  m["tan"] = math1(@math.tan)
  m["cosh"] = math1(@math.cosh)
  m["sinh"] = math1(@math.sinh)
  m["tanh"] = math1(@math.tanh)
  m["exp"] = math1(@math.exp)
  m["sqrt"] = math1(x => x.sqrt())
  m["degrees"] = math1(x => x * (180.0 / @math.PI))
  m["radians"] = math1(x => x * (@math.PI / 180.0))
  m["ln"] = math1(x => if x <= 0.0 { @double.not_a_number } else { @math.ln(x) })
  m["log10"] = math1(x => {
    if x <= 0.0 {
      @double.not_a_number
    } else {
      @math.log10(x)
    }
  })
  m["log2"] = math1(x => {
    if x <= 0.0 {
      @double.not_a_number
    } else {
      @math.log2(x)
    }
  })
  m["log"] = {
    min_args: 1,
    max_args: 2,
    f: args => {
      let vals = []
      for a in args {
        match a.numeric_strict() {
          Some(v) => {
            let d = v.as_double()
            if d <= 0.0 {
              return Null
            }
            vals.push(d)
          }
          None => return Null
        }
      }
      if vals.length() == 1 {
        real_or_null(@math.log10(vals[0]))
      } else {
        real_or_null(@math.ln(vals[1]) / @math.ln(vals[0]))
      }
    },
  }
  m["atan2"] = math2(@math.atan2)
  m["pow"] = math2(@math.pow)
  m["power"] = math2(@math.pow)
  m["mod"] = math2((a, b) => a % b)
  m["ceil"] = int_preserving(x => x.ceil())
  m["ceiling"] = int_preserving(x => x.ceil())
  m["floor"] = int_preserving(x => x.floor())
  m["trunc"] = int_preserving(x => x.trunc())
  m["pi"] = { min_args: 0, max_args: 0, f: _ => Real(@math.PI), }
  register_date_functions(m)
  m
}

///|
pub fn lookup_scalar(name : String, nargs : Int) -> ScalarFunc raise SqlError {
  match scalar_functions.get(name.to_lower()) {
    Some(sf) => {
      if nargs < sf.min_args || (sf.max_args >= 0 && nargs > sf.max_args) {
        raise err("wrong number of arguments to function " + name + "()")
      }
      sf
    }
    None => raise err("no such function: " + name)
  }
}
