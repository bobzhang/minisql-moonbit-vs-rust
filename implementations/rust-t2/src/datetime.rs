// Date and time functions (a port of SQLite's date.c semantics).

use crate::value::{atof, Coll, Value};

#[derive(Debug, Clone, Copy, Default)]
struct DateTime {
    /// Julian day number times 86400000.
    ijd: i64,
    y: i32,
    mo: i32,
    d: i32,
    h: i32,
    mi: i32,
    /// Timezone offset in minutes.
    tz: i32,
    s: f64,
    valid_jd: bool,
    valid_ymd: bool,
    valid_hms: bool,
    valid_tz: bool,
    /// Days by which a YYYY-MM-DD overflowed its month ('floor' undoes it).
    n_floor: i32,
    raw_s: bool,
    is_error: bool,
    use_subsec: bool,
}

fn is_space(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | b'\r' | 0x0b | 0x0c)
}

/// Byte at `i`, or 0 past the end (mimics a NUL-terminated C string).
fn at(z: &[u8], i: usize) -> u8 {
    z.get(i).copied().unwrap_or(0)
}

/// SQLite's getDigits: `fmt` is a sequence of 4-char specs
/// (digit count, minimum, maximum code a..f, following separator or 0).
fn get_digits(z: &[u8], fmt: &str, out: &mut [i32]) -> usize {
    const MX: [i32; 6] = [12, 14, 24, 31, 59, 14712];
    let f = fmt.as_bytes();
    let mut pos = 0;
    let mut cnt = 0;
    let mut k = 0;
    loop {
        let n = (f[k] - b'0') as usize;
        let min = (f[k + 1] - b'0') as i32;
        let max = MX[(f[k + 2] - b'a') as usize];
        let next = if k + 3 < f.len() { f[k + 3] } else { 0 };
        let mut val = 0i32;
        for _ in 0..n {
            let c = at(z, pos);
            if !c.is_ascii_digit() {
                return cnt;
            }
            val = val * 10 + (c - b'0') as i32;
            pos += 1;
        }
        if val < min || val > max || (next != 0 && next != at(z, pos)) {
            return cnt;
        }
        out[cnt] = val;
        pos += 1;
        cnt += 1;
        k += 4;
        if next == 0 {
            return cnt;
        }
    }
}

/// Parse an optional timezone suffix; true on error.
fn parse_timezone(z: &[u8], p: &mut DateTime) -> bool {
    let mut i = 0;
    while is_space(at(z, i)) {
        i += 1;
    }
    p.tz = 0;
    let c = at(z, i);
    let sgn;
    if c == b'-' {
        sgn = -1;
    } else if c == b'+' {
        sgn = 1;
    } else if c == b'Z' || c == b'z' {
        i += 1;
        while is_space(at(z, i)) {
            i += 1;
        }
        return at(z, i) != 0;
    } else {
        return c != 0;
    }
    i += 1;
    let mut v = [0; 2];
    if get_digits(&z[i.min(z.len())..], "20b:20e", &mut v) != 2 {
        return true;
    }
    i += 5;
    p.tz = sgn * (v[1] + v[0] * 60);
    while is_space(at(z, i)) {
        i += 1;
    }
    at(z, i) != 0
}

/// Parse HH:MM[:SS[.FFF]] with optional timezone; true on error.
fn parse_hms(z: &[u8], p: &mut DateTime) -> bool {
    let mut v = [0; 2];
    if get_digits(z, "20c:20e", &mut v) != 2 {
        return true;
    }
    let (h, m) = (v[0], v[1]);
    let mut i = 5;
    let mut s = 0;
    let mut ms = 0.0;
    if at(z, i) == b':' {
        i += 1;
        let mut sv = [0; 1];
        if get_digits(&z[i.min(z.len())..], "20e", &mut sv) != 1 {
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
    p.valid_jd = false;
    p.raw_s = false;
    p.valid_hms = true;
    p.h = h;
    p.mi = m;
    p.s = s as f64 + ms;
    if parse_timezone(&z[i.min(z.len())..], p) {
        return true;
    }
    p.valid_tz = p.tz != 0;
    false
}

fn datetime_error(p: &mut DateTime) {
    *p = DateTime::default();
    p.is_error = true;
}

fn compute_jd(p: &mut DateTime) {
    if p.valid_jd {
        return;
    }
    let (mut y, mut m, d) = if p.valid_ymd {
        (p.y, p.mo, p.d)
    } else {
        (2000, 1, 1)
    };
    if !(-4713..=9999).contains(&y) || p.raw_s {
        datetime_error(p);
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
    p.ijd = (((x1 + x2 + d + b) as f64 - 1524.5) * 86400000.0) as i64;
    p.valid_jd = true;
    if p.valid_hms {
        p.ijd += (p.h * 3600000 + p.mi * 60000) as i64 + (p.s * 1000.0 + 0.5) as i64;
        if p.tz != 0 {
            p.ijd -= p.tz as i64 * 60000;
            p.valid_ymd = false;
            p.valid_hms = false;
            p.tz = 0;
        }
    }
}

fn compute_floor(p: &mut DateTime) {
    if p.d <= 28 {
        p.n_floor = 0;
    } else if (1 << p.mo) & 0x15aa != 0 {
        p.n_floor = 0;
    } else if p.mo != 2 {
        p.n_floor = (p.d == 31) as i32;
    } else if p.y % 4 != 0 || (p.y % 100 == 0 && p.y % 400 != 0) {
        p.n_floor = p.d - 28;
    } else {
        p.n_floor = p.d - 29;
    }
}

/// Parse [-]YYYY-MM-DD[( |T)HH:MM[:SS[.FFF]][tz]]; true on error.
fn parse_ymd(z: &[u8], p: &mut DateTime) -> bool {
    let mut i = 0;
    let neg = at(z, 0) == b'-';
    if neg {
        i = 1;
    }
    let mut v = [0; 3];
    if get_digits(&z[i..], "40f-21a-21d", &mut v) != 3 {
        return true;
    }
    i += 10;
    while is_space(at(z, i)) || at(z, i) == b'T' {
        i += 1;
    }
    let rest = &z[i.min(z.len())..];
    if !parse_hms(rest, p) {
        // got the time
    } else if rest.is_empty() {
        p.valid_hms = false;
    } else {
        return true;
    }
    p.valid_jd = false;
    p.valid_ymd = true;
    p.y = if neg { -v[0] } else { v[0] };
    p.mo = v[1];
    p.d = v[2];
    compute_floor(p);
    if p.valid_tz {
        compute_jd(p);
    }
    false
}

fn set_raw_number(p: &mut DateTime, r: f64) {
    p.s = r;
    p.raw_s = true;
    if (0.0..5373484.5).contains(&r) {
        p.ijd = (r * 86400000.0 + 0.5) as i64;
        p.valid_jd = true;
    }
}

fn now_ms() -> i64 {
    let d = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    210866760000000 + d.as_millis() as i64
}

fn set_now(p: &mut DateTime) {
    p.ijd = now_ms();
    p.valid_jd = true;
}

/// true on error.
fn parse_date_or_time(z: &[u8], p: &mut DateTime) -> bool {
    if !parse_ymd(z, p) {
        return false;
    }
    if !parse_hms(z, p) {
        return false;
    }
    if z.eq_ignore_ascii_case(b"now") {
        set_now(p);
        return false;
    }
    let (rc, r) = atof(z);
    if rc > 0 {
        set_raw_number(p, r);
        return false;
    }
    if z.eq_ignore_ascii_case(b"subsec") || z.eq_ignore_ascii_case(b"subsecond") {
        p.use_subsec = true;
        set_now(p);
        return false;
    }
    true
}

fn valid_julian_day(ijd: i64) -> bool {
    (0..=464269060799999).contains(&ijd)
}

fn compute_ymd(p: &mut DateTime) {
    if p.valid_ymd {
        return;
    }
    if !p.valid_jd {
        p.y = 2000;
        p.mo = 1;
        p.d = 1;
    } else if !valid_julian_day(p.ijd) {
        datetime_error(p);
        return;
    } else {
        let z = ((p.ijd + 43200000) / 86400000) as i32;
        let alpha = ((z as f64 + 32044.75) / 36524.25) as i32 - 52;
        let a = z + 1 + alpha - ((alpha + 100) / 4) + 25;
        let b = a + 1524;
        let c = ((b as f64 - 122.1) / 365.25) as i32;
        let d = (36525 * (c & 32767)) / 100;
        let e = ((b - d) as f64 / 30.6001) as i32;
        let x1 = (30.6001 * e as f64) as i32;
        p.d = b - d - x1;
        p.mo = if e < 14 { e - 1 } else { e - 13 };
        p.y = if p.mo > 2 { c - 4716 } else { c - 4715 };
    }
    p.valid_ymd = true;
}

fn compute_hms(p: &mut DateTime) {
    if p.valid_hms {
        return;
    }
    compute_jd(p);
    let day_ms = ((p.ijd + 43200000) % 86400000) as i32;
    p.s = (day_ms % 60000) as f64 / 1000.0;
    let day_min = day_ms / 60000;
    p.mi = day_min % 60;
    p.h = day_min / 60;
    p.raw_s = false;
    p.valid_hms = true;
}

fn compute_ymd_hms(p: &mut DateTime) {
    compute_ymd(p);
    compute_hms(p);
}

fn clear_ymd_hms_tz(p: &mut DateTime) {
    p.valid_ymd = false;
    p.valid_hms = false;
    p.tz = 0;
}

fn normalize_month(p: &mut DateTime) {
    let x = if p.mo > 0 {
        (p.mo - 1) / 12
    } else {
        (p.mo - 12) / 12
    };
    p.y += x;
    p.mo -= x * 12;
}

/// Apply one modifier; true on error.
fn parse_modifier(zs: &str, p: &mut DateTime, idx: usize) -> bool {
    let z = zs.as_bytes();
    let lower = zs.to_ascii_lowercase();
    match at(z, 0).to_ascii_lowercase() {
        b'a' => {
            if lower == "auto" {
                if idx > 1 {
                    return true;
                }
                if !p.raw_s || p.valid_jd {
                    p.raw_s = false;
                    return false;
                }
                if p.s >= -21086676.0 * 10000.0 && p.s <= 25340230.0 * 10000.0 + 799.0 {
                    let r = p.s * 1000.0 + 210866760000000.0;
                    clear_ymd_hms_tz(p);
                    p.ijd = (r + 0.5) as i64;
                    p.valid_jd = true;
                    p.raw_s = false;
                    return false;
                }
            }
            true
        }
        b'c' => {
            if lower == "ceiling" {
                compute_jd(p);
                clear_ymd_hms_tz(p);
                p.n_floor = 0;
                return false;
            }
            true
        }
        b'f' => {
            if lower == "floor" {
                compute_jd(p);
                p.ijd -= p.n_floor as i64 * 86400000;
                clear_ymd_hms_tz(p);
                return false;
            }
            true
        }
        b'j' => {
            if lower == "julianday" {
                if idx > 1 {
                    return true;
                }
                if p.valid_jd && p.raw_s {
                    p.raw_s = false;
                    return false;
                }
            }
            true
        }
        b'l' => {
            // localtime: treated as UTC.
            if lower == "localtime" {
                compute_jd(p);
                clear_ymd_hms_tz(p);
                return false;
            }
            true
        }
        b'u' => {
            if lower == "unixepoch" && p.raw_s {
                if idx > 1 {
                    return true;
                }
                let r = p.s * 1000.0 + 210866760000000.0;
                if (0.0..464269060800000.0).contains(&r) {
                    clear_ymd_hms_tz(p);
                    p.ijd = (r + 0.5) as i64;
                    p.valid_jd = true;
                    p.raw_s = false;
                    return false;
                }
            } else if lower == "utc" {
                compute_jd(p);
                clear_ymd_hms_tz(p);
                return false;
            }
            true
        }
        b'w' => {
            if lower.starts_with("weekday ") {
                let (rc, r) = atof(&z[8..]);
                if rc > 0 && (0.0..7.0).contains(&r) && (r as i64) as f64 == r {
                    let n = r as i64;
                    compute_ymd_hms(p);
                    p.tz = 0;
                    p.valid_jd = false;
                    compute_jd(p);
                    let mut zz = ((p.ijd + 129600000) / 86400000) % 7;
                    if zz > n {
                        zz -= 7;
                    }
                    p.ijd += (n - zz) * 86400000;
                    clear_ymd_hms_tz(p);
                    return false;
                }
            }
            true
        }
        b's' => {
            if !lower.starts_with("start of ") {
                if lower == "subsec" || lower == "subsecond" {
                    p.use_subsec = true;
                    return false;
                }
                return true;
            }
            if !p.valid_jd && !p.valid_ymd && !p.valid_hms {
                return true;
            }
            compute_ymd(p);
            p.valid_hms = true;
            p.h = 0;
            p.mi = 0;
            p.s = 0.0;
            p.raw_s = false;
            p.tz = 0;
            p.valid_jd = false;
            match &lower[9..] {
                "month" => {
                    p.d = 1;
                    false
                }
                "year" => {
                    p.mo = 1;
                    p.d = 1;
                    false
                }
                "day" => false,
                _ => true,
            }
        }
        b'+' | b'-' | b'0'..=b'9' => numeric_modifier(z, p),
        _ => true,
    }
}

fn numeric_modifier(z: &[u8], p: &mut DateTime) -> bool {
    let z0 = z[0];
    let mut n = 1;
    let mut yv = [0; 3];
    while n < z.len() {
        let c = z[n];
        if c == b':' || is_space(c) {
            break;
        }
        if c == b'-' {
            if n == 5 && get_digits(&z[1..], "40f", &mut yv) == 1 {
                break;
            }
            if n == 6 && get_digits(&z[1..], "50f", &mut yv) == 1 {
                break;
            }
        }
        n += 1;
    }
    let (rc, mut r) = atof(&z[..n]);
    if rc <= 0 {
        return true;
    }
    let mut z2: &[u8] = z;
    if at(z, n) == b'-' {
        // (+|-)YYYY-MM-DD[ HH:MM[:SS]]
        if z0 != b'+' && z0 != b'-' {
            return true;
        }
        let mut v = [0; 3];
        let mut zz = z;
        if n == 5 {
            if get_digits(&z[1..], "40f-20a-20d", &mut v) != 3 {
                return true;
            }
        } else {
            if get_digits(&z[1..], "50f-20a-20d", &mut v) != 3 {
                return true;
            }
            zz = &z[1..];
        }
        let (y, m, mut d) = (v[0], v[1], v[2]);
        if m >= 12 || d >= 31 {
            return true;
        }
        compute_ymd_hms(p);
        p.valid_jd = false;
        if z0 == b'-' {
            p.y -= y;
            p.mo -= m;
            d = -d;
        } else {
            p.y += y;
            p.mo += m;
        }
        normalize_month(p);
        compute_floor(p);
        compute_jd(p);
        p.valid_hms = false;
        p.valid_ymd = false;
        p.ijd += d as i64 * 86400000;
        if at(zz, 11) == 0 {
            return false;
        }
        let mut hm = [0; 2];
        if is_space(at(zz, 11)) && zz.len() > 12 && get_digits(&zz[12..], "20c:20e", &mut hm) == 2 {
            z2 = &zz[12..];
            n = 2;
        } else {
            return true;
        }
    }
    if at(z2, n) == b':' {
        // (+|-)HH:MM[:SS[.FFF]]
        let mut s = z2;
        if !at(s, 0).is_ascii_digit() {
            s = &s[1..];
        }
        let mut tx = DateTime::default();
        if parse_hms(s, &mut tx) {
            return true;
        }
        compute_jd(&mut tx);
        tx.ijd -= 43200000;
        let day = tx.ijd / 86400000;
        tx.ijd -= day * 86400000;
        if z0 == b'-' {
            tx.ijd = -tx.ijd;
        }
        compute_jd(p);
        clear_ymd_hms_tz(p);
        p.ijd += tx.ijd;
        return false;
    }
    // "+NNN units"
    let mut i = n;
    while is_space(at(z, i)) {
        i += 1;
    }
    let unit = &z[i.min(z.len())..];
    let mut len = unit.len();
    if !(3..=10).contains(&len) {
        return true;
    }
    if unit[len - 1].eq_ignore_ascii_case(&b's') {
        len -= 1;
    }
    let unit = &unit[..len];
    compute_jd(p);
    let rounder = if r < 0.0 { -0.5 } else { 0.5 };
    p.n_floor = 0;
    const XFORM: [(&str, f32, f64); 6] = [
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
        if unit.eq_ignore_ascii_case(name.as_bytes()) && r > -limit && r < limit {
            if i == 4 {
                compute_ymd_hms(p);
                p.mo += r as i32;
                normalize_month(p);
                compute_floor(p);
                p.valid_jd = false;
                r -= (r as i32) as f64;
            } else if i == 5 {
                compute_ymd_hms(p);
                p.y += r as i32;
                compute_floor(p);
                p.valid_jd = false;
                r -= (r as i32) as f64;
            }
            compute_jd(p);
            p.ijd += (r * 1000.0 * xform + rounder) as i64;
            rc = false;
            break;
        }
    }
    clear_ymd_hms_tz(p);
    rc
}

/// Build a DateTime from a time value and modifiers; None means NULL.
fn is_date(args: &[Value]) -> Option<DateTime> {
    let mut p = DateTime::default();
    if args.is_empty() {
        set_now(&mut p);
        return Some(p);
    }
    match &args[0] {
        Value::Null => return None,
        Value::Integer(i) => set_raw_number(&mut p, *i as f64),
        Value::Real(r) => set_raw_number(&mut p, *r),
        v => {
            let t = v.to_text()?;
            if parse_date_or_time(t.as_bytes(), &mut p) {
                return None;
            }
        }
    }
    for (i, a) in args.iter().enumerate().skip(1) {
        let t = a.to_text()?;
        if parse_modifier(&t, &mut p, i) {
            return None;
        }
    }
    compute_jd(&mut p);
    if p.is_error || !valid_julian_day(p.ijd) {
        return None;
    }
    if args.len() == 1 && p.valid_ymd && p.d > 28 {
        p.valid_ymd = false;
    }
    Some(p)
}

fn fmt_date(p: &DateTime) -> String {
    let y = p.y.abs() % 10000;
    format!(
        "{}{:04}-{:02}-{:02}",
        if p.y < 0 { "-" } else { "" },
        y,
        p.mo,
        p.d
    )
}

fn fmt_time(p: &DateTime) -> String {
    if p.use_subsec {
        let s = (1000.0 * p.s + 0.5) as i32;
        format!("{:02}:{:02}:{:02}.{:03}", p.h, p.mi, s / 1000, s % 1000)
    } else {
        format!("{:02}:{:02}:{:02}", p.h, p.mi, p.s as i32)
    }
}

pub fn f_date(a: &[Value], _: Coll) -> Result<Value, String> {
    Ok(match is_date(a) {
        Some(mut p) => {
            compute_ymd(&mut p);
            Value::Text(fmt_date(&p))
        }
        None => Value::Null,
    })
}

pub fn f_time(a: &[Value], _: Coll) -> Result<Value, String> {
    Ok(match is_date(a) {
        Some(mut p) => {
            compute_hms(&mut p);
            Value::Text(fmt_time(&p))
        }
        None => Value::Null,
    })
}

pub fn f_datetime(a: &[Value], _: Coll) -> Result<Value, String> {
    Ok(match is_date(a) {
        Some(mut p) => {
            compute_ymd_hms(&mut p);
            Value::Text(format!("{} {}", fmt_date(&p), fmt_time(&p)))
        }
        None => Value::Null,
    })
}

pub fn f_julianday(a: &[Value], _: Coll) -> Result<Value, String> {
    Ok(match is_date(a) {
        Some(p) => Value::Real(p.ijd as f64 / 86400000.0),
        None => Value::Null,
    })
}

pub fn f_unixepoch(a: &[Value], _: Coll) -> Result<Value, String> {
    Ok(match is_date(a) {
        Some(p) => {
            if p.use_subsec {
                Value::Real((p.ijd - 210866760000000) as f64 / 1000.0)
            } else {
                Value::Integer(p.ijd / 1000 - 210866760000)
            }
        }
        None => Value::Null,
    })
}

fn days_after_jan01(p: &DateTime) -> i64 {
    let mut j = *p;
    j.valid_jd = false;
    j.mo = 1;
    j.d = 1;
    compute_jd(&mut j);
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
    compute_ymd(&mut y);
    y
}

const DAYS: [&str; 7] = [
    "Sunday",
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
];
const MONTHS: [&str; 12] = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
];

pub fn f_strftime(a: &[Value], _: Coll) -> Result<Value, String> {
    let Some(mut p) = is_date(&a[1..]) else {
        return Ok(Value::Null);
    };
    let Some(fmt) = a[0].to_text() else {
        return Ok(Value::Null);
    };
    compute_jd(&mut p);
    compute_ymd_hms(&mut p);
    let mut out = String::new();
    let mut chars = fmt.chars();
    while let Some(c) = chars.next() {
        if c != '%' {
            out.push(c);
            continue;
        }
        let Some(cf) = chars.next() else {
            return Ok(Value::Null);
        };
        match cf {
            'd' => out.push_str(&format!("{:02}", p.d)),
            'e' => out.push_str(&format!("{:2}", p.d)),
            'f' => {
                let s = p.s.min(59.999);
                out.push_str(&format!("{:06.3}", s));
            }
            'F' => out.push_str(&format!("{:04}-{:02}-{:02}", p.y, p.mo, p.d)),
            'G' => out.push_str(&format!("{:04}", iso_thursday(&p).y)),
            'g' => out.push_str(&format!("{:02}", iso_thursday(&p).y % 100)),
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
                out.push_str(&if cf == 'I' {
                    format!("{:02}", h)
                } else {
                    format!("{:2}", h)
                });
            }
            'j' => out.push_str(&format!("{:03}", days_after_jan01(&p) + 1)),
            'J' => out.push_str(&crate::func::printf_str(
                "%.16g",
                &[Value::Real(p.ijd as f64 / 86400000.0)],
            )),
            'm' => out.push_str(&format!("{:02}", p.mo)),
            'M' => out.push_str(&format!("{:02}", p.mi)),
            'p' => out.push_str(if p.h >= 12 { "PM" } else { "AM" }),
            'P' => out.push_str(if p.h >= 12 { "pm" } else { "am" }),
            'R' => out.push_str(&format!("{:02}:{:02}", p.h, p.mi)),
            's' => {
                if p.use_subsec {
                    out.push_str(&format!("{:.3}", (p.ijd - 210866760000000) as f64 / 1000.0));
                } else {
                    out.push_str(&(p.ijd / 1000 - 210866760000).to_string());
                }
            }
            'S' => out.push_str(&format!("{:02}", p.s as i32)),
            'T' => out.push_str(&format!("{:02}:{:02}:{:02}", p.h, p.mi, p.s as i32)),
            'u' | 'w' => {
                let mut c = days_after_sunday(&p);
                if c == 0 && cf == 'u' {
                    c = 7;
                }
                out.push_str(&c.to_string());
            }
            'U' => out.push_str(&format!(
                "{:02}",
                (days_after_jan01(&p) - days_after_sunday(&p) + 7) / 7
            )),
            'V' => out.push_str(&format!(
                "{:02}",
                days_after_jan01(&iso_thursday(&p)) / 7 + 1
            )),
            'W' => out.push_str(&format!(
                "{:02}",
                (days_after_jan01(&p) - days_after_monday(&p) + 7) / 7
            )),
            'a' | 'A' => {
                let n = DAYS[days_after_sunday(&p) as usize];
                out.push_str(if cf == 'a' { &n[..3] } else { n });
            }
            'b' | 'h' | 'B' => {
                let n = MONTHS[(p.mo - 1) as usize];
                out.push_str(if cf == 'B' { n } else { &n[..3] });
            }
            'C' => out.push_str(&format!("{:02}", p.y / 100)),
            'D' => out.push_str(&format!("{:02}/{:02}/{:02}", p.mo, p.d, p.y % 100)),
            'r' => {
                let h = if p.h % 12 == 0 { 12 } else { p.h % 12 };
                out.push_str(&format!(
                    "{:02}:{:02}:{:02} {}",
                    h,
                    p.mi,
                    p.s as i32,
                    if p.h >= 12 { "PM" } else { "AM" }
                ));
            }
            'Y' => out.push_str(&format!("{:04}", p.y)),
            'y' => out.push_str(&format!("{:02}", p.y % 100)),
            '%' => out.push('%'),
            _ => return Ok(Value::Null),
        }
    }
    Ok(Value::Text(out))
}

pub fn f_timediff(a: &[Value], _: Coll) -> Result<Value, String> {
    let (Some(mut d1), Some(mut d2)) = (is_date(&a[0..1]), is_date(&a[1..2])) else {
        return Ok(Value::Null);
    };
    compute_ymd_hms(&mut d1);
    compute_ymd_hms(&mut d2);
    let sign;
    let mut y;
    let mut m;
    let recompute = |d: &mut DateTime| {
        d.valid_jd = false;
        compute_jd(d);
    };
    if d1.ijd >= d2.ijd {
        sign = '+';
        y = d1.y - d2.y;
        if y != 0 {
            d2.y = d1.y;
            recompute(&mut d2);
        }
        m = d1.mo - d2.mo;
        if m < 0 {
            y -= 1;
            m += 12;
        }
        if m != 0 {
            d2.mo = d1.mo;
            recompute(&mut d2);
        }
        while d1.ijd < d2.ijd {
            m -= 1;
            if m < 0 {
                m = 11;
                y -= 1;
            }
            d2.mo -= 1;
            if d2.mo < 1 {
                d2.mo = 12;
                d2.y -= 1;
            }
            recompute(&mut d2);
        }
        d1.ijd -= d2.ijd;
    } else {
        sign = '-';
        y = d2.y - d1.y;
        if y != 0 {
            d2.y = d1.y;
            recompute(&mut d2);
        }
        m = d2.mo - d1.mo;
        if m < 0 {
            y -= 1;
            m += 12;
        }
        if m != 0 {
            d2.mo = d1.mo;
            recompute(&mut d2);
        }
        while d1.ijd > d2.ijd {
            m -= 1;
            if m < 0 {
                m = 11;
                y -= 1;
            }
            d2.mo += 1;
            if d2.mo > 12 {
                d2.mo = 1;
                d2.y += 1;
            }
            recompute(&mut d2);
        }
        d1.ijd = d2.ijd - d1.ijd;
    }
    d1.ijd += 148699540800000;
    clear_ymd_hms_tz(&mut d1);
    compute_ymd_hms(&mut d1);
    Ok(Value::Text(format!(
        "{}{:04}-{:02}-{:02} {:02}:{:02}:{:06.3}",
        sign,
        y,
        m,
        d1.d - 1,
        d1.h,
        d1.mi,
        d1.s
    )))
}
