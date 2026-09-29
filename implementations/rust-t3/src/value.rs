// SQL values, conversions, comparison and formatting (SQLite semantics).

use std::cmp::Ordering;

#[derive(Debug, Clone)]
pub enum Value {
    Null,
    Integer(i64),
    Real(f64),
    Text(String),
    Blob(Vec<u8>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Affinity {
    None,
    Blob,
    Text,
    Numeric,
    Integer,
    Real,
}

impl Affinity {
    pub fn is_numeric(self) -> bool {
        matches!(self, Affinity::Numeric | Affinity::Integer | Affinity::Real)
    }

    /// Affinity of a declared column type, by SQLite's rules.
    pub fn from_type(decl: Option<&str>) -> Affinity {
        let t = match decl {
            None => return Affinity::Blob,
            Some(t) => t.to_ascii_uppercase(),
        };
        if t.contains("INT") {
            Affinity::Integer
        } else if t.contains("CHAR") || t.contains("CLOB") || t.contains("TEXT") {
            Affinity::Text
        } else if t.contains("BLOB") || t.trim().is_empty() {
            Affinity::Blob
        } else if t.contains("REAL") || t.contains("FLOA") || t.contains("DOUB") {
            Affinity::Real
        } else {
            Affinity::Numeric
        }
    }
}

/// Collating sequences.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Coll {
    Binary,
    NoCase,
    Rtrim,
    /// An unknown collation name: an error once a comparison needs it.
    Invalid,
}

impl Coll {
    pub fn from_name(name: &str) -> Result<Coll, String> {
        if name.eq_ignore_ascii_case("binary") {
            Ok(Coll::Binary)
        } else if name.eq_ignore_ascii_case("nocase") {
            Ok(Coll::NoCase)
        } else if name.eq_ignore_ascii_case("rtrim") {
            Ok(Coll::Rtrim)
        } else {
            Err(format!("no such collation sequence: {}", name))
        }
    }
}

/// Compares two strings under a collation.
pub fn compare_text(a: &str, b: &str, coll: Coll) -> Ordering {
    match coll {
        Coll::Binary | Coll::Invalid => a.as_bytes().cmp(b.as_bytes()),
        Coll::NoCase => {
            let x = a.as_bytes().iter().map(|c| c.to_ascii_lowercase());
            let y = b.as_bytes().iter().map(|c| c.to_ascii_lowercase());
            x.cmp(y)
        }
        Coll::Rtrim => a.trim_end_matches(' ').as_bytes().cmp(b.trim_end_matches(' ').as_bytes()),
    }
}

/// A number obtained from a value for arithmetic.
#[derive(Debug, Clone, Copy)]
pub enum Num {
    Int(i64),
    Real(f64),
}

impl Value {
    pub fn is_null(&self) -> bool {
        matches!(self, Value::Null)
    }

    pub fn type_name(&self) -> &'static str {
        match self {
            Value::Null => "null",
            Value::Integer(_) => "integer",
            Value::Real(_) => "real",
            Value::Text(_) => "text",
            Value::Blob(_) => "blob",
        }
    }

    /// Text used when printing a row.
    pub fn to_output(&self) -> String {
        match self {
            Value::Null => "NULL".to_string(),
            Value::Integer(i) => i.to_string(),
            Value::Real(r) => format_real(*r),
            Value::Text(s) => s.clone(),
            Value::Blob(b) => {
                let mut s = String::with_capacity(3 + b.len() * 2);
                s.push_str("X'");
                for byte in b {
                    s.push_str(&format!("{:02X}", byte));
                }
                s.push('\'');
                s
            }
        }
    }

    /// Conversion to TEXT (as for `||` or TEXT affinity). NULL gives None.
    pub fn to_text(&self) -> Option<String> {
        match self {
            Value::Null => None,
            Value::Integer(i) => Some(i.to_string()),
            Value::Real(r) => Some(format_real(*r)),
            Value::Text(s) => Some(s.clone()),
            Value::Blob(b) => Some(String::from_utf8_lossy(b).into_owned()),
        }
    }

    /// Numeric value for arithmetic; NULL must be handled by the caller.
    pub fn to_num(&self) -> Num {
        match self {
            Value::Null => Num::Int(0),
            Value::Integer(i) => Num::Int(*i),
            Value::Real(r) => Num::Real(*r),
            Value::Text(s) => text_to_num(s.as_bytes()),
            Value::Blob(b) => text_to_num(b),
        }
    }

    pub fn to_real(&self) -> f64 {
        match self {
            Value::Null => 0.0,
            Value::Integer(i) => *i as f64,
            Value::Real(r) => *r,
            Value::Text(s) => atof(s.as_bytes()).0,
            Value::Blob(b) => atof(b).0,
        }
    }

    /// Integer value (sqlite3VdbeIntValue): reals truncate and saturate, text
    /// uses its longest integer prefix.
    pub fn to_int(&self) -> i64 {
        match self {
            Value::Null => 0,
            Value::Integer(i) => *i,
            Value::Real(r) => real_to_i64(*r),
            Value::Text(s) => atoi64(s.as_bytes()).0,
            Value::Blob(b) => atoi64(b).0,
        }
    }

    /// The value with numeric affinity applied if it is text (as for
    /// sqlite3_value_numeric_type).
    pub fn numeric(&self) -> Value {
        match self {
            Value::Text(s) => numeric_from_text(s, false).unwrap_or_else(|| self.clone()),
            _ => self.clone(),
        }
    }

    /// Bytes of the value's text or blob form (None for NULL).
    pub fn to_bytes(&self) -> Option<Vec<u8>> {
        match self {
            Value::Null => None,
            Value::Blob(b) => Some(b.clone()),
            Value::Text(s) => Some(s.as_bytes().to_vec()),
            _ => self.to_text().map(|s| s.into_bytes()),
        }
    }

    /// Truth value of a condition; None for NULL.
    pub fn truth(&self) -> Option<bool> {
        match self {
            Value::Null => None,
            Value::Integer(i) => Some(*i != 0),
            _ => Some(self.to_real() != 0.0),
        }
    }

    pub fn from_bool(b: bool) -> Value {
        Value::Integer(b as i64)
    }
}

fn text_to_num(b: &[u8]) -> Num {
    let (r, rc) = atof(b);
    if rc == 0 || rc == 1 {
        let (i, irc) = atoi64(b);
        if irc <= 1 {
            return Num::Int(i);
        }
    }
    Num::Real(r)
}

pub fn is_space(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r')
}

/// Like sqlite3AtoF. Returns the value of the longest numeric prefix and a code:
/// 0 not a number (prefix without '.'/exponent, or no digits), -1 not a number but
/// the prefix has '.'/exponent, 1 a pure integer, 2 a pure real.
pub fn atof(s: &[u8]) -> (f64, i32) {
    let n = s.len();
    let mut i = 0;
    while i < n && is_space(s[i]) {
        i += 1;
    }
    let start = i;
    if i < n && (s[i] == b'+' || s[i] == b'-') {
        i += 1;
    }
    let mut digits = 0;
    while i < n && s[i].is_ascii_digit() {
        i += 1;
        digits += 1;
    }
    let mut real = false;
    if i < n && s[i] == b'.' {
        let save = i;
        i += 1;
        let mut fd = 0;
        while i < n && s[i].is_ascii_digit() {
            i += 1;
            fd += 1;
        }
        if digits + fd == 0 {
            i = save;
        } else {
            digits += fd;
            real = true;
        }
    }
    if digits == 0 {
        return (0.0, 0);
    }
    let mant_end = i;
    if i < n && (s[i] == b'e' || s[i] == b'E') {
        let mut j = i + 1;
        if j < n && (s[j] == b'+' || s[j] == b'-') {
            j += 1;
        }
        let ds = j;
        while j < n && s[j].is_ascii_digit() {
            j += 1;
        }
        if j > ds {
            i = j;
            real = true;
        }
    }
    let _ = mant_end;
    let text = std::str::from_utf8(&s[start..i]).unwrap_or("0");
    let v = parse_f64_lenient(text);
    let end = i;
    let mut k = end;
    while k < n && is_space(s[k]) {
        k += 1;
    }
    let rc = if k == n {
        if real {
            2
        } else {
            1
        }
    } else if real {
        -1
    } else {
        0
    };
    (v, rc)
}

fn parse_f64_lenient(t: &str) -> f64 {
    if let Ok(v) = t.parse::<f64>() {
        return v;
    }
    // Rust rejects forms like "5." with sign or huge exponents in some cases; patch up.
    let mut s = t.to_string();
    if let Some(p) = s.find(['e', 'E']) {
        if s[..p].ends_with('.') {
            s.insert(p, '0');
        }
    } else if s.ends_with('.') {
        s.push('0');
    }
    s.parse::<f64>().unwrap_or(0.0)
}

/// Like sqlite3Atoi64. Returns value and code: 0 ok, 1 trailing non-space text,
/// -1 no digits, 2 overflow, 3 exactly 9223372036854775808 (positive).
pub fn atoi64(s: &[u8]) -> (i64, i32) {
    let n = s.len();
    let mut i = 0;
    while i < n && is_space(s[i]) {
        i += 1;
    }
    let mut neg = false;
    if i < n {
        if s[i] == b'-' {
            neg = true;
            i += 1;
        } else if s[i] == b'+' {
            i += 1;
        }
    }
    let zstart = i;
    while i < n && s[i] == b'0' {
        i += 1;
    }
    let dstart = i;
    let mut u: u64 = 0;
    let mut overflow = false;
    while i < n && s[i].is_ascii_digit() {
        match u.checked_mul(10).and_then(|x| x.checked_add((s[i] - b'0') as u64)) {
            Some(x) => u = x,
            None => overflow = true,
        }
        i += 1;
    }
    let nd = i - dstart;
    let mut rc = 0;
    if nd == 0 && zstart == i {
        rc = -1;
    } else if i < n && s[i..].iter().any(|&c| !is_space(c)) {
        rc = 1;
    }
    const LIM: u64 = 9223372036854775808;
    if overflow || u > LIM {
        return (if neg { i64::MIN } else { i64::MAX }, 2);
    }
    if u == LIM {
        if neg {
            return (i64::MIN, rc);
        }
        return (i64::MAX, 3);
    }
    let v = u as i64;
    (if neg { -v } else { v }, rc)
}

/// Saturating real to integer conversion (doubleToInt64).
pub fn real_to_i64(r: f64) -> i64 {
    if r.is_nan() {
        0
    } else if r <= -9223372036854775808.0 {
        i64::MIN
    } else if r >= 9223372036854775807.0 {
        i64::MAX
    } else {
        r as i64
    }
}

/// CAST(v AS <type with affinity aff>).
pub fn cast(v: Value, aff: Affinity) -> Value {
    if v.is_null() {
        return v;
    }
    match aff {
        Affinity::Blob | Affinity::None => match v {
            Value::Blob(_) => v,
            other => Value::Blob(other.to_bytes().unwrap_or_default()),
        },
        Affinity::Text => Value::Text(v.to_text().unwrap_or_default()),
        Affinity::Integer => Value::Integer(v.to_int()),
        Affinity::Real => Value::Real(v.to_real()),
        Affinity::Numeric => match v {
            Value::Integer(_) | Value::Real(_) => v,
            Value::Text(ref s) => numerify(s.as_bytes()),
            Value::Blob(ref b) => numerify(b),
            Value::Null => v,
        },
    }
}

/// sqlite3VdbeMemNumerify on text bytes.
fn numerify(b: &[u8]) -> Value {
    let (r, rc) = atof(b);
    if rc == 0 || rc == 1 {
        let (i, irc) = atoi64(b);
        if irc <= 1 {
            return Value::Integer(i);
        }
    }
    let ix = real_to_i64(r);
    if r == 0.0 || (ix as f64 == r && (-2251799813685248..2251799813685248).contains(&ix)) {
        return Value::Integer(ix);
    }
    Value::Real(r)
}

/// Converts a real to an integer if it is exactly representable (sqlite3VdbeIntegerAffinity).
fn real_to_int_exact(r: f64) -> Option<i64> {
    if !(r > -9223372036854775808.0 && r < 9223372036854775808.0) {
        return None;
    }
    let ix = r as i64;
    if ix as f64 == r && ix > i64::MIN && ix < i64::MAX {
        Some(ix)
    } else {
        None
    }
}

/// Numeric affinity applied to a text value (applyNumericAffinity).
fn numeric_from_text(s: &str, try_int: bool) -> Option<Value> {
    let (r, rc) = atof(s.as_bytes());
    if rc <= 0 {
        return None;
    }
    if rc == 1 {
        let (i, irc) = atoi64(s.as_bytes());
        if irc == 0 {
            return Some(Value::Integer(i));
        }
    }
    if try_int {
        if let Some(i) = real_to_int_exact(r) {
            return Some(Value::Integer(i));
        }
    }
    Some(Value::Real(r))
}

/// Applies a column affinity to a value being stored.
pub fn apply_affinity(v: Value, aff: Affinity) -> Value {
    match aff {
        Affinity::None | Affinity::Blob => v,
        Affinity::Text => match v {
            Value::Integer(_) | Value::Real(_) => Value::Text(v.to_text().unwrap()),
            other => other,
        },
        Affinity::Numeric | Affinity::Integer => match v {
            Value::Text(ref s) => numeric_from_text(s, true).unwrap_or(v),
            Value::Real(r) => match real_to_int_exact(r) {
                Some(i) => Value::Integer(i),
                None => v,
            },
            other => other,
        },
        Affinity::Real => match v {
            Value::Text(ref s) => match numeric_from_text(s, true) {
                Some(Value::Integer(i)) => Value::Real(i as f64),
                Some(x) => x,
                None => v,
            },
            Value::Integer(i) => Value::Real(i as f64),
            other => other,
        },
    }
}

/// Affinity applied to a comparison operand (no forcing to integer).
pub fn apply_cmp_affinity(v: &Value, aff: Affinity) -> Option<Value> {
    match aff {
        Affinity::Numeric | Affinity::Integer | Affinity::Real => match v {
            Value::Text(s) => numeric_from_text(s, false),
            _ => None,
        },
        Affinity::Text => match v {
            Value::Integer(_) | Value::Real(_) => Some(Value::Text(v.to_text().unwrap())),
            _ => None,
        },
        _ => None,
    }
}

/// Comparison under a collation (text only; other classes as `compare`).
pub fn compare_coll(a: &Value, b: &Value, coll: Coll) -> Ordering {
    match (a, b) {
        (Value::Text(x), Value::Text(y)) => compare_text(x, y, coll),
        _ => compare(a, b),
    }
}

pub fn int_float_cmp(i: i64, r: f64) -> Ordering {
    if r.is_nan() {
        return Ordering::Greater;
    }
    if r < -9223372036854775808.0 {
        return Ordering::Greater;
    }
    if r >= 9223372036854775808.0 {
        return Ordering::Less;
    }
    let y = r as i64;
    if i < y {
        return Ordering::Less;
    }
    if i > y {
        return Ordering::Greater;
    }
    let s = i as f64;
    s.partial_cmp(&r).unwrap_or(Ordering::Equal)
}

fn class_rank(v: &Value) -> u8 {
    match v {
        Value::Null => 0,
        Value::Integer(_) | Value::Real(_) => 1,
        Value::Text(_) => 2,
        Value::Blob(_) => 3,
    }
}

/// Total order used for sorting and comparisons (BINARY collation).
pub fn compare(a: &Value, b: &Value) -> Ordering {
    match (a, b) {
        (Value::Integer(x), Value::Integer(y)) => x.cmp(y),
        (Value::Real(x), Value::Real(y)) => x.partial_cmp(y).unwrap_or(Ordering::Equal),
        (Value::Integer(x), Value::Real(y)) => int_float_cmp(*x, *y),
        (Value::Real(x), Value::Integer(y)) => int_float_cmp(*y, *x).reverse(),
        (Value::Text(x), Value::Text(y)) => x.as_bytes().cmp(y.as_bytes()),
        (Value::Blob(x), Value::Blob(y)) => x.cmp(y),
        _ => class_rank(a).cmp(&class_rank(b)),
    }
}

/// Formats a REAL per the output protocol.
pub fn format_real(r: f64) -> String {
    if r.is_nan() {
        return "NULL".to_string();
    }
    if r.is_infinite() {
        return if r > 0.0 { "Inf".to_string() } else { "-Inf".to_string() };
    }
    if r == 0.0 {
        return "0.0".to_string();
    }
    let s = shortest_sci(r);
    let (neg, rest) = match s.strip_prefix('-') {
        Some(x) => (true, x),
        None => (false, s.as_str()),
    };
    let (mant, exp) = rest.split_once('e').unwrap();
    let exp: i32 = exp.parse().unwrap();
    let digits: String = mant.chars().filter(|c| *c != '.').collect();
    let mut out = String::new();
    if neg {
        out.push('-');
    }
    if exp > -5 && exp < 16 {
        if exp >= 0 {
            let e = exp as usize;
            if digits.len() > e + 1 {
                out.push_str(&digits[..e + 1]);
                out.push('.');
                out.push_str(&digits[e + 1..]);
            } else {
                out.push_str(&digits);
                for _ in 0..(e + 1 - digits.len()) {
                    out.push('0');
                }
                out.push_str(".0");
            }
        } else {
            out.push_str("0.");
            for _ in 0..(-exp - 1) {
                out.push('0');
            }
            out.push_str(&digits);
        }
    } else {
        out.push_str(&digits[..1]);
        out.push('.');
        if digits.len() > 1 {
            out.push_str(&digits[1..]);
        } else {
            out.push('0');
        }
        out.push('e');
        out.push(if exp < 0 { '-' } else { '+' });
        out.push_str(&format!("{:02}", exp.abs()));
    }
    out
}

/// Shortest round-trip digits in `{:e}` form; among equally short candidates,
/// the one nearest the exact value (ties to even).
fn shortest_sci(r: f64) -> String {
    let s = format!("{:e}", r);
    let mant = s.split('e').next().unwrap();
    let ndigits = mant.chars().filter(|c| c.is_ascii_digit()).count();
    if ndigits > 1 {
        let alt = format!("{:.*e}", ndigits - 1, r);
        if alt.parse::<f64>() == Ok(r) {
            return alt;
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reals() {
        assert_eq!(format_real(1.0), "1.0");
        assert_eq!(format_real(123456.789), "123456.789");
        assert_eq!(format_real(0.0001), "0.0001");
        assert_eq!(format_real(0.00001), "1.0e-05");
        assert_eq!(format_real(1e15), "1000000000000000.0");
        assert_eq!(format_real(1e16), "1.0e+16");
        assert_eq!(format_real(-2.5e-7), "-2.5e-07");
        assert_eq!(format_real(5e-324), "5.0e-324");
        assert_eq!(format_real(1e15 + 0.3), "1000000000000000.2");
    }
}
