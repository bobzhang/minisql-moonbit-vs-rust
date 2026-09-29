// SQLite-compatible printf() and floating-point digit generation.

///|
/// Decimal digits of a double (SQLite's FpDecode).
priv struct FpDecode {
  neg : Bool
  special : Int // 0 normal, 1 infinity, 2 NaN
  digits : Array[Int] // significant digits, no trailing zeros
  idp : Int // position of the decimal point
}

///|
fn hi_part(x : Double) -> Double {
  (x.reinterpret_as_uint64() & 0xfffffffffc000000UL).reinterpret_as_double()
}

///|
/// Dekker double-double multiply of (x0, x1) by (y, yy).
fn dekker_mul2(x : FixedArray[Double], y : Double, yy : Double) -> Unit {
  let hx = hi_part(x[0])
  let tx = x[0] - hx
  let hy = hi_part(y)
  let ty = y - hy
  let p = hx * hy
  let q1 = hx * ty
  let q2 = tx * hy
  let q = q1 + q2
  let c = p + q
  let t1 = p - c
  let t2 = t1 + q
  let t3 = tx * ty
  let mut cc = t2 + t3
  let u1 = x[0] * yy
  let u2 = x[1] * y
  cc = u1 + u2 + cc
  x[0] = c + cc
  let d = c - x[0]
  x[1] = d + cc
}

///|
fn fp_decode(r0 : Double, iround0 : Int, mxround : Int) -> FpDecode {
  let mut r = r0
  let mut neg = false
  if r < 0.0 {
    neg = true
    r = -r
  } else if r == 0.0 {
    return { neg: false, special: 0, digits: [0], idp: 1, }
  }
  if r.is_nan() {
    return { neg, special: 2, digits: [], idp: 0, }
  }
  if r.is_inf() {
    return { neg, special: 1, digits: [], idp: 0, }
  }
  let rr : FixedArray[Double] = [r, 0.0]
  let mut exp = 0
  if rr[0] > 9.223372036854774784e+18 {
    while rr[0] > 9.223372036854774784e+118 {
      exp += 100
      dekker_mul2(rr, 1.0e-100, -1.99918998026028836196e-117)
    }
    while rr[0] > 9.223372036854774784e+28 {
      exp += 10
      dekker_mul2(rr, 1.0e-10, -3.6432197315497741579e-27)
    }
    while rr[0] > 9.223372036854774784e+18 {
      exp += 1
      dekker_mul2(rr, 1.0e-01, -5.5511151231257827021e-18)
    }
  } else {
    while rr[0] < 9.223372036854774784e-83 {
      exp -= 100
      dekker_mul2(rr, 1.0e+100, -1.5902891109759918046e+83)
    }
    while rr[0] < 9.223372036854774784e+07 {
      exp -= 10
      dekker_mul2(rr, 1.0e+10, 0.0)
    }
    while rr[0] < 9.22337203685477478e+17 {
      exp -= 1
      dekker_mul2(rr, 1.0e+01, 0.0)
    }
  }
  let hi = rr[0].to_uint64()
  let v = if rr[1] < 0.0 {
    hi - (-rr[1]).to_uint64()
  } else {
    hi + rr[1].to_uint64()
  }
  // digits, most significant first; slot 0 is spare for a carry
  let rev : Array[Int] = []
  let mut w = v
  while w > 0UL {
    rev.push((w % 10UL).to_int())
    w = w / 10UL
  }
  let z : Array[Int] = [0]
  for k = rev.length() - 1; k >= 0; k = k - 1 {
    z.push(rev[k])
  }
  let mut start = 1 // index of first digit in z
  let mut n = rev.length()
  let mut idp = n + exp
  let mut iround = iround0
  if iround <= 0 {
    iround = idp - iround
    if iround == 0 && z[start] >= 5 {
      iround = 1
      start -= 1
      z[start] = 0
      n += 1
      idp += 1
    }
  }
  if iround > 0 && (iround < n || n > mxround) {
    if iround > mxround {
      iround = mxround
    }
    n = iround
    if z[start + iround] >= 5 {
      let mut j = iround - 1
      while true {
        z[start + j] += 1
        if z[start + j] <= 9 {
          break
        }
        z[start + j] = 0
        if j == 0 {
          // carry out of the first digit
          if start == 0 {
            z.insert(0, 1)
          } else {
            start -= 1
            z[start] = 1
          }
          n += 1
          idp += 1
          break
        }
        j -= 1
      }
    }
  }
  let digits : Array[Int] = []
  for k in 0..<n {
    digits.push(z[start + k])
  }
  while digits.length() > 1 && digits[digits.length() - 1] == 0 {
    ignore(digits.pop())
  }
  { neg, special: 0, digits, idp, }
}

///|
priv struct Spec {
  mut left : Bool
  mut prefix : Char? // '+' or ' '
  mut alt : Bool // '#'
  mut alt2 : Bool // '!'
  mut zeropad : Bool
  mut thousands : Bool
  mut width : Int
  mut precision : Int // -1: none
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
/// Longest prefix of `s` whose UTF-8 encoding fits in `nbytes` bytes.
fn utf8_prefix(s : String, nbytes : Int) -> String {
  let sb = StringBuilder()
  let mut used = 0
  for c in s {
    let l = utf8_len(c.to_string())
    if used + l > nbytes {
      break
    }
    used += l
    sb.write_char(c)
  }
  sb.to_string()
}

///|
fn char_prefix(s : String, nchars : Int) -> String {
  let sb = StringBuilder()
  let mut k = 0
  for c in s {
    if k >= nchars {
      break
    }
    sb.write_char(c)
    k += 1
  }
  sb.to_string()
}

///|
/// Format a double for %f %e %E %g %G.
fn format_float(value : Double, conv : Char, sp : Spec) -> String {
  let mut precision = if sp.precision < 0 { 6 } else { sp.precision }
  let is_g = conv == 'g' || conv == 'G'
  let upper = conv == 'E' || conv == 'G'
  let iround = if conv == 'f' {
    -precision
  } else if is_g {
    if precision == 0 {
      precision = 1
    }
    precision
  } else {
    precision + 1
  }
  let mut s = fp_decode(value, iround, if sp.alt2 { 26 } else { 16 })
  if s.special == 2 {
    return if sp.zeropad { "null" } else { "NaN" }
  }
  if s.special == 1 {
    if sp.zeropad {
      s = { neg: s.neg, special: 0, digits: [9], idp: 1000, }
    } else if s.neg {
      return "-Inf"
    } else {
      return match sp.prefix {
        Some(p) => p.to_string() + "Inf"
        None => "Inf"
      }
    }
  }
  let prefix : Char? = if s.neg { Some('-') } else { sp.prefix }
  let mut exp = s.idp - 1
  if is_g && precision > 0 {
    precision -= 1
  }
  let mut xexp = conv == 'e' || conv == 'E'
  let rtz = if is_g {
    if exp < -4 || exp > precision {
      xexp = true
    } else {
      precision = precision - exp
    }
    !sp.alt
  } else {
    sp.alt2
  }
  let mut e2 = if xexp { 0 } else { s.idp - 1 }
  let buf = StringBuilder()
  let flag_dp = precision > 0 || sp.alt || sp.alt2
  if prefix is Some(p) {
    buf.write_char(p)
  }
  let digits = s.digits
  let mut j = 0
  fn next_digit() -> Char {
    if j < digits.length() {
      let d = digits[j]
      j += 1
      (d + '0'.to_int()).unsafe_to_char()
    } else {
      '0'
    }
  }

  if e2 < 0 {
    buf.write_char('0')
  } else {
    while e2 >= 0 {
      buf.write_char(next_digit())
      if sp.thousands && e2 % 3 == 0 && e2 > 1 {
        buf.write_char(',')
      }
      e2 -= 1
    }
  }
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
    buf.write_char(next_digit())
    precision -= 1
  }
  let mut out = buf.to_string()
  if rtz && flag_dp {
    let mut end = out.length()
    while end > 0 && out[end - 1] == '0' {
      end -= 1
    }
    if end > 0 && out[end - 1] == '.' {
      if sp.alt2 {
        out = out[:end].to_owned() + "0"
      } else {
        out = out[:end - 1].to_owned()
      }
    } else {
      out = out[:end].to_owned()
    }
  }
  if xexp {
    exp = s.idp - 1
    let eb = StringBuilder()
    eb.write_string(out)
    eb.write_char(if upper { 'E' } else { 'e' })
    if exp < 0 {
      eb.write_char('-')
      exp = -exp
    } else {
      eb.write_char('+')
    }
    if exp >= 100 {
      eb.write_string((exp / 100).to_string())
      exp = exp % 100
    }
    eb.write_string((exp / 10).to_string())
    eb.write_string((exp % 10).to_string())
    out = eb.to_string()
  }
  if sp.zeropad && !sp.left && out.length() < sp.width {
    let npad = sp.width - out.length()
    let k = if prefix is Some(_) { 1 } else { 0 }
    out = out[:k].to_owned() + String::make(npad, '0') + out[k:].to_owned()
  }
  out
}

///|
/// Integer conversions %d %i %u %x %X %o.
fn format_int(v : Int64, conv : Char, sp : Spec) -> String {
  let signed = conv == 'd' || conv == 'i'
  let mut prefix : Char? = None
  let mut lv : UInt64 = v.reinterpret_as_uint64()
  if signed {
    if v < 0L {
      lv = 0UL - v.reinterpret_as_uint64()
      prefix = Some('-')
    } else {
      prefix = sp.prefix
    }
  }
  let mut alt = sp.alt
  if lv == 0UL {
    alt = false
  }
  let mut precision = sp.precision
  let plen = if prefix is Some(_) { 1 } else { 0 }
  if sp.zeropad && precision < sp.width - plen {
    precision = sp.width - plen
  }
  let base : UInt64 = match conv {
    'x' | 'X' => 16UL
    'o' => 8UL
    _ => 10UL
  }
  let cset = if conv == 'X' { "0123456789ABCDEF" } else { "0123456789abcdef" }
  let rev : Array[Char] = []
  while true {
    rev.push(cset.get_char((lv % base).to_int()).unwrap())
    lv = lv / base
    if lv == 0UL {
      break
    }
  }
  while precision > rev.length() {
    rev.push('0')
  }
  let mut digits = String::from_array(rev.rev())
  if sp.thousands && base == 10UL {
    let sb = StringBuilder()
    let n = digits.length()
    for i in 0..<n {
      if i > 0 && (n - i) % 3 == 0 {
        sb.write_char(',')
      }
      sb.write_char(digits.get_char(i).unwrap())
    }
    digits = sb.to_string()
  }
  let sb = StringBuilder()
  if alt {
    match conv {
      'x' => sb.write_string("0x")
      'X' => sb.write_string("0X")
      'o' => sb.write_string("0")
      _ => ()
    }
  }
  if prefix is Some(p) {
    sb.write_char(p)
  }
  sb.write_string(digits)
  sb.to_string()
}

///|
/// SQL printf(): format a string with SQL values as arguments.
fn sql_printf(fmt : String, args : ArrayView[Value]) -> String {
  let f = fmt.to_array()
  let n = f.length()
  let out = StringBuilder()
  let mut ai = 0
  fn next_arg() -> Value {
    if ai < args.length() {
      let v = args[ai]
      ai += 1
      v
    } else {
      Null
    }
  }

  let mut i = 0
  while i < n {
    let c0 = f[i]
    if c0 != '%' {
      out.write_char(c0)
      i += 1
      continue
    }
    i += 1
    if i >= n {
      out.write_char('%')
      break
    }
    let sp : Spec = {
      left: false,
      prefix: None,
      alt: false,
      alt2: false,
      zeropad: false,
      thousands: false,
      width: 0,
      precision: -1,
    }
    // flags, width, precision
    let mut c = f[i]
    let mut done = false
    while !done {
      match c {
        '-' => sp.left = true
        '+' => sp.prefix = Some('+')
        ' ' => sp.prefix = Some(' ')
        '#' => sp.alt = true
        '!' => sp.alt2 = true
        '0' => sp.zeropad = true
        ',' => sp.thousands = true
        'l' => {
          i += 1
          c = if i < n { f[i] } else { '\u{0}' }
          if c == 'l' {
            i += 1
            c = if i < n { f[i] } else { '\u{0}' }
          }
          done = true
        }
        '1'..='9' => {
          let mut wx = c.to_int() - '0'.to_int()
          i += 1
          c = if i < n { f[i] } else { '\u{0}' }
          while c >= '0' && c <= '9' {
            wx = (wx * 10 + (c.to_int() - '0'.to_int())) & 0x7fffffff
            i += 1
            c = if i < n { f[i] } else { '\u{0}' }
          }
          sp.width = wx
          if c != '.' && c != 'l' {
            done = true
          } else {
            i -= 1
          }
        }
        '*' => {
          let w = next_arg().to_int64()
          let mut wi = if w > 2147483647L {
            2147483647
          } else if w < -2147483647L {
            -2147483648
          } else {
            w.to_int()
          }
          if wi < 0 {
            sp.left = true
            wi = if wi >= -2147483647 { -wi } else { 0 }
          }
          sp.width = wi
          let nc = if i + 1 < n { f[i + 1] } else { '\u{0}' }
          if nc != '.' && nc != 'l' {
            i += 1
            c = if i < n { f[i] } else { '\u{0}' }
            done = true
          }
        }
        '.' => {
          i += 1
          c = if i < n { f[i] } else { '\u{0}' }
          if c == '*' {
            let pv = next_arg().to_int64()
            let mut p = if pv > 2147483647L {
              2147483647
            } else if pv < -2147483647L {
              -2147483648
            } else {
              pv.to_int()
            }
            if p < 0 {
              p = if p >= -2147483647 { -p } else { -1 }
            }
            sp.precision = p
            i += 1
            c = if i < n { f[i] } else { '\u{0}' }
          } else {
            let mut px = 0
            while c >= '0' && c <= '9' {
              px = (px * 10 + (c.to_int() - '0'.to_int())) & 0x7fffffff
              i += 1
              c = if i < n { f[i] } else { '\u{0}' }
            }
            sp.precision = px
          }
          if c == 'l' {
            i -= 1
          } else {
            done = true
          }
        }
        _ => done = true
      }
      if !done {
        i += 1
        if i >= n {
          c = '\u{0}'
          break
        }
        c = f[i]
      }
    }
    if c == '\u{0}' {
      break
    }
    i += 1 // past the conversion character
    let mut width = sp.width
    let mut count_chars = sp.alt2
    let body = match c {
      'd' | 'i' | 'u' | 'x' | 'X' | 'o' | 'p' => {
        let conv = if c == 'p' { 'X' } else { c }
        format_int(next_arg().to_int64(), conv, sp)
      }
      'f' | 'e' | 'E' | 'g' | 'G' => format_float(next_arg().to_double(), c, sp)
      's' | 'z' => {
        let t = next_arg().to_text().unwrap_or("")
        if sp.precision >= 0 {
          if sp.alt2 {
            char_prefix(t, sp.precision)
          } else {
            utf8_prefix(t, sp.precision)
          }
        } else {
          t
        }
      }
      'c' => {
        count_chars = true
        let t = next_arg().to_text().unwrap_or("")
        let ch = char_prefix(t, 1)
        if sp.precision > 1 {
          ch.repeat(sp.precision)
        } else {
          ch
        }
      }
      'q' | 'Q' | 'w' => {
        let q = if c == 'w' { '"' } else { '\'' }
        let arg = next_arg().to_text()
        let isnull = arg is None
        let src = match arg {
          Some(t) => t
          None => if c == 'Q' { "NULL" } else { "(NULL)" }
        }
        let src = if sp.precision >= 0 {
          if sp.alt2 {
            char_prefix(src, sp.precision)
          } else {
            utf8_prefix(src, sp.precision)
          }
        } else {
          src
        }
        let sb = StringBuilder()
        let need_quote = !isnull && c == 'Q'
        if need_quote {
          sb.write_char(q)
        }
        for ch in src {
          sb.write_char(ch)
          if ch == q {
            sb.write_char(q)
          }
        }
        if need_quote {
          sb.write_char(q)
        }
        sb.to_string()
      }
      '%' => "%"
      'n' => ""
      _ => break
    }
    let len = if count_chars { body.char_length() } else { utf8_len(body) }
    width -= len
    if width > 0 {
      if !sp.left {
        out.write_string(String::make(width, ' '))
      }
      out.write_string(body)
      if sp.left {
        out.write_string(String::make(width, ' '))
      }
    } else {
      out.write_string(body)
    }
  }
  out.to_string()
}
