// Date and time functions, following SQLite's date.c.

use crate::printf::format_float;
use crate::value::{is_space, text_to_numeric_strict, Value};

#[derive(Clone, Copy, Debug, Default)]
struct DateTime {
    /// Julian day number times 86400000.
    i_jd: i64,
    y: i32,
    m_: i32,
    d: i32,
    h: i32,
    mi: i32,
    /// Timezone offset in minutes.
    tz: i32,
    s: f64,
    valid_jd: bool,
    valid_ymd: bool,
    valid_hms: bool,
    n_floor: i32,
    /// `s` holds a raw numeric time value.
    raw_s: bool,
    is_error: bool,
    use_subsec: bool,
}

/// Parse fixed-width digit fields: (digits, min, max, separator or 0).
/// Returns the number of fields parsed.
fn get_digits(z: &[u8], fields: &[(usize, i32, i32, u8)], out: &mut [i32]) -> usize {
    let mut p = 0;
    for (cnt, &(n, min, max, sep)) in fields.iter().enumerate() {
        let mut val = 0i32;
        for _ in 0..n {
            match z.get(p) {
                Some(c) if c.is_ascii_digit() => {
                    val = val * 10 + (c - b'0') as i32;
                    p += 1;
                }
                _ => return cnt,
            }
        }
        if val < min || val > max || (sep != 0 && z.get(p) != Some(&sep)) {
            return cnt;
        }
        out[cnt] = val;
        p += 1;
    }
    fields.len()
}

const YMD: [(usize, i32, i32, u8); 3] = [(4, 0, 14712, b'-'), (2, 1, 12, b'-'), (2, 1, 31, 0)];
const HM: [(usize, i32, i32, u8); 2] = [(2, 0, 24, b':'), (2, 0, 59, 0)];
const SEC: [(usize, i32, i32, u8); 1] = [(2, 0, 59, 0)];
const TZ: [(usize, i32, i32, u8); 2] = [(2, 0, 14, b':'), (2, 0, 59, 0)];

fn at(z: &[u8], i: usize) -> u8 {
    z.get(i).copied().unwrap_or(0)
}

/// sqlite3AtoF: the whole text (ignoring surrounding spaces) is a number.
fn atof(z: &[u8]) -> Option<f64> {
    let s = std::str::from_utf8(z).ok()?;
    match text_to_numeric_strict(s)? {
        Value::Int(i) => Some(i as f64),
        Value::Real(f) => Some(f),
        _ => None,
    }
}

impl DateTime {
    fn error(&mut self) {
        *self = DateTime { is_error: true, ..Default::default() };
    }

    /// Parse an optional timezone suffix; true on error.
    fn parse_timezone(&mut self, z: &[u8]) -> bool {
        let mut i = 0;
        while is_space(at(z, i)) {
            i += 1;
        }
        self.tz = 0;
        let c = at(z, i);
        let sgn = match c {
            b'-' => -1,
            b'+' => 1,
            b'Z' | b'z' => {
                i += 1;
                while is_space(at(z, i)) {
                    i += 1;
                }
                return at(z, i) != 0;
            }
            _ => return c != 0,
        };
        i += 1;
        let mut v = [0; 2];
        if get_digits(&z[i..], &TZ, &mut v) != 2 {
            return true;
        }
        i += 5;
        self.tz = sgn * (v[1] + v[0] * 60);
        while is_space(at(z, i)) {
            i += 1;
        }
        at(z, i) != 0
    }

    /// HH:MM[:SS[.FFF]] [timezone]; true on error.
    fn parse_hms(&mut self, z: &[u8]) -> bool {
        let mut v = [0; 2];
        if get_digits(z, &HM, &mut v) != 2 {
            return true;
        }
        let mut i = 5;
        let mut s = 0;
        let mut ms = 0.0;
        if at(z, i) == b':' {
            i += 1;
            let mut sv = [0; 1];
            if get_digits(&z[i..], &SEC, &mut sv) != 1 {
                return true;
            }
            s = sv[0];
            i += 2;
            if at(z, i) == b'.' && at(z, i + 1).is_ascii_digit() {
                let mut scale = 1.0;
                i += 1;
                while at(z, i).is_ascii_digit() {
                    ms = ms * 10.0 + (at(z, i) - b'0') as f64;
                    scale *= 10.0;
                    i += 1;
                }
                ms /= scale;
                if ms > 0.999 {
                    ms = 0.999;
                }
            }
        }
        self.valid_jd = false;
        self.raw_s = false;
        self.valid_hms = true;
        self.h = v[0];
        self.mi = v[1];
        self.s = s as f64 + ms;
        self.parse_timezone(&z[i..])
    }

    fn compute_floor(&mut self) {
        self.n_floor = if self.d <= 28 || (1 << self.m_) & 0x15aa != 0 {
            0
        } else if self.m_ != 2 {
            (self.d == 31) as i32
        } else if self.y % 4 != 0 || (self.y % 100 == 0 && self.y % 400 != 0) {
            self.d - 28
        } else {
            self.d - 29
        };
    }

    /// [-]YYYY-MM-DD [time]; true on error.
    fn parse_ymd(&mut self, z: &[u8]) -> bool {
        let (neg, z) = if at(z, 0) == b'-' { (true, &z[1..]) } else { (false, z) };
        let mut v = [0; 3];
        if get_digits(z, &YMD, &mut v) != 3 {
            return true;
        }
        let mut i = 10;
        while is_space(at(z, i)) || at(z, i) == b'T' {
            i += 1;
        }
        if !self.parse_hms(&z[i.min(z.len())..]) {
            // got the time
        } else if at(z, i) == 0 {
            self.valid_hms = false;
        } else {
            return true;
        }
        self.valid_jd = false;
        self.valid_ymd = true;
        self.y = if neg { -v[0] } else { v[0] };
        self.m_ = v[1];
        self.d = v[2];
        self.compute_floor();
        if self.tz != 0 {
            self.compute_jd();
        }
        false
    }

    fn set_raw_number(&mut self, r: f64) {
        self.s = r;
        self.raw_s = true;
        if (0.0..5373484.5).contains(&r) {
            self.i_jd = (r * 86400000.0 + 0.5) as i64;
            self.valid_jd = true;
        }
    }

    fn parse_date_or_time(&mut self, z: &[u8]) -> bool {
        if !self.parse_ymd(z) {
            return false;
        }
        *self = DateTime::default();
        if !self.parse_hms(z) {
            return false;
        }
        *self = DateTime::default();
        if let Some(r) = atof(z) {
            self.set_raw_number(r);
            return false;
        }
        true
    }

    fn compute_jd(&mut self) {
        if self.valid_jd {
            return;
        }
        let (mut y, mut m, d) = if self.valid_ymd { (self.y, self.m_, self.d) } else { (2000, 1, 1) };
        if !(-4713..=9999).contains(&y) || self.raw_s {
            self.error();
            return;
        }
        if m <= 2 {
            y -= 1;
            m += 12;
        }
        let a = y / 100;
        let b = 2 - a + (a / 4);
        let x1 = 36525 * (y + 4716) / 100;
        let x2 = 306001 * (m + 1) / 10000;
        self.i_jd = (((x1 + x2 + d + b) as f64 - 1524.5) * 86400000.0) as i64;
        self.valid_jd = true;
        if self.valid_hms {
            self.i_jd += self.h as i64 * 3600000 + self.mi as i64 * 60000 + (self.s * 1000.0 + 0.5) as i64;
            if self.tz != 0 {
                self.i_jd -= self.tz as i64 * 60000;
                self.valid_ymd = false;
                self.valid_hms = false;
                self.tz = 0;
            }
        }
    }

    fn compute_ymd(&mut self) {
        if self.valid_ymd {
            return;
        }
        if !self.valid_jd {
            self.y = 2000;
            self.m_ = 1;
            self.d = 1;
        } else if !valid_julian_day(self.i_jd) {
            self.error();
            return;
        } else {
            let z = ((self.i_jd + 43200000) / 86400000) as i32;
            let alpha = ((z as f64 + 32044.75) / 36524.25) as i32 - 52;
            let a = z + 1 + alpha - ((alpha + 100) / 4) + 25;
            let b = a + 1524;
            let c = ((b as f64 - 122.1) / 365.25) as i32;
            let d = (36525 * (c & 32767)) / 100;
            let e = ((b - d) as f64 / 30.6001) as i32;
            let x1 = (30.6001 * e as f64) as i32;
            self.d = b - d - x1;
            self.m_ = if e < 14 { e - 1 } else { e - 13 };
            self.y = if self.m_ > 2 { c - 4716 } else { c - 4715 };
        }
        self.valid_ymd = true;
    }

    fn compute_hms(&mut self) {
        if self.valid_hms {
            return;
        }
        self.compute_jd();
        let day_ms = ((self.i_jd + 43200000) % 86400000) as i32;
        self.s = (day_ms % 60000) as f64 / 1000.0;
        let day_min = day_ms / 60000;
        self.mi = day_min % 60;
        self.h = day_min / 60;
        self.raw_s = false;
        self.valid_hms = true;
    }

    fn compute_ymd_hms(&mut self) {
        self.compute_ymd();
        self.compute_hms();
    }

    fn clear_ymd_hms_tz(&mut self) {
        self.valid_ymd = false;
        self.valid_hms = false;
        self.tz = 0;
    }

    /// Apply one modifier; true on error. `idx` is the argument position.
    fn parse_modifier(&mut self, zs: &str, idx: usize) -> bool {
        let z = zs.as_bytes();
        let lower = zs.to_ascii_lowercase();
        match at(z, 0).to_ascii_lowercase() {
            b'a' => {
                if lower == "auto" {
                    if idx > 1 {
                        return true;
                    }
                    if !self.raw_s || self.valid_jd {
                        self.raw_s = false;
                        return false;
                    } else if self.s >= -210866760000.0 && self.s <= 253402300799.0 {
                        let r = self.s * 1000.0 + 210866760000000.0;
                        self.clear_ymd_hms_tz();
                        self.i_jd = (r + 0.5) as i64;
                        self.valid_jd = true;
                        self.raw_s = false;
                        return false;
                    }
                }
                true
            }
            b'c' => {
                if lower == "ceiling" {
                    self.compute_jd();
                    self.clear_ymd_hms_tz();
                    self.n_floor = 0;
                    return false;
                }
                true
            }
            b'f' => {
                if lower == "floor" {
                    self.compute_jd();
                    self.i_jd -= self.n_floor as i64 * 86400000;
                    self.clear_ymd_hms_tz();
                    return false;
                }
                true
            }
            b'j' => {
                if lower == "julianday" {
                    if idx > 1 {
                        return true;
                    }
                    if self.valid_jd && self.raw_s {
                        self.raw_s = false;
                        return false;
                    }
                }
                true
            }
            b'u' => {
                if lower == "unixepoch" && self.raw_s {
                    if idx > 1 {
                        return true;
                    }
                    let r = self.s * 1000.0 + 210866760000000.0;
                    if (0.0..464269060800000.0).contains(&r) {
                        self.clear_ymd_hms_tz();
                        self.i_jd = (r + 0.5) as i64;
                        self.valid_jd = true;
                        self.raw_s = false;
                        return false;
                    }
                }
                // 'utc' is not supported (no time zone database).
                true
            }
            b'w' => {
                if lower.starts_with("weekday ") {
                    if let Some(r) = atof(&z[8..]) {
                        if (0.0..7.0).contains(&r) && (r as i64) as f64 == r {
                            let n = r as i64;
                            self.compute_ymd_hms();
                            self.tz = 0;
                            self.valid_jd = false;
                            self.compute_jd();
                            let mut zz = ((self.i_jd + 129600000) / 86400000) % 7;
                            if zz > n {
                                zz -= 7;
                            }
                            self.i_jd += (n - zz) * 86400000;
                            self.clear_ymd_hms_tz();
                            return false;
                        }
                    }
                }
                true
            }
            b's' => {
                if !lower.starts_with("start of ") {
                    if lower == "subsec" || lower == "subsecond" {
                        self.use_subsec = true;
                        return false;
                    }
                    return true;
                }
                if !self.valid_jd && !self.valid_ymd && !self.valid_hms {
                    return true;
                }
                self.compute_ymd();
                self.valid_hms = true;
                self.h = 0;
                self.mi = 0;
                self.s = 0.0;
                self.raw_s = false;
                self.tz = 0;
                self.valid_jd = false;
                match &lower[9..] {
                    "month" => {
                        self.d = 1;
                        false
                    }
                    "year" => {
                        self.m_ = 1;
                        self.d = 1;
                        false
                    }
                    "day" => false,
                    _ => true,
                }
            }
            b'+' | b'-' | b'0'..=b'9' => self.numeric_modifier(z),
            _ => true,
        }
    }

    fn numeric_modifier(&mut self, zfull: &[u8]) -> bool {
        let mut z = zfull;
        let z0 = at(z, 0);
        let mut n = 1;
        while n < z.len() {
            let c = z[n];
            if c == b':' || is_space(c) {
                break;
            }
            if c == b'-' {
                let mut y = [0; 1];
                if n == 5 && get_digits(&z[1..], &[(4, 0, 14712, 0)], &mut y) == 1 {
                    break;
                }
                if n == 6 && get_digits(&z[1..], &[(5, 0, 14712, 0)], &mut y) == 1 {
                    break;
                }
            }
            n += 1;
        }
        let Some(mut r) = atof(&z[..n]) else { return true };
        let mut z2: &[u8] = z;
        if at(z, n) == b'-' {
            // (+|-)YYYY-MM-DD[ HH:MM[:SS]]
            if z0 != b'+' && z0 != b'-' {
                return true;
            }
            let mut v = [0; 3];
            let spec_y = if n == 5 { 4 } else { 5 };
            let spec = [(spec_y, 0, 14712, b'-'), (2, 0, 12, b'-'), (2, 0, 31, 0)];
            if get_digits(&z[1..], &spec, &mut v) != 3 {
                return true;
            }
            if n == 6 {
                z = &z[1..];
            }
            let (yy, mm, mut dd) = (v[0], v[1], v[2]);
            if mm >= 12 || dd >= 31 {
                return true;
            }
            self.compute_ymd_hms();
            self.valid_jd = false;
            if z0 == b'-' {
                self.y -= yy;
                self.m_ -= mm;
                dd = -dd;
            } else {
                self.y += yy;
                self.m_ += mm;
            }
            let x = if self.m_ > 0 { (self.m_ - 1) / 12 } else { (self.m_ - 12) / 12 };
            self.y += x;
            self.m_ -= x * 12;
            self.compute_floor();
            self.compute_jd();
            self.valid_hms = false;
            self.valid_ymd = false;
            self.i_jd += dd as i64 * 86400000;
            if at(z, 11) == 0 {
                return false;
            }
            let mut hm = [0; 2];
            if is_space(at(z, 11)) && z.len() > 12 && get_digits(&z[12..], &HM, &mut hm) == 2 {
                z2 = &z[12..];
                n = 2;
            } else {
                return true;
            }
        }
        if at(z2, n) == b':' {
            // (+|-)HH:MM[:SS[.FFF]]
            let mut t = z2;
            if !at(t, 0).is_ascii_digit() {
                t = &t[1..];
            }
            let mut tx = DateTime::default();
            if tx.parse_hms(t) {
                return true;
            }
            tx.compute_jd();
            tx.i_jd -= 43200000;
            let day = tx.i_jd / 86400000;
            tx.i_jd -= day * 86400000;
            if z0 == b'-' {
                tx.i_jd = -tx.i_jd;
            }
            self.compute_jd();
            self.clear_ymd_hms_tz();
            self.i_jd += tx.i_jd;
            return false;
        }

        // "+NNN units"
        let mut rest = &z[n..];
        while !rest.is_empty() && is_space(rest[0]) {
            rest = &rest[1..];
        }
        let mut len = rest.len();
        if !(3..=10).contains(&len) {
            return true;
        }
        if rest[len - 1].to_ascii_lowercase() == b's' {
            len -= 1;
        }
        let unit = String::from_utf8_lossy(&rest[..len]).to_ascii_lowercase();
        self.compute_jd();
        let rounder = if r < 0.0 { -0.5 } else { 0.5 };
        self.n_floor = 0;
        const XFORM: [(&str, f32, f32); 6] = [
            ("second", 4.6427e+14, 1.0),
            ("minute", 7.7379e+12, 60.0),
            ("hour", 1.2897e+11, 3600.0),
            ("day", 5373485.0, 86400.0),
            ("month", 176546.0, 2592000.0),
            ("year", 14713.0, 31536000.0),
        ];
        let mut rc = true;
        for (i, (name, limit, xform)) in XFORM.iter().enumerate() {
            let limit = *limit as f64;
            if *name == unit && r > -limit && r < limit {
                match i {
                    4 => {
                        self.compute_ymd_hms();
                        self.m_ += r as i32;
                        let x = if self.m_ > 0 { (self.m_ - 1) / 12 } else { (self.m_ - 12) / 12 };
                        self.y += x;
                        self.m_ -= x * 12;
                        self.compute_floor();
                        self.valid_jd = false;
                        r -= (r as i32) as f64;
                    }
                    5 => {
                        self.compute_ymd_hms();
                        self.y += r as i32;
                        self.compute_floor();
                        self.valid_jd = false;
                        r -= (r as i32) as f64;
                    }
                    _ => {}
                }
                self.compute_jd();
                self.i_jd += (r * 1000.0 * *xform as f64 + rounder) as i64;
                rc = false;
                break;
            }
        }
        self.clear_ymd_hms_tz();
        rc
    }
}

fn valid_julian_day(i_jd: i64) -> bool {
    (0..=464269060799999).contains(&i_jd)
}

/// Parse a time value and modifiers (SQLite's isDate). None on error.
fn is_date(args: &[Value]) -> Option<DateTime> {
    let mut p = DateTime::default();
    let first = args.first()?;
    match first {
        Value::Null => return None,
        Value::Int(_) | Value::Real(_) => p.set_raw_number(first.to_f64()),
        v => {
            let t = v.to_text()?;
            if p.parse_date_or_time(t.as_bytes()) {
                return None;
            }
        }
    }
    for (i, a) in args.iter().enumerate().skip(1) {
        let m = a.to_text()?;
        if p.parse_modifier(&m, i) {
            return None;
        }
    }
    p.compute_jd();
    if p.is_error || !valid_julian_day(p.i_jd) {
        return None;
    }
    if args.len() == 1 && p.valid_ymd && p.d > 28 {
        p.valid_ymd = false;
    }
    Some(p)
}

fn fmt_date(p: &DateTime) -> String {
    if p.y < 0 {
        format!("-{:04}-{:02}-{:02}", -p.y, p.m_, p.d)
    } else {
        format!("{:04}-{:02}-{:02}", p.y, p.m_, p.d)
    }
}

fn fmt_time(p: &DateTime) -> String {
    if p.use_subsec {
        let s = (1000.0 * p.s + 0.5) as i32;
        format!("{:02}:{:02}:{:02}.{:03}", p.h, p.mi, s / 1000, s % 1000)
    } else {
        format!("{:02}:{:02}:{:02}", p.h, p.mi, p.s as i32)
    }
}

fn days_after_jan01(p: &DateTime) -> i64 {
    let mut j = *p;
    j.valid_jd = false;
    j.m_ = 1;
    j.d = 1;
    j.compute_jd();
    (p.i_jd - j.i_jd + 43200000) / 86400000
}

fn days_after_monday(p: &DateTime) -> i64 {
    ((p.i_jd + 43200000) / 86400000) % 7
}

fn days_after_sunday(p: &DateTime) -> i64 {
    ((p.i_jd + 129600000) / 86400000) % 7
}

/// The Thursday of the ISO week containing `p`.
fn iso_thursday(p: &DateTime) -> DateTime {
    let mut y = *p;
    y.i_jd += (3 - days_after_monday(p)) * 86400000;
    y.valid_ymd = false;
    y.compute_ymd();
    y
}

fn strftime(fmt: &str, mut x: DateTime) -> Option<String> {
    x.compute_jd();
    x.compute_ymd_hms();
    let mut out = String::new();
    let mut chars = fmt.chars();
    while let Some(c) = chars.next() {
        if c != '%' {
            out.push(c);
            continue;
        }
        let cf = chars.next()?;
        match cf {
            'd' => out.push_str(&format!("{:02}", x.d)),
            'e' => out.push_str(&format!("{:2}", x.d)),
            'f' => {
                let s = x.s.min(59.999);
                out.push_str(&format!("{:06.3}", s));
            }
            'F' => out.push_str(&format!("{:04}-{:02}-{:02}", x.y, x.m_, x.d)),
            'G' => out.push_str(&format!("{:04}", iso_thursday(&x).y)),
            'g' => out.push_str(&format!("{:02}", iso_thursday(&x).y % 100)),
            'H' => out.push_str(&format!("{:02}", x.h)),
            'k' => out.push_str(&format!("{:2}", x.h)),
            'I' | 'l' => {
                let mut h = x.h;
                if h > 12 {
                    h -= 12;
                }
                if h == 0 {
                    h = 12;
                }
                if cf == 'I' {
                    out.push_str(&format!("{:02}", h));
                } else {
                    out.push_str(&format!("{:2}", h));
                }
            }
            'j' => out.push_str(&format!("{:03}", days_after_jan01(&x) + 1)),
            'J' => out.push_str(&format_float(x.i_jd as f64 / 86400000.0, b'g', 16, false)),
            'm' => out.push_str(&format!("{:02}", x.m_)),
            'M' => out.push_str(&format!("{:02}", x.mi)),
            'p' => out.push_str(if x.h >= 12 { "PM" } else { "AM" }),
            'P' => out.push_str(if x.h >= 12 { "pm" } else { "am" }),
            'R' => out.push_str(&format!("{:02}:{:02}", x.h, x.mi)),
            's' => {
                if x.use_subsec {
                    let v = (x.i_jd - 210866760000000) as f64 / 1000.0;
                    out.push_str(&format_float(v, b'f', 3, false));
                } else {
                    out.push_str(&(x.i_jd / 1000 - 210866760000).to_string());
                }
            }
            'S' => out.push_str(&format!("{:02}", x.s as i32)),
            'T' => out.push_str(&format!("{:02}:{:02}:{:02}", x.h, x.mi, x.s as i32)),
            'u' | 'w' => {
                let mut d = days_after_sunday(&x);
                if d == 0 && cf == 'u' {
                    d = 7;
                }
                out.push_str(&d.to_string());
            }
            'U' => out.push_str(&format!("{:02}", (days_after_jan01(&x) - days_after_sunday(&x) + 7) / 7)),
            'V' => out.push_str(&format!("{:02}", days_after_jan01(&iso_thursday(&x)) / 7 + 1)),
            'W' => out.push_str(&format!("{:02}", (days_after_jan01(&x) - days_after_monday(&x) + 7) / 7)),
            'Y' => out.push_str(&format!("{:04}", x.y)),
            'y' => out.push_str(&format!("{:02}", x.y % 100)),
            '%' => out.push('%'),
            _ => return None,
        }
    }
    Some(out)
}

fn timediff(a: &Value, b: &Value) -> Option<String> {
    let mut d1 = is_date(std::slice::from_ref(a))?;
    let mut d2 = is_date(std::slice::from_ref(b))?;
    d1.compute_ymd_hms();
    d2.compute_ymd_hms();
    let sign;
    let mut y;
    let mut m;
    if d1.i_jd >= d2.i_jd {
        sign = '+';
        y = d1.y - d2.y;
        if y != 0 {
            d2.y = d1.y;
            d2.valid_jd = false;
            d2.compute_jd();
        }
        m = d1.m_ - d2.m_;
        if m < 0 {
            y -= 1;
            m += 12;
        }
        if m != 0 {
            d2.m_ = d1.m_;
            d2.valid_jd = false;
            d2.compute_jd();
        }
        while d1.i_jd < d2.i_jd {
            m -= 1;
            if m < 0 {
                m = 11;
                y -= 1;
            }
            d2.m_ -= 1;
            if d2.m_ < 1 {
                d2.m_ = 12;
                d2.y -= 1;
            }
            d2.valid_jd = false;
            d2.compute_jd();
        }
        d1.i_jd -= d2.i_jd;
    } else {
        sign = '-';
        y = d2.y - d1.y;
        if y != 0 {
            d2.y = d1.y;
            d2.valid_jd = false;
            d2.compute_jd();
        }
        m = d2.m_ - d1.m_;
        if m < 0 {
            y -= 1;
            m += 12;
        }
        if m != 0 {
            d2.m_ = d1.m_;
            d2.valid_jd = false;
            d2.compute_jd();
        }
        while d1.i_jd > d2.i_jd {
            m -= 1;
            if m < 0 {
                m = 11;
                y -= 1;
            }
            d2.m_ += 1;
            if d2.m_ > 12 {
                d2.m_ = 1;
                d2.y += 1;
            }
            d2.valid_jd = false;
            d2.compute_jd();
        }
        d1.i_jd = d2.i_jd - d1.i_jd;
    }
    d1.i_jd += 1486995408i64 * 100000;
    d1.clear_ymd_hms_tz();
    d1.compute_ymd_hms();
    Some(format!("{}{:04}-{:02}-{:02} {:02}:{:02}:{:06.3}", sign, y, m, d1.d - 1, d1.h, d1.mi, d1.s))
}

/// Evaluate a date/time function; None if `name` is not one.
pub fn call(name: &str, args: &[Value]) -> Option<Value> {
    let text = |s: Option<String>| s.map(Value::Text).unwrap_or(Value::Null);
    Some(match name {
        "date" => text(is_date(args).map(|mut p| {
            p.compute_ymd();
            fmt_date(&p)
        })),
        "time" => text(is_date(args).map(|mut p| {
            p.compute_hms();
            fmt_time(&p)
        })),
        "datetime" => text(is_date(args).map(|mut p| {
            p.compute_ymd_hms();
            format!("{} {}", fmt_date(&p), fmt_time(&p))
        })),
        "julianday" => match is_date(args) {
            Some(p) => Value::Real(p.i_jd as f64 / 86400000.0),
            None => Value::Null,
        },
        "unixepoch" => match is_date(args) {
            Some(p) => {
                if p.use_subsec {
                    Value::Real((p.i_jd - 210866760000000) as f64 / 1000.0)
                } else {
                    Value::Int(p.i_jd / 1000 - 210866760000)
                }
            }
            None => Value::Null,
        },
        "strftime" => {
            let Some(fmt) = args[0].to_text() else { return Some(Value::Null) };
            text(is_date(&args[1..]).and_then(|p| strftime(&fmt, p)))
        }
        "timediff" => text(timediff(&args[0], &args[1])),
        _ => return None,
    })
}
