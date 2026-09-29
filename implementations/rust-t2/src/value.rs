// Values, type affinity, numeric conversions and formatting.

use std::cmp::Ordering;

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Integer(i64),
    Real(f64),
    Text(String),
    Blob(Vec<u8>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
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
}

/// SQLite's estimate of a column's stored size (units of ~4 bytes), from its
/// declared type (sqlite3AffinityType).
pub fn size_estimate(decl: &str) -> u32 {
    if decl.trim().is_empty() {
        return 1;
    }
    let t = decl.to_ascii_lowercase();
    let b = t.as_bytes();
    let mut h: u32 = 0;
    let mut aff = Affinity::Numeric;
    let mut zchar: Option<usize> = None;
    let code = |s: &[u8; 4]| u32::from_be_bytes(*s);
    for (i, &x) in b.iter().enumerate() {
        h = (h << 8).wrapping_add(x as u32);
        if h == code(b"char") {
            aff = Affinity::Text;
            zchar = Some(i + 1);
        } else if h == code(b"clob") || h == code(b"text") {
            aff = Affinity::Text;
        } else if h == code(b"blob") && matches!(aff, Affinity::Numeric | Affinity::Real) {
            aff = Affinity::Blob;
            if b.get(i + 1) == Some(&b'(') {
                zchar = Some(i + 1);
            }
        } else if (h == code(b"real") || h == code(b"floa") || h == code(b"doub"))
            && aff == Affinity::Numeric
        {
            aff = Affinity::Real;
        } else if h & 0x00FF_FFFF == u32::from_be_bytes([0, b'i', b'n', b't']) {
            aff = Affinity::Integer;
            break;
        }
    }
    let mut v: u32 = 0;
    if matches!(aff, Affinity::Blob | Affinity::Text) {
        match zchar {
            Some(z) => {
                if let Some(d) = b[z..].iter().position(|c| c.is_ascii_digit()) {
                    let digits: String = b[z + d..]
                        .iter()
                        .take_while(|c| c.is_ascii_digit())
                        .map(|&c| c as char)
                        .collect();
                    v = digits
                        .parse::<u64>()
                        .unwrap_or(u64::from(u32::MAX))
                        .min(u64::from(u32::MAX / 2)) as u32;
                }
            }
            None => v = 16,
        }
    }
    (v / 4 + 1).min(255)
}

/// SQLite's LogEst: roughly 10*log2(x).
pub fn log_est(mut x: u64) -> i32 {
    const A: [i32; 8] = [0, 2, 3, 5, 6, 7, 8, 9];
    let mut y: i32 = 40;
    if x < 8 {
        if x < 2 {
            return 0;
        }
        while x < 8 {
            y -= 10;
            x <<= 1;
        }
    } else {
        let i = 60 - x.leading_zeros() as i32;
        y += i * 10;
        x >>= i;
    }
    A[(x & 7) as usize] + y - 10
}

/// Affinity from a declared column type name (SQLite §3.1 rules).
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

impl Value {
    pub fn type_name(&self) -> &'static str {
        match self {
            Value::Null => "null",
            Value::Integer(_) => "integer",
            Value::Real(_) => "real",
            Value::Text(_) => "text",
            Value::Blob(_) => "blob",
        }
    }

    pub fn is_null(&self) -> bool {
        matches!(self, Value::Null)
    }

    /// Render for output / text conversion. NULL renders as "NULL" here;
    /// callers that need SQL text conversion should handle NULL themselves.
    pub fn to_output(&self) -> String {
        match self {
            Value::Null => "NULL".to_string(),
            Value::Integer(i) => i.to_string(),
            Value::Real(r) => format_real(*r),
            Value::Text(s) => s.clone(),
            Value::Blob(b) => {
                let mut s = String::with_capacity(b.len() * 2 + 3);
                s.push_str("X'");
                for byte in b {
                    s.push_str(&format!("{:02X}", byte));
                }
                s.push('\'');
                s
            }
        }
    }

    /// SQL text conversion (for ||, CAST AS TEXT, text affinity).
    /// Returns None for NULL.
    pub fn to_text(&self) -> Option<String> {
        match self {
            Value::Null => None,
            Value::Integer(i) => Some(i.to_string()),
            Value::Real(r) => Some(format_real(*r)),
            Value::Text(s) => Some(s.clone()),
            Value::Blob(b) => Some(String::from_utf8_lossy(b).into_owned()),
        }
    }

    /// Numeric value for arithmetic (SQLite's numericType): NULL stays NULL,
    /// text and blobs are parsed as a number prefix.
    pub fn to_numeric(&self) -> Value {
        match self {
            Value::Null => Value::Null,
            Value::Integer(_) | Value::Real(_) => self.clone(),
            Value::Text(s) => text_to_numeric(s.as_bytes()),
            Value::Blob(b) => text_to_numeric(b),
        }
    }

    pub fn to_f64(&self) -> f64 {
        match self {
            Value::Null => 0.0,
            Value::Integer(i) => *i as f64,
            Value::Real(r) => *r,
            Value::Text(s) => atof(s.as_bytes()).1,
            Value::Blob(b) => atof(b).1,
        }
    }

    pub fn to_i64(&self) -> i64 {
        match self {
            Value::Null => 0,
            Value::Integer(i) => *i,
            Value::Real(r) => real_to_i64(*r),
            Value::Text(s) => atoi64(s.as_bytes()).1,
            Value::Blob(b) => atoi64(b).1,
        }
    }

    /// Truth value: None for NULL.
    pub fn truthy(&self) -> Option<bool> {
        match self {
            Value::Null => None,
            Value::Integer(i) => Some(*i != 0),
            _ => Some(self.to_f64() != 0.0),
        }
    }
}

pub fn real_to_i64(r: f64) -> i64 {
    if r.is_nan() {
        0
    } else {
        r as i64
    }
}

/// Format a REAL per SPEC §2.3.
pub fn format_real(x: f64) -> String {
    if x == 0.0 {
        return "0.0".to_string();
    }
    if x.is_infinite() {
        return if x > 0.0 { "Inf".into() } else { "-Inf".into() };
    }
    if x.is_nan() {
        return "NaN".into();
    }
    let mut e = format!("{:e}", x.abs());
    // When two shortest candidates are equally close, Rust rounds up while
    // SQLite/Python pick the correctly rounded (ties-to-even) digits.
    let ndigits = e
        .split_once('e')
        .unwrap()
        .0
        .chars()
        .filter(|c| c.is_ascii_digit())
        .count();
    if ndigits > 1 {
        let alt = format!("{:.*e}", ndigits - 1, x.abs());
        if alt != e && alt.parse::<f64>() == Ok(x.abs()) {
            e = alt;
        }
    }
    let (mant, exp) = e.split_once('e').unwrap();
    let exp: i32 = exp.parse().unwrap();
    let digits: String = mant.chars().filter(|c| *c != '.').collect();
    let mut out = String::new();
    if x < 0.0 {
        out.push('-');
    }
    if exp > -5 && exp < 16 {
        if exp >= 0 {
            let int_len = (exp + 1) as usize;
            if digits.len() <= int_len {
                out.push_str(&digits);
                for _ in digits.len()..int_len {
                    out.push('0');
                }
                out.push_str(".0");
            } else {
                out.push_str(&digits[..int_len]);
                out.push('.');
                out.push_str(&digits[int_len..]);
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
        let a = exp.unsigned_abs();
        if a < 10 {
            out.push('0');
        }
        out.push_str(&a.to_string());
    }
    out
}

fn is_space(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | b'\r' | 0x0b | 0x0c)
}

/// Equivalent of sqlite3AtoF. Returns (rc, value):
///   rc <= 0 : not a well-formed number (value holds the prefix value);
///             -1 when the prefix contains '.' or an exponent.
///   rc == 1 : pure integer text; rc == 2 : well-formed real text.
pub fn atof(z: &[u8]) -> (i32, f64) {
    let n = z.len();
    let mut i = 0;
    while i < n && is_space(z[i]) {
        i += 1;
    }
    let start = i;
    if i < n && (z[i] == b'+' || z[i] == b'-') {
        i += 1;
    }
    let mut ndig = 0;
    while i < n && z[i].is_ascii_digit() {
        i += 1;
        ndig += 1;
    }
    let mut is_real = false;
    if i < n && z[i] == b'.' {
        let mut j = i + 1;
        let mut fd = 0;
        while j < n && z[j].is_ascii_digit() {
            j += 1;
            fd += 1;
        }
        if ndig + fd > 0 {
            is_real = true;
            ndig += fd;
            i = j;
        }
    }
    if ndig == 0 {
        return (0, 0.0);
    }
    let mut end = i;
    if i < n && (z[i] == b'e' || z[i] == b'E') {
        let mut j = i + 1;
        if j < n && (z[j] == b'+' || z[j] == b'-') {
            j += 1;
        }
        let ds = j;
        while j < n && z[j].is_ascii_digit() {
            j += 1;
        }
        if j > ds {
            is_real = true;
            end = j;
        }
    }
    let text = std::str::from_utf8(&z[start..end]).unwrap_or("0");
    let v = parse_f64_lenient(text);
    let mut k = end;
    while k < n && is_space(z[k]) {
        k += 1;
    }
    if k == n {
        (if is_real { 2 } else { 1 }, v)
    } else if is_real {
        (-1, v)
    } else {
        (0, v)
    }
}

fn parse_f64_lenient(t: &str) -> f64 {
    if let Ok(v) = t.parse::<f64>() {
        return v;
    }
    // Forms like "5." or "-.5" that Rust may reject.
    let mut s = t.to_string();
    if s.ends_with('.') {
        s.push('0');
    }
    s.replace("-.", "-0.")
        .replace("+.", "0.")
        .parse::<f64>()
        .unwrap_or(0.0)
}

/// Equivalent of sqlite3Atoi64. Returns (rc, value): rc 0 = exact integer,
/// 1 = extra text after the digits (or no digits), 2 = overflow.
pub fn atoi64(z: &[u8]) -> (i32, i64) {
    let n = z.len();
    let mut i = 0;
    while i < n && is_space(z[i]) {
        i += 1;
    }
    let mut neg = false;
    if i < n && (z[i] == b'+' || z[i] == b'-') {
        neg = z[i] == b'-';
        i += 1;
    }
    let ds = i;
    let mut acc: u128 = 0;
    while i < n && z[i].is_ascii_digit() {
        if acc < (1u128 << 70) {
            acc = acc * 10 + (z[i] - b'0') as u128;
        }
        i += 1;
    }
    let nodigits = i == ds;
    let mut k = i;
    while k < n && is_space(z[k]) {
        k += 1;
    }
    let extra = k < n || nodigits;
    let limit: u128 = 1u128 << 63;
    if neg {
        if acc > limit {
            return (2, i64::MIN);
        }
        let v = if acc == limit {
            i64::MIN
        } else {
            -(acc as i64)
        };
        (if extra { 1 } else { 0 }, v)
    } else {
        if acc >= limit {
            return (2, i64::MAX);
        }
        (if extra { 1 } else { 0 }, acc as i64)
    }
}

/// SQLite's computeNumericType for text/blob operands of arithmetic.
pub fn text_to_numeric(z: &[u8]) -> Value {
    let (rc, r) = atof(z);
    if rc <= 0 {
        if rc == 0 {
            let (irc, iv) = atoi64(z);
            if irc <= 1 {
                return Value::Integer(iv);
            }
        }
        Value::Real(r)
    } else if rc == 1 {
        let (irc, iv) = atoi64(z);
        if irc == 0 {
            Value::Integer(iv)
        } else {
            Value::Real(r)
        }
    } else {
        Value::Real(r)
    }
}

/// Convert an integral real to an integer if it is exactly representable.
fn real_integer_affinity(r: f64) -> Value {
    let ix = real_to_i64(r);
    if r == ix as f64 && ix > i64::MIN && ix < i64::MAX {
        Value::Integer(ix)
    } else {
        Value::Real(r)
    }
}

/// Numeric affinity on text: converts only well-formed numbers.
/// Returns None if the text is not a number.
pub fn text_numeric_affinity(s: &str, try_for_int: bool) -> Option<Value> {
    let (rc, r) = atof(s.as_bytes());
    if rc <= 0 {
        return None;
    }
    if rc == 1 {
        let (irc, iv) = atoi64(s.as_bytes());
        if irc == 0 {
            return Some(Value::Integer(iv));
        }
    }
    if try_for_int {
        Some(real_integer_affinity(r))
    } else {
        Some(Value::Real(r))
    }
}

/// Apply column affinity to a value being stored.
pub fn apply_affinity(v: Value, aff: Affinity) -> Value {
    match aff {
        Affinity::None | Affinity::Blob => v,
        Affinity::Text => match v {
            Value::Integer(_) | Value::Real(_) => Value::Text(v.to_text().unwrap()),
            other => other,
        },
        Affinity::Numeric | Affinity::Integer => match v {
            Value::Text(ref s) => text_numeric_affinity(s, true).unwrap_or(v),
            Value::Real(r) => real_integer_affinity(r),
            other => other,
        },
        Affinity::Real => match v {
            Value::Text(ref s) => match text_numeric_affinity(s, true) {
                Some(Value::Integer(i)) => Value::Real(i as f64),
                Some(x) => x,
                None => v,
            },
            Value::Integer(i) => Value::Real(i as f64),
            other => other,
        },
    }
}

fn class_rank(v: &Value) -> u8 {
    match v {
        Value::Null => 0,
        Value::Integer(_) | Value::Real(_) => 1,
        Value::Text(_) => 2,
        Value::Blob(_) => 3,
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
    match i.cmp(&y) {
        Ordering::Equal => {}
        o => return o,
    }
    let s = i as f64;
    s.partial_cmp(&r).unwrap_or(Ordering::Equal)
}

/// Total order used for sorting and comparisons (BINARY collation).
pub fn compare_values(a: &Value, b: &Value) -> Ordering {
    let (ra, rb) = (class_rank(a), class_rank(b));
    if ra != rb {
        return ra.cmp(&rb);
    }
    match (a, b) {
        (Value::Null, Value::Null) => Ordering::Equal,
        (Value::Integer(x), Value::Integer(y)) => x.cmp(y),
        (Value::Real(x), Value::Real(y)) => x.partial_cmp(y).unwrap_or(Ordering::Equal),
        (Value::Integer(x), Value::Real(y)) => int_float_cmp(*x, *y),
        (Value::Real(x), Value::Integer(y)) => int_float_cmp(*y, *x).reverse(),
        (Value::Text(x), Value::Text(y)) => x.as_bytes().cmp(y.as_bytes()),
        (Value::Blob(x), Value::Blob(y)) => x.cmp(y),
        _ => Ordering::Equal,
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
        assert_eq!(format_real(0.00001), "1.0e-05");
        assert_eq!(format_real(1e16), "1.0e+16");
        assert_eq!(format_real(1e15), "1000000000000000.0");
        assert_eq!(format_real(123456.789), "123456.789");
        assert_eq!(format_real(5e-324), "5.0e-324");
        assert_eq!(format_real(-2.5e-7), "-2.5e-07");
    }
}

/// Collating sequences.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Coll {
    Binary,
    NoCase,
    RTrim,
    /// An unknown name given with the COLLATE operator; an error only if a
    /// comparison actually uses it.
    Unknown,
}

impl Coll {
    pub fn from_name(name: &str) -> Result<Coll, String> {
        match name.to_ascii_lowercase().as_str() {
            "binary" => Ok(Coll::Binary),
            "nocase" => Ok(Coll::NoCase),
            "rtrim" => Ok(Coll::RTrim),
            _ => Err(format!("no such collation sequence: {}", name)),
        }
    }
}

pub fn compare_text_coll(a: &str, b: &str, coll: Coll) -> Ordering {
    match coll {
        Coll::Binary => a.as_bytes().cmp(b.as_bytes()),
        Coll::NoCase => {
            let x = a.as_bytes().iter().map(|c| c.to_ascii_lowercase());
            let y = b.as_bytes().iter().map(|c| c.to_ascii_lowercase());
            x.cmp(y)
        }
        Coll::RTrim => a
            .trim_end_matches(' ')
            .as_bytes()
            .cmp(b.trim_end_matches(' ').as_bytes()),
        Coll::Unknown => a.as_bytes().cmp(b.as_bytes()),
    }
}

/// Total order with a collating sequence applied to text values.
pub fn compare_values_coll(a: &Value, b: &Value, coll: Coll) -> Ordering {
    match (a, b) {
        (Value::Text(x), Value::Text(y)) => compare_text_coll(x, y, coll),
        _ => compare_values(a, b),
    }
}
