///|
/// Decimal decomposition of a double as produced by SQLite's
/// sqlite3FpDecode: value = 0.d1d2d3... * 10^idp.
priv struct FpDecode {
  neg : Bool
  mut digits : Array[Int]
  mut idp : Int
  special : Int // 0 = finite, 1 = infinity, 2 = NaN
}

///|
/// Exact decimal digits of a non-negative big integer given as base-1e9
/// little-endian limbs.
fn limbs_to_digits(limbs : Array[Int64]) -> Array[Int] {
  let mut top = limbs.length() - 1
  while top > 0 && limbs[top] == 0L {
    top -= 1
  }
  let out : Array[Int] = []
  let first = limbs[top].to_string()
  for c in first {
    out.push(c.to_int() - '0'.to_int())
  }
  for i = top - 1; i >= 0; i = i - 1 {
    let s = limbs[i].to_string()
    for _ in 0..<(9 - s.length()) {
      out.push(0)
    }
    for c in s {
      out.push(c.to_int() - '0'.to_int())
    }
  }
  out
}

///|
fn limbs_mul_small(limbs : Array[Int64], m : Int64) -> Unit {
  let mut carry = 0L
  for i in 0..<limbs.length() {
    let v = limbs[i] * m + carry
    limbs[i] = v % 1000000000L
    carry = v / 1000000000L
  }
  while carry > 0L {
    limbs.push(carry % 1000000000L)
    carry = carry / 1000000000L
  }
}

///|
/// Exact decimal digits (no leading zeros) and exponent for a positive
/// finite double.
fn exact_decimal(x : Double) -> (Array[Int], Int) {
  let bits = x.reinterpret_as_uint64()
  let biased = ((bits >> 52) & 0x7FFUL).to_int()
  let frac = bits & 0xFFFFFFFFFFFFFUL
  let (mant, e) = if biased == 0 {
    (frac, -1074)
  } else {
    (frac | 0x10000000000000UL, biased - 1075)
  }
  let m = mant.reinterpret_as_int64()
  let limbs : Array[Int64] = [
    m % 1000000000L,
    m / 1000000000L % 1000000000L,
    m / 1000000000000000000L,
  ]
  if e >= 0 {
    let mut k = e
    while k > 0 {
      let step = if k > 29 { 29 } else { k }
      limbs_mul_small(limbs, 1L << step)
      k -= step
    }
    let d = limbs_to_digits(limbs)
    (d, d.length())
  } else {
    let mut k = -e
    while k > 0 {
      let step = if k > 13 { 13 } else { k }
      let mut p = 1L
      for _ in 0..<step {
        p = p * 5L
      }
      limbs_mul_small(limbs, p)
      k -= step
    }
    let d = limbs_to_digits(limbs)
    (d, d.length() + e)
  }
}

///|
fn fp_decode(r : Double, iround : Int, mx_round : Int) -> FpDecode {
  if r.is_nan() {
    return { neg: false, digits: [], idp: 0, special: 2, }
  }
  let neg = r < 0.0
  let x = r.abs()
  if x.is_inf() {
    return { neg, digits: [], idp: 0, special: 1, }
  }
  if x == 0.0 {
    return { neg: false, digits: [0], idp: 1, special: 0, }
  }
  let (digits, idp) = exact_decimal(x)
  let p : FpDecode = { neg, digits, idp, special: 0, }
  // Drop trailing zeros.
  while p.digits.length() > 1 && p.digits[p.digits.length() - 1] == 0 {
    ignore(p.digits.pop())
  }
  let mut iround = iround
  if iround <= 0 {
    iround = p.idp - iround
    if iround == 0 && p.digits[0] >= 5 {
      iround = 1
      p.digits.insert(0, 0)
      p.idp += 1
    }
  }
  if iround > 0 && (iround < p.digits.length() || p.digits.length() > mx_round) {
    if iround > mx_round {
      iround = mx_round
    }
    let round_up = iround < p.digits.length() && p.digits[iround] >= 5
    p.digits.truncate(iround)
    if round_up {
      let mut j = iround - 1
      while true {
        p.digits[j] += 1
        if p.digits[j] <= 9 {
          break
        }
        p.digits[j] = 0
        if j == 0 {
          p.digits.insert(0, 1)
          p.idp += 1
          break
        }
        j -= 1
      }
    }
  }
  while p.digits.length() > 1 && p.digits[p.digits.length() - 1] == 0 {
    ignore(p.digits.pop())
  }
  p
}

///|
/// Formats a double like SQLite's %f / %e / %g conversions.
/// `conv` is one of 'f', 'e', 'E', 'g', 'G'.
fn format_float(
  value : Double,
  conv : Char,
  precision : Int,
  width : Int,
  flag_plus : Bool,
  flag_blank : Bool,
  flag_alt : Bool,
  flag_alt2 : Bool,
  flag_zeropad : Bool,
  flag_left : Bool,
  flag_comma : Bool,
) -> String {
  let mut precision = if precision < 0 { 6 } else { precision }
  let upper = conv == 'E' || conv == 'G'
  let is_generic = conv == 'g' || conv == 'G'
  let is_exp0 = conv == 'e' || conv == 'E'
  let iround = if conv == 'f' {
    -precision
  } else if is_generic {
    if precision == 0 {
      precision = 1
    }
    precision
  } else {
    precision + 1
  }
  let s = fp_decode(value, iround, if flag_alt2 { 26 } else { 16 })
  let prefix : Char? = if s.neg {
    Some('-')
  } else if flag_plus {
    Some('+')
  } else if flag_blank {
    Some(' ')
  } else {
    None
  }
  if s.special == 2 {
    return if flag_zeropad { "null" } else { "NaN" }
  }
  if s.special == 1 {
    if flag_zeropad {
      s.digits = [9]
      s.idp = 1000
    } else if s.neg {
      return "-Inf"
    } else if flag_plus {
      return "+Inf"
    } else {
      return "Inf"
    }
  }
  let mut is_exp = is_exp0
  let mut flag_rtz = flag_alt2
  let exp0 = s.idp - 1
  if is_generic {
    precision -= 1
    flag_rtz = !flag_alt
    if exp0 < -4 || exp0 > precision {
      is_exp = true
    } else {
      precision = precision - exp0
    }
  }
  let mut e2 = if is_exp { 0 } else { s.idp - 1 }
  let buf = StringBuilder()
  if prefix is Some(p) {
    buf.write_char(p)
  }
  let nd = s.digits.length()
  let mut j = 0
  let digit = (k : Int) => (s.digits[k] + '0'.to_int()).unsafe_to_char()
  if e2 < 0 {
    buf.write_char('0')
  } else {
    while e2 >= 0 {
      if j < nd {
        buf.write_char(digit(j))
        j += 1
      } else {
        buf.write_char('0')
      }
      if flag_comma && e2 % 3 == 0 && e2 > 1 {
        buf.write_char(',')
      }
      e2 -= 1
    }
  }
  let flag_dp = precision > 0 || flag_alt || flag_alt2
  if flag_dp {
    buf.write_char('.')
  }
  e2 += 1
  while e2 < 0 && precision > 0 {
    buf.write_char('0')
    precision -= 1
    e2 += 1
  }
  while precision > 0 {
    if j < nd {
      buf.write_char(digit(j))
      j += 1
    } else {
      buf.write_char('0')
    }
    precision -= 1
  }
  let mut out = buf.to_string()
  if flag_rtz && flag_dp {
    let mut end = out.length()
    while end > 0 && out[end - 1] == '0' {
      end -= 1
    }
    out = out[:end].to_owned()
    if out.has_suffix(".") {
      if flag_alt2 {
        out = out + "0"
      } else {
        out = out[:out.length() - 1].to_owned()
      }
    }
  }
  if is_exp {
    let mut ex = s.idp - 1
    if s.digits == [0] {
      ex = 0
    }
    let eb = StringBuilder()
    eb.write_char(if upper { 'E' } else { 'e' })
    if ex < 0 {
      eb.write_char('-')
      ex = -ex
    } else {
      eb.write_char('+')
    }
    if ex >= 100 {
      eb.write_string((ex / 100).to_string())
      ex = ex % 100
    }
    eb.write_string((ex / 10).to_string())
    eb.write_string((ex % 10).to_string())
    out = out + eb.to_string()
  }
  if flag_zeropad && !flag_left && out.length() < width {
    let npad = width - out.length()
    let k = if prefix is Some(_) { 1 } else { 0 }
    out = out[:k].to_owned() + String::make(npad, '0') + out[k:].to_owned()
  }
  out
}

///|
fn utf8_len_char(c : Char) -> Int {
  let v = c.to_int()
  if v < 0x80 {
    1
  } else if v < 0x800 {
    2
  } else if v < 0x10000 {
    3
  } else {
    4
  }
}

///|
pub fn utf8_length(s : String) -> Int {
  let mut n = 0
  for c in s {
    n += utf8_len_char(c)
  }
  n
}

///|
/// Implements SQL printf()/format().
pub fn sql_printf(fmt : String, args : ArrayView[Value]) -> String {
  let out = StringBuilder()
  let f = fmt.to_array()
  let n = f.length()
  let mut argi = 0
  let next_arg = () => {
    if argi < args.length() {
      let v = args[argi]
      argi += 1
      Some(v)
    } else {
      None
    }
  }
  let int_arg = () => {
    match next_arg() {
      Some(v) => v.to_int64_cast()
      None => 0L
    }
  }
  let double_arg = () => {
    match next_arg() {
      Some(v) => v.as_double()
      None => 0.0
    }
  }
  let mut i = 0
  while i < n {
    let c = f[i]
    if c != '%' {
      out.write_char(c)
      i += 1
      continue
    }
    i += 1
    if i >= n {
      out.write_char('%')
      break
    }
    let mut flag_left = false
    let mut flag_plus = false
    let mut flag_blank = false
    let mut flag_alt = false
    let mut flag_alt2 = false
    let mut flag_zeropad = false
    let mut flag_comma = false
    while i < n {
      match f[i] {
        '-' => flag_left = true
        '+' => flag_plus = true
        ' ' => flag_blank = true
        '#' => flag_alt = true
        '!' => flag_alt2 = true
        '0' => flag_zeropad = true
        ',' => flag_comma = true
        _ => break
      }
      i += 1
    }
    let mut width = 0
    if i < n && f[i] == '*' {
      let w = int_arg()
      if w < 0L {
        flag_left = true
        width = if w < -2147483647L { 2147483647 } else { (-w).to_int() }
      } else {
        width = if w > 2147483647L { 2147483647 } else { w.to_int() }
      }
      i += 1
    } else {
      while i < n && f[i] >= '0' && f[i] <= '9' {
        width = width * 10 + (f[i].to_int() - '0'.to_int())
        if width > 100000000 {
          width = 100000000
        }
        i += 1
      }
    }
    let mut precision = -1
    if i < n && f[i] == '.' {
      i += 1
      if i < n && f[i] == '*' {
        let p = int_arg()
        precision = if p < 0L {
          -1
        } else if p > 2147483647L {
          2147483647
        } else {
          p.to_int()
        }
        i += 1
      } else {
        precision = 0
        while i < n && f[i] >= '0' && f[i] <= '9' {
          precision = precision * 10 + (f[i].to_int() - '0'.to_int())
          if precision > 100000000 {
            precision = 100000000
          }
          i += 1
        }
      }
    }
    // Length modifiers are accepted and ignored.
    while i < n && (f[i] == 'l' || f[i] == 'h') {
      i += 1
    }
    if i >= n {
      break
    }
    let conv = f[i]
    i += 1
    // `text` is the converted field; `len` its length for width purposes.
    let mut text = ""
    let mut len = -1
    match conv {
      'd' | 'i' | 'u' | 'x' | 'X' | 'o' | 'p' | 'r' => {
        let v = int_arg()
        let signed = conv == 'd' || conv == 'i' || conv == 'r'
        let mut prefix = ""
        let mut uv : UInt64 = v.reinterpret_as_uint64()
        if signed {
          if v < 0L {
            uv = (0L - v).reinterpret_as_uint64()
            prefix = "-"
          } else if flag_plus {
            prefix = "+"
          } else if flag_blank {
            prefix = " "
          }
        }
        let mut alt = flag_alt
        if uv == 0UL {
          alt = false
        }
        let mut prec = precision
        if flag_zeropad && prec < width - prefix.length() {
          prec = width - prefix.length()
        }
        let radix = match conv {
          'x' | 'X' | 'p' => 16
          'o' => 8
          _ => 10
        }
        let digits_raw = if radix == 10 {
          uv.to_string()
        } else {
          uv.to_string(radix~)
        }
        let digits_s = if conv == 'X' || conv == 'p' {
          digits_raw.to_upper()
        } else {
          digits_raw
        }
        let mut digits = digits_s
        if conv == 'r' {
          let m100 = uv % 100UL
          let m10 = uv % 10UL
          let suf = if m100 >= 11UL && m100 <= 13UL {
            "th"
          } else if m10 == 1UL {
            "st"
          } else if m10 == 2UL {
            "nd"
          } else if m10 == 3UL {
            "rd"
          } else {
            "th"
          }
          digits = digits + suf
        }
        if flag_comma && radix == 10 && conv != 'r' {
          let sb = StringBuilder()
          let l = digits.length()
          for k in 0..<l {
            if k > 0 && (l - k) % 3 == 0 {
              sb.write_char(',')
            }
            sb.write_char(digits.get_char(k).unwrap())
          }
          digits = sb.to_string()
        }
        if digits.length() < prec {
          digits = String::make(prec - digits.length(), '0') + digits
        }
        let pre = if alt {
          match conv {
            'x' => "0x"
            'X' => "0X"
            'o' => "0"
            _ => ""
          }
        } else {
          ""
        }
        text = prefix + pre + digits
      }
      'f' | 'e' | 'E' | 'g' | 'G' =>
        text = format_float(
          double_arg(),
          conv,
          precision,
          width,
          flag_plus,
          flag_blank,
          flag_alt,
          flag_alt2,
          flag_zeropad,
          flag_left,
          flag_comma,
        )
      's' | 'z' => {
        let s = match next_arg() {
          Some(v) => v.to_text()
          None => ""
        }
        if flag_alt2 {
          // Width and precision count characters.
          let chars = s.to_array()
          let taken = if precision >= 0 && precision < chars.length() {
            String::from_array(chars[:precision])
          } else {
            s
          }
          text = taken
          len = if precision >= 0 && precision < chars.length() {
            precision
          } else {
            chars.length()
          }
        } else if precision >= 0 {
          let sb = StringBuilder()
          let mut bytes = 0
          for ch in s {
            let l = utf8_len_char(ch)
            if bytes + l > precision {
              break
            }
            bytes += l
            sb.write_char(ch)
          }
          text = sb.to_string()
          len = bytes
        } else {
          text = s
          len = utf8_length(s)
        }
      }
      'c' => {
        let s = match next_arg() {
          Some(v) => v.to_text()
          None => ""
        }
        let ch = match s.get_char(0) {
          Some(x) => x.to_string()
          None => ""
        }
        let reps = if precision > 1 { precision } else { 1 }
        text = if ch == "" { "" } else { ch.repeat(reps) }
        len = utf8_length(text)
      }
      'q' | 'Q' | 'w' => {
        let arg = next_arg()
        let quote = if conv == 'w' { '"' } else { '\'' }
        match arg {
          None | Some(Null) =>
            text = if conv == 'Q' { "NULL" } else { "(NULL)" }
          Some(v) => {
            let s = v.to_text()
            let chars = s.to_array()
            let limit = if precision >= 0 && precision < chars.length() {
              precision
            } else {
              chars.length()
            }
            let sb = StringBuilder()
            if conv == 'Q' {
              sb.write_char('\'')
            }
            for k in 0..<limit {
              sb.write_char(chars[k])
              if chars[k] == quote {
                sb.write_char(quote)
              }
            }
            if conv == 'Q' {
              sb.write_char('\'')
            }
            text = sb.to_string()
          }
        }
        len = utf8_length(text)
      }
      '%' => {
        text = "%"
        len = 1
      }
      'n' => continue
      _ => break
    }
    if len < 0 {
      len = utf8_length(text)
    }
    if width > len {
      let pad = String::make(width - len, ' ')
      if flag_left {
        out.write_string(text)
        out.write_string(pad)
      } else {
        out.write_string(pad)
        out.write_string(text)
      }
    } else {
      out.write_string(text)
    }
  }
  out.to_string()
}

///|
/// round(X, N) as implemented by SQLite.
pub fn sql_round(r : Double, n : Int64) -> Double {
  if r < -4503599627370496.0 || r > 4503599627370496.0 {
    r
  } else if n == 0L {
    let v = if r < 0.0 { r - 0.5 } else { r + 0.5 }
    v.to_int64().to_double()
  } else {
    let s = format_float(
      r,
      'f',
      n.to_int(),
      0,
      false,
      false,
      false,
      true,
      false,
      false,
      false,
    )
    text_to_numeric_lenient(s).as_double()
  }
}
