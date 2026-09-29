// Values, type affinity, conversions, comparison and output formatting.

use std::cmp::Ordering;
use std::fmt::Write;

#[derive(Clone, Debug)]
pub enum Value {
    Null,
    Int(i64),
    Real(f64),
    Text(String),
    Blob(Vec<u8>),
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Affinity {
    Integer,
    Real,
    Numeric,
    Text,
    /// BLOB affinity, which is also "no affinity".
    Blob,
}

impl Affinity {
    pub fn is_numeric(self) -> bool {
        matches!(self, Affinity::Integer | Affinity::Real | Affinity::Numeric)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Collation {
    Binary,
    NoCase,
    Rtrim,
}

impl Collation {
    pub fn from_name(name: &str) -> Option<Collation> {
        if name.eq_ignore_ascii_case("BINARY") {
            Some(Collation::Binary)
        } else if name.eq_ignore_ascii_case("NOCASE") {
            Some(Collation::NoCase)
        } else if name.eq_ignore_ascii_case("RTRIM") {
            Some(Collation::Rtrim)
        } else {
            None
        }
    }

    pub fn compare_str(self, a: &str, b: &str) -> Ordering {
        let (x, y) = (a.as_bytes(), b.as_bytes());
        match self {
            Collation::Binary => x.cmp(y),
            Collation::NoCase => {
                let n = x.len().min(y.len());
                for i in 0..n {
                    let (p, q) = (x[i].to_ascii_lowercase(), y[i].to_ascii_lowercase());
                    if p != q {
                        return p.cmp(&q);
                    }
                }
                x.len().cmp(&y.len())
            }
            Collation::Rtrim => {
                let n = x.len().min(y.len());
                match x[..n].cmp(&y[..n]) {
                    Ordering::Equal => {
                        let rest = if x.len() > n { &x[n..] } else { &y[n..] };
                        if rest.iter().all(|&c| c == b' ') {
                            Ordering::Equal
                        } else {
                            x.len().cmp(&y.len())
                        }
                    }
                    o => o,
                }
            }
        }
    }
}

/// Column affinity from a declared type name (SQLite §3.1 rules).
pub fn affinity_of_type(decl: &str) -> Affinity {
    let t = decl.to_ascii_uppercase();
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

pub fn is_space(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r')
}

/// Result of scanning a numeric prefix.
struct NumScan {
    /// Byte length of the numeric prefix (after leading whitespace).
    end: usize,
    /// True if a '.' or exponent was part of the number.
    is_real: bool,
    /// True if any digit was seen.
    any_digits: bool,
}

fn scan_number(b: &[u8], start: usize) -> NumScan {
    let mut i = start;
    if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
        i += 1;
    }
    let mut digits = 0;
    while i < b.len() && b[i].is_ascii_digit() {
        i += 1;
        digits += 1;
    }
    let mut is_real = false;
    if i < b.len() && b[i] == b'.' {
        let mut j = i + 1;
        let mut frac = 0;
        while j < b.len() && b[j].is_ascii_digit() {
            j += 1;
            frac += 1;
        }
        if digits + frac > 0 {
            is_real = true;
            digits += frac;
            i = j;
        }
    }
    if digits > 0 && i < b.len() && (b[i] == b'e' || b[i] == b'E') {
        let mut j = i + 1;
        if j < b.len() && (b[j] == b'+' || b[j] == b'-') {
            j += 1;
        }
        let es = j;
        while j < b.len() && b[j].is_ascii_digit() {
            j += 1;
        }
        if j > es {
            is_real = true;
            i = j;
        }
    }
    NumScan { end: i, is_real, any_digits: digits > 0 }
}

fn number_from_text(s: &str, is_real: bool) -> Value {
    if !is_real {
        if let Ok(v) = s.parse::<i64>() {
            return Value::Int(v);
        }
    }
    Value::Real(s.parse::<f64>().unwrap_or(0.0))
}

/// Parse text as a number the way SQLite does for arithmetic: the longest
/// numeric prefix after leading whitespace; no digits means 0.
pub fn text_to_numeric(s: &str) -> Value {
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() && is_space(b[i]) {
        i += 1;
    }
    let scan = scan_number(b, i);
    if !scan.any_digits {
        return Value::Int(0);
    }
    number_from_text(&s[i..scan.end], scan.is_real)
}

/// Integer value of text as SQLite's sqlite3Atoi64 reads it: optional
/// whitespace and sign, then the longest run of digits; saturates.
pub fn text_to_int_prefix(s: &str) -> i64 {
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() && is_space(b[i]) {
        i += 1;
    }
    let mut neg = false;
    if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
        neg = b[i] == b'-';
        i += 1;
    }
    let mut v: i128 = 0;
    while i < b.len() && b[i].is_ascii_digit() {
        v = v * 10 + (b[i] - b'0') as i128;
        if v > (i64::MAX as i128) + 1 {
            v = (i64::MAX as i128) + 1;
        }
        i += 1;
    }
    if neg {
        v = -v;
    }
    v.clamp(i64::MIN as i128, i64::MAX as i128) as i64
}

/// Parse text that must be entirely a number (surrounding whitespace allowed).
pub fn text_to_numeric_strict(s: &str) -> Option<Value> {
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() && is_space(b[i]) {
        i += 1;
    }
    let scan = scan_number(b, i);
    if !scan.any_digits {
        return None;
    }
    let mut j = scan.end;
    while j < b.len() && is_space(b[j]) {
        j += 1;
    }
    if j != b.len() {
        return None;
    }
    Some(number_from_text(&s[i..scan.end], scan.is_real))
}

/// f64 -> i64 if the real is an exact integer in range.
pub fn real_as_exact_int(f: f64) -> Option<i64> {
    if f.fract() == 0.0 && f > -9.223372036854775808e18 && f < 9.223372036854775808e18 {
        Some(f as i64)
    } else {
        None
    }
}

pub fn format_real(f: f64) -> String {
    if f.is_nan() {
        return "NULL".to_string();
    }
    if f.is_infinite() {
        return if f > 0.0 { "Inf".into() } else { "-Inf".into() };
    }
    if f == 0.0 {
        return "0.0".into();
    }
    // Shortest round-trip digit count; among candidates of that length
    // pick the one closest to the exact value (ties to even), like repr.
    let mut e = format!("{:e}", f);
    let ndigits = e.split_once('e').unwrap().0.chars().filter(|c| c.is_ascii_digit()).count();
    if ndigits > 1 {
        let exact = format!("{:.*e}", ndigits - 1, f);
        if exact.parse::<f64>().ok() == Some(f) {
            e = exact;
        }
    }
    let (mant, exp) = e.split_once('e').unwrap();
    let exp: i32 = exp.parse().unwrap();
    let neg = mant.starts_with('-');
    let digits: String = mant.chars().filter(|c| c.is_ascii_digit()).collect();
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
                for _ in digits.len()..e + 1 {
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
        let _ = write!(out, "{:02}", exp.abs());
    }
    out
}

impl Value {
    pub fn type_name(&self) -> &'static str {
        match self {
            Value::Null => "null",
            Value::Int(_) => "integer",
            Value::Real(_) => "real",
            Value::Text(_) => "text",
            Value::Blob(_) => "blob",
        }
    }

    pub fn is_null(&self) -> bool {
        matches!(self, Value::Null)
    }

    /// Normalize a real result: NaN becomes NULL.
    pub fn real(f: f64) -> Value {
        if f.is_nan() {
            Value::Null
        } else {
            Value::Real(f)
        }
    }

    /// Output representation (SPEC §2.3).
    pub fn render(&self) -> String {
        match self {
            Value::Null => "NULL".into(),
            Value::Int(i) => i.to_string(),
            Value::Real(f) => format_real(*f),
            Value::Text(s) => s.clone(),
            Value::Blob(b) => {
                let mut s = String::with_capacity(3 + b.len() * 2);
                s.push_str("X'");
                for x in b {
                    let _ = write!(s, "{:02X}", x);
                }
                s.push('\'');
                s
            }
        }
    }

    /// Text conversion (CAST AS TEXT, ||). NULL stays None.
    pub fn to_text(&self) -> Option<String> {
        match self {
            Value::Null => None,
            Value::Int(i) => Some(i.to_string()),
            Value::Real(f) => Some(format_real(*f)),
            Value::Text(s) => Some(s.clone()),
            Value::Blob(b) => Some(String::from_utf8_lossy(b).into_owned()),
        }
    }

    /// Numeric value for arithmetic: Int or Real; NULL stays NULL.
    pub fn to_numeric(&self) -> Value {
        match self {
            Value::Null => Value::Null,
            Value::Int(_) | Value::Real(_) => self.clone(),
            Value::Text(s) => text_to_numeric(s),
            Value::Blob(b) => text_to_numeric(&String::from_utf8_lossy(b)),
        }
    }

    pub fn to_f64(&self) -> f64 {
        match self.to_numeric() {
            Value::Int(i) => i as f64,
            Value::Real(f) => f,
            _ => 0.0,
        }
    }

    pub fn to_i64(&self) -> i64 {
        match self.to_numeric() {
            Value::Int(i) => i,
            Value::Real(f) => real_to_i64(f),
            _ => 0,
        }
    }

    /// Integer value as sqlite3_value_int64 computes it (CAST AS INTEGER).
    pub fn to_int(&self) -> i64 {
        match self {
            Value::Null => 0,
            Value::Int(i) => *i,
            Value::Real(f) => real_to_i64(*f),
            Value::Text(s) => text_to_int_prefix(s),
            Value::Blob(b) => text_to_int_prefix(&String::from_utf8_lossy(b)),
        }
    }

    /// Bytes of the value's text form (or the blob itself).
    pub fn to_bytes(&self) -> Vec<u8> {
        match self {
            Value::Blob(b) => b.clone(),
            v => v.to_text().unwrap_or_default().into_bytes(),
        }
    }

    /// CAST(self AS <type with affinity aff>).
    pub fn cast(self, aff: Affinity) -> Value {
        if self.is_null() {
            return Value::Null;
        }
        match aff {
            Affinity::Integer => Value::Int(self.to_int()),
            Affinity::Real => Value::Real(self.to_f64()),
            Affinity::Text => match self {
                Value::Text(_) => self,
                v => Value::Text(v.to_text().unwrap()),
            },
            Affinity::Blob => Value::Blob(self.to_bytes()),
            Affinity::Numeric => match self {
                Value::Int(_) | Value::Real(_) => self,
                v => {
                    let t = v.to_text().unwrap();
                    match text_to_numeric(&t) {
                        Value::Real(f) => match real_as_exact_int(f) {
                            Some(i) => Value::Int(i),
                            None => Value::Real(f),
                        },
                        n => n,
                    }
                }
            },
        }
    }

    /// Numeric value if the value is a number or text that looks entirely
    /// like one (sqlite3_value_numeric_type); None otherwise.
    pub fn as_strict_number(&self) -> Option<Value> {
        match self {
            Value::Int(_) | Value::Real(_) => Some(self.clone()),
            Value::Text(s) => text_to_numeric_strict(s),
            _ => None,
        }
    }

    /// Truth value: None for NULL.
    pub fn truthy(&self) -> Option<bool> {
        match self.to_numeric() {
            Value::Null => None,
            Value::Int(i) => Some(i != 0),
            Value::Real(f) => Some(f != 0.0),
            _ => Some(false),
        }
    }

    /// Apply a column affinity (for storage).
    pub fn apply_affinity(self, aff: Affinity) -> Value {
        match aff {
            Affinity::Blob => self,
            Affinity::Text => match self {
                Value::Int(_) | Value::Real(_) => Value::Text(self.to_text().unwrap()),
                v => v,
            },
            Affinity::Numeric | Affinity::Integer => match self {
                Value::Text(ref s) => match text_to_numeric_strict(s) {
                    Some(Value::Real(f)) => match real_as_exact_int(f) {
                        Some(i) => Value::Int(i),
                        None => Value::Real(f),
                    },
                    Some(v) => v,
                    None => self,
                },
                Value::Real(f) => match real_as_exact_int(f) {
                    Some(i) => Value::Int(i),
                    None => self,
                },
                v => v,
            },
            Affinity::Real => match self {
                Value::Text(ref s) => match text_to_numeric_strict(s) {
                    Some(Value::Int(i)) => Value::Real(i as f64),
                    Some(v) => v,
                    None => self,
                },
                Value::Int(i) => Value::Real(i as f64),
                v => v,
            },
        }
    }

    /// Numeric affinity as applied in comparisons (no real->int squashing
    /// needed, but text that looks numeric becomes a number).
    pub fn apply_numeric_cmp(self) -> Value {
        match self {
            Value::Text(ref s) => match text_to_numeric_strict(s) {
                Some(v) => v,
                None => self,
            },
            v => v,
        }
    }
}

/// Saturating real -> integer conversion as SQLite does.
pub fn real_to_i64(f: f64) -> i64 {
    if f.is_nan() {
        0
    } else {
        f as i64
    }
}

fn class_rank(v: &Value) -> u8 {
    match v {
        Value::Null => 0,
        Value::Int(_) | Value::Real(_) => 1,
        Value::Text(_) => 2,
        Value::Blob(_) => 3,
    }
}

/// Compare an integer with a real exactly.
pub fn cmp_int_real(i: i64, f: f64) -> Ordering {
    if f.is_nan() {
        return Ordering::Greater;
    }
    if f >= 9.223372036854775808e18 {
        return Ordering::Less;
    }
    if f < -9.223372036854775808e18 {
        return Ordering::Greater;
    }
    let t = f.trunc();
    let ti = t as i64;
    match i.cmp(&ti) {
        Ordering::Equal => {
            // i == trunc(f); compare with fractional part
            if f > t {
                Ordering::Less
            } else if f < t {
                Ordering::Greater
            } else {
                Ordering::Equal
            }
        }
        o => o,
    }
}

/// Total order used for sorting and comparisons (BINARY collation).
pub fn compare(a: &Value, b: &Value) -> Ordering {
    let (ra, rb) = (class_rank(a), class_rank(b));
    if ra != rb {
        return ra.cmp(&rb);
    }
    match (a, b) {
        (Value::Null, Value::Null) => Ordering::Equal,
        (Value::Int(x), Value::Int(y)) => x.cmp(y),
        (Value::Real(x), Value::Real(y)) => x.partial_cmp(y).unwrap_or(Ordering::Equal),
        (Value::Int(x), Value::Real(y)) => cmp_int_real(*x, *y),
        (Value::Real(x), Value::Int(y)) => cmp_int_real(*y, *x).reverse(),
        (Value::Text(x), Value::Text(y)) => x.as_bytes().cmp(y.as_bytes()),
        (Value::Blob(x), Value::Blob(y)) => x.cmp(y),
        _ => Ordering::Equal,
    }
}

/// Comparison under a collating sequence (applies only to text pairs).
pub fn compare_coll(a: &Value, b: &Value, coll: Collation) -> Ordering {
    match (a, b) {
        (Value::Text(x), Value::Text(y)) => coll.compare_str(x, y),
        _ => compare(a, b),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reals() {
        assert_eq!(format_real(1.0), "1.0");
        assert_eq!(format_real(100.0), "100.0");
        assert_eq!(format_real(0.0001), "0.0001");
        assert_eq!(format_real(1e-5), "1.0e-05");
        assert_eq!(format_real(1e16), "1.0e+16");
        assert_eq!(format_real(1e15), "1000000000000000.0");
        assert_eq!(format_real(123456.789), "123456.789");
        assert_eq!(format_real(-2.5e-7), "-2.5e-07");
        assert_eq!(format_real(5e-324), "5.0e-324");
    }
}
