// Scalar SQL functions, LIKE/GLOB matching and printf formatting.

use std::cmp::Ordering;

use crate::value::*;

pub type ScalarFn = fn(&[Value], Coll) -> Result<Value, String>;

thread_local! {
    /// Connection state read by changes(), total_changes(), last_insert_rowid().
    static CHANGES: std::cell::Cell<(i64, i64, i64)> = const { std::cell::Cell::new((0, 0, 0)) };
}

pub fn set_changes(changes: i64, total: i64) {
    CHANGES.with(|c| {
        let (_, _, last) = c.get();
        c.set((changes, total, last));
    });
}

pub fn set_last_insert_rowid(rowid: i64) {
    CHANGES.with(|c| {
        let (ch, total, _) = c.get();
        c.set((ch, total, rowid));
    });
}

/// Look up a scalar function: (min args, max args or None for unlimited, fn).
pub fn lookup(name: &str) -> Option<(usize, Option<usize>, ScalarFn)> {
    let f: (usize, Option<usize>, ScalarFn) = match name {
        "typeof" => (1, Some(1), f_typeof),
        "abs" => (1, Some(1), f_abs),
        "char" => (0, None, f_char),
        "concat" => (1, None, f_concat),
        "concat_ws" => (2, None, f_concat_ws),
        "format" | "printf" => (0, None, f_printf),
        "glob" => (2, Some(2), f_glob),
        "like" => (2, Some(3), f_like),
        "hex" => (1, Some(1), f_hex),
        "instr" => (2, Some(2), f_instr),
        "length" => (1, Some(1), f_length),
        "octet_length" => (1, Some(1), f_octet_length),
        "likely" | "unlikely" => (1, Some(1), f_first),
        "likelihood" => (2, Some(2), f_first),
        "lower" => (1, Some(1), f_lower),
        "upper" => (1, Some(1), f_upper),
        "ltrim" => (1, Some(2), f_ltrim),
        "rtrim" => (1, Some(2), f_rtrim),
        "trim" => (1, Some(2), f_trim),
        "max" => (1, None, f_max),
        "min" => (1, None, f_min),
        "nullif" => (2, Some(2), f_nullif),
        "quote" => (1, Some(1), f_quote),
        "replace" => (3, Some(3), f_replace),
        "round" => (1, Some(2), f_round),
        "sign" => (1, Some(1), f_sign),
        "substr" | "substring" => (2, Some(3), f_substr),
        "unhex" => (1, Some(2), f_unhex),
        "unicode" => (1, Some(1), f_unicode),
        "zeroblob" => (1, Some(1), f_zeroblob),
        "acos" => (1, Some(1), |a, _| math1(a, f64::acos)),
        "acosh" => (1, Some(1), |a, _| math1(a, f64::acosh)),
        "asin" => (1, Some(1), |a, _| math1(a, f64::asin)),
        "asinh" => (1, Some(1), |a, _| math1(a, f64::asinh)),
        "atan" => (1, Some(1), |a, _| math1(a, f64::atan)),
        "atanh" => (1, Some(1), |a, _| math1(a, f64::atanh)),
        "cos" => (1, Some(1), |a, _| math1(a, f64::cos)),
        "cosh" => (1, Some(1), |a, _| math1(a, f64::cosh)),
        "sin" => (1, Some(1), |a, _| math1(a, f64::sin)),
        "sinh" => (1, Some(1), |a, _| math1(a, f64::sinh)),
        "tan" => (1, Some(1), |a, _| math1(a, f64::tan)),
        "tanh" => (1, Some(1), |a, _| math1(a, f64::tanh)),
        "exp" => (1, Some(1), |a, _| math1(a, f64::exp)),
        "sqrt" => (1, Some(1), |a, _| math1(a, f64::sqrt)),
        "degrees" => (1, Some(1), |a, _| math1(a, f64::to_degrees)),
        "radians" => (1, Some(1), |a, _| math1(a, f64::to_radians)),
        "ceil" | "ceiling" => (1, Some(1), |a, _| round_like(a, f64::ceil)),
        "floor" => (1, Some(1), |a, _| round_like(a, f64::floor)),
        "trunc" => (1, Some(1), |a, _| round_like(a, f64::trunc)),
        "ln" => (1, Some(1), |a, _| f_log(a, 0)),
        "log" => (1, Some(2), |a, _| f_log(a, 10)),
        "log10" => (1, Some(1), |a, _| f_log(a, 10)),
        "log2" => (1, Some(1), |a, _| f_log(a, 2)),
        "atan2" => (2, Some(2), |a, _| math2(a, f64::atan2)),
        "pow" | "power" => (2, Some(2), |a, _| math2(a, f64::powf)),
        "mod" => (2, Some(2), |a, _| math2(a, |x, y| x % y)),
        "changes" => (0, Some(0), |_, _| {
            Ok(Value::Integer(CHANGES.with(|c| c.get().0)))
        }),
        "total_changes" => (0, Some(0), |_, _| {
            Ok(Value::Integer(CHANGES.with(|c| c.get().1)))
        }),
        "last_insert_rowid" => (0, Some(0), |_, _| {
            Ok(Value::Integer(CHANGES.with(|c| c.get().2)))
        }),
        "date" => (0, None, crate::datetime::f_date),
        "time" => (0, None, crate::datetime::f_time),
        "datetime" => (0, None, crate::datetime::f_datetime),
        "julianday" => (0, None, crate::datetime::f_julianday),
        "unixepoch" => (0, None, crate::datetime::f_unixepoch),
        "strftime" => (1, None, crate::datetime::f_strftime),
        "timediff" => (2, Some(2), crate::datetime::f_timediff),
        "pi" => (0, Some(0), |_, _| Ok(Value::Real(std::f64::consts::PI))),
        _ => return None,
    };
    Some(f)
}

/// Functions whose comparisons use a collating sequence.
pub fn needs_coll(name: &str) -> bool {
    matches!(name, "max" | "min" | "nullif")
}

fn real(r: f64) -> Value {
    if r.is_nan() {
        Value::Null
    } else {
        Value::Real(r)
    }
}

fn text_bytes(v: &Value) -> Option<Vec<u8>> {
    match v {
        Value::Null => None,
        Value::Blob(b) => Some(b.clone()),
        other => Some(other.to_text().unwrap().into_bytes()),
    }
}

fn bytes_to_text(b: Vec<u8>) -> Value {
    Value::Text(match String::from_utf8(b) {
        Ok(s) => s,
        Err(e) => String::from_utf8_lossy(e.as_bytes()).into_owned(),
    })
}

/// sqlite3_value_numeric_type: numbers, or text that looks like a number.
fn numeric_arg(v: &Value) -> Option<Value> {
    match v {
        Value::Integer(_) | Value::Real(_) => Some(v.clone()),
        Value::Text(s) => text_numeric_affinity(s, false),
        _ => None,
    }
}

fn f_typeof(a: &[Value], _: Coll) -> Result<Value, String> {
    Ok(Value::Text(a[0].type_name().to_string()))
}

fn f_first(a: &[Value], _: Coll) -> Result<Value, String> {
    Ok(a[0].clone())
}

fn f_abs(a: &[Value], _: Coll) -> Result<Value, String> {
    Ok(match &a[0] {
        Value::Null => Value::Null,
        Value::Integer(i) => match i.checked_abs() {
            Some(x) => Value::Integer(x),
            None => return Err("integer overflow".into()),
        },
        other => Value::Real(other.to_f64().abs()),
    })
}

fn f_char(a: &[Value], _: Coll) -> Result<Value, String> {
    let mut s = String::new();
    for v in a {
        let x = v.to_i64();
        let c = if (0..=0x10ffff).contains(&x) {
            char::from_u32(x as u32).unwrap_or('\u{fffd}')
        } else {
            '\u{fffd}'
        };
        s.push(c);
    }
    Ok(Value::Text(s))
}

fn f_concat(a: &[Value], _: Coll) -> Result<Value, String> {
    let mut out = Vec::new();
    for v in a {
        if let Some(b) = text_bytes(v) {
            out.extend(b);
        }
    }
    Ok(bytes_to_text(out))
}

fn f_concat_ws(a: &[Value], _: Coll) -> Result<Value, String> {
    let sep = match text_bytes(&a[0]) {
        None => return Ok(Value::Null),
        Some(s) => s,
    };
    let mut out = Vec::new();
    let mut first = true;
    for v in &a[1..] {
        if let Some(b) = text_bytes(v) {
            if !first {
                out.extend_from_slice(&sep);
            }
            first = false;
            out.extend(b);
        }
    }
    Ok(bytes_to_text(out))
}

fn f_hex(a: &[Value], _: Coll) -> Result<Value, String> {
    let b = text_bytes(&a[0]).unwrap_or_default();
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        s.push_str(&format!("{:02X}", x));
    }
    Ok(Value::Text(s))
}

fn f_unhex(a: &[Value], _: Coll) -> Result<Value, String> {
    let src = match text_bytes(&a[0]) {
        None => return Ok(Value::Null),
        Some(b) => b,
    };
    let ignore: Vec<char> = if a.len() > 1 {
        match a[1].to_text() {
            None => return Ok(Value::Null),
            Some(s) => s.chars().collect(),
        }
    } else {
        Vec::new()
    };
    let s = String::from_utf8_lossy(&src).into_owned();
    let chars: Vec<char> = s.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c.is_ascii_hexdigit() {
            if i + 1 >= chars.len() || !chars[i + 1].is_ascii_hexdigit() {
                return Ok(Value::Null);
            }
            let hi = c.to_digit(16).unwrap() as u8;
            let lo = chars[i + 1].to_digit(16).unwrap() as u8;
            out.push(hi * 16 + lo);
            i += 2;
        } else if ignore.contains(&c) {
            i += 1;
        } else {
            return Ok(Value::Null);
        }
    }
    Ok(Value::Blob(out))
}

fn f_instr(a: &[Value], _: Coll) -> Result<Value, String> {
    if a[0].is_null() || a[1].is_null() {
        return Ok(Value::Null);
    }
    let (hay, needle, is_text) = match (&a[0], &a[1]) {
        (Value::Blob(x), Value::Blob(y)) => (x.clone(), y.clone(), false),
        _ => (text_bytes(&a[0]).unwrap(), text_bytes(&a[1]).unwrap(), true),
    };
    if needle.is_empty() {
        return Ok(Value::Integer(1));
    }
    let mut n = 1i64;
    let mut i = 0;
    while i + needle.len() <= hay.len() {
        if hay[i..i + needle.len()] == needle[..] {
            return Ok(Value::Integer(n));
        }
        n += 1;
        i += 1;
        while is_text && i < hay.len() && (hay[i] & 0xc0) == 0x80 {
            i += 1;
        }
    }
    Ok(Value::Integer(0))
}

fn f_length(a: &[Value], _: Coll) -> Result<Value, String> {
    Ok(match &a[0] {
        Value::Null => Value::Null,
        Value::Blob(b) => Value::Integer(b.len() as i64),
        Value::Text(s) => Value::Integer(s.chars().take_while(|c| *c != '\0').count() as i64),
        other => Value::Integer(other.to_text().unwrap().chars().count() as i64),
    })
}

fn f_octet_length(a: &[Value], _: Coll) -> Result<Value, String> {
    Ok(match text_bytes(&a[0]) {
        None => Value::Null,
        Some(b) => Value::Integer(b.len() as i64),
    })
}

fn f_lower(a: &[Value], _: Coll) -> Result<Value, String> {
    Ok(match a[0].to_text() {
        None => Value::Null,
        Some(s) => Value::Text(s.to_ascii_lowercase()),
    })
}

fn f_upper(a: &[Value], _: Coll) -> Result<Value, String> {
    Ok(match a[0].to_text() {
        None => Value::Null,
        Some(s) => Value::Text(s.to_ascii_uppercase()),
    })
}

fn trim_impl(a: &[Value], left: bool, right: bool) -> Result<Value, String> {
    let s = match a[0].to_text() {
        None => return Ok(Value::Null),
        Some(s) => s,
    };
    let set: Vec<char> = if a.len() > 1 {
        match a[1].to_text() {
            None => return Ok(Value::Null),
            Some(t) => t.chars().collect(),
        }
    } else {
        vec![' ']
    };
    let mut r: &str = &s;
    if left {
        r = r.trim_start_matches(|c| set.contains(&c));
    }
    if right {
        r = r.trim_end_matches(|c| set.contains(&c));
    }
    Ok(Value::Text(r.to_string()))
}

fn f_ltrim(a: &[Value], _: Coll) -> Result<Value, String> {
    trim_impl(a, true, false)
}

fn f_rtrim(a: &[Value], _: Coll) -> Result<Value, String> {
    trim_impl(a, false, true)
}

fn f_trim(a: &[Value], _: Coll) -> Result<Value, String> {
    trim_impl(a, true, true)
}

fn minmax(a: &[Value], coll: Coll, is_max: bool) -> Result<Value, String> {
    if a.len() < 2 {
        return Err(format!(
            "misuse of aggregate function {}()",
            if is_max { "max" } else { "min" }
        ));
    }
    let mut best = 0;
    if a[0].is_null() {
        return Ok(Value::Null);
    }
    for i in 1..a.len() {
        if a[i].is_null() {
            return Ok(Value::Null);
        }
        let o = compare_values_coll(&a[best], &a[i], coll);
        if (is_max && o == Ordering::Less) || (!is_max && o != Ordering::Less) {
            best = i;
        }
    }
    Ok(a[best].clone())
}

fn f_max(a: &[Value], coll: Coll) -> Result<Value, String> {
    minmax(a, coll, true)
}

fn f_min(a: &[Value], coll: Coll) -> Result<Value, String> {
    minmax(a, coll, false)
}

fn f_nullif(a: &[Value], coll: Coll) -> Result<Value, String> {
    if compare_values_coll(&a[0], &a[1], coll) != Ordering::Equal {
        Ok(a[0].clone())
    } else {
        Ok(Value::Null)
    }
}

pub fn quote_value(v: &Value) -> String {
    match v {
        Value::Null => "NULL".into(),
        Value::Integer(i) => i.to_string(),
        Value::Real(r) => {
            let s = printf_str("%!0.15g", &[Value::Real(*r)]);
            if s.parse::<f64>().ok() == Some(*r) {
                s
            } else {
                printf_str("%!0.20e", &[Value::Real(*r)])
            }
        }
        Value::Text(s) => format!("'{}'", s.replace('\'', "''")),
        Value::Blob(_) => v.to_output(),
    }
}

fn f_quote(a: &[Value], _: Coll) -> Result<Value, String> {
    Ok(Value::Text(quote_value(&a[0])))
}

fn f_replace(a: &[Value], _: Coll) -> Result<Value, String> {
    let s = match text_bytes(&a[0]) {
        None => return Ok(Value::Null),
        Some(s) => s,
    };
    let pat = match text_bytes(&a[1]) {
        None => return Ok(Value::Null),
        Some(p) => p,
    };
    if pat.is_empty() {
        return Ok(bytes_to_text(s));
    }
    let rep = match text_bytes(&a[2]) {
        None => return Ok(Value::Null),
        Some(r) => r,
    };
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        if i + pat.len() <= s.len() && s[i..i + pat.len()] == pat[..] {
            out.extend_from_slice(&rep);
            i += pat.len();
        } else {
            out.push(s[i]);
            i += 1;
        }
    }
    Ok(bytes_to_text(out))
}

fn f_round(a: &[Value], _: Coll) -> Result<Value, String> {
    let mut n = 0i64;
    if a.len() > 1 {
        if a[1].is_null() {
            return Ok(Value::Null);
        }
        n = a[1].to_i64().clamp(0, 30);
    }
    if a[0].is_null() {
        return Ok(Value::Null);
    }
    let mut r = a[0].to_f64();
    if !(-4503599627370496.0..=4503599627370496.0).contains(&r) {
        // No fractional part.
    } else if n == 0 {
        r = ((r + if r < 0.0 { -0.5 } else { 0.5 }) as i64) as f64;
    } else {
        let s = printf_str(&format!("%!.{}f", n), &[Value::Real(r)]);
        r = s.parse::<f64>().unwrap_or(r);
    }
    Ok(real(r))
}

fn f_sign(a: &[Value], _: Coll) -> Result<Value, String> {
    Ok(match numeric_arg(&a[0]) {
        Some(Value::Integer(i)) => Value::Integer(i.signum()),
        Some(Value::Real(r)) => {
            if r > 0.0 {
                Value::Integer(1)
            } else if r < 0.0 {
                Value::Integer(-1)
            } else if r == 0.0 {
                Value::Integer(0)
            } else {
                Value::Null
            }
        }
        _ => Value::Null,
    })
}

fn f_substr(a: &[Value], _: Coll) -> Result<Value, String> {
    if a[1].is_null() || (a.len() == 3 && a[2].is_null()) || a[0].is_null() {
        return Ok(Value::Null);
    }
    let is_blob = matches!(a[0], Value::Blob(_));
    let z = text_bytes(&a[0]).unwrap();
    let mut p1 = a[1].to_i64();
    let mut len = 0i64;
    if is_blob {
        len = z.len() as i64;
    } else if p1 < 0 {
        len = z.iter().filter(|b| (**b & 0xc0) != 0x80).count() as i64;
    }
    let mut neg_p2 = false;
    let mut p2 = if a.len() == 3 {
        let v = a[2].to_i64();
        if v < 0 {
            neg_p2 = true;
            v.checked_neg().unwrap_or(i64::MAX)
        } else {
            v
        }
    } else {
        1_000_000_000
    };
    if p1 < 0 {
        p1 += len;
        if p1 < 0 {
            if p2 < 0 {
                p2 = 0;
            } else {
                p2 = p2.saturating_add(p1);
            }
            p1 = 0;
        }
    } else if p1 > 0 {
        p1 -= 1;
    } else if p2 > 0 {
        p2 -= 1;
    }
    if neg_p2 {
        p1 -= p2;
        if p1 < 0 {
            p2 += p1;
            p1 = 0;
        }
    }
    let p2 = p2.max(0);
    if is_blob {
        let (s, n) = if p1 >= len {
            (0, 0)
        } else {
            (p1, p2.min(len - p1))
        };
        Ok(Value::Blob(z[s as usize..(s + n) as usize].to_vec()))
    } else {
        let mut i = 0usize;
        let mut k = p1;
        while i < z.len() && k > 0 {
            i += 1;
            while i < z.len() && (z[i] & 0xc0) == 0x80 {
                i += 1;
            }
            k -= 1;
        }
        let start = i;
        let mut k = p2;
        while i < z.len() && k > 0 {
            i += 1;
            while i < z.len() && (z[i] & 0xc0) == 0x80 {
                i += 1;
            }
            k -= 1;
        }
        Ok(bytes_to_text(z[start..i].to_vec()))
    }
}

fn f_unicode(a: &[Value], _: Coll) -> Result<Value, String> {
    Ok(match a[0].to_text() {
        None => Value::Null,
        Some(s) => match s.chars().next() {
            None => Value::Null,
            Some(c) => Value::Integer(c as i64),
        },
    })
}

fn f_zeroblob(a: &[Value], _: Coll) -> Result<Value, String> {
    let n = a[0].to_i64().max(0);
    if n > 1_000_000_000 {
        return Err("string or blob too big".into());
    }
    Ok(Value::Blob(vec![0; n as usize]))
}

fn math1(a: &[Value], f: fn(f64) -> f64) -> Result<Value, String> {
    Ok(match numeric_arg(&a[0]) {
        Some(v) => real(f(v.to_f64())),
        None => Value::Null,
    })
}

fn math2(a: &[Value], f: fn(f64, f64) -> f64) -> Result<Value, String> {
    Ok(match (numeric_arg(&a[0]), numeric_arg(&a[1])) {
        (Some(x), Some(y)) => real(f(x.to_f64(), y.to_f64())),
        _ => Value::Null,
    })
}

fn round_like(a: &[Value], f: fn(f64) -> f64) -> Result<Value, String> {
    Ok(match numeric_arg(&a[0]) {
        Some(Value::Integer(i)) => Value::Integer(i),
        Some(v) => real(f(v.to_f64())),
        None => Value::Null,
    })
}

fn f_log(a: &[Value], base: u32) -> Result<Value, String> {
    let x = match numeric_arg(&a[0]) {
        Some(v) => v.to_f64(),
        None => return Ok(Value::Null),
    };
    if x <= 0.0 {
        return Ok(Value::Null);
    }
    if a.len() == 2 {
        if x <= 1.0 {
            return Ok(Value::Null);
        }
        let y = match numeric_arg(&a[1]) {
            Some(v) => v.to_f64(),
            None => return Ok(Value::Null),
        };
        if y <= 0.0 {
            return Ok(Value::Null);
        }
        return Ok(real(y.ln() / x.ln()));
    }
    Ok(real(match base {
        10 => x.log10(),
        2 => x.log2(),
        _ => x.ln(),
    }))
}

// ---------------------------------------------------------------------
// LIKE and GLOB
// ---------------------------------------------------------------------

const MATCH: u8 = 0;
const NOMATCH: u8 = 1;
const NOWILDCARDMATCH: u8 = 2;

struct PatInfo {
    match_all: char,
    match_one: char,
    match_set: bool,
    no_case: bool,
}

fn fold_eq(a: char, b: char) -> bool {
    a == b || (a.is_ascii() && b.is_ascii() && a.to_ascii_lowercase() == b.to_ascii_lowercase())
}

fn pattern_compare(pat: &[char], s: &[char], info: &PatInfo, other: Option<char>) -> u8 {
    let mut p = 0;
    let mut si = 0;
    let mut escaped_at: Option<usize> = None;
    while p < pat.len() {
        let c = pat[p];
        p += 1;
        if c == info.match_all {
            let mut c = None;
            while p < pat.len() {
                let x = pat[p];
                p += 1;
                if x == info.match_all {
                    continue;
                }
                if x == info.match_one {
                    if si >= s.len() {
                        return NOWILDCARDMATCH;
                    }
                    si += 1;
                    continue;
                }
                c = Some(x);
                break;
            }
            let mut c = match c {
                None => return MATCH,
                Some(c) => c,
            };
            if Some(c) == other {
                if !info.match_set {
                    if p >= pat.len() {
                        return NOWILDCARDMATCH;
                    }
                    c = pat[p];
                    p += 1;
                } else {
                    while si < s.len() {
                        let m = pattern_compare(&pat[p - 1..], &s[si..], info, other);
                        if m != NOMATCH {
                            return m;
                        }
                        si += 1;
                    }
                    return NOWILDCARDMATCH;
                }
            }
            while si < s.len() {
                let c2 = s[si];
                si += 1;
                let eq = if info.no_case {
                    fold_eq(c, c2)
                } else {
                    c == c2
                };
                if !eq {
                    continue;
                }
                let m = pattern_compare(&pat[p..], &s[si..], info, other);
                if m != NOMATCH {
                    return m;
                }
            }
            return NOWILDCARDMATCH;
        }
        let mut c = c;
        if Some(c) == other {
            if !info.match_set {
                if p >= pat.len() {
                    return NOMATCH;
                }
                c = pat[p];
                p += 1;
                escaped_at = Some(p);
            } else {
                if si >= s.len() {
                    return NOMATCH;
                }
                let sc = s[si];
                si += 1;
                let mut prior: Option<char> = None;
                let mut seen = false;
                let mut invert = false;
                let next = |p: &mut usize| -> Option<char> {
                    if *p < pat.len() {
                        *p += 1;
                        Some(pat[*p - 1])
                    } else {
                        None
                    }
                };
                let mut c2 = next(&mut p);
                if c2 == Some('^') {
                    invert = true;
                    c2 = next(&mut p);
                }
                if c2 == Some(']') {
                    if sc == ']' {
                        seen = true;
                    }
                    c2 = next(&mut p);
                }
                while let Some(x) = c2 {
                    if x == ']' {
                        break;
                    }
                    if x == '-' && p < pat.len() && pat[p] != ']' && prior.is_some() {
                        let hi = next(&mut p).unwrap();
                        if sc >= prior.unwrap() && sc <= hi {
                            seen = true;
                        }
                        prior = None;
                    } else {
                        if sc == x {
                            seen = true;
                        }
                        prior = Some(x);
                    }
                    c2 = next(&mut p);
                }
                if c2.is_none() || seen == invert {
                    return NOMATCH;
                }
                continue;
            }
        }
        let c2 = if si < s.len() {
            si += 1;
            Some(s[si - 1])
        } else {
            None
        };
        if Some(c) == c2 {
            continue;
        }
        if let Some(c2) = c2 {
            if info.no_case && fold_eq(c, c2) {
                continue;
            }
            if c == info.match_one && escaped_at != Some(p) {
                continue;
            }
        }
        return NOMATCH;
    }
    if si == s.len() {
        MATCH
    } else {
        NOMATCH
    }
}

pub fn glob_match(pattern: &str, s: &str) -> bool {
    let info = PatInfo {
        match_all: '*',
        match_one: '?',
        match_set: true,
        no_case: false,
    };
    let p: Vec<char> = pattern.chars().collect();
    let sv: Vec<char> = s.chars().collect();
    pattern_compare(&p, &sv, &info, Some('[')) == MATCH
}

fn f_like(a: &[Value], _: Coll) -> Result<Value, String> {
    let mut esc = None;
    if a.len() == 3 {
        let e = match a[2].to_text() {
            None => return Ok(Value::Null),
            Some(e) => e,
        };
        let mut it = e.chars();
        match (it.next(), it.next()) {
            (Some(c), None) => esc = Some(c),
            _ => return Err("ESCAPE expression must be a single character".into()),
        }
    }
    match (a[0].to_text(), a[1].to_text()) {
        (Some(p), Some(s)) => {
            let mut info = PatInfo {
                match_all: '%',
                match_one: '_',
                match_set: false,
                no_case: true,
            };
            if esc == Some('%') {
                info.match_all = '\0';
            }
            if esc == Some('_') {
                info.match_one = '\0';
            }
            let p: Vec<char> = p.chars().collect();
            let s: Vec<char> = s.chars().collect();
            Ok(Value::Integer(
                (pattern_compare(&p, &s, &info, esc) == MATCH) as i64,
            ))
        }
        _ => Ok(Value::Null),
    }
}

fn f_glob(a: &[Value], _: Coll) -> Result<Value, String> {
    match (a[0].to_text(), a[1].to_text()) {
        (Some(p), Some(s)) => Ok(Value::Integer(glob_match(&p, &s) as i64)),
        _ => Ok(Value::Null),
    }
}

// ---------------------------------------------------------------------
// printf
// ---------------------------------------------------------------------

fn f_printf(a: &[Value], _: Coll) -> Result<Value, String> {
    if a.is_empty() {
        return Ok(Value::Null);
    }
    let fmt = match text_bytes(&a[0]) {
        None => return Ok(Value::Null),
        Some(f) => f,
    };
    let out = printf_bytes(&fmt, &a[1..]);
    // Like SQLite, an empty result is NULL.
    if out.is_empty() {
        return Ok(Value::Null);
    }
    Ok(bytes_to_text(out))
}

pub fn printf_str(fmt: &str, args: &[Value]) -> String {
    String::from_utf8_lossy(&printf_bytes(fmt.as_bytes(), args)).into_owned()
}

struct Args<'a> {
    args: &'a [Value],
    i: usize,
}

impl<'a> Args<'a> {
    fn next(&mut self) -> Option<&'a Value> {
        let v = self.args.get(self.i);
        if v.is_some() {
            self.i += 1;
        }
        v
    }
    fn int(&mut self) -> i64 {
        self.next().map_or(0, |v| v.to_i64())
    }
    fn double(&mut self) -> f64 {
        self.next().map_or(0.0, |v| v.to_f64())
    }
    fn text(&mut self) -> Option<Vec<u8>> {
        self.next().and_then(text_bytes)
    }
}

/// Decimal decomposition of a double (SQLite's FpDecode).
struct FpDecode {
    neg: bool,
    digits: Vec<u8>,
    idp: i32,
    special: u8,
}

fn fp_decode(r: f64, iround: i32, mxround: i32) -> FpDecode {
    if r.is_nan() {
        return FpDecode {
            neg: false,
            digits: vec![],
            idp: 0,
            special: 2,
        };
    }
    if r.is_infinite() {
        return FpDecode {
            neg: r < 0.0,
            digits: vec![],
            idp: 0,
            special: 1,
        };
    }
    if r == 0.0 {
        return FpDecode {
            neg: false,
            digits: vec![b'0'],
            idp: 1,
            special: 0,
        };
    }
    let neg = r < 0.0;
    let e = format!("{:.39e}", r.abs());
    let (mant, exp) = e.split_once('e').unwrap();
    let exp: i32 = exp.parse().unwrap();
    let all: Vec<u8> = mant.bytes().filter(|c| c.is_ascii_digit()).collect();
    // SQLite works with 18 or 19 significant digits.
    let p19: u64 = std::str::from_utf8(&all[..19]).unwrap().parse().unwrap();
    let nd = if p19 > 9223372036854774784 { 18 } else { 19 };
    let mut z: Vec<u8> = all[..nd].to_vec();
    let mut idp = exp + 1;
    let mut n = z.len() as i32;
    let mut iround = iround;
    if iround <= 0 {
        iround = idp - iround;
        if iround == 0 && z[0] >= b'5' {
            iround = 1;
            z.insert(0, b'0');
            n += 1;
            idp += 1;
        }
    }
    if iround > 0 && (iround < n || n > mxround) {
        if iround > mxround {
            iround = mxround;
        }
        let round_up = z[iround as usize] >= b'5';
        z.truncate(iround as usize);
        if round_up {
            let mut j = iround as usize - 1;
            loop {
                z[j] += 1;
                if z[j] <= b'9' {
                    break;
                }
                z[j] = b'0';
                if j == 0 {
                    z.insert(0, b'1');
                    idp += 1;
                    break;
                }
                j -= 1;
            }
        }
    }
    while z.len() > 1 && *z.last().unwrap() == b'0' {
        z.pop();
    }
    FpDecode {
        neg,
        digits: z,
        idp,
        special: 0,
    }
}

pub fn printf_bytes(fmt: &[u8], args: &[Value]) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    let mut args = Args { args, i: 0 };
    let n = fmt.len();
    let mut i = 0;
    let at = |i: usize| if i < n { fmt[i] } else { 0 };
    while i < n {
        if fmt[i] != b'%' {
            out.push(fmt[i]);
            i += 1;
            continue;
        }
        i += 1;
        if i >= n {
            out.push(b'%');
            break;
        }
        let mut leftjustify = false;
        let mut prefix_flag: u8 = 0;
        let mut alternate = false;
        let mut altform2 = false;
        let mut zeropad = false;
        let mut thousand = false;
        let mut width: i64 = 0;
        let mut precision: i64 = -1;
        let mut c = at(i);
        // Flags, width and precision.
        loop {
            match c {
                b'-' => leftjustify = true,
                b'+' => prefix_flag = b'+',
                b' ' => prefix_flag = b' ',
                b'#' => alternate = true,
                b'!' => altform2 = true,
                b'0' => zeropad = true,
                b',' => thousand = true,
                b'l' => {
                    i += 1;
                    c = at(i);
                    if c == b'l' {
                        i += 1;
                        c = at(i);
                    }
                    break;
                }
                b'1'..=b'9' => {
                    let mut wx: i64 = 0;
                    while c.is_ascii_digit() {
                        wx = (wx * 10 + (c - b'0') as i64) & 0x7fffffff;
                        i += 1;
                        c = at(i);
                    }
                    width = wx;
                    if c != b'.' && c != b'l' {
                        break;
                    }
                    continue;
                }
                b'*' => {
                    width = args.int();
                    if width < 0 {
                        leftjustify = true;
                        width = if width >= -2147483647 { -width } else { 0 };
                    }
                    i += 1;
                    c = at(i);
                    if c != b'.' && c != b'l' {
                        break;
                    }
                    continue;
                }
                b'.' => {
                    i += 1;
                    c = at(i);
                    if c == b'*' {
                        precision = args.int();
                        if precision < 0 {
                            precision = if precision >= -2147483647 {
                                -precision
                            } else {
                                -1
                            };
                        }
                        i += 1;
                        c = at(i);
                    } else {
                        let mut px: i64 = 0;
                        while c.is_ascii_digit() {
                            px = (px * 10 + (c - b'0') as i64) & 0x7fffffff;
                            i += 1;
                            c = at(i);
                        }
                        precision = px;
                    }
                    if c == b'l' {
                        continue;
                    }
                    break;
                }
                _ => break,
            }
            i += 1;
            c = at(i);
            if c == 0 && i >= n {
                break;
            }
        }
        if i >= n {
            break;
        }
        i += 1;
        // Guard against absurd sizes.
        width = width.min(100_000);
        precision = precision.min(100_000);
        let mut buf: Vec<u8> = Vec::new();
        let mut width_adj = 0i64;
        match c {
            b'd' | b'i' | b'u' | b'x' | b'X' | b'o' | b'p' | b'r' => {
                let signed = matches!(c, b'd' | b'i' | b'r');
                let (base, upper, pre): (u64, bool, &[u8]) = match c {
                    b'x' => (16, false, b"0x"),
                    b'X' | b'p' => (16, true, b"0X"),
                    b'o' => (8, false, b"0"),
                    _ => (10, false, b""),
                };
                let v = args.int();
                let (mut lv, prefix) = if signed {
                    if v < 0 {
                        ((v as u64).wrapping_neg(), b'-')
                    } else {
                        (v as u64, prefix_flag)
                    }
                } else {
                    (v as u64, 0)
                };
                let mut alternate = alternate;
                if lv == 0 {
                    alternate = false;
                }
                let mut prec = precision;
                if zeropad && prec < width - (prefix != 0) as i64 {
                    prec = width - (prefix != 0) as i64;
                }
                let orig = lv;
                let mut digits: Vec<u8> = Vec::new();
                let cset: &[u8] = if upper {
                    b"0123456789ABCDEF"
                } else {
                    b"0123456789abcdef"
                };
                loop {
                    digits.push(cset[(lv % base) as usize]);
                    lv /= base;
                    if lv == 0 {
                        break;
                    }
                }
                digits.reverse();
                if c == b'r' {
                    let x = orig % 100;
                    let suf: &[u8] = if (11..=13).contains(&x) {
                        b"th"
                    } else {
                        match orig % 10 {
                            1 => b"st",
                            2 => b"nd",
                            3 => b"rd",
                            _ => b"th",
                        }
                    };
                    digits.extend_from_slice(suf);
                }
                while (digits.len() as i64) < prec {
                    digits.insert(0, b'0');
                }
                if thousand && c != b'r' {
                    digits = group_thousands(&digits);
                }
                if prefix != 0 {
                    buf.push(prefix);
                }
                if alternate && !pre.is_empty() {
                    buf.extend_from_slice(pre);
                }
                buf.extend(digits);
            }
            b'f' | b'e' | b'E' | b'g' | b'G' => {
                let r = args.double();
                buf = format_float(
                    r,
                    c,
                    precision,
                    width,
                    prefix_flag,
                    alternate,
                    altform2,
                    zeropad,
                    leftjustify,
                    thousand,
                );
            }
            b's' | b'z' => {
                let s = args.text().unwrap_or_default();
                let len = if precision >= 0 {
                    if altform2 {
                        utf8_prefix_len(&s, precision as usize)
                    } else {
                        (precision as usize).min(s.len())
                    }
                } else {
                    s.len()
                };
                buf.extend_from_slice(&s[..len]);
                if altform2 {
                    width_adj = continuation_bytes(&buf);
                }
            }
            b'q' | b'Q' | b'w' => {
                let q = if c == b'w' { b'"' } else { b'\'' };
                let arg = args.text();
                let isnull = arg.is_none();
                let s = arg.unwrap_or_else(|| {
                    if c == b'Q' {
                        b"NULL".to_vec()
                    } else {
                        b"(NULL)".to_vec()
                    }
                });
                let len = if precision >= 0 {
                    if altform2 {
                        utf8_prefix_len(&s, precision as usize)
                    } else {
                        (precision as usize).min(s.len())
                    }
                } else {
                    s.len()
                };
                let quote = !isnull && c == b'Q';
                if quote {
                    buf.push(q);
                }
                for &ch in &s[..len] {
                    buf.push(ch);
                    if ch == q {
                        buf.push(ch);
                    }
                }
                if quote {
                    buf.push(q);
                }
                if altform2 {
                    width_adj = continuation_bytes(&buf);
                }
            }
            b'c' => {
                let ch: Vec<u8> = match args.text() {
                    Some(t) if !t.is_empty() => {
                        let l = utf8_prefix_len(&t, 1);
                        t[..l].to_vec()
                    }
                    _ => vec![0],
                };
                if precision > 1 {
                    for _ in 0..precision {
                        buf.extend_from_slice(&ch);
                    }
                } else {
                    buf.extend_from_slice(&ch);
                }
                width_adj = continuation_bytes(&buf);
            }
            b'%' => buf.push(b'%'),
            b'n' => {}
            _ => return out,
        }
        let pad = width + width_adj - buf.len() as i64;
        if pad > 0 {
            if !leftjustify {
                out.extend(std::iter::repeat(b' ').take(pad as usize));
            }
            out.extend(buf);
            if leftjustify {
                out.extend(std::iter::repeat(b' ').take(pad as usize));
            }
        } else {
            out.extend(buf);
        }
    }
    out
}

fn group_thousands(d: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let n = d.len();
    for (k, &ch) in d.iter().enumerate() {
        if k > 0 && (n - k) % 3 == 0 {
            out.push(b',');
        }
        out.push(ch);
    }
    out
}

fn utf8_prefix_len(s: &[u8], nchars: usize) -> usize {
    let mut i = 0;
    let mut k = 0;
    while i < s.len() && k < nchars {
        i += 1;
        while i < s.len() && (s[i] & 0xc0) == 0x80 {
            i += 1;
        }
        k += 1;
    }
    i
}

fn continuation_bytes(s: &[u8]) -> i64 {
    s.iter().filter(|b| (**b & 0xc0) == 0x80).count() as i64
}

#[allow(clippy::too_many_arguments)]
fn format_float(
    r: f64,
    conv: u8,
    precision: i64,
    width: i64,
    prefix_flag: u8,
    alternate: bool,
    altform2: bool,
    zeropad: bool,
    leftjustify: bool,
    thousand: bool,
) -> Vec<u8> {
    let mut precision = if precision < 0 { 6 } else { precision };
    let generic = conv == b'g' || conv == b'G';
    let mut is_exp = conv == b'e' || conv == b'E';
    let upper = conv == b'E' || conv == b'G';
    let iround = if conv == b'f' {
        -(precision as i32)
    } else if generic {
        if precision == 0 {
            precision = 1;
        }
        precision as i32
    } else {
        precision as i32 + 1
    };
    let s = fp_decode(r, iround, if altform2 { 26 } else { 16 });
    let mut digits = s.digits;
    if s.special == 2 {
        return if zeropad {
            b"null".to_vec()
        } else {
            b"NaN".to_vec()
        };
    }
    let mut idp = s.idp;
    if s.special == 1 {
        if zeropad {
            digits = vec![b'9'];
            idp = 1000;
        } else {
            let mut b = Vec::new();
            if s.neg {
                b.push(b'-');
            } else if prefix_flag != 0 {
                b.push(prefix_flag);
            }
            b.extend_from_slice(b"Inf");
            return b;
        }
    }
    let prefix = if s.neg { b'-' } else { prefix_flag };
    let exp = idp - 1;
    if generic && precision > 0 {
        precision -= 1;
    }
    let rtz;
    if generic {
        rtz = !alternate;
        if exp < -4 || exp as i64 > precision {
            is_exp = true;
        } else {
            precision -= exp as i64;
        }
    } else {
        rtz = altform2;
    }
    let mut e2: i64 = if is_exp { 0 } else { idp as i64 - 1 };
    let mut b: Vec<u8> = Vec::new();
    let flag_dp = precision > 0 || alternate || altform2;
    if prefix != 0 {
        b.push(prefix);
    }
    let start = b.len();
    let mut j = 0;
    let next_digit = |j: &mut usize| {
        if *j < digits.len() {
            *j += 1;
            digits[*j - 1]
        } else {
            b'0'
        }
    };
    if e2 < 0 {
        b.push(b'0');
    } else {
        while e2 >= 0 {
            b.push(next_digit(&mut j));
            if thousand && e2 % 3 == 0 && e2 > 1 {
                b.push(b',');
            }
            e2 -= 1;
        }
    }
    if flag_dp {
        b.push(b'.');
    }
    e2 += 1;
    while e2 < 0 && precision > 0 {
        b.push(b'0');
        precision -= 1;
        e2 += 1;
    }
    while precision > 0 {
        b.push(next_digit(&mut j));
        precision -= 1;
    }
    if rtz && flag_dp {
        while b.len() > start && *b.last().unwrap() == b'0' {
            b.pop();
        }
        if b.last() == Some(&b'.') {
            if altform2 {
                b.push(b'0');
            } else {
                b.pop();
            }
        }
    }
    if is_exp {
        let mut exp = idp - 1;
        b.push(if upper { b'E' } else { b'e' });
        if exp < 0 {
            b.push(b'-');
            exp = -exp;
        } else {
            b.push(b'+');
        }
        if exp >= 100 {
            b.push(b'0' + (exp / 100) as u8);
            exp %= 100;
        }
        b.push(b'0' + (exp / 10) as u8);
        b.push(b'0' + (exp % 10) as u8);
    }
    if zeropad && !leftjustify && (b.len() as i64) < width {
        let npad = (width - b.len() as i64) as usize;
        let at = (prefix != 0) as usize;
        for _ in 0..npad {
            b.insert(at, b'0');
        }
    }
    b
}
