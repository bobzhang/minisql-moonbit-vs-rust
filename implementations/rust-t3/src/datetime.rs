// Date and time functions (a port of SQLite's date.c semantics).

use crate::value::{atof, Coll, Value};

#[derive(Debug, Clone, Copy, Default)]
struct DateTime {
    /// Julian day number times 86400000.
    ijd: i64,
    y: i32,
    m: i32,
    d: i32,
    h: i32,
    min: i32,
    s: f64,
    /// Time zone offset in minutes.
    tz: i32,
    valid_jd: bool,
    valid_ymd: bool,
    valid_hms: bool,
    raw_s: bool,
    is_error: bool,
    use_subsec: bool,
    /// Days to subtract for the 'floor' modifier.
    n_floor: i32,
}

const MAX_JD: i64 = 464269060799999;

fn valid_julian_day(ijd: i64) -> bool {
    (0..=MAX_JD).contains(&ijd)
}

/// Reads fixed-width digit fields. `spec` holds (digits, min, max, separator)
/// per field; a separator of 0 ends the list. Returns the number of fields read.
fn get_digits(z: &[u8], spec: &[(usize, i32, i32, u8)], out: &mut [i32]) -> usize {
    let mut p = 0;
    for (cnt, &(n, lo, hi, next)) in spec.iter().enumerate() {
        let mut val = 0;
        for _ in 0..n {
            match z.get(p) {
                Some(c) if c.is_ascii_digit() => {
                    val = val * 10 + (c - b'0') as i32;
                    p += 1;
                }
                _ => return cnt,
            }
        }
        if val < lo || val > hi || (next != 0 && z.get(p).copied() != Some(next)) {
            return cnt;
        }
        out[cnt] = val;
        p += 1;
    }
    spec.len()
}

fn is_space(c: u8) -> bool {
    crate::value::is_space(c)
}

fn skip_spaces(z: &[u8], mut p: usize) -> usize {
    while p < z.len() && is_space(z[p]) {
        p += 1;
    }
    p
}

impl DateTime {
    fn error(&mut self) {
        *self = DateTime { is_error: true, ..DateTime::default() };
    }

    fn compute_jd(&mut self) {
        if self.valid_jd {
            return;
        }
        let (mut y, mut m, d) = if self.valid_ymd { (self.y, self.m, self.d) } else { (2000, 1, 1) };
        if !(-4713..=9999).contains(&y) || self.raw_s {
            self.error();
            return;
        }
        if m <= 2 {
            y -= 1;
            m += 12;
        }
        let a = (y + 4800) / 100;
        let b = 38 - a + (a / 4);
        let x1 = 36525 * (y + 4716) / 100;
        let x2 = 306001 * (m + 1) / 10000;
        self.ijd = (((x1 + x2 + d + b) as f64 - 1524.5) * 86400000.0) as i64;
        self.valid_jd = true;
        if self.valid_hms {
            self.ijd += self.h as i64 * 3600000 + self.min as i64 * 60000 + (self.s * 1000.0 + 0.5) as i64;
            if self.tz != 0 {
                self.ijd -= self.tz as i64 * 60000;
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
            self.m = 1;
            self.d = 1;
        } else if !valid_julian_day(self.ijd) {
            self.error();
            return;
        } else {
            let z = ((self.ijd + 43200000) / 86400000) as i32;
            let alpha = ((z as f64 + 32044.75) / 36524.25) as i32 - 52;
            let a = z + 1 + alpha - ((alpha + 100) / 4) + 25;
            let b = a + 1524;
            let c = ((b as f64 - 122.1) / 365.25) as i32;
            let d = (36525 * (c & 32767)) / 100;
            let e = ((b - d) as f64 / 30.6001) as i32;
            let x1 = (30.6001 * e as f64) as i32;
            self.d = b - d - x1;
            self.m = if e < 14 { e - 1 } else { e - 13 };
            self.y = if self.m > 2 { c - 4716 } else { c - 4715 };
        }
        self.valid_ymd = true;
    }

    fn compute_hms(&mut self) {
        if self.valid_hms {
            return;
        }
        self.compute_jd();
        let day_ms = ((self.ijd + 43200000) % 86400000) as i32;
        self.s = (day_ms % 60000) as f64 / 1000.0;
        let day_min = day_ms / 60000;
        self.min = day_min % 60;
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

    fn compute_floor(&mut self) {
        self.n_floor = if self.d <= 28 {
            0
        } else if (1 << self.m) & 0x15aa != 0 {
            0
        } else if self.m != 2 {
            (self.d == 31) as i32
        } else if self.y % 4 != 0 || (self.y % 100 == 0 && self.y % 400 != 0) {
            self.d - 28
        } else {
            self.d - 29
        };
    }

    fn set_raw_number(&mut self, r: f64) {
        self.s = r;
        self.raw_s = true;
        if (0.0..5373484.5).contains(&r) {
            self.ijd = (r * 86400000.0 + 0.5) as i64;
            self.valid_jd = true;
        }
    }
}

/// Parses an optional time zone suffix; returns false on error.
fn parse_timezone(z: &[u8], p: &mut DateTime) -> bool {
    let mut i = skip_spaces(z, 0);
    p.tz = 0;
    let sgn = match z.get(i) {
        None => return true,
        Some(b'-') => -1,
        Some(b'+') => 1,
        Some(b'Z') | Some(b'z') => {
            i += 1;
            return skip_spaces(z, i) == z.len();
        }
        Some(_) => return false,
    };
    i += 1;
    let mut v = [0; 2];
    if get_digits(&z[i..], &[(2, 0, 14, b':'), (2, 0, 59, 0)], &mut v) != 2 {
        return false;
    }
    i += 5;
    p.tz = sgn * (v[1] + v[0] * 60);
    skip_spaces(z, i) == z.len()
}

/// Parses HH:MM[:SS[.FFF]][tz]; returns false on error.
fn parse_hms(z: &[u8], p: &mut DateTime) -> bool {
    let mut v = [0; 2];
    if get_digits(z, &[(2, 0, 24, b':'), (2, 0, 59, 0)], &mut v) != 2 {
        return false;
    }
    let mut i = 5;
    let mut s = 0;
    let mut ms = 0.0;
    if z.get(i) == Some(&b':') {
        i += 1;
        let mut sv = [0; 1];
        if get_digits(&z[i..], &[(2, 0, 59, 0)], &mut sv) != 1 {
            return false;
        }
        s = sv[0];
        i += 2;
        if z.get(i) == Some(&b'.') && z.get(i + 1).is_some_and(|c| c.is_ascii_digit()) {
            let mut scale = 1.0;
            i += 1;
            while let Some(c) = z.get(i).filter(|c| c.is_ascii_digit()) {
                ms = ms * 10.0 + (c - b'0') as f64;
                scale *= 10.0;
                i += 1;
            }
            ms /= scale;
            if ms > 0.999 {
                ms = 0.999;
            }
        }
    }
    p.valid_jd = false;
    p.raw_s = false;
    p.valid_hms = true;
    p.h = v[0];
    p.min = v[1];
    p.s = s as f64 + ms;
    parse_timezone(&z[i..], p)
}

/// Parses [-]YYYY-MM-DD[( |T)time]; returns false on error.
fn parse_ymd(z: &[u8], p: &mut DateTime) -> bool {
    let (neg, z) = if z.first() == Some(&b'-') { (true, &z[1..]) } else { (false, z) };
    let mut v = [0; 3];
    if get_digits(z, &[(4, 0, 9999, b'-'), (2, 1, 12, b'-'), (2, 1, 31, 0)], &mut v) != 3 {
        return false;
    }
    let mut i = 10;
    while i < z.len() && (is_space(z[i]) || z[i] == b'T') {
        i += 1;
    }
    if parse_hms(&z[i..], p) {
        // got the time
    } else if i == z.len() {
        p.valid_hms = false;
    } else {
        return false;
    }
    p.valid_jd = false;
    p.valid_ymd = true;
    p.y = if neg { -v[0] } else { v[0] };
    p.m = v[1];
    p.d = v[2];
    p.compute_floor();
    if p.tz != 0 {
        p.compute_jd();
    }
    true
}

/// Parses a numeric string completely (sqlite3AtoF > 0).
fn full_number(z: &[u8]) -> Option<f64> {
    let (r, rc) = atof(z);
    if rc > 0 {
        Some(r)
    } else {
        None
    }
}

fn parse_date_or_time(z: &[u8], p: &mut DateTime) -> bool {
    if parse_ymd(z, p) {
        return true;
    }
    *p = DateTime::default();
    if parse_hms(z, p) {
        return true;
    }
    *p = DateTime::default();
    if let Some(r) = full_number(z) {
        p.set_raw_number(r);
        return true;
    }
    false
}

/// (name, limit, seconds per unit)
const XFORMS: [(&str, f64, f64); 6] = [
    ("second", 4.6427e+14, 1.0),
    ("minute", 7.7379e+12, 60.0),
    ("hour", 1.2897e+11, 3600.0),
    ("day", 5373485.0, 86400.0),
    ("month", 176546.0, 2592000.0),
    ("year", 14713.0, 31536000.0),
];

fn normalize_month(p: &mut DateTime) {
    let x = if p.m > 0 { (p.m - 1) / 12 } else { (p.m - 12) / 12 };
    p.y += x;
    p.m -= x * 12;
}

/// Applies one modifier; returns false on error.
fn parse_modifier(zs: &str, p: &mut DateTime, idx: usize) -> bool {
    let z = zs.as_bytes();
    let lower = zs.to_ascii_lowercase();
    let first = match z.first() {
        Some(c) => c.to_ascii_lowercase(),
        None => return false,
    };
    match first {
        b'a' => {
            if lower == "auto" {
                if idx > 1 {
                    return false;
                }
                if !p.raw_s || p.valid_jd {
                    p.raw_s = false;
                    return true;
                }
                if p.s >= -21086676.0 * 10000.0 && p.s <= 25340230.0 * 10000.0 + 799.0 {
                    let r = p.s * 1000.0 + 210866760000000.0;
                    p.clear_ymd_hms_tz();
                    p.ijd = (r + 0.5) as i64;
                    p.valid_jd = true;
                    p.raw_s = false;
                    return true;
                }
            }
            false
        }
        b'c' => {
            if lower == "ceiling" {
                p.compute_jd();
                p.clear_ymd_hms_tz();
                p.n_floor = 0;
                return true;
            }
            false
        }
        b'f' => {
            if lower == "floor" {
                p.compute_jd();
                p.ijd -= p.n_floor as i64 * 86400000;
                p.clear_ymd_hms_tz();
                return true;
            }
            false
        }
        b'j' => {
            if lower == "julianday" {
                if idx > 1 {
                    return false;
                }
                if p.valid_jd && p.raw_s {
                    p.raw_s = false;
                    return true;
                }
            }
            false
        }
        b'l' => {
            // local time is taken to be UTC
            if lower == "localtime" {
                p.compute_jd();
                p.clear_ymd_hms_tz();
                return true;
            }
            false
        }
        b'u' => {
            if lower == "unixepoch" && p.raw_s {
                if idx > 1 {
                    return false;
                }
                let r = p.s * 1000.0 + 210866760000000.0;
                if (0.0..464269060800000.0).contains(&r) {
                    p.clear_ymd_hms_tz();
                    p.ijd = (r + 0.5) as i64;
                    p.valid_jd = true;
                    p.raw_s = false;
                    return true;
                }
                return false;
            }
            if lower == "utc" {
                p.compute_jd();
                p.clear_ymd_hms_tz();
                return true;
            }
            false
        }
        b'w' => {
            if lower.starts_with("weekday ") {
                if let Some(r) = full_number(&z[8..]) {
                    if (0.0..7.0).contains(&r) && (r as i64) as f64 == r {
                        let n = r as i64;
                        p.compute_ymd_hms();
                        p.tz = 0;
                        p.valid_jd = false;
                        p.compute_jd();
                        let mut zz = ((p.ijd + 129600000) / 86400000) % 7;
                        if zz > n {
                            zz -= 7;
                        }
                        p.ijd += (n - zz) * 86400000;
                        p.clear_ymd_hms_tz();
                        return true;
                    }
                }
            }
            false
        }
        b's' => {
            if !lower.starts_with("start of ") {
                if lower == "subsec" || lower == "subsecond" {
                    p.use_subsec = true;
                    return true;
                }
                return false;
            }
            if !p.valid_jd && !p.valid_ymd && !p.valid_hms {
                return false;
            }
            p.compute_ymd();
            p.valid_hms = true;
            p.h = 0;
            p.min = 0;
            p.s = 0.0;
            p.raw_s = false;
            p.tz = 0;
            p.valid_jd = false;
            match &lower[9..] {
                "month" => {
                    p.d = 1;
                    true
                }
                "year" => {
                    p.m = 1;
                    p.d = 1;
                    true
                }
                "day" => true,
                _ => false,
            }
        }
        b'+' | b'-' | b'0'..=b'9' => numeric_modifier(z, p),
        _ => false,
    }
}

fn numeric_modifier(z: &[u8], p: &mut DateTime) -> bool {
    let z0 = z[0];
    let mut n = 1;
    let mut tmp = [0; 3];
    while n < z.len() {
        let c = z[n];
        if c == b':' || is_space(c) {
            break;
        }
        if c == b'-' {
            if n == 5 && get_digits(&z[1..], &[(4, 0, 14712, 0)], &mut tmp) == 1 {
                break;
            }
            if n == 6 && get_digits(&z[1..], &[(5, 0, 14712, 0)], &mut tmp) == 1 {
                break;
            }
        }
        n += 1;
    }
    let r = match full_number(&z[..n]) {
        Some(r) => r,
        None => return false,
    };
    // the part holding HH:MM[:SS] for the time-offset forms
    let mut time_part: &[u8] = z;
    let mut tn = n;
    if z.get(n) == Some(&b'-') {
        // (+|-)YYYY-MM-DD[ HH:MM[:SS]]
        if z0 != b'+' && z0 != b'-' {
            return false;
        }
        let mut v = [0; 3];
        let zz = if n == 5 {
            if get_digits(&z[1..], &[(4, 0, 14712, b'-'), (2, 0, 12, b'-'), (2, 0, 31, 0)], &mut v) != 3 {
                return false;
            }
            z
        } else {
            if get_digits(&z[1..], &[(5, 0, 14712, b'-'), (2, 0, 12, b'-'), (2, 0, 31, 0)], &mut v) != 3 {
                return false;
            }
            &z[1..]
        };
        let (yy, mm, mut dd) = (v[0], v[1], v[2]);
        if mm >= 12 || dd >= 31 {
            return false;
        }
        p.compute_ymd_hms();
        p.valid_jd = false;
        if z0 == b'-' {
            p.y -= yy;
            p.m -= mm;
            dd = -dd;
        } else {
            p.y += yy;
            p.m += mm;
        }
        normalize_month(p);
        p.compute_floor();
        p.compute_jd();
        p.valid_hms = false;
        p.valid_ymd = false;
        p.ijd += dd as i64 * 86400000;
        if zz.len() <= 11 {
            return true;
        }
        let mut hm = [0; 2];
        if is_space(zz[11]) && get_digits(&zz[12..], &[(2, 0, 24, b':'), (2, 0, 59, 0)], &mut hm) == 2 {
            time_part = &zz[12..];
            tn = 2;
        } else {
            return false;
        }
    }
    if time_part.get(tn) == Some(&b':') {
        // (+|-)HH:MM[:SS[.FFF]]
        let mut z2 = time_part;
        if !z2[0].is_ascii_digit() {
            z2 = &z2[1..];
        }
        let mut tx = DateTime::default();
        if !parse_hms(z2, &mut tx) {
            return false;
        }
        tx.compute_jd();
        tx.ijd -= 43200000;
        let day = tx.ijd / 86400000;
        tx.ijd -= day * 86400000;
        if z0 == b'-' {
            tx.ijd = -tx.ijd;
        }
        p.compute_jd();
        p.clear_ymd_hms_tz();
        p.ijd += tx.ijd;
        return true;
    }
    // NNN units
    let mut i = n;
    while i < z.len() && is_space(z[i]) {
        i += 1;
    }
    let unit = &z[i..];
    let mut un = unit.len();
    if !(3..=10).contains(&un) {
        return false;
    }
    if unit[un - 1].eq_ignore_ascii_case(&b's') {
        un -= 1;
    }
    let unit = &unit[..un];
    p.compute_jd();
    let rounder = if r < 0.0 { -0.5 } else { 0.5 };
    p.n_floor = 0;
    let mut ok = false;
    for (idx, &(name, limit, xform)) in XFORMS.iter().enumerate() {
        if name.len() == un && name.as_bytes().eq_ignore_ascii_case(unit) && r > -limit && r < limit {
            let mut r = r;
            if idx == 4 {
                p.compute_ymd_hms();
                p.m += r as i32;
                normalize_month(p);
                p.compute_floor();
                p.valid_jd = false;
                r -= (r as i32) as f64;
            } else if idx == 5 {
                p.compute_ymd_hms();
                p.y += r as i32;
                p.compute_floor();
                p.valid_jd = false;
                r -= (r as i32) as f64;
            }
            p.compute_jd();
            p.ijd += (r * 1000.0 * xform + rounder) as i64;
            ok = true;
            break;
        }
    }
    p.clear_ymd_hms_tz();
    ok
}

/// Interprets a time value and modifiers (isDate). None on any error.
fn is_date(args: &[Value]) -> Option<DateTime> {
    let mut p = DateTime::default();
    if args.is_empty() {
        return None;
    }
    match &args[0] {
        Value::Integer(i) => p.set_raw_number(*i as f64),
        Value::Real(r) => p.set_raw_number(*r),
        Value::Null => return None,
        v => {
            let t = v.to_bytes()?;
            if !parse_date_or_time(&t, &mut p) {
                return None;
            }
        }
    }
    for (i, a) in args.iter().enumerate().skip(1) {
        let t = match a {
            Value::Null => return None,
            Value::Blob(b) => String::from_utf8_lossy(b).into_owned(),
            v => v.to_text()?,
        };
        if !parse_modifier(&t, &mut p, i) {
            return None;
        }
    }
    p.compute_jd();
    if p.is_error || !valid_julian_day(p.ijd) {
        return None;
    }
    if args.len() == 1 && p.valid_ymd && p.d > 28 {
        p.valid_ymd = false;
    }
    Some(p)
}

fn fmt_ymd(p: &DateTime) -> String {
    if p.y < 0 {
        format!("-{:04}-{:02}-{:02}", -p.y, p.m, p.d)
    } else {
        format!("{:04}-{:02}-{:02}", p.y, p.m, p.d)
    }
}

fn fmt_hms(p: &DateTime) -> String {
    if p.use_subsec {
        let s = (1000.0 * p.s + 0.5) as i32;
        format!("{:02}:{:02}:{:02}.{:03}", p.h, p.min, s / 1000, s % 1000)
    } else {
        format!("{:02}:{:02}:{:02}", p.h, p.min, p.s as i32)
    }
}

type R = Result<Value, String>;

pub fn f_date(a: &[Value], _: Coll) -> R {
    Ok(match is_date(a) {
        Some(mut p) => {
            p.compute_ymd();
            Value::Text(fmt_ymd(&p))
        }
        None => Value::Null,
    })
}

pub fn f_time(a: &[Value], _: Coll) -> R {
    Ok(match is_date(a) {
        Some(mut p) => {
            p.compute_hms();
            Value::Text(fmt_hms(&p))
        }
        None => Value::Null,
    })
}

pub fn f_datetime(a: &[Value], _: Coll) -> R {
    Ok(match is_date(a) {
        Some(mut p) => {
            p.compute_ymd_hms();
            Value::Text(format!("{} {}", fmt_ymd(&p), fmt_hms(&p)))
        }
        None => Value::Null,
    })
}

pub fn f_julianday(a: &[Value], _: Coll) -> R {
    Ok(match is_date(a) {
        Some(p) => Value::Real(p.ijd as f64 / 86400000.0),
        None => Value::Null,
    })
}

const UNIX_EPOCH_JD_MS: i64 = 21086676 * 10000000;

pub fn f_unixepoch(a: &[Value], _: Coll) -> R {
    Ok(match is_date(a) {
        Some(p) => {
            if p.use_subsec {
                Value::Real((p.ijd - UNIX_EPOCH_JD_MS) as f64 / 1000.0)
            } else {
                Value::Integer(p.ijd / 1000 - UNIX_EPOCH_JD_MS / 1000)
            }
        }
        None => Value::Null,
    })
}

fn days_after_jan01(p: &DateTime) -> i64 {
    let mut j = *p;
    j.valid_jd = false;
    j.m = 1;
    j.d = 1;
    j.compute_jd();
    (p.ijd - j.ijd + 43200000) / 86400000
}

fn days_after_monday(p: &DateTime) -> i64 {
    ((p.ijd + 43200000) / 86400000) % 7
}

fn days_after_sunday(p: &DateTime) -> i64 {
    ((p.ijd + 129600000) / 86400000) % 7
}

/// The Thursday of the ISO week containing `p`.
fn iso_thursday(p: &DateTime) -> DateTime {
    let mut y = *p;
    y.ijd += (3 - days_after_monday(p)) * 86400000;
    y.valid_ymd = false;
    y.compute_ymd();
    y
}

pub fn f_strftime(a: &[Value], _: Coll) -> R {
    let fmt = match &a[0] {
        Value::Null => return Ok(Value::Null),
        v => v.to_text().unwrap_or_default(),
    };
    let mut p = match is_date(&a[1..]) {
        Some(p) => p,
        None => return Ok(Value::Null),
    };
    p.compute_jd();
    p.compute_ymd_hms();
    let mut out = String::new();
    let mut chars = fmt.chars();
    while let Some(c) = chars.next() {
        if c != '%' {
            out.push(c);
            continue;
        }
        let cf = match chars.next() {
            Some(c) => c,
            None => return Ok(Value::Null),
        };
        match cf {
            'd' => out.push_str(&format!("{:02}", p.d)),
            'e' => out.push_str(&format!("{:2}", p.d)),
            'f' => {
                let s = p.s.min(59.999);
                out.push_str(&format!("{:06.3}", s));
            }
            'F' => out.push_str(&format!("{:04}-{:02}-{:02}", p.y, p.m, p.d)),
            'G' | 'g' => {
                let y = iso_thursday(&p);
                if cf == 'g' {
                    out.push_str(&format!("{:02}", y.y % 100));
                } else {
                    out.push_str(&format!("{:04}", y.y));
                }
            }
            'H' => out.push_str(&format!("{:02}", p.h)),
            'k' => out.push_str(&format!("{:2}", p.h)),
            'I' | 'l' => {
                let mut h = p.h;
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
            'j' => out.push_str(&format!("{:03}", days_after_jan01(&p) + 1)),
            'J' => {
                let s = crate::printf::format("%.16g", &[Value::Real(p.ijd as f64 / 86400000.0)]).unwrap_or_default();
                out.push_str(&s);
            }
            'm' => out.push_str(&format!("{:02}", p.m)),
            'M' => out.push_str(&format!("{:02}", p.min)),
            'p' => out.push_str(if p.h >= 12 { "PM" } else { "AM" }),
            'P' => out.push_str(if p.h >= 12 { "pm" } else { "am" }),
            'R' => out.push_str(&format!("{:02}:{:02}", p.h, p.min)),
            's' => {
                if p.use_subsec {
                    out.push_str(&format!("{:.3}", (p.ijd - UNIX_EPOCH_JD_MS) as f64 / 1000.0));
                } else {
                    out.push_str(&(p.ijd / 1000 - UNIX_EPOCH_JD_MS / 1000).to_string());
                }
            }
            'S' => out.push_str(&format!("{:02}", p.s as i32)),
            'T' => out.push_str(&format!("{:02}:{:02}:{:02}", p.h, p.min, p.s as i32)),
            'u' | 'w' => {
                let mut d = days_after_sunday(&p);
                if d == 0 && cf == 'u' {
                    d = 7;
                }
                out.push_str(&d.to_string());
            }
            'U' => out.push_str(&format!("{:02}", (days_after_jan01(&p) - days_after_sunday(&p) + 7) / 7)),
            'V' => {
                let y = iso_thursday(&p);
                out.push_str(&format!("{:02}", days_after_jan01(&y) / 7 + 1));
            }
            'W' => out.push_str(&format!("{:02}", (days_after_jan01(&p) - days_after_monday(&p) + 7) / 7)),
            'Y' => out.push_str(&format!("{:04}", p.y)),
            '%' => out.push('%'),
            _ => return Ok(Value::Null),
        }
    }
    Ok(Value::Text(out))
}

pub fn f_timediff(a: &[Value], _: Coll) -> R {
    let (mut d1, mut d2) = match (is_date(&a[0..1]), is_date(&a[1..2])) {
        (Some(x), Some(y)) => (x, y),
        _ => return Ok(Value::Null),
    };
    d1.compute_ymd_hms();
    d2.compute_ymd_hms();
    let sign;
    let mut y;
    let mut m;
    if d1.ijd >= d2.ijd {
        sign = '+';
        y = d1.y - d2.y;
        if y != 0 {
            d2.y = d1.y;
            d2.valid_jd = false;
            d2.compute_jd();
        }
        m = d1.m - d2.m;
        if m < 0 {
            y -= 1;
            m += 12;
        }
        if m != 0 {
            d2.m = d1.m;
            d2.valid_jd = false;
            d2.compute_jd();
        }
        while d1.ijd < d2.ijd {
            m -= 1;
            if m < 0 {
                m = 11;
                y -= 1;
            }
            d2.m -= 1;
            if d2.m < 1 {
                d2.m = 12;
                d2.y -= 1;
            }
            d2.valid_jd = false;
            d2.compute_jd();
        }
        d1.ijd -= d2.ijd;
    } else {
        sign = '-';
        y = d2.y - d1.y;
        if y != 0 {
            d2.y = d1.y;
            d2.valid_jd = false;
            d2.compute_jd();
        }
        m = d2.m - d1.m;
        if m < 0 {
            y -= 1;
            m += 12;
        }
        if m != 0 {
            d2.m = d1.m;
            d2.valid_jd = false;
            d2.compute_jd();
        }
        while d1.ijd > d2.ijd {
            m -= 1;
            if m < 0 {
                m = 11;
                y -= 1;
            }
            d2.m += 1;
            if d2.m > 12 {
                d2.m = 1;
                d2.y += 1;
            }
            d2.valid_jd = false;
            d2.compute_jd();
        }
        d1.ijd = d2.ijd - d1.ijd;
    }
    d1.ijd += 1486995408 * 100000;
    d1.clear_ymd_hms_tz();
    d1.valid_jd = true;
    d1.compute_ymd_hms();
    Ok(Value::Text(format!(
        "{}{:04}-{:02}-{:02} {:02}:{:02}:{:06.3}",
        sign,
        y,
        m,
        d1.d - 1,
        d1.h,
        d1.min,
        d1.s
    )))
}
