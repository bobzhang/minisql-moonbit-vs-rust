// Scalar functions.

use std::cmp::Ordering;
use std::fmt::Write;

use crate::error::{err, Result};
use crate::printf;
use crate::value::{compare_coll, Collation, Value};

/// Allowed argument counts: (min, max), max = None for unbounded.
fn arity(name: &str) -> Option<(usize, Option<usize>)> {
    let one = Some((1, Some(1)));
    let two = Some((2, Some(2)));
    match name {
        "typeof" | "abs" | "hex" | "length" | "likely" | "unlikely" | "lower" | "upper" | "octet_length"
        | "quote" | "sign" | "unicode" | "zeroblob" => one,
        "acos" | "acosh" | "asin" | "asinh" | "atan" | "atanh" | "ceil" | "ceiling" | "cos" | "cosh"
        | "degrees" | "exp" | "floor" | "ln" | "log10" | "log2" | "radians" | "sin" | "sinh" | "sqrt"
        | "tan" | "tanh" | "trunc" => one,
        "atan2" | "mod" | "pow" | "power" | "glob" | "ifnull" | "instr" | "likelihood" | "nullif" => two,
        "log" | "round" | "ltrim" | "rtrim" | "trim" | "unhex" => Some((1, Some(2))),
        "iif" | "if" => Some((2, Some(3))),
        "like" | "substr" | "substring" => Some((2, Some(3))),
        "replace" => Some((3, Some(3))),
        "pi" | "changes" | "total_changes" | "last_insert_rowid" => Some((0, Some(0))),
        "char" | "printf" | "format" => Some((0, None)),
        "concat" => Some((1, None)),
        "coalesce" | "concat_ws" => Some((2, None)),
        "max" | "min" => Some((1, None)),
        "count" => Some((0, Some(1))),
        "sum" | "total" | "avg" => one,
        "group_concat" => Some((1, Some(2))),
        "string_agg" => two,
        "date" | "time" | "datetime" | "julianday" | "unixepoch" => Some((0, None)),
        "strftime" => Some((1, None)),
        "timediff" => two,
        _ => None,
    }
}

pub fn check_function(name: &str, nargs: usize, star: bool) -> Result<()> {
    let (lo, hi) = match arity(name) {
        Some(a) => a,
        None => return err!("no such function: {}", name),
    };
    if (star && !(name == "count" && nargs == 0)) || nargs < lo || hi.is_some_and(|h| nargs > h) {
        return err!("wrong number of arguments to function {}()", name);
    }
    Ok(())
}

/// Is a call with `nargs` arguments an aggregate?
pub fn is_aggregate(name: &str, nargs: usize) -> bool {
    match name {
        "count" | "sum" | "total" | "avg" | "group_concat" | "string_agg" => true,
        "min" | "max" => nargs == 1,
        _ => false,
    }
}

fn text(v: &Value) -> Option<String> {
    v.to_text()
}

/// Per-connection counters read by `changes()`, `total_changes()` and
/// `last_insert_rowid()`.
#[derive(Clone, Copy, Debug, Default)]
pub struct ConnState {
    pub changes: i64,
    pub total_changes: i64,
    pub last_insert_rowid: i64,
}

thread_local! {
    static CONN: std::cell::Cell<ConnState> = std::cell::Cell::new(ConnState::default());
}

pub fn conn_state() -> ConnState {
    CONN.with(|c| c.get())
}

pub fn update_conn_state(f: impl FnOnce(&mut ConnState)) {
    CONN.with(|c| {
        let mut s = c.get();
        f(&mut s);
        c.set(s);
    })
}

/// Evaluate a (non-lazy) scalar function on already-evaluated arguments.
pub fn call(name: &str, args: Vec<Value>, coll: Collation) -> Result<Value> {
    if let Some(v) = crate::datetime::call(name, &args) {
        return Ok(v);
    }
    let a0 = args.first().cloned().unwrap_or(Value::Null);
    Ok(match name {
        "typeof" => Value::Text(a0.type_name().to_string()),
        "changes" => Value::Int(conn_state().changes),
        "total_changes" => Value::Int(conn_state().total_changes),
        "last_insert_rowid" => Value::Int(conn_state().last_insert_rowid),
        "abs" => match a0 {
            Value::Null => Value::Null,
            Value::Int(i) => match i.checked_abs() {
                Some(v) => Value::Int(v),
                None => return err!("integer overflow"),
            },
            Value::Real(f) => Value::Real(f.abs()),
            v => Value::Real(v.to_f64().abs()),
        },
        "char" => {
            let mut s = String::new();
            for a in &args {
                let x = a.to_int();
                let c = u32::try_from(x).ok().and_then(char::from_u32).unwrap_or('\u{FFFD}');
                s.push(c);
            }
            Value::Text(s)
        }
        "coalesce" | "ifnull" => args.into_iter().find(|v| !v.is_null()).unwrap_or(Value::Null),
        "iif" | "if" => {
            if a0.truthy() == Some(true) {
                args[1].clone()
            } else {
                args.get(2).cloned().unwrap_or(Value::Null)
            }
        }
        "likely" | "unlikely" | "likelihood" => a0,
        "concat" => {
            let mut s = String::new();
            for a in &args {
                if let Some(t) = text(a) {
                    s.push_str(&t);
                }
            }
            Value::Text(s)
        }
        "concat_ws" => {
            let sep = match text(&a0) {
                Some(s) => s,
                None => return Ok(Value::Null),
            };
            let parts: Vec<String> = args[1..].iter().filter_map(text).collect();
            Value::Text(parts.join(&sep))
        }
        "printf" | "format" => match args.first().and_then(text) {
            Some(f) => Value::Text(printf::format(&f, &args[1..])),
            None => Value::Null,
        },
        "glob" => match like_values(&args[0], &args[1], None, true)? {
            Some(m) => Value::Int(m as i64),
            None => Value::Null,
        },
        "like" => match like_values(&args[0], &args[1], args.get(2), false)? {
            Some(m) => Value::Int(m as i64),
            None => Value::Null,
        },
        "hex" => {
            let mut s = String::new();
            for b in a0.to_bytes() {
                let _ = write!(s, "{:02X}", b);
            }
            Value::Text(s)
        }
        "unhex" => {
            let ignore = match args.get(1) {
                Some(Value::Null) => return Ok(Value::Null),
                Some(v) => text(v).unwrap_or_default(),
                None => String::new(),
            };
            match text(&a0) {
                None => Value::Null,
                Some(s) => match unhex(&s, &ignore) {
                    Some(b) => Value::Blob(b),
                    None => Value::Null,
                },
            }
        }
        "instr" => {
            if a0.is_null() || args[1].is_null() {
                return Ok(Value::Null);
            }
            match (&a0, &args[1]) {
                (Value::Blob(h), Value::Blob(n)) => Value::Int(find_bytes(h, n).map(|i| i as i64 + 1).unwrap_or(0)),
                _ => {
                    let h = text(&a0).unwrap();
                    let n = text(&args[1]).unwrap();
                    Value::Int(match h.find(&n) {
                        Some(i) => h[..i].chars().count() as i64 + 1,
                        None => 0,
                    })
                }
            }
        }
        "length" => match a0 {
            Value::Null => Value::Null,
            Value::Blob(b) => Value::Int(b.len() as i64),
            v => Value::Int(text(&v).unwrap().chars().count() as i64),
        },
        "octet_length" => match a0 {
            Value::Null => Value::Null,
            v => Value::Int(v.to_bytes().len() as i64),
        },
        "lower" | "upper" => match text(&a0) {
            None => Value::Null,
            Some(s) => Value::Text(if name == "lower" { s.to_ascii_lowercase() } else { s.to_ascii_uppercase() }),
        },
        "ltrim" | "rtrim" | "trim" => {
            let s = match text(&a0) {
                Some(s) => s,
                None => return Ok(Value::Null),
            };
            let set: Vec<char> = match args.get(1) {
                None => vec![' '],
                Some(v) => match text(v) {
                    Some(t) => t.chars().collect(),
                    None => return Ok(Value::Null),
                },
            };
            let mut r: &str = &s;
            if name != "rtrim" {
                r = r.trim_start_matches(|c| set.contains(&c));
            }
            if name != "ltrim" {
                r = r.trim_end_matches(|c| set.contains(&c));
            }
            Value::Text(r.to_string())
        }
        "max" | "min" => {
            if args.iter().any(|v| v.is_null()) {
                return Ok(Value::Null);
            }
            let mut best = 0;
            for i in 1..args.len() {
                let c = compare_coll(&args[best], &args[i], coll);
                if (name == "max" && c == Ordering::Less) || (name == "min" && c != Ordering::Less) {
                    best = i;
                }
            }
            args[best].clone()
        }
        "nullif" => {
            if !a0.is_null() && !args[1].is_null() && compare_coll(&a0, &args[1], coll) == Ordering::Equal {
                Value::Null
            } else {
                a0
            }
        }
        "quote" => Value::Text(quote(&a0)),
        "replace" => {
            if args.iter().any(|v| v.is_null()) {
                return Ok(Value::Null);
            }
            let pat = text(&args[1]).unwrap();
            if pat.is_empty() {
                return Ok(a0);
            }
            Value::Text(text(&a0).unwrap().replace(&pat, &text(&args[2]).unwrap()))
        }
        "round" => {
            if a0.is_null() {
                return Ok(Value::Null);
            }
            let n = match args.get(1) {
                Some(Value::Null) => return Ok(Value::Null),
                Some(v) => v.to_int().clamp(0, 30),
                None => 0,
            };
            Value::Real(round(a0.to_f64(), n as usize))
        }
        "sign" => match a0.as_strict_number() {
            Some(Value::Int(i)) => Value::Int(i.signum()),
            Some(Value::Real(f)) => Value::Int(if f > 0.0 {
                1
            } else if f < 0.0 {
                -1
            } else {
                0
            }),
            _ => Value::Null,
        },
        "substr" | "substring" => substr(&args),
        "unicode" => match text(&a0).and_then(|s| s.chars().next()) {
            Some(c) => Value::Int(c as i64),
            None => Value::Null,
        },
        "zeroblob" => Value::Blob(vec![0; a0.to_int().max(0) as usize]),
        // Math functions.
        "pi" => Value::Real(std::f64::consts::PI),
        "ceil" | "ceiling" | "floor" | "trunc" => match a0.as_strict_number() {
            Some(Value::Int(i)) => Value::Int(i),
            Some(Value::Real(f)) => Value::Real(match name {
                "floor" => f.floor(),
                "trunc" => f.trunc(),
                _ => f.ceil(),
            }),
            _ => Value::Null,
        },
        "log" | "ln" | "log10" | "log2" => {
            let x = match num(&a0) {
                Some(x) if x > 0.0 => x,
                _ => return Ok(Value::Null),
            };
            if args.len() == 2 {
                let y = match num(&args[1]) {
                    Some(y) if y > 0.0 => y,
                    _ => return Ok(Value::Null),
                };
                if x.ln() == 0.0 {
                    return Ok(Value::Null);
                }
                Value::real(y.ln() / x.ln())
            } else {
                Value::real(match name {
                    "ln" => x.ln(),
                    "log2" => x.log2(),
                    _ => x.log10(),
                })
            }
        }
        "atan2" | "pow" | "power" | "mod" => {
            let (x, y) = match (num(&a0), num(&args[1])) {
                (Some(x), Some(y)) => (x, y),
                _ => return Ok(Value::Null),
            };
            Value::real(match name {
                "atan2" => x.atan2(y),
                "mod" => x % y,
                _ => x.powf(y),
            })
        }
        _ => {
            let f: fn(f64) -> f64 = match name {
                "acos" => f64::acos,
                "acosh" => f64::acosh,
                "asin" => f64::asin,
                "asinh" => f64::asinh,
                "atan" => f64::atan,
                "atanh" => f64::atanh,
                "cos" => f64::cos,
                "cosh" => f64::cosh,
                "degrees" => |x| x * (180.0 / std::f64::consts::PI),
                "radians" => |x| x * (std::f64::consts::PI / 180.0),
                "exp" => f64::exp,
                "sin" => f64::sin,
                "sinh" => f64::sinh,
                "sqrt" => f64::sqrt,
                "tan" => f64::tan,
                "tanh" => f64::tanh,
                _ => return err!("no such function: {}", name),
            };
            match num(&a0) {
                Some(x) => Value::real(f(x)),
                None => Value::Null,
            }
        }
    })
}

/// Numeric argument of a math function (None for NULL and non-numbers).
fn num(v: &Value) -> Option<f64> {
    match v.as_strict_number()? {
        Value::Int(i) => Some(i as f64),
        Value::Real(f) => Some(f),
        _ => None,
    }
}

/// SQLite's round(): half away from zero on the decimal expansion.
pub fn round(x: f64, n: usize) -> f64 {
    if !(-4503599627370496.0..=4503599627370496.0).contains(&x) {
        x
    } else if n == 0 {
        ((x + if x < 0.0 { -0.5 } else { 0.5 }) as i64) as f64
    } else {
        printf::format_float(x, b'f', n, true).parse::<f64>().unwrap_or(x)
    }
}

pub fn quote(v: &Value) -> String {
    match v {
        Value::Null => "NULL".into(),
        Value::Int(i) => i.to_string(),
        Value::Real(f) => {
            if f.is_infinite() {
                return if *f > 0.0 { "9.0e+999".into() } else { "-9.0e+999".into() };
            }
            let s = printf::format_float(*f, b'g', 15, true);
            if s.parse::<f64>().ok() == Some(*f) {
                s
            } else {
                printf::format_float(*f, b'e', 20, true)
            }
        }
        Value::Text(s) => format!("'{}'", s.replace('\'', "''")),
        Value::Blob(b) => {
            let mut s = String::from("X'");
            for x in b {
                let _ = write!(s, "{:02X}", x);
            }
            s.push('\'');
            s
        }
    }
}

fn find_bytes(h: &[u8], n: &[u8]) -> Option<usize> {
    if n.is_empty() {
        return Some(0);
    }
    h.windows(n.len()).position(|w| w == n)
}

fn unhex(s: &str, ignore: &str) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let mut it = s.chars();
    while let Some(c) = it.next() {
        match c.to_digit(16) {
            Some(hi) => {
                let lo = it.next()?.to_digit(16)?;
                out.push((hi * 16 + lo) as u8);
            }
            None => {
                if !ignore.contains(c) {
                    return None;
                }
            }
        }
    }
    Some(out)
}

fn substr(args: &[Value]) -> Value {
    if args.iter().any(|v| v.is_null()) {
        return Value::Null;
    }
    let mut p1 = args[1].to_int();
    let mut neg_p2 = false;
    let mut p2 = match args.get(2) {
        Some(v) => {
            let x = v.to_int();
            if x < 0 {
                neg_p2 = true;
                x.saturating_neg()
            } else {
                x
            }
        }
        None => i64::MAX / 4,
    };
    let (chars, bytes): (Option<Vec<char>>, Option<&Vec<u8>>) = match &args[0] {
        Value::Blob(b) => (None, Some(b)),
        v => (Some(v.to_text().unwrap().chars().collect()), None),
    };
    let len = match (&chars, bytes) {
        (Some(c), _) => c.len() as i64,
        (_, Some(b)) => b.len() as i64,
        _ => 0,
    };
    if p1 < 0 {
        p1 = p1.saturating_add(len);
        if p1 < 0 {
            p2 = p2.saturating_add(p1).max(0);
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
    let start = p1.min(len);
    let end = start.saturating_add(p2).min(len);
    let (start, end) = (start as usize, end as usize);
    match (chars, bytes) {
        (Some(c), _) => Value::Text(c[start..end].iter().collect()),
        (_, Some(b)) => Value::Blob(b[start..end].to_vec()),
        _ => Value::Null,
    }
}

/// `x LIKE pat [ESCAPE esc]` / `x GLOB pat`; None when a NULL is involved.
pub fn like_values(pat: &Value, x: &Value, esc: Option<&Value>, glob: bool) -> Result<Option<bool>> {
    let esc = match esc {
        None => None,
        Some(Value::Null) => return Ok(None),
        Some(v) => {
            let t = v.to_text().unwrap();
            let mut cs = t.chars();
            match (cs.next(), cs.next()) {
                (Some(c), None) => Some(c),
                _ => return err!("ESCAPE expression must be a single character"),
            }
        }
    };
    let (p, s) = match (pat.to_text(), x.to_text()) {
        (Some(p), Some(s)) => (p, s),
        _ => return Ok(None),
    };
    let p: Vec<char> = p.chars().collect();
    let s: Vec<char> = s.chars().collect();
    Ok(Some(if glob {
        glob_match(&p, &s)
    } else {
        let all = if esc == Some('%') { None } else { Some('%') };
        let one = if esc == Some('_') { None } else { Some('_') };
        like_match(&p, &s, esc, all, one)
    }))
}

fn fold(c: char) -> char {
    c.to_ascii_lowercase()
}

fn like_match(p: &[char], s: &[char], esc: Option<char>, all: Option<char>, one: Option<char>) -> bool {
    let (mut pi, mut si) = (0, 0);
    while pi < p.len() {
        let c = p[pi];
        if Some(c) == all {
            let mut need = 0;
            while pi < p.len() && (Some(p[pi]) == all || Some(p[pi]) == one) {
                if Some(p[pi]) == one {
                    need += 1;
                }
                pi += 1;
            }
            if si + need > s.len() {
                return false;
            }
            si += need;
            if pi == p.len() {
                return true;
            }
            return (si..=s.len()).any(|k| like_match(&p[pi..], &s[k..], esc, all, one));
        }
        if Some(c) == one {
            if si >= s.len() {
                return false;
            }
            pi += 1;
            si += 1;
            continue;
        }
        let lit = if Some(c) == esc {
            pi += 1;
            if pi >= p.len() {
                return false;
            }
            p[pi]
        } else {
            c
        };
        if si >= s.len() || fold(lit) != fold(s[si]) {
            return false;
        }
        pi += 1;
        si += 1;
    }
    si == s.len()
}

fn glob_match(p: &[char], s: &[char]) -> bool {
    let (mut pi, mut si) = (0, 0);
    while pi < p.len() {
        match p[pi] {
            '*' => {
                let mut need = 0;
                while pi < p.len() && (p[pi] == '*' || p[pi] == '?') {
                    if p[pi] == '?' {
                        need += 1;
                    }
                    pi += 1;
                }
                if si + need > s.len() {
                    return false;
                }
                si += need;
                if pi == p.len() {
                    return true;
                }
                return (si..=s.len()).any(|k| glob_match(&p[pi..], &s[k..]));
            }
            '?' => {
                if si >= s.len() {
                    return false;
                }
                pi += 1;
                si += 1;
            }
            '[' => {
                if si >= s.len() {
                    return false;
                }
                let c = s[si];
                let mut j = pi + 1;
                let negate = j < p.len() && p[j] == '^';
                if negate {
                    j += 1;
                }
                let mut matched = false;
                let mut first = true;
                loop {
                    if j >= p.len() {
                        return false;
                    }
                    if p[j] == ']' && !first {
                        break;
                    }
                    first = false;
                    if j + 2 < p.len() && p[j + 1] == '-' && p[j + 2] != ']' {
                        if p[j] <= c && c <= p[j + 2] {
                            matched = true;
                        }
                        j += 3;
                    } else {
                        if p[j] == c {
                            matched = true;
                        }
                        j += 1;
                    }
                }
                if matched == negate {
                    return false;
                }
                pi = j + 1;
                si += 1;
            }
            c => {
                if si >= s.len() || s[si] != c {
                    return false;
                }
                pi += 1;
                si += 1;
            }
        }
    }
    si == s.len()
}
