// Date and time functions, following SQLite's date.c.

///|
priv struct DateTime {
  mut ijd : Int64 // Julian day number times 86400000
  mut y : Int
  mut mo : Int
  mut d : Int
  mut h : Int
  mut mi : Int
  mut tz : Int // time zone offset in minutes
  mut s : Double
  mut valid_jd : Bool
  mut valid_ymd : Bool
  mut valid_hms : Bool
  mut valid_tz : Bool
  mut raw_s : Bool // `s` holds a raw number not yet interpreted
  mut use_subsec : Bool
  mut is_error : Bool
  mut n_floor : Int // days to subtract for the 'floor' modifier
}

///|
fn DateTime::new() -> DateTime {
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
    use_subsec: false,
    is_error: false,
    n_floor: 0,
  }
}

///|
fn DateTime::copy(self : DateTime) -> DateTime {
  { ..self, }
}

///|
/// Code unit at `i`, or 0 past the end (like a C string terminator).
fn zc(z : String, i : Int) -> Int {
  if i >= 0 && i < z.length() {
    z[i].to_int()
  } else {
    0
  }
}

///|
fn is_c_space(c : Int) -> Bool {
  c == 32 || (c >= 9 && c <= 13)
}

///|
fn is_c_digit(c : Int) -> Bool {
  c >= 48 && c <= 57
}

///|
let digit_max : Array[Int] = [12, 14, 24, 31, 59, 14712]

///|
/// SQLite's getDigits(): each 4-character group of `fmt` is
/// (digit count, minimum, maximum code, separator). Returns the values
/// successfully parsed.
fn get_digits(z : String, pos : Int, fmt : String) -> Array[Int] {
  let out = []
  let mut i = pos
  let mut f = 0
  while f + 2 < fmt.length() {
    let n = fmt[f].to_int() - 48
    let min = fmt[f + 1].to_int() - 48
    let max = digit_max[fmt[f + 2].to_int() - 97]
    let next = if f + 3 < fmt.length() { fmt[f + 3].to_int() } else { 0 }
    let mut val = 0
    for _ in 0..<n {
      let c = zc(z, i)
      if !is_c_digit(c) {
        return out
      }
      val = val * 10 + c - 48
      i += 1
    }
    if val < min || val > max || (next != 0 && next != zc(z, i)) {
      return out
    }
    out.push(val)
    i += 1
    f += 4
    if next == 0 {
      break
    }
  }
  out
}

///|
/// Parses an optional time zone suffix. Returns true on error.
fn parse_timezone(z : String, pos : Int, p : DateTime) -> Bool {
  let mut i = pos
  while is_c_space(zc(z, i)) {
    i += 1
  }
  p.tz = 0
  let c = zc(z, i)
  if c == 'Z' || c == 'z' {
    i += 1
  } else {
    let sgn = if c == '-' { -1 } else if c == '+' { 1 } else { return c != 0 }
    i += 1
    let v = get_digits(z, i, "20b:20e")
    if v.length() != 2 {
      return true
    }
    i += 5
    p.tz = sgn * (v[1] + v[0] * 60)
  }
  while is_c_space(zc(z, i)) {
    i += 1
  }
  zc(z, i) != 0
}

///|
/// Parses HH:MM[:SS[.FFF]] with an optional time zone. Returns true on error.
fn parse_hhmmss(z : String, pos : Int, p : DateTime) -> Bool {
  let hm = get_digits(z, pos, "20c:20e")
  if hm.length() != 2 {
    return true
  }
  let mut i = pos + 5
  let mut sec = 0
  let mut ms = 0.0
  if zc(z, i) == ':' {
    i += 1
    let sv = get_digits(z, i, "20e")
    if sv.length() != 1 {
      return true
    }
    sec = sv[0]
    i += 2
    if zc(z, i) == '.' && is_c_digit(zc(z, i + 1)) {
      let mut scale = 1.0
      i += 1
      while is_c_digit(zc(z, i)) {
        ms = ms * 10.0 + (zc(z, i) - 48).to_double()
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
  p.h = hm[0]
  p.mi = hm[1]
  p.s = sec.to_double() + ms
  if parse_timezone(z, i, p) {
    return true
  }
  p.valid_tz = p.tz != 0
  false
}

///|
fn DateTime::error(self : DateTime) -> Unit {
  self.is_error = true
  self.valid_jd = false
  self.valid_ymd = false
  self.valid_hms = false
  self.valid_tz = false
}

///|
fn DateTime::compute_jd(self : DateTime) -> Unit {
  if self.valid_jd {
    return
  }
  let (y0, m0, d) = if self.valid_ymd {
    (self.y, self.mo, self.d)
  } else {
    (2000, 1, 1)
  }
  let mut y = y0
  let mut m = m0
  if y < -4713 || y > 9999 || self.raw_s {
    self.error()
    return
  }
  if m <= 2 {
    y -= 1
    m += 12
  }
  let a = y / 100
  let b = 2 - a + a / 4
  let x1 = 36525 * (y + 4716) / 100
  let x2 = 306001 * (m + 1) / 10000
  self.ijd = double_to_int64(
    ((x1 + x2 + d + b).to_double() - 1524.5) * 86400000.0,
  )
  self.valid_jd = true
  if self.valid_hms {
    self.ijd += (self.h * 3600000 + self.mi * 60000).to_int64() +
      (self.s * 1000.0 + 0.5).to_int64()
    if self.valid_tz {
      self.ijd -= (self.tz * 60000).to_int64()
      self.valid_ymd = false
      self.valid_hms = false
      self.valid_tz = false
    }
  }
}

///|
fn valid_julian_day(ijd : Int64) -> Bool {
  ijd >= 0L && ijd <= 464269060799999L
}

///|
fn DateTime::compute_ymd(self : DateTime) -> Unit {
  if self.valid_ymd {
    return
  }
  if !self.valid_jd {
    self.y = 2000
    self.mo = 1
    self.d = 1
  } else if !valid_julian_day(self.ijd) {
    self.error()
    return
  } else {
    let z = ((self.ijd + 43200000L) / 86400000L).to_int()
    let alpha = ((z.to_double() + 32044.75) / 36524.25).to_int() - 52
    let a = z + 1 + alpha - (alpha + 100) / 4 + 25
    let b = a + 1524
    let c = ((b.to_double() - 122.1) / 365.25).to_int()
    let d = 36525 * (c & 32767) / 100
    let e = ((b - d).to_double() / 30.6001).to_int()
    let x1 = (30.6001 * e.to_double()).to_int()
    self.d = b - d - x1
    self.mo = if e < 14 { e - 1 } else { e - 13 }
    self.y = if self.mo > 2 { c - 4716 } else { c - 4715 }
  }
  self.valid_ymd = true
}

///|
fn DateTime::compute_hms(self : DateTime) -> Unit {
  if self.valid_hms {
    return
  }
  self.compute_jd()
  let day_ms = ((self.ijd + 43200000L) % 86400000L).to_int()
  self.s = (day_ms % 60000).to_double() / 1000.0
  let day_min = day_ms / 60000
  self.mi = day_min % 60
  self.h = day_min / 60
  self.raw_s = false
  self.valid_hms = true
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
fn DateTime::compute_floor(self : DateTime) -> Unit {
  if self.d <= 28 {
    self.n_floor = 0
  } else if ((1 << self.mo) & 0x15aa) != 0 {
    self.n_floor = 0
  } else if self.mo != 2 {
    self.n_floor = if self.d == 31 { 1 } else { 0 }
  } else if self.y % 4 != 0 || (self.y % 100 == 0 && self.y % 400 != 0) {
    self.n_floor = self.d - 28
  } else {
    self.n_floor = self.d - 29
  }
}

///|
/// Parses YYYY-MM-DD with an optional time. Returns true on error.
fn parse_yyyymmdd(z : String, p : DateTime) -> Bool {
  let mut i = 0
  let neg = zc(z, 0) == '-'
  if neg {
    i = 1
  }
  let v = get_digits(z, i, "40f-21a-21d")
  if v.length() != 3 {
    return true
  }
  i += 10
  while is_c_space(zc(z, i)) || zc(z, i) == 'T' {
    i += 1
  }
  if !parse_hhmmss(z, i, p) {
    ()
  } else if zc(z, i) == 0 {
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
/// sqlite3AtoF(...) > 0: the whole text is a number.
fn full_number(z : StringView) -> Double? {
  match text_to_numeric_strict(z.to_owned()) {
    Some(v) => Some(v.as_double())
    None => None
  }
}

///|
fn DateTime::set_now(self : DateTime) -> Unit {
  // No clock is available; 'now' is never tested.
  self.ijd = 210866760000000L
  self.valid_jd = true
}

///|
/// Returns true on error.
fn parse_date_or_time(z : String, p : DateTime) -> Bool {
  if !parse_yyyymmdd(z, p) {
    return false
  }
  if !parse_hhmmss(z, 0, p) {
    return false
  }
  if z.to_lower() == "now" {
    p.set_now()
    return false
  }
  match full_number(z) {
    Some(r) => {
      p.set_raw_number(r)
      false
    }
    None => {
      let l = z.to_lower()
      if l == "subsec" || l == "subsecond" {
        p.use_subsec = true
        p.set_now()
        return false
      }
      true
    }
  }
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
fn DateTime::normalize_month(self : DateTime) -> Unit {
  let x = if self.mo > 0 { (self.mo - 1) / 12 } else { (self.mo - 12) / 12 }
  self.y += x
  self.mo -= x * 12
}

///|
/// Applies one modifier. Returns true on error.
fn parse_modifier(z : String, p : DateTime, idx : Int) -> Bool {
  let lz = z.to_lower()
  let c0 = zc(lz, 0)
  if c0 == 'a' {
    if lz == "auto" {
      if idx > 1 {
        return true
      }
      if !p.raw_s || p.valid_jd {
        p.raw_s = false
        return false
      }
      if p.s >= -210866760000.0 && p.s <= 253402300799.0 {
        let r = p.s * 1000.0 + 210866760000000.0
        p.clear_ymd_hms_tz()
        p.ijd = (r + 0.5).to_int64()
        p.valid_jd = true
        p.raw_s = false
        return false
      }
    }
    return true
  }
  if c0 == 'c' {
    if lz == "ceiling" {
      p.compute_jd()
      p.clear_ymd_hms_tz()
      p.n_floor = 0
      return false
    }
    return true
  }
  if c0 == 'f' {
    if lz == "floor" {
      p.compute_jd()
      p.ijd -= p.n_floor.to_int64() * 86400000L
      p.clear_ymd_hms_tz()
      return false
    }
    return true
  }
  if c0 == 'j' {
    if lz == "julianday" {
      if idx > 1 {
        return true
      }
      if p.valid_jd && p.raw_s {
        p.raw_s = false
        return false
      }
    }
    return true
  }
  if c0 == 'u' {
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
    } else if lz == "utc" {
      // Local time is UTC here.
      p.compute_jd()
      return false
    }
    return true
  }
  if c0 == 'l' {
    if lz == "localtime" {
      p.compute_jd()
      return false
    }
    return true
  }
  if c0 == 'w' {
    if lz.has_prefix("weekday ") {
      match full_number(lz[8:]) {
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
    return true
  }
  if c0 == 's' {
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
      return false
    } else if rest == "year" {
      p.mo = 1
      p.d = 1
      return false
    } else if rest == "day" {
      return false
    }
    return true
  }
  if !(c0 == '+' || c0 == '-' || is_c_digit(c0)) {
    return true
  }
  // Numeric modifiers.
  let mut n = 1
  while zc(z, n) != 0 {
    let c = zc(z, n)
    if c == ':' || is_c_space(c) {
      break
    }
    if c == '-' {
      if n == 5 && get_digits(z, 1, "40f").length() == 1 {
        break
      }
      if n == 6 && get_digits(z, 1, "50f").length() == 1 {
        break
      }
    }
    n += 1
  }
  guard full_number(z[0:n]) is Some(r) else { return true }
  let mut zo = 0 // offset of z
  let mut z2 = 0 // offset of the HH:MM part
  if zc(z, n) == '-' {
    // (+|-)YYYY-MM-DD[ HH:MM[:SS]]
    if c0 != '+' && c0 != '-' {
      return true
    }
    let v = if n == 5 {
      get_digits(z, 1, "40f-20a-20d")
    } else {
      get_digits(z, 1, "50f-20a-20d")
    }
    if v.length() != 3 {
      return true
    }
    if n == 6 {
      zo = 1
    }
    let (yy, mm, dd0) = (v[0], v[1], v[2])
    if mm >= 12 || dd0 >= 31 {
      return true
    }
    p.compute_ymd_hms()
    p.valid_jd = false
    let mut dd = dd0
    if c0 == '-' {
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
    if zc(z, zo + 11) == 0 {
      return false
    }
    if is_c_space(zc(z, zo + 11)) &&
      get_digits(z, zo + 12, "20c:20e").length() == 2 {
      z2 = zo + 12
      n = 2
    } else {
      return true
    }
  }
  if zc(z, z2 + n) == ':' {
    // (+|-)HH:MM[:SS[.FFF]]
    let mut start = z2
    if !is_c_digit(zc(z, start)) {
      start += 1
    }
    let tx = DateTime::new()
    if parse_hhmmss(z, start, tx) {
      return true
    }
    tx.compute_jd()
    tx.ijd -= 43200000L
    let day = tx.ijd / 86400000L
    tx.ijd -= day * 86400000L
    if c0 == '-' {
      tx.ijd = -tx.ijd
    }
    p.compute_jd()
    p.clear_ymd_hms_tz()
    p.ijd += tx.ijd
    return false
  }
  // "+NNN units"
  let mut i = n
  while is_c_space(zc(z, i)) {
    i += 1
  }
  let unit = lz[i:].to_owned()
  let mut un = unit.length()
  if un < 3 || un > 10 {
    return true
  }
  if zc(unit, un - 1) == 's' {
    un -= 1
  }
  let unit = unit[0:un].to_owned()
  p.compute_jd()
  let rounder = if r < 0.0 { -0.5 } else { 0.5 }
  p.n_floor = 0
  let mut failed = true
  for xf in xform_types {
    let (name, limit, xform) = xf
    if name == unit && r > -limit && r < limit {
      let mut r2 = r
      if name == "month" {
        p.compute_ymd_hms()
        p.mo += r.to_int()
        p.normalize_month()
        p.compute_floor()
        p.valid_jd = false
        r2 = r - r.to_int().to_double()
      } else if name == "year" {
        p.compute_ymd_hms()
        p.y += r.to_int()
        p.compute_floor()
        p.valid_jd = false
        r2 = r - r.to_int().to_double()
      }
      p.compute_jd()
      p.ijd += (r2 * 1000.0 * xform + rounder).to_int64()
      failed = false
      break
    }
  }
  p.clear_ymd_hms_tz()
  failed
}

///|
/// Interprets a time value and modifiers; None if invalid.
fn is_date(args : ArrayView[Value]) -> DateTime? {
  let p = DateTime::new()
  if args.length() == 0 {
    p.set_now()
    return Some(p)
  }
  match args[0] {
    Null => return None
    Int(_) | Real(_) => p.set_raw_number(args[0].as_double())
    v => if parse_date_or_time(v.to_text(), p) { return None }
  }
  for i in 1..<args.length() {
    if args[i] is Null {
      return None
    }
    if parse_modifier(args[i].to_text(), p, i) {
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
/// Zero-pads a non-negative number to `w` digits.
fn zpad(n : Int, w : Int) -> String {
  let s = n.to_string()
  if s.length() >= w {
    s
  } else {
    String::make(w - s.length(), '0') + s
  }
}

///|
/// printf "%0<w>d".
fn zpad_signed(n : Int, w : Int) -> String {
  if n < 0 {
    "-" + zpad(-n, w - 1)
  } else {
    zpad(n, w)
  }
}

///|
/// printf "%<w>d".
fn spad(n : Int, w : Int) -> String {
  let s = n.to_string()
  if s.length() >= w {
    s
  } else {
    String::make(w - s.length(), ' ') + s
  }
}

///|
fn format_date_part(p : DateTime) -> String {
  let y = if p.y < 0 { -p.y } else { p.y }
  let body = zpad(y % 10000, 4) + "-" + zpad(p.mo, 2) + "-" + zpad(p.d, 2)
  if p.y < 0 {
    "-" + body
  } else {
    body
  }
}

///|
fn format_time_part(p : DateTime) -> String {
  let base = zpad(p.h, 2) + ":" + zpad(p.mi, 2) + ":"
  if p.use_subsec {
    let s = (1000.0 * p.s + 0.5).to_int()
    base + zpad(s / 1000, 2) + "." + zpad(s % 1000, 3)
  } else {
    base + zpad(p.s.to_int(), 2)
  }
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
/// The Thursday in the same ISO week as `p`.
fn iso_thursday(p : DateTime) -> DateTime {
  let y = p.copy()
  y.ijd += (3 - days_after_monday(p)).to_int64() * 86400000L
  y.valid_ymd = false
  y.compute_ymd()
  y
}

///|
fn strftime_impl(fmt : String, p : DateTime) -> Value {
  p.compute_jd()
  p.compute_ymd_hms()
  let sb = StringBuilder()
  let n = fmt.length()
  let mut i = 0
  while i < n {
    let c = fmt[i]
    if c != '%' {
      // Copy a whole code point (surrogate pairs included).
      let j = i
      i += 1
      while i < n && fmt[i] != '%' {
        i += 1
      }
      sb.write_view(fmt[j:i])
      continue
    }
    i += 1
    let cf = zc(fmt, i)
    i += 1
    match cf {
      'd' => sb.write_string(zpad(p.d, 2))
      'e' => sb.write_string(spad(p.d, 2))
      'f' => {
        let s = if p.s > 59.999 { 59.999 } else { p.s }
        sb.write_string(sql_printf("%06.3f", [Real(s)]))
      }
      'F' =>
        sb.write_string(
          zpad_signed(p.y, 4) + "-" + zpad(p.mo, 2) + "-" + zpad(p.d, 2),
        )
      'G' | 'g' => {
        let y = iso_thursday(p)
        if cf == 'g' {
          sb.write_string(zpad_signed(y.y % 100, 2))
        } else {
          sb.write_string(zpad_signed(y.y, 4))
        }
      }
      'H' => sb.write_string(zpad(p.h, 2))
      'k' => sb.write_string(spad(p.h, 2))
      'I' | 'l' => {
        let mut h = p.h
        if h > 12 {
          h -= 12
        }
        if h == 0 {
          h = 12
        }
        sb.write_string(if cf == 'I' { zpad(h, 2) } else { spad(h, 2) })
      }
      'j' => sb.write_string(zpad(days_after_jan01(p) + 1, 3))
      'J' =>
        sb.write_string(
          sql_printf("%.16g", [Real(p.ijd.to_double() / 86400000.0)]),
        )
      'm' => sb.write_string(zpad(p.mo, 2))
      'M' => sb.write_string(zpad(p.mi, 2))
      'p' => sb.write_string(if p.h >= 12 { "PM" } else { "AM" })
      'P' => sb.write_string(if p.h >= 12 { "pm" } else { "am" })
      'R' => sb.write_string(zpad(p.h, 2) + ":" + zpad(p.mi, 2))
      's' =>
        if p.use_subsec {
          sb.write_string(
            sql_printf("%.3f", [
              Real((p.ijd - 210866760000000L).to_double() / 1000.0),
            ]),
          )
        } else {
          sb.write_string((p.ijd / 1000L - 210866760000L).to_string())
        }
      'S' => sb.write_string(zpad(p.s.to_int(), 2))
      'T' =>
        sb.write_string(
          zpad(p.h, 2) + ":" + zpad(p.mi, 2) + ":" + zpad(p.s.to_int(), 2),
        )
      'u' | 'w' => {
        let mut d = days_after_sunday(p)
        if d == 0 && cf == 'u' {
          d = 7
        }
        sb.write_string(d.to_string())
      }
      'U' =>
        sb.write_string(
          zpad((days_after_jan01(p) - days_after_sunday(p) + 7) / 7, 2),
        )
      'V' => {
        let y = iso_thursday(p)
        sb.write_string(zpad(days_after_jan01(y) / 7 + 1, 2))
      }
      'W' =>
        sb.write_string(
          zpad((days_after_jan01(p) - days_after_monday(p) + 7) / 7, 2),
        )
      'Y' => sb.write_string(zpad_signed(p.y, 4))
      '%' => sb.write_char('%')
      _ => return Null
    }
  }
  Text(sb.to_string())
}

///|
fn timediff_impl(a : Value, b : Value) -> Value {
  guard is_date([a][:]) is Some(d1) else { return Null }
  guard is_date([b][:]) is Some(d2) else { return Null }
  d1.compute_ymd_hms()
  d2.compute_ymd_hms()
  let mut y = 0
  let mut m = 0
  let sign = if d1.ijd >= d2.ijd { '+' } else { '-' }
  if sign == '+' {
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
    d1.ijd -= d2.ijd
  } else {
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
    d1.ijd = d2.ijd - d1.ijd
  }
  d1.ijd += 148699540800000L
  d1.clear_ymd_hms_tz()
  d1.compute_ymd_hms()
  Text(
    sign.to_string() +
    zpad_signed(y, 4) +
    "-" +
    zpad(m, 2) +
    "-" +
    zpad(d1.d - 1, 2) +
    " " +
    zpad(d1.h, 2) +
    ":" +
    zpad(d1.mi, 2) +
    ":" +
    sql_printf("%06.3f", [Real(d1.s)]),
  )
}

///|
fn register_date_functions(m : Map[String, ScalarFunc]) -> Unit {
  m["date"] = {
    min_args: 0,
    max_args: -1,
    f: args => {
      match is_date(args[:]) {
        Some(p) => {
          p.compute_ymd()
          Text(format_date_part(p))
        }
        None => Null
      }
    },
  }
  m["time"] = {
    min_args: 0,
    max_args: -1,
    f: args => {
      match is_date(args[:]) {
        Some(p) => {
          p.compute_hms()
          Text(format_time_part(p))
        }
        None => Null
      }
    },
  }
  m["datetime"] = {
    min_args: 0,
    max_args: -1,
    f: args => {
      match is_date(args[:]) {
        Some(p) => {
          p.compute_ymd_hms()
          Text(format_date_part(p) + " " + format_time_part(p))
        }
        None => Null
      }
    },
  }
  m["julianday"] = {
    min_args: 0,
    max_args: -1,
    f: args => {
      match is_date(args[:]) {
        Some(p) => Real(p.ijd.to_double() / 86400000.0)
        None => Null
      }
    },
  }
  m["unixepoch"] = {
    min_args: 0,
    max_args: -1,
    f: args => {
      match is_date(args[:]) {
        Some(p) =>
          if p.use_subsec {
            Real((p.ijd - 210866760000000L).to_double() / 1000.0)
          } else {
            Int(p.ijd / 1000L - 210866760000L)
          }
        None => Null
      }
    },
  }
  m["strftime"] = {
    min_args: 1,
    max_args: -1,
    f: args => {
      if args[0] is Null {
        return Null
      }
      match is_date(args[1:]) {
        Some(p) => strftime_impl(args[0].to_text(), p)
        None => Null
      }
    },
  }
  m["timediff"] = {
    min_args: 2,
    max_args: 2,
    f: args => timediff_impl(args[0], args[1]),
  }
}
