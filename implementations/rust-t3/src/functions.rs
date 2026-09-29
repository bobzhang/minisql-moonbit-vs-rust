// Scalar SQL functions.

use std::cmp::Ordering;

use crate::printf;
use crate::value::{compare_coll, format_real, Coll, Value};

/// A scalar function: arguments and the collation that applies to them.
pub type ScalarFn = fn(&[Value], Coll) -> Result<Value, String>;

struct FuncDef {
    name: &'static str,
    /// Allowed argument counts: min..=max (max -1 means unbounded).
    min: i32,
    max: i32,
    f: ScalarFn,
}

macro_rules! fd {
    ($name:expr, $min:expr, $max:expr, $f:expr) => {
        FuncDef { name: $name, min: $min, max: $max, f: $f }
    };
}

const FUNCS: &[FuncDef] = &[
    fd!("typeof", 1, 1, f_typeof),
    fd!("changes", 0, 0, |_, _| Ok(Value::Integer(crate::db::changes()))),
    fd!("total_changes", 0, 0, |_, _| Ok(Value::Integer(crate::db::total_changes()))),
    fd!("last_insert_rowid", 0, 0, |_, _| Ok(Value::Integer(crate::db::last_insert_rowid()))),
    fd!("abs", 1, 1, f_abs),
    fd!("char", 0, -1, f_char),
    fd!("coalesce", 2, -1, f_coalesce),
    fd!("ifnull", 2, 2, f_coalesce),
    fd!("iif", 2, 3, f_iif),
    fd!("if", 2, 3, f_iif),
    fd!("concat", 1, -1, f_concat),
    fd!("concat_ws", 2, -1, f_concat_ws),
    fd!("format", 0, -1, f_printf),
    fd!("printf", 0, -1, f_printf),
    fd!("glob", 2, 2, f_glob),
    fd!("like", 2, 3, f_like),
    fd!("hex", 1, 1, f_hex),
    fd!("unhex", 1, 2, f_unhex),
    fd!("instr", 2, 2, f_instr),
    fd!("length", 1, 1, f_length),
    fd!("octet_length", 1, 1, f_octet_length),
    fd!("likelihood", 2, 2, f_first),
    fd!("likely", 1, 1, f_first),
    fd!("unlikely", 1, 1, f_first),
    fd!("lower", 1, 1, f_lower),
    fd!("upper", 1, 1, f_upper),
    fd!("ltrim", 1, 2, f_ltrim),
    fd!("rtrim", 1, 2, f_rtrim),
    fd!("trim", 1, 2, f_trim),
    fd!("max", 2, -1, f_max),
    fd!("min", 2, -1, f_min),
    fd!("nullif", 2, 2, f_nullif),
    fd!("quote", 1, 1, f_quote),
    fd!("replace", 3, 3, f_replace),
    fd!("round", 1, 2, f_round),
    fd!("sign", 1, 1, f_sign),
    fd!("substr", 2, 3, f_substr),
    fd!("substring", 2, 3, f_substr),
    fd!("unicode", 1, 1, f_unicode),
    fd!("zeroblob", 1, 1, f_zeroblob),
    // date and time
    fd!("date", 0, -1, crate::datetime::f_date),
    fd!("time", 0, -1, crate::datetime::f_time),
    fd!("datetime", 0, -1, crate::datetime::f_datetime),
    fd!("julianday", 0, -1, crate::datetime::f_julianday),
    fd!("unixepoch", 0, -1, crate::datetime::f_unixepoch),
    fd!("strftime", 1, -1, crate::datetime::f_strftime),
    fd!("timediff", 2, 2, crate::datetime::f_timediff),
    // math
    fd!("acos", 1, 1, |a, _| math1(a, f64::acos)),
    fd!("acosh", 1, 1, |a, _| math1(a, f64::acosh)),
    fd!("asin", 1, 1, |a, _| math1(a, f64::asin)),
    fd!("asinh", 1, 1, |a, _| math1(a, f64::asinh)),
    fd!("atan", 1, 1, |a, _| math1(a, f64::atan)),
    fd!("atanh", 1, 1, |a, _| math1(a, f64::atanh)),
    fd!("atan2", 2, 2, |a, _| math2(a, f64::atan2)),
    fd!("cos", 1, 1, |a, _| math1(a, f64::cos)),
    fd!("cosh", 1, 1, |a, _| math1(a, f64::cosh)),
    fd!("sin", 1, 1, |a, _| math1(a, f64::sin)),
    fd!("sinh", 1, 1, |a, _| math1(a, f64::sinh)),
    fd!("tan", 1, 1, |a, _| math1(a, f64::tan)),
    fd!("tanh", 1, 1, |a, _| math1(a, f64::tanh)),
    fd!("exp", 1, 1, |a, _| math1(a, f64::exp)),
    fd!("sqrt", 1, 1, |a, _| math1(a, f64::sqrt)),
    fd!("degrees", 1, 1, |a, _| math1(a, |x| x * (180.0 / std::f64::consts::PI))),
    fd!("radians", 1, 1, |a, _| math1(a, |x| x * (std::f64::consts::PI / 180.0))),
    fd!("pow", 2, 2, |a, _| math2(a, f64::powf)),
    fd!("power", 2, 2, |a, _| math2(a, f64::powf)),
    fd!("mod", 2, 2, |a, _| math2(a, |x, y| x % y)),
    fd!("pi", 0, 0, |_, _| Ok(Value::Real(std::f64::consts::PI))),
    fd!("ceil", 1, 1, |a, _| rounding(a, f64::ceil)),
    fd!("ceiling", 1, 1, |a, _| rounding(a, f64::ceil)),
    fd!("floor", 1, 1, |a, _| rounding(a, f64::floor)),
    fd!("trunc", 1, 1, |a, _| rounding(a, f64::trunc)),
    fd!("ln", 1, 1, |a, _| log_fn(a, f64::ln)),
    fd!("log", 1, 2, |a, _| log_fn(a, f64::log10)),
    fd!("log10", 1, 1, |a, _| log_fn(a, f64::log10)),
    fd!("log2", 1, 1, |a, _| log_fn(a, f64::log2)),
];

pub fn lookup(name: &str, nargs: usize) -> Result<ScalarFn, String> {
    let mut found_name = false;
    for d in FUNCS {
        if d.name.eq_ignore_ascii_case(name) {
            found_name = true;
            let n = nargs as i32;
            if n >= d.min && (d.max < 0 || n <= d.max) {
                return Ok(d.f);
            }
        }
    }
    if found_name {
        Err(format!("wrong number of arguments to function {}()", name))
    } else {
        Err(format!("no such function: {}", name))
    }
}

type R = Result<Value, String>;

fn real(r: f64) -> Value {
    if r.is_nan() {
        Value::Null
    } else {
        Value::Real(r)
    }
}

fn f_typeof(a: &[Value], _: Coll) -> R {
    Ok(Value::Text(a[0].type_name().to_string()))
}

fn f_first(a: &[Value], _: Coll) -> R {
    Ok(a[0].clone())
}

// coalesce/ifnull/iif are evaluated lazily by the evaluator; these are only
// reached if called directly.
fn f_coalesce(a: &[Value], _: Coll) -> R {
    Ok(a.iter().find(|v| !v.is_null()).cloned().unwrap_or(Value::Null))
}

fn f_iif(a: &[Value], _: Coll) -> R {
    if a[0].truth() == Some(true) {
        Ok(a[1].clone())
    } else {
        Ok(a.get(2).cloned().unwrap_or(Value::Null))
    }
}

fn f_abs(a: &[Value], _: Coll) -> R {
    Ok(match &a[0] {
        Value::Null => Value::Null,
        Value::Integer(i) => match i.checked_abs() {
            Some(x) => Value::Integer(x),
            None => return Err("integer overflow".to_string()),
        },
        v => Value::Real(v.to_real().abs()),
    })
}

fn f_char(a: &[Value], _: Coll) -> R {
    let mut s = String::new();
    for v in a {
        let x = v.to_int();
        let c = if (0..=0x10ffff).contains(&x) { char::from_u32(x as u32) } else { None };
        s.push(c.unwrap_or('\u{fffd}'));
    }
    Ok(Value::Text(s))
}

fn f_concat(a: &[Value], _: Coll) -> R {
    let mut s = String::new();
    for v in a {
        if let Some(t) = v.to_text() {
            s.push_str(&t);
        }
    }
    Ok(Value::Text(s))
}

fn f_concat_ws(a: &[Value], _: Coll) -> R {
    let sep = match a[0].to_text() {
        Some(s) => s,
        None => return Ok(Value::Null),
    };
    let parts: Vec<String> = a[1..].iter().filter_map(|v| v.to_text()).collect();
    Ok(Value::Text(parts.join(&sep)))
}

fn f_printf(a: &[Value], _: Coll) -> R {
    if a.is_empty() {
        return Ok(Value::Null);
    }
    match a[0].to_text() {
        None => Ok(Value::Null),
        Some(fmt) => Ok(printf::format(&fmt, &a[1..]).map(Value::Text).unwrap_or(Value::Null)),
    }
}

// ---------- LIKE / GLOB ----------

const MATCH: i32 = 0;
const NOMATCH: i32 = 1;
const NOWILDCARDMATCH: i32 = 2;

struct PatInfo {
    match_all: u32,
    match_one: u32,
    match_set: bool,
    no_case: bool,
}

fn to_chars(s: &str) -> Vec<u32> {
    let mut v: Vec<u32> = s.chars().map(|c| c as u32).collect();
    // the pattern and string end at the first NUL
    if let Some(p) = v.iter().position(|&c| c == 0) {
        v.truncate(p);
    }
    v.push(0);
    v
}

fn lower(c: u32) -> u32 {
    if (b'A' as u32..=b'Z' as u32).contains(&c) {
        c + 32
    } else {
        c
    }
}

/// Port of SQLite's patternCompare. `p` and `s` are NUL-terminated.
fn pattern_compare(p: &[u32], s: &[u32], info: &PatInfo, match_other: u32) -> i32 {
    let (mut pi, mut si) = (0usize, 0usize);
    let mut escaped: Option<usize> = None;
    loop {
        let c = p[pi];
        if c == 0 {
            break;
        }
        pi += 1;
        if c == info.match_all && info.match_all != 0 {
            let mut c;
            loop {
                c = p[pi];
                pi += 1;
                if c != 0 && c == info.match_all {
                    continue;
                }
                if c != 0 && c == info.match_one {
                    if s[si] == 0 {
                        return NOWILDCARDMATCH;
                    }
                    si += 1;
                    continue;
                }
                break;
            }
            if c == 0 {
                return MATCH;
            }
            if c == match_other && match_other != 0 {
                if !info.match_set {
                    c = p[pi];
                    if c == 0 {
                        return NOWILDCARDMATCH;
                    }
                    pi += 1;
                } else {
                    while s[si] != 0 {
                        let r = pattern_compare(&p[pi - 1..], &s[si..], info, match_other);
                        if r != NOMATCH {
                            return r;
                        }
                        si += 1;
                    }
                    return NOWILDCARDMATCH;
                }
            }
            while s[si] != 0 {
                let c2 = s[si];
                si += 1;
                let eq = c2 == c || (info.no_case && c < 0x80 && c2 < 0x80 && lower(c) == lower(c2));
                if !eq {
                    continue;
                }
                let r = pattern_compare(&p[pi..], &s[si..], info, match_other);
                if r != NOMATCH {
                    return r;
                }
            }
            return NOWILDCARDMATCH;
        }
        let mut c = c;
        if c == match_other && match_other != 0 {
            if !info.match_set {
                c = p[pi];
                if c == 0 {
                    return NOMATCH;
                }
                pi += 1;
                escaped = Some(pi);
            } else {
                let mut prior_c = 0u32;
                let mut seen = false;
                let mut invert = false;
                let c = s[si];
                if c == 0 {
                    return NOMATCH;
                }
                si += 1;
                let mut c2 = p[pi];
                pi += 1;
                if c2 == '^' as u32 {
                    invert = true;
                    c2 = p[pi];
                    pi += 1;
                }
                if c2 == ']' as u32 {
                    if c == ']' as u32 {
                        seen = true;
                    }
                    c2 = p[pi];
                    pi += 1;
                }
                while c2 != 0 && c2 != ']' as u32 {
                    if c2 == '-' as u32 && p[pi] != ']' as u32 && p[pi] != 0 && prior_c > 0 {
                        c2 = p[pi];
                        pi += 1;
                        if c >= prior_c && c <= c2 {
                            seen = true;
                        }
                        prior_c = 0;
                    } else {
                        if c == c2 {
                            seen = true;
                        }
                        prior_c = c2;
                    }
                    c2 = p[pi];
                    if c2 != 0 {
                        pi += 1;
                    }
                }
                if c2 == 0 || seen == invert {
                    return NOMATCH;
                }
                continue;
            }
        }
        let c2 = s[si];
        if c2 != 0 {
            si += 1;
        }
        if c == c2 {
            continue;
        }
        if info.no_case && c < 0x80 && c2 < 0x80 && lower(c) == lower(c2) {
            continue;
        }
        if c == info.match_one && info.match_one != 0 && escaped != Some(pi) && c2 != 0 {
            continue;
        }
        return NOMATCH;
    }
    if s[si] == 0 {
        MATCH
    } else {
        NOMATCH
    }
}

fn f_like(a: &[Value], _: Coll) -> R {
    let mut info = PatInfo { match_all: '%' as u32, match_one: '_' as u32, match_set: false, no_case: true };
    let mut esc = 0u32;
    if a.len() == 3 {
        let e = match a[2].to_text() {
            Some(e) => e,
            None => return Ok(Value::Null),
        };
        let mut it = e.chars();
        match (it.next(), it.next()) {
            (Some(c), None) => esc = c as u32,
            _ => return Err("ESCAPE expression must be a single character".to_string()),
        }
        if esc == info.match_all {
            info.match_all = 0;
        }
        if esc == info.match_one {
            info.match_one = 0;
        }
    }
    let (p, s) = match (a[0].to_text(), a[1].to_text()) {
        (Some(p), Some(s)) => (p, s),
        _ => return Ok(Value::Null),
    };
    let r = pattern_compare(&to_chars(&p), &to_chars(&s), &info, esc);
    Ok(Value::from_bool(r == MATCH))
}

fn f_glob(a: &[Value], _: Coll) -> R {
    let info = PatInfo { match_all: '*' as u32, match_one: '?' as u32, match_set: true, no_case: false };
    let (p, s) = match (a[0].to_text(), a[1].to_text()) {
        (Some(p), Some(s)) => (p, s),
        _ => return Ok(Value::Null),
    };
    let r = pattern_compare(&to_chars(&p), &to_chars(&s), &info, '[' as u32);
    Ok(Value::from_bool(r == MATCH))
}

// ---------- text and blob functions ----------

fn hex_upper(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for byte in b {
        s.push_str(&format!("{:02X}", byte));
    }
    s
}

fn f_hex(a: &[Value], _: Coll) -> R {
    Ok(Value::Text(hex_upper(&a[0].to_bytes().unwrap_or_default())))
}

fn f_unhex(a: &[Value], _: Coll) -> R {
    let h = match a[0].to_text() {
        Some(h) => h,
        None => return Ok(Value::Null),
    };
    let pass: Vec<char> = if a.len() == 2 {
        match a[1].to_text() {
            Some(p) => p.chars().collect(),
            None => return Ok(Value::Null),
        }
    } else {
        Vec::new()
    };
    let chars: Vec<char> = h.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if !c.is_ascii_hexdigit() {
            if !pass.contains(&c) {
                return Ok(Value::Null);
            }
            i += 1;
            continue;
        }
        let d = match chars.get(i + 1) {
            Some(d) if d.is_ascii_hexdigit() => *d,
            _ => return Ok(Value::Null),
        };
        out.push((c.to_digit(16).unwrap() * 16 + d.to_digit(16).unwrap()) as u8);
        i += 2;
    }
    Ok(Value::Blob(out))
}

fn f_instr(a: &[Value], _: Coll) -> R {
    if a[0].is_null() || a[1].is_null() {
        return Ok(Value::Null);
    }
    if let (Value::Blob(h), Value::Blob(n)) = (&a[0], &a[1]) {
        if n.is_empty() {
            return Ok(Value::Integer(1));
        }
        let pos = h.windows(n.len()).position(|w| w == &n[..]);
        return Ok(Value::Integer(pos.map(|p| p as i64 + 1).unwrap_or(0)));
    }
    let h = a[0].to_text().unwrap();
    let n = a[1].to_text().unwrap();
    Ok(Value::Integer(match h.find(&n) {
        Some(p) => h[..p].chars().count() as i64 + 1,
        None => 0,
    }))
}

fn f_length(a: &[Value], _: Coll) -> R {
    Ok(match &a[0] {
        Value::Null => Value::Null,
        Value::Blob(b) => Value::Integer(b.len() as i64),
        v => {
            let s = v.to_text().unwrap();
            let s = s.split('\0').next().unwrap();
            Value::Integer(s.chars().count() as i64)
        }
    })
}

fn f_octet_length(a: &[Value], _: Coll) -> R {
    Ok(match a[0].to_bytes() {
        None => Value::Null,
        Some(b) => Value::Integer(b.len() as i64),
    })
}

fn f_lower(a: &[Value], _: Coll) -> R {
    Ok(match a[0].to_text() {
        None => Value::Null,
        Some(s) => Value::Text(s.to_ascii_lowercase()),
    })
}

fn f_upper(a: &[Value], _: Coll) -> R {
    Ok(match a[0].to_text() {
        None => Value::Null,
        Some(s) => Value::Text(s.to_ascii_uppercase()),
    })
}

fn trim_impl(a: &[Value], left: bool, right: bool) -> R {
    let s = match a[0].to_text() {
        Some(s) => s,
        None => return Ok(Value::Null),
    };
    let set: Vec<char> = if a.len() == 2 {
        match a[1].to_text() {
            Some(t) => t.chars().collect(),
            None => return Ok(Value::Null),
        }
    } else {
        vec![' ']
    };
    let mut t: &str = &s;
    if left {
        t = t.trim_start_matches(|c| set.contains(&c));
    }
    if right {
        t = t.trim_end_matches(|c| set.contains(&c));
    }
    Ok(Value::Text(t.to_string()))
}

fn f_ltrim(a: &[Value], _: Coll) -> R {
    trim_impl(a, true, false)
}

fn f_rtrim(a: &[Value], _: Coll) -> R {
    trim_impl(a, false, true)
}

fn f_trim(a: &[Value], _: Coll) -> R {
    trim_impl(a, true, true)
}

fn minmax(a: &[Value], coll: Coll, want: Ordering) -> R {
    let mut best = &a[0];
    for v in a {
        if v.is_null() {
            return Ok(Value::Null);
        }
        // on ties max() keeps the earlier argument and min() takes the later
        let o = compare_coll(v, best, coll);
        if o == want || (want == Ordering::Less && o == Ordering::Equal) {
            best = v;
        }
    }
    Ok(best.clone())
}

fn f_max(a: &[Value], coll: Coll) -> R {
    minmax(a, coll, Ordering::Greater)
}

fn f_min(a: &[Value], coll: Coll) -> R {
    minmax(a, coll, Ordering::Less)
}

fn f_nullif(a: &[Value], coll: Coll) -> R {
    if !a[0].is_null() && !a[1].is_null() && compare_coll(&a[0], &a[1], coll) == Ordering::Equal {
        return Ok(Value::Null);
    }
    Ok(a[0].clone())
}

fn f_quote(a: &[Value], _: Coll) -> R {
    Ok(Value::Text(quote(&a[0])))
}

pub fn quote(v: &Value) -> String {
    match v {
        Value::Null => "NULL".to_string(),
        Value::Integer(i) => i.to_string(),
        Value::Real(r) => {
            if r.is_infinite() {
                if *r > 0.0 { "9.0e+999" } else { "-9.0e+999" }.to_string()
            } else {
                format_real(*r)
            }
        }
        Value::Text(s) => format!("'{}'", s.replace('\'', "''")),
        Value::Blob(b) => format!("X'{}'", hex_upper(b)),
    }
}

fn f_replace(a: &[Value], _: Coll) -> R {
    let (s, from, to) = match (a[0].to_text(), a[1].to_text(), a[2].to_text()) {
        (Some(s), Some(f), Some(t)) => (s, f, t),
        _ => return Ok(Value::Null),
    };
    if from.is_empty() {
        return Ok(Value::Text(s));
    }
    Ok(Value::Text(s.replace(&from, &to)))
}

fn f_round(a: &[Value], _: Coll) -> R {
    let mut n = 0i64;
    if a.len() == 2 {
        if a[1].is_null() {
            return Ok(Value::Null);
        }
        n = a[1].to_int().clamp(0, 30);
    }
    if a[0].is_null() {
        return Ok(Value::Null);
    }
    let r = a[0].to_real();
    let res = if !(-4503599627370496.0..=4503599627370496.0).contains(&r) {
        r
    } else if n == 0 {
        (r + if r < 0.0 { -0.5 } else { 0.5 }) as i64 as f64
    } else {
        let s = printf::format_float(r, n as usize);
        s.parse::<f64>().unwrap_or(r)
    };
    Ok(real(res))
}

fn f_sign(a: &[Value], _: Coll) -> R {
    let x = match a[0].numeric() {
        Value::Integer(i) => i as f64,
        Value::Real(r) => r,
        _ => return Ok(Value::Null),
    };
    Ok(Value::Integer(if x < 0.0 {
        -1
    } else if x > 0.0 {
        1
    } else {
        0
    }))
}

fn f_substr(a: &[Value], _: Coll) -> R {
    if a[1].is_null() || (a.len() == 3 && a[2].is_null()) {
        return Ok(Value::Null);
    }
    if a[0].is_null() {
        return Ok(Value::Null);
    }
    let mut p1 = a[1].to_int();
    let is_blob = matches!(a[0], Value::Blob(_));
    let text;
    let chars: Vec<char>;
    let len: i64 = if is_blob {
        chars = Vec::new();
        text = String::new();
        match &a[0] {
            Value::Blob(b) => b.len() as i64,
            _ => unreachable!(),
        }
    } else {
        text = a[0].to_text().unwrap();
        chars = text.chars().collect();
        chars.len() as i64
    };
    let _ = &text;
    let mut neg_p2 = false;
    let mut p2: i64 = if a.len() == 3 {
        let v = a[2].to_int();
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
        p1 = p1.saturating_add(len);
        if p1 < 0 {
            p2 = p2.saturating_add(p1);
            if p2 < 0 {
                p2 = 0;
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
    let start = p1.min(len) as usize;
    let end = (p1.saturating_add(p2)).min(len).max(p1.min(len)) as usize;
    Ok(match &a[0] {
        Value::Blob(b) => Value::Blob(b[start..end].to_vec()),
        _ => Value::Text(chars[start..end].iter().collect()),
    })
}

fn f_unicode(a: &[Value], _: Coll) -> R {
    Ok(match a[0].to_text() {
        None => Value::Null,
        Some(s) => match s.chars().next() {
            Some(c) => Value::Integer(c as i64),
            None => Value::Null,
        },
    })
}

fn f_zeroblob(a: &[Value], _: Coll) -> R {
    let n = a[0].to_int();
    if n > 1_000_000_000 {
        return Err("string or blob too big".to_string());
    }
    Ok(Value::Blob(vec![0; n.max(0) as usize]))
}

// ---------- math ----------

fn num_arg(v: &Value) -> Option<Value> {
    match v.numeric() {
        n @ (Value::Integer(_) | Value::Real(_)) => Some(n),
        _ => None,
    }
}

fn math1(a: &[Value], f: fn(f64) -> f64) -> R {
    Ok(match num_arg(&a[0]) {
        Some(v) => real(f(v.to_real())),
        None => Value::Null,
    })
}

fn math2(a: &[Value], f: fn(f64, f64) -> f64) -> R {
    Ok(match (num_arg(&a[0]), num_arg(&a[1])) {
        (Some(x), Some(y)) => real(f(x.to_real(), y.to_real())),
        _ => Value::Null,
    })
}

fn rounding(a: &[Value], f: fn(f64) -> f64) -> R {
    Ok(match num_arg(&a[0]) {
        Some(Value::Integer(i)) => Value::Integer(i),
        Some(v) => real(f(v.to_real())),
        None => Value::Null,
    })
}

fn log_fn(a: &[Value], f: fn(f64) -> f64) -> R {
    let x = match num_arg(&a[0]) {
        Some(v) => v.to_real(),
        None => return Ok(Value::Null),
    };
    if x <= 0.0 {
        return Ok(Value::Null);
    }
    if a.len() == 2 {
        let b = x.ln();
        if b <= 0.0 {
            return Ok(Value::Null);
        }
        let y = match num_arg(&a[1]) {
            Some(v) => v.to_real(),
            None => return Ok(Value::Null),
        };
        if y <= 0.0 {
            return Ok(Value::Null);
        }
        return Ok(real(y.ln() / b));
    }
    Ok(real(f(x)))
}
