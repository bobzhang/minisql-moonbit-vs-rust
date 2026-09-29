// Date and time functions (a port of SQLite's date.c semantics).

///|
priv struct DateTime {
  mut ijd : Int64 // Julian day number times 86400000
  mut y : Int
  mut mo : Int
  mut d : Int
  mut h : Int
  mut mi : Int
  mut tz : Int // minutes
  mut s : Double
  mut valid_jd : Bool
  mut valid_ymd : Bool
  mut valid_hms : Bool
  mut valid_tz : Bool
  mut raw_s : Bool
  mut is_error : Bool
  mut use_subsec : Bool
  mut n_floor : Int
}

///|
fn new_datetime() -> DateTime {
  {
    ijd: 0L,
    y: 0,
    mo: 0,
    d: 0,
    h: 0,
    mi: 0,
    tz: 0,
    s: 0.0,
    valid_jd: false,
    valid_ymd: false,
    valid_hms: false,
    valid_tz: false,
    raw_s: false,
    is_error: false,
    use_subsec: false,
    n_floor: 0,
  }
}

///|
fn DateTime::copy(self : DateTime) -> DateTime {
  { ..self, }
}

///|
/// Code unit at i, or 0 past the end.
fn cu_at(z : String, i : Int) -> Int {
  if i < z.length() {
    z[i].to_int()
  } else {
    0
  }
}

///|
fn is_digit_i(c : Int) -> Bool {
  c >= '0'.to_int() && c <= '9'.to_int()
}

///|
fn is_space_i(c : Int) -> Bool {
  c == ' '.to_int() ||
  c == '\t'.to_int() ||
  c == '\n'.to_int() ||
  c == '\r'.to_int() ||
  c == 0x0b ||
  c == 0x0c
}

///|
/// Parse fixed-width digit fields: each (ndigits, min, max, next separator;
/// 0 = none). Returns the parsed values (fewer than requested on failure).
fn get_digits(
  z : String,
  start : Int,
  fields : Array[(Int, Int, Int, Int)],
) -> Array[Int] {
  let out : Array[Int] = []
  let mut i = start
  for f in fields {
    let (n, lo, hi, next) = f
    let mut v = 0
    for _ in 0..<n {
      let c = cu_at(z, i)
      if !is_digit_i(c) {
        return out
      }
      v = v * 10 + (c - '0'.to_int())
      i += 1
    }
    if v < lo || v > hi {
      return out
    }
    if next != 0 && cu_at(z, i) != next {
      out.push(v)
      return out
    }
    out.push(v)
    i += 1
  }
  out
}

///|
let colon : Int = ':'.to_int()

///|
let dash : Int = '-'.to_int()

///|
/// Parse an optional timezone suffix at z[i..]; true on error.
fn parse_timezone(z : String, i0 : Int, p : DateTime) -> Bool {
  let mut i = i0
  while is_space_i(cu_at(z, i)) {
    i += 1
  }
  p.tz = 0
  let c = cu_at(z, i)
  let mut sgn = 0
  if c == '-'.to_int() {
    sgn = -1
  } else if c == '+'.to_int() {
    sgn = 1
  } else if c == 'Z'.to_int() || c == 'z'.to_int() {
    i += 1
    while is_space_i(cu_at(z, i)) {
      i += 1
    }
    return i < z.length()
  } else {
    return c != 0
  }
  i += 1
  let v = get_digits(z, i, [(2, 0, 14, colon), (2, 0, 59, 0)])
  if v.length() != 2 {
    return true
  }
  i += 5
  p.tz = sgn * (v[1] + v[0] * 60)
  while is_space_i(cu_at(z, i)) {
    i += 1
  }
  i < z.length()
}

///|
/// Parse HH:MM[:SS[.FFF]] [tz] at z[i..]; true on error.
fn parse_hms(z : String, i0 : Int, p : DateTime) -> Bool {
  let v = get_digits(z, i0, [(2, 0, 24, colon), (2, 0, 59, 0)])
  if v.length() != 2 {
    return true
  }
  let mut i = i0 + 5
  let mut s = 0
  let mut ms = 0.0
  if cu_at(z, i) == colon {
    i += 1
    let sv = get_digits(z, i, [(2, 0, 59, 0)])
    if sv.length() != 1 {
      return true
    }
    s = sv[0]
    i += 2
    if cu_at(z, i) == '.'.to_int() && is_digit_i(cu_at(z, i + 1)) {
      let mut scale = 1.0
      i += 1
      while is_digit_i(cu_at(z, i)) {
        ms = ms * 10.0 + (cu_at(z, i) - '0'.to_int()).to_double()
        scale *= 10.0
        i += 1
      }
      ms /= scale
      if ms > 0.999 {
        ms = 0.999
      }
    }
  }
  p.valid_jd = false
  p.raw_s = false
  p.valid_hms = true
  p.h = v[0]
  p.mi = v[1]
  p.s = s.to_double() + ms
  if parse_timezone(z, i, p) {
    return true
  }
  p.valid_tz = p.tz != 0
  false
}

///|
fn DateTime::compute_floor(self : DateTime) -> Unit {
  let p = self
  if p.d <= 28 {
    p.n_floor = 0
  } else if ((1 << p.mo) & 0x15aa) != 0 {
    p.n_floor = 0
  } else if p.mo != 2 {
    p.n_floor = if p.d == 31 { 1 } else { 0 }
  } else if p.y % 4 != 0 || (p.y % 100 == 0 && p.y % 400 != 0) {
    p.n_floor = p.d - 28
  } else {
    p.n_floor = p.d - 29
  }
}

///|
fn DateTime::compute_jd(self : DateTime) -> Unit {
  let p = self
  if p.valid_jd {
    return
  }
  let (y0, m0, d) = if p.valid_ymd { (p.y, p.mo, p.d) } else { (2000, 1, 1) }
  let mut y = y0
  let mut m = m0
  if y < -4713 || y > 9999 || p.raw_s {
    p.is_error = true
    return
  }
  if m <= 2 {
    y -= 1
    m += 12
  }
  let a = (y + 4800) / 100
  let b = 38 - a + a / 4
  let x1 = 36525 * (y + 4716) / 100
  let x2 = 306001 * (m + 1) / 10000
  p.ijd = (((x1 + x2 + d + b).to_double() - 1524.5) * 86400000.0).to_int64()
  p.valid_jd = true
  if p.valid_hms {
    p.ijd += (p.h * 3600000 + p.mi * 60000).to_int64() +
      (p.s * 1000.0 + 0.5).to_int64()
    if p.valid_tz {
      p.ijd -= p.tz.to_int64() * 60000L
      p.valid_ymd = false
      p.valid_hms = false
      p.valid_tz = false
    }
  }
}

///|
/// Parse YYYY-MM-DD [time]; true on error.
fn parse_ymd(z : String, p : DateTime) -> Bool {
  let mut i = 0
  let neg = cu_at(z, 0) == dash
  if neg {
    i = 1
  }
  let v = get_digits(z, i, [(4, 0, 9999, dash), (2, 1, 12, dash), (2, 1, 31, 0)])
  if v.length() != 3 {
    return true
  }
  i += 10
  while is_space_i(cu_at(z, i)) || cu_at(z, i) == 'T'.to_int() {
    i += 1
  }
  if !parse_hms(z, i, p) {
    ()
  } else if i >= z.length() {
    p.valid_hms = false
  } else {
    return true
  }
  p.valid_jd = false
  p.valid_ymd = true
  p.y = if neg { -v[0] } else { v[0] }
  p.mo = v[1]
  p.d = v[2]
  p.compute_floor()
  if p.valid_tz {
    p.compute_jd()
  }
  false
}

///|
fn DateTime::set_raw_number(self : DateTime, r : Double) -> Unit {
  self.s = r
  self.raw_s = true
  if r >= 0.0 && r < 5373484.5 {
    self.ijd = (r * 86400000.0 + 0.5).to_int64()
    self.valid_jd = true
  }
}

///|
/// A whole string that is a valid number (like sqlite3AtoF() > 0).
fn text_as_number(s : String) -> Double? {
  let r = scan_number(s)
  if r.has_num && r.whole {
    Some(r.rval)
  } else {
    None
  }
}

///|
fn parse_date_or_time(z : String, p : DateTime) -> Bool {
  if !parse_ymd(z, p) {
    return false
  }
  if !parse_hms(z, 0, p) {
    return false
  }
  match text_as_number(z) {
    Some(r) => {
      p.set_raw_number(r)
      false
    }
    None => true
  }
}

///|
fn valid_julian_day(ijd : Int64) -> Bool {
  ijd >= 0L && ijd <= 464269060799999L
}

///|
fn DateTime::compute_ymd(self : DateTime) -> Unit {
  let p = self
  if p.valid_ymd {
    return
  }
  if !p.valid_jd {
    p.y = 2000
    p.mo = 1
    p.d = 1
  } else if !valid_julian_day(p.ijd) {
    p.is_error = true
    return
  } else {
    let z = ((p.ijd + 43200000L) / 86400000L).to_int()
    let alpha = ((z.to_double() + 32044.75) / 36524.25).to_int() - 52
    let a = z + 1 + alpha - (alpha + 100) / 4 + 25
    let b = a + 1524
    let c = ((b.to_double() - 122.1) / 365.25).to_int()
    let d = 36525 * (c & 32767) / 100
    let e = ((b - d).to_double() / 30.6001).to_int()
    let x1 = (30.6001 * e.to_double()).to_int()
    p.d = b - d - x1
    p.mo = if e < 14 { e - 1 } else { e - 13 }
    p.y = if p.mo > 2 { c - 4716 } else { c - 4715 }
  }
  p.valid_ymd = true
}

///|
fn DateTime::compute_hms(self : DateTime) -> Unit {
  let p = self
  if p.valid_hms {
    return
  }
  p.compute_jd()
  let day_ms = ((p.ijd + 43200000L) % 86400000L).to_int()
  p.s = (day_ms % 60000).to_double() / 1000.0
  let day_min = day_ms / 60000
  p.mi = day_min % 60
  p.h = day_min / 60
  p.raw_s = false
  p.valid_hms = true
}

///|
fn DateTime::compute_ymd_hms(self : DateTime) -> Unit {
  self.compute_ymd()
  self.compute_hms()
}

///|
fn DateTime::clear_ymd_hms_tz(self : DateTime) -> Unit {
  self.valid_ymd = false
  self.valid_hms = false
  self.valid_tz = false
}

///|
fn DateTime::normalize_month(self : DateTime) -> Unit {
  let x = if self.mo > 0 { (self.mo - 1) / 12 } else { (self.mo - 12) / 12 }
  self.y += x
  self.mo -= x * 12
}

///|
let xform_types : Array[(String, Double, Double)] = [
  ("second", 4.6427e+14, 1.0),
  ("minute", 7.7379e+12, 60.0),
  ("hour", 1.2897e+11, 3600.0),
  ("day", 5373485.0, 86400.0),
  ("month", 176546.0, 2592000.0),
  ("year", 14713.0, 31536000.0),
]

///|
/// Apply one modifier; true on error.
fn parse_modifier(z0 : String, p : DateTime, idx : Int) -> Bool {
  let z = z0
  let lz = z.to_lower()
  let first = if z.length() > 0 { ascii_lower_cu(z[0].to_int()) } else { 0 }
  match first.unsafe_to_char() {
    'a' => {
      if lz == "auto" {
        if idx > 1 {
          return true
        }
        if !p.raw_s || p.valid_jd {
          p.raw_s = false
          return false
        } else if p.s >= -210866760000.0 && p.s <= 253402300799.0 {
          let r = p.s * 1000.0 + 210866760000000.0
          p.clear_ymd_hms_tz()
          p.ijd = (r + 0.5).to_int64()
          p.valid_jd = true
          p.raw_s = false
          return false
        }
      }
      true
    }
    'j' => {
      if lz == "julianday" {
        if idx > 1 {
          return true
        }
        if p.valid_jd && p.raw_s {
          p.raw_s = false
          return false
        }
      }
      true
    }
    'u' => {
      if lz == "unixepoch" && p.raw_s {
        if idx > 1 {
          return true
        }
        let r = p.s * 1000.0 + 210866760000000.0
        if r >= 0.0 && r < 464269060800000.0 {
          p.clear_ymd_hms_tz()
          p.ijd = (r + 0.5).to_int64()
          p.valid_jd = true
          p.raw_s = false
          return false
        }
      }
      true
    }
    'w' => {
      if lz.has_prefix("weekday ") {
        match text_as_number(z[8:].to_owned()) {
          Some(r) if r >= 0.0 && r < 7.0 && r.to_int().to_double() == r => {
            let n = r.to_int().to_int64()
            p.compute_ymd_hms()
            p.valid_tz = false
            p.valid_jd = false
            p.compute_jd()
            let mut zz = (p.ijd + 129600000L) / 86400000L % 7L
            if zz > n {
              zz -= 7L
            }
            p.ijd += (n - zz) * 86400000L
            p.clear_ymd_hms_tz()
            return false
          }
          _ => ()
        }
      }
      true
    }
    's' => {
      if !lz.has_prefix("start of ") {
        if lz == "subsec" || lz == "subsecond" {
          p.use_subsec = true
          return false
        }
        return true
      }
      if !p.valid_jd && !p.valid_ymd && !p.valid_hms {
        return true
      }
      let rest = lz[9:]
      p.compute_ymd()
      p.valid_hms = true
      p.h = 0
      p.mi = 0
      p.s = 0.0
      p.raw_s = false
      p.valid_tz = false
      p.valid_jd = false
      if rest == "month" {
        p.d = 1
        false
      } else if rest == "year" {
        p.mo = 1
        p.d = 1
        false
      } else {
        rest != "day"
      }
    }
    'c' => {
      if lz == "ceiling" {
        p.compute_jd()
        p.clear_ymd_hms_tz()
        p.n_floor = 0
        return false
      }
      true
    }
    'f' => {
      if lz == "floor" {
        p.compute_jd()
        p.ijd -= p.n_floor.to_int64() * 86400000L
        p.clear_ymd_hms_tz()
        return false
      }
      true
    }
    '+' | '-' | '0'..='9' => parse_numeric_modifier(z, p)
    _ => true
  }
}

///|
fn parse_numeric_modifier(z0 : String, p : DateTime) -> Bool {
  let mut z = z0
  let c0 = cu_at(z, 0)
  let mut n = 1
  while n < z.length() {
    let c = cu_at(z, n)
    if c == colon || is_space_i(c) {
      break
    }
    if c == dash {
      if n == 5 && get_digits(z, 1, [(4, 0, 9999, 0)]).length() == 1 {
        break
      }
      if n == 6 && get_digits(z, 1, [(5, 0, 14712, 0)]).length() == 1 {
        break
      }
    }
    n += 1
  }
  guard text_as_number(z[:n].to_owned()) is Some(r0) else { return true }
  let mut r = r0
  let mut z2 = z
  if cu_at(z, n) == dash {
    // (+|-)YYYY-MM-DD [HH:MM[:SS]]
    if c0 != '+'.to_int() && c0 != '-'.to_int() {
      return true
    }
    let v = if n == 5 {
      get_digits(z, 1, [(4, 0, 9999, dash), (2, 0, 11, dash), (2, 0, 30, 0)])
    } else {
      z = z[1:].to_owned()
      get_digits(z, 1, [(5, 0, 14712, dash), (2, 0, 11, dash), (2, 0, 30, 0)])
    }
    if v.length() != 3 {
      return true
    }
    let (yy, mm, dd0) = (v[0], v[1], v[2])
    p.compute_ymd_hms()
    p.valid_jd = false
    let mut dd = dd0
    if c0 == dash {
      p.y -= yy
      p.mo -= mm
      dd = -dd
    } else {
      p.y += yy
      p.mo += mm
    }
    p.normalize_month()
    p.compute_floor()
    p.compute_jd()
    p.valid_hms = false
    p.valid_ymd = false
    p.ijd += dd.to_int64() * 86400000L
    if z.length() <= 11 {
      return false
    }
    if is_space_i(cu_at(z, 11)) &&
      get_digits(z, 12, [(2, 0, 24, colon), (2, 0, 59, 0)]).length() == 2 {
      z2 = z[12:].to_owned()
      n = 2
    } else {
      return true
    }
  }
  if cu_at(z2, n) == colon {
    // (+|-)HH:MM[:SS[.FFF]]
    let start = if is_digit_i(cu_at(z2, 0)) { 0 } else { 1 }
    let tx = new_datetime()
    if parse_hms(z2, start, tx) {
      return true
    }
    tx.compute_jd()
    tx.ijd -= 43200000L
    let day = tx.ijd / 86400000L
    tx.ijd -= day * 86400000L
    if c0 == dash {
      tx.ijd = -tx.ijd
    }
    p.compute_jd()
    p.clear_ymd_hms_tz()
    p.ijd += tx.ijd
    return false
  }
  // "+NNN units"
  let mut i = n
  while is_space_i(cu_at(z2, i)) {
    i += 1
  }
  let unit0 = z2[i:].to_owned().to_lower()
  let mut len = unit0.length()
  if len < 3 || len > 10 {
    return true
  }
  if unit0[len - 1] == 's' {
    len -= 1
  }
  let unit = unit0[:len].to_owned()
  p.compute_jd()
  let rounder = if r < 0.0 { -0.5 } else { 0.5 }
  p.n_floor = 0
  let mut rc = true
  for k, xf in xform_types {
    let (name, limit, xform) = xf
    if name == unit && r > -limit && r < limit {
      if k == 4 {
        p.compute_ymd_hms()
        p.mo += r.to_int()
        p.normalize_month()
        p.compute_floor()
        p.valid_jd = false
        r -= r.to_int().to_double()
      } else if k == 5 {
        p.compute_ymd_hms()
        p.y += r.to_int()
        p.compute_floor()
        p.valid_jd = false
        r -= r.to_int().to_double()
      }
      p.compute_jd()
      p.ijd += (r * 1000.0 * xform + rounder).to_int64()
      rc = false
      break
    }
  }
  p.clear_ymd_hms_tz()
  rc
}

///|
/// Build a DateTime from a time value and modifiers; None on any error.
fn is_date(args : ArrayView[Value]) -> DateTime? {
  let p = new_datetime()
  if args.length() == 0 {
    return None
  }
  match args[0] {
    Int(_) | Real(_) => p.set_raw_number(args[0].to_double())
    Null => return None
    v => {
      guard v.to_text() is Some(z) else { return None }
      if parse_date_or_time(z, p) {
        return None
      }
    }
  }
  for i in 1..<args.length() {
    guard args[i].to_text() is Some(z) else { return None }
    if parse_modifier(z, p, i) {
      return None
    }
  }
  p.compute_jd()
  if p.is_error || !valid_julian_day(p.ijd) {
    return None
  }
  if args.length() == 1 && p.valid_ymd && p.d > 28 {
    p.valid_ymd = false
  }
  Some(p)
}

///|
/// Like C's "%0*d": the width includes the sign.
fn pad_int(v : Int, width : Int) -> String {
  let s = v.abs().to_string()
  let w = if v < 0 { width - 1 } else { width }
  let body = if s.length() < w {
    String::make(w - s.length(), '0') + s
  } else {
    s
  }
  if v < 0 {
    "-" + body
  } else {
    body
  }
}

///|
fn space_pad(v : Int) -> String {
  if v < 10 && v >= 0 {
    " " + v.to_string()
  } else {
    v.to_string()
  }
}

///|
fn date_part(p : DateTime) -> String {
  let ys = pad_int(p.y.abs(), 4)
  (if p.y < 0 { "-" } else { "" }) +
  ys +
  "-" +
  pad_int(p.mo, 2) +
  "-" +
  pad_int(p.d, 2)
}

///|
fn time_part(p : DateTime) -> String {
  let base = pad_int(p.h, 2) + ":" + pad_int(p.mi, 2) + ":"
  if p.use_subsec {
    let ms = (1000.0 * p.s).to_int()
    base + pad_int(ms / 1000, 2) + "." + pad_int(ms % 1000, 3)
  } else {
    base + pad_int(p.s.to_int(), 2)
  }
}

///|
fn unix_ms(p : DateTime) -> Int64 {
  p.ijd - 210866760000000L
}

///|
fn days_after_jan01(p : DateTime) -> Int {
  let j = p.copy()
  j.valid_jd = false
  j.mo = 1
  j.d = 1
  j.compute_jd()
  ((p.ijd - j.ijd + 43200000L) / 86400000L).to_int()
}

///|
fn days_after_monday(p : DateTime) -> Int {
  ((p.ijd + 43200000L) / 86400000L % 7L).to_int()
}

///|
fn days_after_sunday(p : DateTime) -> Int {
  ((p.ijd + 129600000L) / 86400000L % 7L).to_int()
}

///|
fn thursday_of_week(p : DateTime) -> DateTime {
  let y = p.copy()
  y.ijd += (3 - days_after_monday(p)).to_int64() * 86400000L
  y.valid_ymd = false
  y.compute_ymd()
  y
}

///|
fn strftime_value(fmt : String, p : DateTime) -> Value {
  p.compute_jd()
  p.compute_ymd_hms()
  let sb = StringBuilder()
  let chars = fmt.to_array()
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if c != '%' {
      sb.write_char(c)
      i += 1
      continue
    }
    i += 1
    if i >= chars.length() {
      return Null
    }
    let cf = chars[i]
    i += 1
    match cf {
      'd' => sb.write_string(pad_int(p.d, 2))
      'e' => sb.write_string(space_pad(p.d))
      'f' => {
        let s = if p.s > 59.999 { 59.999 } else { p.s }
        let t = sql_printf("%06.3f", [Real(s)])
        sb.write_string(t)
      }
      'F' =>
        sb.write_string(
          pad_int(p.y, 4) + "-" + pad_int(p.mo, 2) + "-" + pad_int(p.d, 2),
        )
      'G' => sb.write_string(pad_int(thursday_of_week(p).y, 4))
      'g' => sb.write_string(pad_int(thursday_of_week(p).y % 100, 2))
      'H' => sb.write_string(pad_int(p.h, 2))
      'k' => sb.write_string(space_pad(p.h))
      'I' | 'l' => {
        let mut h = p.h
        if h > 12 {
          h -= 12
        }
        if h == 0 {
          h = 12
        }
        sb.write_string(if cf == 'I' { pad_int(h, 2) } else { space_pad(h) })
      }
      'j' => sb.write_string(pad_int(days_after_jan01(p) + 1, 3))
      'J' =>
        sb.write_string(
          sql_printf("%.16g", [Real(p.ijd.to_double() / 86400000.0)]),
        )
      'm' => sb.write_string(pad_int(p.mo, 2))
      'M' => sb.write_string(pad_int(p.mi, 2))
      'p' => sb.write_string(if p.h >= 12 { "PM" } else { "AM" })
      'P' => sb.write_string(if p.h >= 12 { "pm" } else { "am" })
      'R' => sb.write_string(pad_int(p.h, 2) + ":" + pad_int(p.mi, 2))
      's' =>
        if p.use_subsec {
          sb.write_string(
            sql_printf("%.3f", [Real(unix_ms(p).to_double() / 1000.0)]),
          )
        } else {
          sb.write_string((p.ijd / 1000L - 210866760000L).to_string())
        }
      'S' => sb.write_string(pad_int(p.s.to_int(), 2))
      'T' =>
        sb.write_string(
          pad_int(p.h, 2) +
          ":" +
          pad_int(p.mi, 2) +
          ":" +
          pad_int(p.s.to_int(), 2),
        )
      'u' => {
        let w = days_after_sunday(p)
        sb.write_string((if w == 0 { 7 } else { w }).to_string())
      }
      'w' => sb.write_string(days_after_sunday(p).to_string())
      'U' =>
        sb.write_string(
          pad_int((days_after_jan01(p) - days_after_sunday(p) + 7) / 7, 2),
        )
      'V' =>
        sb.write_string(
          pad_int(days_after_jan01(thursday_of_week(p)) / 7 + 1, 2),
        )
      'W' =>
        sb.write_string(
          pad_int((days_after_jan01(p) - days_after_monday(p) + 7) / 7, 2),
        )
      'Y' => sb.write_string(pad_int(p.y, 4))
      '%' => sb.write_char('%')
      _ => return Null
    }
  }
  Text(sb.to_string())
}

///|
fn timediff_value(a : Value, b : Value) -> Value {
  guard is_date([a][:]) is Some(d1) else { return Null }
  guard is_date([b][:]) is Some(d2) else { return Null }
  d1.compute_ymd_hms()
  d2.compute_ymd_hms()
  let mut sign = '+'
  let mut y = 0
  let mut m = 0
  if d1.ijd >= d2.ijd {
    y = d1.y - d2.y
    if y != 0 {
      d2.y = d1.y
      d2.valid_jd = false
      d2.compute_jd()
    }
    m = d1.mo - d2.mo
    if m < 0 {
      y -= 1
      m += 12
    }
    if m != 0 {
      d2.mo = d1.mo
      d2.valid_jd = false
      d2.compute_jd()
    }
    while d1.ijd < d2.ijd {
      m -= 1
      if m < 0 {
        m = 11
        y -= 1
      }
      d2.mo -= 1
      if d2.mo < 1 {
        d2.mo = 12
        d2.y -= 1
      }
      d2.valid_jd = false
      d2.compute_jd()
    }
    d1.ijd = d1.ijd - d2.ijd + 148699540800000L
  } else {
    sign = '-'
    y = d2.y - d1.y
    if y != 0 {
      d2.y = d1.y
      d2.valid_jd = false
      d2.compute_jd()
    }
    m = d2.mo - d1.mo
    if m < 0 {
      y -= 1
      m += 12
    }
    if m != 0 {
      d2.mo = d1.mo
      d2.valid_jd = false
      d2.compute_jd()
    }
    while d1.ijd > d2.ijd {
      m -= 1
      if m < 0 {
        m = 11
        y -= 1
      }
      d2.mo += 1
      if d2.mo > 12 {
        d2.mo = 1
        d2.y += 1
      }
      d2.valid_jd = false
      d2.compute_jd()
    }
    d1.ijd = d2.ijd - d1.ijd + 148699540800000L
  }
  d1.clear_ymd_hms_tz()
  d1.compute_ymd_hms()
  Text(
    sign.to_string() +
    pad_int(y, 4) +
    "-" +
    pad_int(m, 2) +
    "-" +
    pad_int(d1.d - 1, 2) +
    " " +
    pad_int(d1.h, 2) +
    ":" +
    pad_int(d1.mi, 2) +
    ":" +
    sql_printf("%06.3f", [Real(d1.s)]),
  )
}

///|
/// Evaluate a date/time function; None if `name` is not one.
fn datetime_function(name : String, v : Array[Value]) -> Value? {
  let r = match name {
    "DATE" | "TIME" | "DATETIME" | "JULIANDAY" | "UNIXEPOCH" => {
      guard is_date(v[:]) is Some(p) else { return Some(Null) }
      match name {
        "DATE" => {
          p.compute_ymd()
          Text(date_part(p))
        }
        "TIME" => {
          p.compute_hms()
          Text(time_part(p))
        }
        "DATETIME" => {
          p.compute_ymd_hms()
          Text(date_part(p) + " " + time_part(p))
        }
        "JULIANDAY" => Real(p.ijd.to_double() / 86400000.0)
        _ =>
          if p.use_subsec {
            Real(unix_ms(p).to_double() / 1000.0)
          } else {
            Int(p.ijd / 1000L - 210866760000L)
          }
      }
    }
    "STRFTIME" => {
      guard v.length() >= 1 && v[0].to_text() is Some(fmt) else {
        return Some(Null)
      }
      guard is_date(v[1:]) is Some(p) else { return Some(Null) }
      strftime_value(fmt, p)
    }
    "TIMEDIFF" => timediff_value(v[0], v[1])
    _ => return None
  }
  Some(r)
}
