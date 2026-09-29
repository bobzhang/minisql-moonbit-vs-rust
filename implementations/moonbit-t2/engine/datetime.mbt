// Date and time functions, following SQLite's date.c.

///|
priv struct DateTime {
  mut ijd : Int64 // Julian day number times 86400000
  mut y : Int
  mut mo : Int
  mut d : Int
  mut h : Int
  mut mi : Int
  mut tz : Int // timezone offset in minutes
  mut s : Double
  mut valid_jd : Bool
  mut valid_ymd : Bool
  mut valid_hms : Bool
  mut raw_s : Bool // `s` holds a raw number not yet interpreted
  mut is_error : Bool
  mut use_subsec : Bool
  mut n_floor : Int // days to subtract for the `floor` modifier
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
fn DateTime::set_error(self : DateTime) -> Unit {
  let z = DateTime::new()
  self.ijd = z.ijd
  self.y = 0
  self.mo = 0
  self.d = 0
  self.h = 0
  self.mi = 0
  self.tz = 0
  self.s = 0.0
  self.valid_jd = false
  self.valid_ymd = false
  self.valid_hms = false
  self.raw_s = false
  self.use_subsec = false
  self.n_floor = 0
  self.is_error = true
}

///|
fn cu_at(s : String, i : Int) -> Int {
  if i < s.length() {
    s[i].to_int()
  } else {
    0
  }
}

///|
fn is_space_at(s : String, i : Int) -> Bool {
  i < s.length() && is_space_cu(s[i])
}

///|
fn is_digit_at(s : String, i : Int) -> Bool {
  i < s.length() && is_digit_cu(s[i])
}

///|
/// Reads fixed-width digit fields starting at `pos`. Each spec is
/// (digits, min, max, separator or 0).
fn get_digits(
  s : String,
  pos : Int,
  specs : Array[(Int, Int, Int, Int)],
) -> Array[Int]? {
  let out : Array[Int] = []
  let mut i = pos
  for spec in specs {
    let (n, lo, hi, sep) = spec
    let mut v = 0
    for _ in 0..<n {
      if !is_digit_at(s, i) {
        return None
      }
      v = v * 10 + (s[i].to_int() - '0'.to_int())
      i += 1
    }
    if v < lo || v > hi {
      return None
    }
    if sep != 0 && cu_at(s, i) != sep {
      return None
    }
    i += 1
    out.push(v)
  }
  Some(out)
}

///|
let colon : Int = ':'.to_int()

///|
let dash : Int = '-'.to_int()

///|
/// Parses a timezone suffix at `i`; true on error.
fn DateTime::parse_timezone(self : DateTime, s : String, i0 : Int) -> Bool {
  let mut i = i0
  while is_space_at(s, i) {
    i += 1
  }
  self.tz = 0
  let c = cu_at(s, i)
  let mut sgn = 0
  if c == '-'.to_int() {
    sgn = -1
  } else if c == '+'.to_int() {
    sgn = 1
  } else if c == 'Z'.to_int() || c == 'z'.to_int() {
    i += 1
    while is_space_at(s, i) {
      i += 1
    }
    return i < s.length()
  } else {
    return c != 0
  }
  i += 1
  guard get_digits(s, i, [(2, 0, 14, colon), (2, 0, 59, 0)]) is Some(v) else {
    return true
  }
  i += 5
  self.tz = sgn * (v[1] + v[0] * 60)
  while is_space_at(s, i) {
    i += 1
  }
  i < s.length()
}

///|
/// Parses HH:MM[:SS[.FFF]] [timezone] at `i`; true on error.
fn DateTime::parse_hms(self : DateTime, s : String, i0 : Int) -> Bool {
  guard get_digits(s, i0, [(2, 0, 24, colon), (2, 0, 59, 0)]) is Some(hm) else {
    return true
  }
  let mut i = i0 + 5
  let mut sec = 0
  let mut ms = 0.0
  if cu_at(s, i) == colon {
    i += 1
    guard get_digits(s, i, [(2, 0, 59, 0)]) is Some(sv) else { return true }
    sec = sv[0]
    i += 2
    if cu_at(s, i) == '.'.to_int() && is_digit_at(s, i + 1) {
      let mut scale = 1.0
      i += 1
      while is_digit_at(s, i) {
        ms = ms * 10.0 + (s[i].to_int() - '0'.to_int()).to_double()
        scale *= 10.0
        i += 1
      }
      ms /= scale
      if ms > 0.999 {
        ms = 0.999
      }
    }
  }
  self.valid_jd = false
  self.raw_s = false
  self.valid_hms = true
  self.h = hm[0]
  self.mi = hm[1]
  self.s = sec.to_double() + ms
  if self.parse_timezone(s, i) {
    return true
  }
  false
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
/// Parses YYYY-MM-DD [time]; true on error.
fn DateTime::parse_ymd(self : DateTime, s : String) -> Bool {
  let mut i = 0
  let neg = cu_at(s, 0) == dash
  if neg {
    i = 1
  }
  guard get_digits(s, i, [(4, 0, 14712, dash), (2, 1, 12, dash), (2, 1, 31, 0)])
    is Some(v) else {
    return true
  }
  i += 10
  while is_space_at(s, i) || cu_at(s, i) == 'T'.to_int() {
    i += 1
  }
  if !self.parse_hms(s, i) {
    ()
  } else if i >= s.length() {
    self.valid_hms = false
  } else {
    return true
  }
  self.valid_jd = false
  self.valid_ymd = true
  self.y = if neg { -v[0] } else { v[0] }
  self.mo = v[1]
  self.d = v[2]
  self.compute_floor()
  if self.tz != 0 {
    self.compute_jd()
  }
  false
}

///|
fn DateTime::compute_jd(self : DateTime) -> Unit {
  if self.valid_jd {
    return
  }
  let mut yy = 2000
  let mut mm = 1
  let mut dd = 1
  if self.valid_ymd {
    yy = self.y
    mm = self.mo
    dd = self.d
  }
  if yy < -4713 || yy > 9999 || self.raw_s {
    self.set_error()
    return
  }
  if mm <= 2 {
    yy -= 1
    mm += 12
  }
  let a = yy / 100
  let b = 2 - a + a / 4
  let x1 = 36525 * (yy + 4716) / 100
  let x2 = 306001 * (mm + 1) / 10000
  self.ijd = (((x1 + x2 + dd + b).to_double() - 1524.5) * 86400000.0).to_int64()
  self.valid_jd = true
  if self.valid_hms {
    self.ijd += (self.h * 3600000 + self.mi * 60000).to_int64() +
      (self.s * 1000.0 + 0.5).to_int64()
    if self.tz != 0 {
      self.ijd -= (self.tz * 60000).to_int64()
      self.valid_ymd = false
      self.valid_hms = false
      self.tz = 0
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
    self.set_error()
    return
  } else {
    let z = ((self.ijd + 43200000L) / 86400000L).to_int()
    let a0 = ((z.to_double() - 1867216.25) / 36524.25).to_int()
    let a = z + 1 + a0 - a0 / 4
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
  self.tz = 0
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
/// The number spelled by the whole of `s` (SQLite's AtoF > 0).
fn full_number(s : String) -> Double? {
  match parse_numeric_text(s) {
    Some(v) => Some(value_to_double(v))
    None => None
  }
}

///|
fn DateTime::parse_date_or_time(self : DateTime, s : String) -> Bool {
  if !self.parse_ymd(s) {
    return false
  }
  if !self.parse_hms(s, 0) {
    return false
  }
  match full_number(s) {
    Some(r) => {
      self.set_raw_number(r)
      false
    }
    None => true
  }
}

///|
/// Name, limit and scale (seconds) of the `+NNN unit` modifiers.
let xform_types : Array[(String, Double, Double)] = [
  ("second", 4.6427e+14, 1.0),
  ("minute", 7.7379e+12, 60.0),
  ("hour", 1.2897e+11, 3600.0),
  ("day", 5373485.0, 86400.0),
  ("month", 176546.0, 30.0 * 86400.0),
  ("year", 14713.0, 365.0 * 86400.0),
]

///|
/// Applies one modifier; true on error.
fn DateTime::apply_modifier(self : DateTime, z : String, idx : Int) -> Bool {
  let lz = ascii_case(z, false)
  let n = z.length()
  if n == 0 {
    return true
  }
  match lz.get_char(0).unwrap_or(' ') {
    'a' => {
      if lz != "auto" {
        return true
      }
      if idx > 1 {
        return true
      }
      if !self.raw_s || self.valid_jd {
        self.raw_s = false
        return false
      }
      if self.s >= -210866760000.0 && self.s <= 253402300799.0 {
        let r = self.s * 1000.0 + 210866760000000.0
        self.clear_ymd_hms_tz()
        self.ijd = (r + 0.5).to_int64()
        self.valid_jd = true
        self.raw_s = false
        return false
      }
      true
    }
    'c' => {
      if lz != "ceiling" {
        return true
      }
      self.compute_jd()
      self.clear_ymd_hms_tz()
      self.n_floor = 0
      false
    }
    'f' => {
      if lz != "floor" {
        return true
      }
      self.compute_jd()
      self.ijd -= self.n_floor.to_int64() * 86400000L
      self.clear_ymd_hms_tz()
      false
    }
    'j' => {
      if lz != "julianday" {
        return true
      }
      if idx > 1 {
        return true
      }
      if self.valid_jd && self.raw_s {
        self.raw_s = false
        return false
      }
      true
    }
    'l' => {
      // localtime: the local timezone is taken to be UTC
      if lz != "localtime" {
        return true
      }
      self.compute_jd()
      self.clear_ymd_hms_tz()
      false
    }
    'u' => {
      if lz == "unixepoch" && self.raw_s {
        if idx > 1 {
          return true
        }
        let r = self.s * 1000.0 + 210866760000000.0
        if r >= 0.0 && r < 464269060800000.0 {
          self.clear_ymd_hms_tz()
          self.ijd = (r + 0.5).to_int64()
          self.valid_jd = true
          self.raw_s = false
          return false
        }
        return true
      }
      if lz == "utc" {
        self.compute_jd()
        self.clear_ymd_hms_tz()
        return false
      }
      true
    }
    'w' => {
      guard lz.strip_prefix("weekday ") is Some(rest) else { return true }
      guard full_number(rest.to_owned()) is Some(r) else { return true }
      if !(r >= 0.0 && r < 7.0) {
        return true
      }
      let wd = r.to_int()
      if wd.to_double() != r {
        return true
      }
      self.compute_ymd_hms()
      self.tz = 0
      self.valid_jd = false
      self.compute_jd()
      let mut zz = (self.ijd + 129600000L) / 86400000L % 7L
      if zz > wd.to_int64() {
        zz -= 7L
      }
      self.ijd += (wd.to_int64() - zz) * 86400000L
      self.clear_ymd_hms_tz()
      false
    }
    's' => {
      if lz == "subsec" || lz == "subsecond" {
        self.use_subsec = true
        return false
      }
      guard lz.strip_prefix("start of ") is Some(unit) else { return true }
      if !self.valid_jd && !self.valid_ymd && !self.valid_hms {
        return true
      }
      self.compute_ymd()
      self.valid_hms = true
      self.h = 0
      self.mi = 0
      self.s = 0.0
      self.raw_s = false
      self.tz = 0
      self.valid_jd = false
      if unit == "month" {
        self.d = 1
        false
      } else if unit == "year" {
        self.mo = 1
        self.d = 1
        false
      } else if unit == "day" {
        false
      } else {
        true
      }
    }
    '+' | '-' | '0'..='9' => self.apply_offset(z)
    _ => true
  }
}

///|
/// The numeric modifiers: `±NNN unit`, `±HH:MM[:SS]`, `±YYYY-MM-DD[ HH:MM]`.
fn DateTime::apply_offset(self : DateTime, z : String) -> Bool {
  let len = z.length()
  let z0 = z[0]
  let mut n = 1
  while n < len {
    let c = z[n]
    if c == ':' || is_space_cu(c) {
      break
    }
    if c == '-' {
      if n == 5 && get_digits(z, 1, [(4, 0, 14712, 0)]) is Some(_) {
        break
      }
      if n == 6 && get_digits(z, 1, [(5, 0, 14712, 0)]) is Some(_) {
        break
      }
    }
    n += 1
  }
  guard full_number(z[0:n].to_owned()) is Some(r0) else { return true }
  let mut r = r0
  let mut z2 = 0
  if n < len && z[n] == '-' {
    if z0 != '+' && z0 != '-' {
      return true
    }
    let mut off = 0
    let v = if n == 5 {
      get_digits(z, 1, [(4, 0, 14712, dash), (2, 0, 11, dash), (2, 0, 30, 0)])
    } else {
      off = 1
      get_digits(z, 1, [(5, 0, 14712, dash), (2, 0, 11, dash), (2, 0, 30, 0)])
    }
    guard v is Some(ymd) else { return true }
    self.compute_ymd_hms()
    self.valid_jd = false
    let mut dd = ymd[2]
    if z0 == '-' {
      self.y -= ymd[0]
      self.mo -= ymd[1]
      dd = -dd
    } else {
      self.y += ymd[0]
      self.mo += ymd[1]
    }
    let x = if self.mo > 0 { (self.mo - 1) / 12 } else { (self.mo - 12) / 12 }
    self.y += x
    self.mo -= x * 12
    self.compute_floor()
    self.compute_jd()
    self.valid_hms = false
    self.valid_ymd = false
    self.ijd += dd.to_int64() * 86400000L
    let e = off + 11
    if e >= len {
      return false
    }
    if is_space_cu(z[e]) &&
      get_digits(z, e + 1, [(2, 0, 24, colon), (2, 0, 59, 0)]) is Some(_) {
      z2 = e + 1
      n = 2
    } else {
      return true
    }
  }
  if z2 + n < len && z[z2 + n] == ':' {
    let mut p2 = z2
    if !is_digit_cu(z[p2]) {
      p2 += 1
    }
    let tx = DateTime::new()
    if tx.parse_hms(z, p2) {
      return true
    }
    tx.compute_jd()
    tx.ijd -= 43200000L
    let day = tx.ijd / 86400000L
    tx.ijd -= day * 86400000L
    if z0 == '-' {
      tx.ijd = -tx.ijd
    }
    self.compute_jd()
    self.clear_ymd_hms_tz()
    self.ijd += tx.ijd
    return false
  }
  // `±NNN unit`
  let mut i = n
  while i < len && is_space_cu(z[i]) {
    i += 1
  }
  let mut unit = ascii_case(z[i:].to_owned(), false)
  let mut un = unit.length()
  if un < 3 || un > 10 {
    return true
  }
  if unit[un - 1] == 's' {
    un -= 1
    unit = unit[0:un].to_owned()
  }
  self.compute_jd()
  let rounder = if r < 0.0 { -0.5 } else { 0.5 }
  self.n_floor = 0
  let mut rc = true
  for k, xf in xform_types {
    let (name, limit, scale) = xf
    if name == unit && r > -limit && r < limit {
      if k == 4 {
        self.compute_ymd_hms()
        self.mo += r.to_int()
        let x = if self.mo > 0 {
          (self.mo - 1) / 12
        } else {
          (self.mo - 12) / 12
        }
        self.y += x
        self.mo -= x * 12
        self.compute_floor()
        self.valid_jd = false
        r -= r.to_int().to_double()
      } else if k == 5 {
        self.compute_ymd_hms()
        self.y += r.to_int()
        self.compute_floor()
        self.valid_jd = false
        r -= r.to_int().to_double()
      }
      self.compute_jd()
      self.ijd += (r * 1000.0 * scale + rounder).to_int64()
      rc = false
      break
    }
  }
  self.clear_ymd_hms_tz()
  rc
}

///|
/// Interprets a time value and modifiers (SQLite's isDate). None if invalid.
fn date_from_args(args : ArrayView[Value]) -> DateTime? {
  let p = DateTime::new()
  if args.length() == 0 {
    return None
  }
  match args[0] {
    Null => return None
    Int(i) => p.set_raw_number(i.to_double())
    Real(d) => p.set_raw_number(d)
    v => if p.parse_date_or_time(v.to_text()) { return None }
  }
  for i in 1..<args.length() {
    let m = args[i]
    if m is Null {
      return None
    }
    if p.apply_modifier(m.to_text(), i) {
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
/// Formats `v` as a decimal padded to `width` (with zeros or spaces).
fn pad_int(v : Int, width : Int, zero : Bool) -> String {
  let neg = v < 0
  let digits = (if neg { -v } else { v }).to_string()
  let body_len = digits.length() + (if neg { 1 } else { 0 })
  if body_len >= width {
    return if neg { "-" + digits } else { digits }
  }
  let fill = width - body_len
  if zero {
    (if neg { "-" } else { "" }) + String::make(fill, '0') + digits
  } else {
    String::make(fill, ' ') + (if neg { "-" } else { "" }) + digits
  }
}

///|
fn fmt_seconds(s : Double) -> String {
  sql_printf("%06.3f", [Real(s)])
}

///|
fn DateTime::date_text(self : DateTime) -> String {
  let yy = if self.y < 0 { -self.y } else { self.y }
  let ys = pad_int(yy % 10000, 4, true)
  (if self.y < 0 { "-" } else { "" }) +
  ys +
  "-" +
  pad_int(self.mo, 2, true) +
  "-" +
  pad_int(self.d, 2, true)
}

///|
fn DateTime::time_text(self : DateTime) -> String {
  let base = pad_int(self.h, 2, true) + ":" + pad_int(self.mi, 2, true) + ":"
  if self.use_subsec {
    let ms = (1000.0 * self.s + 0.5).to_int()
    base + pad_int(ms / 1000, 2, true) + "." + pad_int(ms % 1000, 3, true)
  } else {
    base + pad_int(self.s.to_int(), 2, true)
  }
}

///|
fn DateTime::days_after_jan01(self : DateTime) -> Int {
  let j = self.copy()
  j.valid_jd = false
  j.mo = 1
  j.d = 1
  j.compute_jd()
  ((self.ijd - j.ijd + 43200000L) / 86400000L).to_int()
}

///|
fn DateTime::days_after_monday(self : DateTime) -> Int {
  ((self.ijd + 43200000L) / 86400000L % 7L).to_int()
}

///|
fn DateTime::days_after_sunday(self : DateTime) -> Int {
  ((self.ijd + 129600000L) / 86400000L % 7L).to_int()
}

///|
/// The Thursday of the ISO week containing this date.
fn DateTime::iso_thursday(self : DateTime) -> DateTime {
  let y = self.copy()
  y.ijd += (3 - self.days_after_monday()).to_int64() * 86400000L
  y.valid_ymd = false
  y.compute_ymd()
  y
}

///|
fn unix_seconds(p : DateTime) -> Value {
  if p.use_subsec {
    Real((p.ijd - 210866760000000L).to_double() / 1000.0)
  } else {
    Int(p.ijd / 1000L - 210866760000L)
  }
}

///|
fn sql_strftime(fmt : String, x : DateTime) -> Value {
  x.compute_jd()
  x.compute_ymd_hms()
  let sb = StringBuilder()
  let n = fmt.length()
  let mut i = 0
  while i < n {
    if fmt[i] != '%' {
      let start = i
      while i < n && fmt[i] != '%' {
        i += 1
      }
      sb.write_view(fmt[start:i])
      continue
    }
    if i + 1 >= n {
      return Null
    }
    let cf = fmt[i + 1]
    i += 2
    match cf.to_char().unwrap_or('?') {
      'd' => sb.write_string(pad_int(x.d, 2, true))
      'e' => sb.write_string(pad_int(x.d, 2, false))
      'f' => {
        let s = if x.s > 59.999 { 59.999 } else { x.s }
        sb.write_string(fmt_seconds(s))
      }
      'F' => sb.write_string(x.date_text())
      'G' => sb.write_string(pad_int(x.iso_thursday().y, 4, true))
      'g' => sb.write_string(pad_int(x.iso_thursday().y % 100, 2, true))
      'H' => sb.write_string(pad_int(x.h, 2, true))
      'k' => sb.write_string(pad_int(x.h, 2, false))
      'I' | 'l' => {
        let mut h = x.h
        if h > 12 {
          h -= 12
        }
        if h == 0 {
          h = 12
        }
        sb.write_string(pad_int(h, 2, cf == 'I'))
      }
      'j' => sb.write_string(pad_int(x.days_after_jan01() + 1, 3, true))
      'J' =>
        sb.write_string(
          sql_printf("%.16g", [Real(x.ijd.to_double() / 86400000.0)]),
        )
      'm' => sb.write_string(pad_int(x.mo, 2, true))
      'M' => sb.write_string(pad_int(x.mi, 2, true))
      'p' => sb.write_string(if x.h >= 12 { "PM" } else { "AM" })
      'P' => sb.write_string(if x.h >= 12 { "pm" } else { "am" })
      'R' =>
        sb.write_string(pad_int(x.h, 2, true) + ":" + pad_int(x.mi, 2, true))
      's' =>
        if x.use_subsec {
          sb.write_string(
            sql_printf("%.3f", [
              Real((x.ijd - 210866760000000L).to_double() / 1000.0),
            ]),
          )
        } else {
          sb.write_string((x.ijd / 1000L - 210866760000L).to_string())
        }
      'S' => sb.write_string(pad_int(x.s.to_int(), 2, true))
      'T' =>
        sb.write_string(
          pad_int(x.h, 2, true) +
          ":" +
          pad_int(x.mi, 2, true) +
          ":" +
          pad_int(x.s.to_int(), 2, true),
        )
      'u' => {
        let w = x.days_after_sunday()
        sb.write_string((if w == 0 { 7 } else { w }).to_string())
      }
      'w' => sb.write_string(x.days_after_sunday().to_string())
      'U' =>
        sb.write_string(
          pad_int(
            (x.days_after_jan01() - x.days_after_sunday() + 7) / 7,
            2,
            true,
          ),
        )
      'V' =>
        sb.write_string(
          pad_int(x.iso_thursday().days_after_jan01() / 7 + 1, 2, true),
        )
      'W' =>
        sb.write_string(
          pad_int(
            (x.days_after_jan01() - x.days_after_monday() + 7) / 7,
            2,
            true,
          ),
        )
      'Y' => sb.write_string(pad_int(x.y, 4, true))
      '%' => sb.write_char('%')
      _ => return Null
    }
  }
  Text(sb.to_string())
}

///|
fn sql_timediff(a : Value, b : Value) -> Value {
  guard date_from_args([a]) is Some(d1) else { return Null }
  guard date_from_args([b]) is Some(d2) else { return Null }
  d1.compute_ymd_hms()
  d2.compute_ymd_hms()
  let mut yy = 0
  let mut mm = 0
  let mut sign = '+'
  if d1.ijd >= d2.ijd {
    yy = d1.y - d2.y
    if yy != 0 {
      d2.y = d1.y
      d2.valid_jd = false
      d2.compute_jd()
    }
    mm = d1.mo - d2.mo
    if mm < 0 {
      yy -= 1
      mm += 12
    }
    if mm != 0 {
      d2.mo = d1.mo
      d2.valid_jd = false
      d2.compute_jd()
    }
    while d1.ijd < d2.ijd {
      mm -= 1
      if mm < 0 {
        mm = 11
        yy -= 1
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
    sign = '-'
    yy = d2.y - d1.y
    if yy != 0 {
      d2.y = d1.y
      d2.valid_jd = false
      d2.compute_jd()
    }
    mm = d2.mo - d1.mo
    if mm < 0 {
      yy -= 1
      mm += 12
    }
    if mm != 0 {
      d2.mo = d1.mo
      d2.valid_jd = false
      d2.compute_jd()
    }
    while d1.ijd > d2.ijd {
      mm -= 1
      if mm < 0 {
        mm = 11
        yy -= 1
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
    pad_int(yy, 4, true) +
    "-" +
    pad_int(mm, 2, true) +
    "-" +
    pad_int(d1.d - 1, 2, true) +
    " " +
    pad_int(d1.h, 2, true) +
    ":" +
    pad_int(d1.mi, 2, true) +
    ":" +
    fmt_seconds(d1.s),
  )
}

///|
/// Dispatches the date/time SQL functions; None if `name` is not one.
fn datetime_function(name : String, v : Array[Value]) -> Value? {
  let r = match name {
    "date" =>
      match date_from_args(v[:]) {
        Some(p) => {
          p.compute_ymd()
          Text(p.date_text())
        }
        None => Null
      }
    "time" =>
      match date_from_args(v[:]) {
        Some(p) => {
          p.compute_hms()
          Text(p.time_text())
        }
        None => Null
      }
    "datetime" =>
      match date_from_args(v[:]) {
        Some(p) => {
          p.compute_ymd_hms()
          Text(p.date_text() + " " + p.time_text())
        }
        None => Null
      }
    "julianday" =>
      match date_from_args(v[:]) {
        Some(p) => Real(p.ijd.to_double() / 86400000.0)
        None => Null
      }
    "unixepoch" =>
      match date_from_args(v[:]) {
        Some(p) => unix_seconds(p)
        None => Null
      }
    "strftime" => {
      if v[0] is Null {
        return Some(Null)
      }
      match date_from_args(v[1:]) {
        Some(p) => sql_strftime(v[0].to_text(), p)
        None => Null
      }
    }
    "timediff" => sql_timediff(v[0], v[1])
    _ => return None
  }
  Some(r)
}
