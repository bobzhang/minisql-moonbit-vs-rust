// SQLite-compatible printf()/format() and decimal digit generation.

///|
/// Exact decimal expansion of a positive finite double: the significant
/// digits (no leading or trailing zeros) and the position of the decimal
/// point relative to the first digit (value = 0.d1d2... * 10^dp).
fn exact_decimal(d : Double) -> (Array[Int], Int) {
  let bits = d.reinterpret_as_uint64()
  let be = ((bits >> 52) & 0x7FFUL).reinterpret_as_int64().to_int()
  let frac = bits & 0xFFFFFFFFFFFFFUL
  let mut m = if be == 0 { frac } else { frac | (1UL << 52) }
  let mut e = if be == 0 { -1074 } else { be - 1075 }
  while (m & 1UL) == 0UL && e < 0 {
    m = m >> 1
    e += 1
  }
  let base = 1000000000L
  let limbs : Array[Int64] = []
  let mut mm = m
  while mm > 0UL {
    limbs.push((mm % 1000000000UL).reinterpret_as_int64())
    mm = mm / 1000000000UL
  }
  let mul = fn(k : Int64) {
    let mut carry = 0L
    for i in 0..<limbs.length() {
      let v = limbs[i] * k + carry
      limbs[i] = v % base
      carry = v / base
    }
    while carry > 0L {
      limbs.push(carry % base)
      carry = carry / base
    }
  }
  let mut scale = 0
  if e >= 0 {
    let mut rem = e
    while rem > 0 {
      let s = if rem > 29 { 29 } else { rem }
      mul(1L << s)
      rem -= s
    }
  } else {
    let mut rem = -e
    scale = rem
    while rem > 0 {
      let s = if rem > 12 { 12 } else { rem }
      let mut p = 1L
      for _ in 0..<s {
        p = p * 5L
      }
      mul(p)
      rem -= s
    }
  }
  let digits : Array[Int] = []
  let top = limbs[limbs.length() - 1]
  let ts = top.to_string()
  for c in ts {
    digits.push(c.to_int() - '0'.to_int())
  }
  for i = limbs.length() - 2; i >= 0; i = i - 1 {
    let ls = limbs[i].to_string()
    for _ in 0..<(9 - ls.length()) {
      digits.push(0)
    }
    for c in ls {
      digits.push(c.to_int() - '0'.to_int())
    }
  }
  let dp = digits.length() - scale
  while digits.length() > 1 && digits[digits.length() - 1] == 0 {
    ignore(digits.pop())
  }
  (digits, dp)
}

///|
priv struct FpDec {
  digits : Array[Int]
  dp : Int // number of digits before the decimal point
  neg : Bool
}

///|
/// Port of SQLite's sqlite3FpDecode rounding rules.
fn fp_decode(r : Double, round : Int, mx_round : Int) -> FpDec {
  let neg = r < 0.0
  let a = r.abs()
  if a == 0.0 {
    return { digits: [0], dp: 1, neg, }
  }
  let (z, dp0) = exact_decimal(a)
  let mut dp = dp0
  let mut ir = round
  if ir <= 0 {
    ir = dp - ir
    if ir == 0 && z[0] >= 5 {
      z.insert(0, 0)
      dp += 1
      ir = 1
    }
  }
  if ir > 0 && (ir < z.length() || z.length() > mx_round) {
    if ir > mx_round {
      ir = mx_round
    }
    let up = ir < z.length() && z[ir] >= 5
    if ir < z.length() {
      z.truncate(ir)
    }
    if up {
      let mut j = ir - 1
      while true {
        z[j] = z[j] + 1
        if z[j] <= 9 {
          break
        }
        z[j] = 0
        if j == 0 {
          z.insert(0, 1)
          dp += 1
          break
        }
        j -= 1
      }
    }
  }
  while z.length() > 1 && z[z.length() - 1] == 0 {
    ignore(z.pop())
  }
  { digits: z, dp, neg, }
}

///|
fn utf8_len(s : String) -> Int {
  let mut n = 0
  for c in s {
    let v = c.to_int()
    n += if v < 0x80 {
      1
    } else if v < 0x800 {
      2
    } else if v < 0x10000 {
      3
    } else {
      4
    }
  }
  n
}

///|
/// Prefix of `s` containing at most `nbytes` UTF-8 bytes (whole characters).
fn utf8_prefix(s : String, nbytes : Int) -> String {
  let sb = StringBuilder()
  let mut n = 0
  for c in s {
    let v = c.to_int()
    let l = if v < 0x80 {
      1
    } else if v < 0x800 {
      2
    } else if v < 0x10000 {
      3
    } else {
      4
    }
    if n + l > nbytes {
      break
    }
    n += l
    sb.write_char(c)
  }
  sb.to_string()
}

///|
fn char_prefix(s : String, nchars : Int) -> String {
  let sb = StringBuilder()
  let mut n = 0
  for c in s {
    if n >= nchars {
      break
    }
    sb.write_char(c)
    n += 1
  }
  sb.to_string()
}

///|
fn u64_to_radix(v : UInt64, base : UInt64, upper : Bool) -> String {
  let digs = if upper { "0123456789ABCDEF" } else { "0123456789abcdef" }
  let buf : Array[Char] = []
  let mut x = v
  while true {
    buf.push(digs.get_char((x % base).reinterpret_as_int64().to_int()).unwrap())
    x = x / base
    if x == 0UL {
      break
    }
  }
  buf.rev_in_place()
  String::from_array(buf[:])
}

///|
/// Formats a double like SQLite's %f / %e / %g conversions.
fn format_float(
  value : Double,
  conv : Char,
  precision0 : Int,
  width : Int,
  flag_prefix : Char?,
  flag_alt : Bool,
  flag_alt2 : Bool,
  flag_zeropad : Bool,
  flag_left : Bool,
  flag_comma? : Bool = false,
) -> String {
  let mut precision = if precision0 < 0 { 6 } else { precision0 }
  let mut xtype = match conv {
    'f' => 0
    'e' | 'E' => 1
    _ => 2
  }
  let echar = if conv == 'E' || conv == 'G' { 'E' } else { 'e' }
  if value.is_nan() {
    return "NaN"
  }
  if value.is_inf() {
    if value < 0.0 {
      return "-Inf"
    }
    return match flag_prefix {
      Some(p) => p.to_string() + "Inf"
      None => "Inf"
    }
  }
  let iround = match xtype {
    0 => -precision
    2 => {
      if precision == 0 {
        precision = 1
      }
      precision
    }
    _ => precision + 1
  }
  let s = fp_decode(value, iround, if flag_alt2 { 26 } else { 16 })
  let prefix : Char? = if s.neg { Some('-') } else { flag_prefix }
  let mut exp = s.dp - 1
  let mut flag_rtz = false
  if xtype == 2 {
    flag_rtz = !flag_alt
    precision -= 1
    if exp < -4 || exp > precision {
      xtype = 1
    } else {
      precision = precision - exp
      xtype = 0
    }
  } else {
    flag_rtz = flag_alt2
  }
  let mut e2 = if xtype == 1 { 0 } else { s.dp - 1 }
  let buf = StringBuilder()
  let digit = fn(j : Int) -> Char {
    if j < s.digits.length() {
      digit_char(s.digits[j])
    } else {
      '0'
    }
  }
  let flag_dp = precision > 0 || flag_alt || flag_alt2
  let body : Array[Char] = []
  let mut j = 0
  if e2 < 0 {
    body.push('0')
  } else {
    while e2 >= 0 {
      body.push(digit(j))
      j += 1
      if flag_comma && e2 % 3 == 0 && e2 > 1 {
        body.push(',')
      }
      e2 -= 1
    }
  }
  if flag_dp {
    body.push('.')
  }
  e2 += 1
  while e2 < 0 && precision > 0 {
    body.push('0')
    precision -= 1
    e2 += 1
  }
  while precision > 0 {
    body.push(digit(j))
    j += 1
    precision -= 1
  }
  if flag_rtz && flag_dp {
    while body.length() > 0 && body[body.length() - 1] == '0' {
      ignore(body.pop())
    }
    if body.length() > 0 && body[body.length() - 1] == '.' {
      if flag_alt2 {
        body.push('0')
      } else {
        ignore(body.pop())
      }
    }
  }
  if xtype == 1 {
    exp = s.dp - 1
    if s.digits.length() == 1 && s.digits[0] == 0 {
      exp = 0
    }
    body.push(echar)
    if exp < 0 {
      body.push('-')
      exp = -exp
    } else {
      body.push('+')
    }
    if exp >= 100 {
      body.push(digit_char(exp / 100))
      exp = exp % 100
    }
    body.push(digit_char(exp / 10))
    body.push(digit_char(exp % 10))
  }
  match prefix {
    Some(p) => buf.write_char(p)
    None => ()
  }
  let plen = if prefix is Some(_) { 1 } else { 0 }
  if flag_zeropad && !flag_left && body.length() + plen < width {
    for _ in 0..<(width - body.length() - plen) {
      buf.write_char('0')
    }
  }
  for c in body {
    buf.write_char(c)
  }
  buf.to_string()
}

///|
/// SQLite's printf(): `args` are the values after the format string.
pub fn sql_printf(fmt : String, args : ArrayView[Value]) -> String {
  let out = StringBuilder()
  let mut ai = 0
  let n = fmt.length()
  let mut i = 0
  while i < n {
    // copy literal text
    let start = i
    while i < n && fmt[i] != '%' {
      i += 1
    }
    if i > start {
      out.write_view(fmt[start:i])
    }
    if i >= n {
      break
    }
    i += 1 // skip '%'
    if i >= n {
      out.write_char('%')
      break
    }
    let mut flag_left = false
    let mut flag_prefix : Char? = None
    let mut flag_alt = false
    let mut flag_alt2 = false
    let mut flag_zeropad = false
    let mut flag_comma = false
    while i < n {
      match fmt[i] {
        '-' => flag_left = true
        '+' => flag_prefix = Some('+')
        ' ' => if flag_prefix is None { flag_prefix = Some(' ') }
        '#' => flag_alt = true
        '!' => flag_alt2 = true
        '0' => flag_zeropad = true
        ',' => flag_comma = true
        _ => break
      }
      i += 1
    }
    let mut width = 0
    if i < n && fmt[i] == '*' {
      i += 1
      let w = if ai < args.length() {
        ai += 1
        value_to_int64(args[ai - 1])
      } else {
        0L
      }
      if w < 0L {
        flag_left = true
        width = if w < -100000000L { 100000000 } else { (-w).to_int() }
      } else {
        width = if w > 100000000L { 100000000 } else { w.to_int() }
      }
    } else {
      while i < n && is_digit_cu(fmt[i]) {
        width = width * 10 + (fmt[i].to_int() - '0'.to_int())
        if width > 100000000 {
          width = 100000000
        }
        i += 1
      }
    }
    let mut precision = -1
    if i < n && fmt[i] == '.' {
      i += 1
      if i < n && fmt[i] == '*' {
        i += 1
        let p = if ai < args.length() {
          ai += 1
          value_to_int64(args[ai - 1])
        } else {
          0L
        }
        let p = if p < 0L { -p } else { p }
        precision = if p > 100000000L { 100000000 } else { p.to_int() }
      } else {
        precision = 0
        while i < n && is_digit_cu(fmt[i]) {
          precision = precision * 10 + (fmt[i].to_int() - '0'.to_int())
          if precision > 100000000 {
            precision = 100000000
          }
          i += 1
        }
      }
    }
    while i < n && fmt[i] == 'l' {
      i += 1
    }
    if i >= n {
      break
    }
    let conv = fmt.get_char(i).unwrap_or('?')
    i += 1
    let next_val = fn() -> Value {
      if ai < args.length() {
        ai += 1
        args[ai - 1]
      } else {
        Null
      }
    }
    // body text, and whether width counts characters instead of bytes
    let mut body = ""
    let mut count_chars = false
    match conv {
      'd' | 'i' | 'u' | 'x' | 'X' | 'o' | 'p' => {
        let v = value_to_int64(next_val())
        let (base, upper, signed, pfx) = match conv {
          'd' | 'i' => (10UL, false, true, "")
          'u' => (10UL, false, false, "")
          'x' => (16UL, false, false, "0x")
          'p' => (16UL, false, false, "")
          'X' => (16UL, true, false, "0X")
          _ => (8UL, false, false, "0")
        }
        let mut prefix : Char? = None
        let uv = if signed {
          if v < 0L {
            prefix = Some('-')
            (-v).reinterpret_as_uint64()
          } else {
            prefix = flag_prefix
            v.reinterpret_as_uint64()
          }
        } else {
          v.reinterpret_as_uint64()
        }
        let alt = flag_alt && uv != 0UL
        let mut prec = precision
        let plen = if prefix is Some(_) { 1 } else { 0 }
        if flag_zeropad && prec < width - plen {
          prec = width - plen
        }
        let mut digits = u64_to_radix(uv, base, upper)
        if digits.length() < prec {
          digits = String::make(prec - digits.length(), '0') + digits
        }
        if flag_comma && base == 10UL {
          let sb = StringBuilder()
          let len = digits.length()
          for k in 0..<len {
            if k > 0 && (len - k) % 3 == 0 {
              sb.write_char(',')
            }
            sb.write_view(digits[k:k + 1])
          }
          digits = sb.to_string()
        }
        match prefix {
          Some(p) => digits = p.to_string() + digits
          None => ()
        }
        if alt {
          digits = pfx + digits
        }
        body = digits
      }
      'f' | 'e' | 'E' | 'g' | 'G' => {
        let d = value_to_double(next_val())
        body = format_float(
          d,
          conv,
          precision,
          width,
          flag_prefix,
          flag_alt,
          flag_alt2,
          flag_zeropad,
          flag_left,
          flag_comma~,
        )
      }
      's' | 'z' => {
        let v = next_val()
        let mut s = if v is Null { "" } else { v.to_text() }
        if precision >= 0 {
          s = if flag_alt2 {
            char_prefix(s, precision)
          } else {
            utf8_prefix(s, precision)
          }
        }
        body = s
        count_chars = flag_alt2
      }
      'c' => {
        let v = next_val()
        let s = if v is Null { "" } else { v.to_text() }
        let first = match s.get_char(0) {
          Some(c) => c.to_string()
          None => ""
        }
        body = if precision > 1 { first.repeat(precision) } else { first }
        count_chars = true
      }
      'q' | 'Q' | 'w' => {
        let v = next_val()
        let q = if conv == 'w' { '"' } else { '\'' }
        let isnull = v is Null
        let mut s = if isnull {
          if conv == 'Q' {
            "NULL"
          } else {
            "(NULL)"
          }
        } else {
          v.to_text()
        }
        if precision >= 0 {
          s = if flag_alt2 {
            char_prefix(s, precision)
          } else {
            utf8_prefix(s, precision)
          }
        }
        let sb = StringBuilder()
        let quote = !isnull && conv == 'Q'
        if quote {
          sb.write_char(q)
        }
        for c in s {
          sb.write_char(c)
          if c == q {
            sb.write_char(q)
          }
        }
        if quote {
          sb.write_char(q)
        }
        body = sb.to_string()
        count_chars = flag_alt2
      }
      '%' => body = "%"
      'n' => continue
      _ => break
    }
    let len = if count_chars { body.char_length() } else { utf8_len(body) }
    let pad = width - len
    if pad > 0 && !flag_left {
      for _ in 0..<pad {
        out.write_char(' ')
      }
    }
    out.write_string(body)
    if pad > 0 && flag_left {
      for _ in 0..<pad {
        out.write_char(' ')
      }
    }
  }
  out.to_string()
}

///|
fn digit_char(d : Int) -> Char {
  "0123456789".get_char(d).unwrap()
}
