// SQLite-compatible printf()/format() implementation.

use crate::value::Value;

/// Decimal digits of a finite, non-negative double: `digits` has no leading
/// zeros and value = 0.digits * 10^dp.
struct Decoded {
    digits: Vec<u8>,
    dp: i32,
}

/// Decode `f` (>= 0) and round it like sqlite3FpDecode: keep `round`
/// significant digits (if `round` <= 0, it counts from the decimal point:
/// keep dp - round digits), at most `max_digits`; ties round away from zero.
fn fp_decode(f: f64, round: i32, max_digits: i32) -> Decoded {
    if f == 0.0 {
        return Decoded { digits: vec![b'0'], dp: 1 };
    }
    let s = format!("{:.40e}", f);
    let (mant, exp) = s.split_once('e').unwrap();
    let mut digits: Vec<u8> = mant.bytes().filter(|b| b.is_ascii_digit()).collect();
    let mut dp: i32 = exp.parse::<i32>().unwrap() + 1;
    while digits.len() > 1 && *digits.last().unwrap() == b'0' {
        digits.pop();
    }
    let mut r = round;
    if r <= 0 {
        r = dp - r;
        if r == 0 && digits[0] >= b'5' {
            digits.insert(0, b'0');
            dp += 1;
            r = 1;
        }
    }
    if r > 0 && ((r as usize) < digits.len() || digits.len() > max_digits as usize) {
        let r = r.min(max_digits) as usize;
        let up = digits[r] >= b'5';
        digits.truncate(r);
        if up {
            let mut j = r;
            loop {
                if j == 0 {
                    digits.insert(0, b'1');
                    dp += 1;
                    break;
                }
                j -= 1;
                if digits[j] == b'9' {
                    digits[j] = b'0';
                } else {
                    digits[j] += 1;
                    break;
                }
            }
        }
    }
    while digits.len() > 1 && *digits.last().unwrap() == b'0' {
        digits.pop();
    }
    if digits[0] == b'0' && digits.len() > 1 {
        digits.remove(0);
        dp -= 1;
    }
    Decoded { digits, dp }
}

#[derive(Default, Clone, Copy)]
struct Spec {
    left: bool,
    plus: bool,
    blank: bool,
    alt: bool,
    alt2: bool,
    zero: bool,
    thousands: bool,
    width: usize,
    precision: Option<usize>,
}

/// Format a float conversion (`f`, `e`, `E`, `g`, `G`) with the given
/// precision; `alt2` is SQLite's '!' flag.
pub fn format_float(f: f64, conv: u8, precision: usize, alt2: bool) -> String {
    let spec = Spec { alt2, precision: Some(precision), ..Default::default() };
    String::from_utf8_lossy(&float_conv(f, conv, &spec)).into_owned()
}

fn float_conv(f: f64, conv: u8, sp: &Spec) -> Vec<u8> {
    let mut precision = sp.precision.unwrap_or(6) as i64;
    let prefix: Option<u8> = if f < 0.0 {
        Some(b'-')
    } else if sp.plus {
        Some(b'+')
    } else if sp.blank {
        Some(b' ')
    } else {
        None
    };
    let upper = conv.is_ascii_uppercase();
    let mut xtype = conv.to_ascii_lowercase();
    let round = match xtype {
        b'f' => -(precision.min(100_000_000) as i32),
        b'g' => {
            if precision == 0 {
                precision = 1;
            }
            precision.min(100_000_000) as i32
        }
        _ => (precision + 1).min(100_000_000) as i32,
    };
    let mut d = if f.is_infinite() {
        if !sp.zero {
            let mut out = Vec::new();
            if let Some(p) = prefix {
                out.push(p);
            }
            out.extend_from_slice(b"Inf");
            return pad(out, sp.width, sp.left);
        }
        Decoded { digits: vec![b'9'], dp: 1000 }
    } else {
        fp_decode(f.abs(), round, if sp.alt2 { 26 } else { 16 })
    };
    if d.digits.is_empty() {
        d.digits.push(b'0');
    }
    let exp = d.dp as i64 - 1;
    let rtz;
    if xtype == b'g' {
        rtz = !sp.alt;
        if exp < -4 || exp > precision - 1 {
            xtype = b'e';
            precision -= 1;
        } else {
            precision = precision - 1 - exp;
            xtype = b'f';
        }
    } else {
        rtz = sp.alt2;
    }
    let mut out = Vec::new();
    if let Some(p) = prefix {
        out.push(p);
    }
    let digit = |j: usize| -> u8 { d.digits.get(j).copied().unwrap_or(b'0') };
    let mut j = 0usize;
    let mut e2: i64 = if xtype == b'e' { 0 } else { exp };
    if e2 < 0 {
        out.push(b'0');
    } else {
        while e2 >= 0 {
            out.push(digit(j));
            j += 1;
            if sp.thousands && e2 % 3 == 0 && e2 > 1 {
                out.push(b',');
            }
            e2 -= 1;
        }
    }
    let flag_dp = precision > 0 || sp.alt || sp.alt2;
    if flag_dp {
        out.push(b'.');
    }
    e2 += 1;
    while e2 < 0 && precision > 0 {
        out.push(b'0');
        precision -= 1;
        e2 += 1;
    }
    while precision > 0 {
        out.push(digit(j));
        j += 1;
        precision -= 1;
    }
    if rtz && flag_dp {
        while out.last() == Some(&b'0') {
            out.pop();
        }
        if out.last() == Some(&b'.') {
            if sp.alt2 {
                out.push(b'0');
            } else {
                out.pop();
            }
        }
    }
    if xtype == b'e' {
        out.push(if upper { b'E' } else { b'e' });
        let mut x = d.dp as i64 - 1;
        if x < 0 {
            out.push(b'-');
            x = -x;
        } else {
            out.push(b'+');
        }
        if x >= 100 {
            out.push(b'0' + (x / 100) as u8);
            x %= 100;
        }
        out.push(b'0' + (x / 10) as u8);
        out.push(b'0' + (x % 10) as u8);
    }
    if sp.zero && !sp.left && out.len() < sp.width {
        let n = sp.width - out.len();
        let at = prefix.is_some() as usize;
        out.splice(at..at, std::iter::repeat_n(b'0', n));
    }
    pad(out, sp.width, sp.left)
}

fn pad(mut s: Vec<u8>, width: usize, left: bool) -> Vec<u8> {
    if s.len() >= width {
        return s;
    }
    let n = width - s.len();
    if left {
        s.extend(std::iter::repeat_n(b' ', n));
        s
    } else {
        let mut out = vec![b' '; n];
        out.extend_from_slice(&s);
        out
    }
}

/// Width padding where `alt2` makes the width count characters.
fn pad_utf8(s: Vec<u8>, width: usize, left: bool, alt2: bool) -> Vec<u8> {
    let mut w = width;
    if alt2 && w > 0 {
        w += s.iter().filter(|&&b| (b & 0xc0) == 0x80).count();
    }
    pad(s, w, left)
}

/// Number of bytes covering the first `n` characters of `s`.
fn utf8_prefix_len(s: &[u8], n: usize) -> usize {
    let mut i = 0;
    let mut k = 0;
    while i < s.len() && k < n {
        i += 1;
        while i < s.len() && (s[i] & 0xc0) == 0x80 {
            i += 1;
        }
        k += 1;
    }
    i
}

fn int_conv(v: &Value, conv: u8, sp: &Spec) -> Vec<u8> {
    let x = v.to_int();
    let signed = conv == b'd' || conv == b'i';
    let (mag, prefix): (u64, Option<u8>) = if signed {
        if x < 0 {
            (x.unsigned_abs(), Some(b'-'))
        } else if sp.plus {
            (x as u64, Some(b'+'))
        } else if sp.blank {
            (x as u64, Some(b' '))
        } else {
            (x as u64, None)
        }
    } else {
        (x as u64, None)
    };
    let mut precision = sp.precision.unwrap_or(0);
    if sp.zero {
        let w = sp.width.saturating_sub(prefix.is_some() as usize);
        if precision < w {
            precision = w;
        }
    }
    let mut digits = match conv {
        b'x' | b'p' => format!("{:x}", mag),
        b'X' => format!("{:X}", mag),
        b'o' => format!("{:o}", mag),
        _ => mag.to_string(),
    }
    .into_bytes();
    if digits.len() < precision {
        let mut z = vec![b'0'; precision - digits.len()];
        z.extend_from_slice(&digits);
        digits = z;
    }
    if sp.thousands && (conv == b'd' || conv == b'i' || conv == b'u') {
        let n = digits.len();
        let mut t = Vec::with_capacity(n + n / 3);
        for (i, c) in digits.iter().enumerate() {
            if i > 0 && (n - i) % 3 == 0 {
                t.push(b',');
            }
            t.push(*c);
        }
        digits = t;
    }
    let mut out = Vec::new();
    if sp.alt && mag != 0 {
        match conv {
            b'x' => out.extend_from_slice(b"0x"),
            b'X' => out.extend_from_slice(b"0X"),
            b'o' => out.push(b'0'),
            _ => {}
        }
    }
    if let Some(p) = prefix {
        out.push(p);
    }
    out.extend_from_slice(&digits);
    pad(out, sp.width, sp.left)
}

/// printf(fmt, args...).
pub fn format(fmt: &str, args: &[Value]) -> String {
    let f = fmt.as_bytes();
    let mut out: Vec<u8> = Vec::new();
    let mut next_arg = 0usize;
    let null = Value::Null;
    let mut take = || -> &Value {
        let v = args.get(next_arg).unwrap_or(&null);
        next_arg += 1;
        v
    };
    let mut i = 0;
    while i < f.len() {
        if f[i] != b'%' {
            let start = i;
            while i < f.len() && f[i] != b'%' {
                i += 1;
            }
            out.extend_from_slice(&f[start..i]);
            continue;
        }
        i += 1;
        if i >= f.len() {
            break;
        }
        let mut sp = Spec::default();
        loop {
            match f.get(i) {
                Some(b'-') => sp.left = true,
                Some(b'+') => sp.plus = true,
                Some(b' ') => sp.blank = true,
                Some(b'#') => sp.alt = true,
                Some(b'!') => sp.alt2 = true,
                Some(b'0') => sp.zero = true,
                Some(b',') => sp.thousands = true,
                _ => break,
            }
            i += 1;
        }
        if f.get(i) == Some(&b'*') {
            i += 1;
            let w = take().to_int();
            if w < 0 {
                sp.left = true;
                sp.width = w.unsigned_abs().min(100_000_000) as usize;
            } else {
                sp.width = w.min(100_000_000) as usize;
            }
        } else {
            let mut w = 0usize;
            while let Some(c) = f.get(i).filter(|c| c.is_ascii_digit()) {
                w = (w * 10 + (c - b'0') as usize).min(100_000_000);
                i += 1;
            }
            sp.width = w;
        }
        if f.get(i) == Some(&b'.') {
            i += 1;
            if f.get(i) == Some(&b'*') {
                i += 1;
                let p = take().to_int();
                sp.precision = Some(p.unsigned_abs().min(100_000_000) as usize);
            } else {
                let mut p = 0usize;
                while let Some(c) = f.get(i).filter(|c| c.is_ascii_digit()) {
                    p = (p * 10 + (c - b'0') as usize).min(100_000_000);
                    i += 1;
                }
                sp.precision = Some(p);
            }
        }
        while f.get(i) == Some(&b'l') {
            i += 1;
        }
        let conv = match f.get(i) {
            Some(c) => *c,
            None => break,
        };
        i += 1;
        match conv {
            b'd' | b'i' | b'u' | b'x' | b'X' | b'o' | b'p' => {
                let v = take();
                out.extend(int_conv(v, conv, &sp));
            }
            b'f' | b'e' | b'E' | b'g' | b'G' => {
                let v = take().to_f64();
                out.extend(float_conv(v, conv, &sp));
            }
            b's' | b'z' => {
                let t = take().to_bytes();
                let len = match sp.precision {
                    Some(p) if sp.alt2 => utf8_prefix_len(&t, p),
                    Some(p) => p.min(t.len()),
                    None => t.len(),
                };
                out.extend(pad_utf8(t[..len].to_vec(), sp.width, sp.left, sp.alt2));
            }
            b'q' | b'Q' | b'w' => {
                let v = take();
                let q = if conv == b'w' { b'"' } else { b'\'' };
                let s = match v {
                    Value::Null => {
                        if conv == b'Q' {
                            b"NULL".to_vec()
                        } else {
                            b"(NULL)".to_vec()
                        }
                    }
                    v => {
                        let t = v.to_bytes();
                        let len = match sp.precision {
                            Some(p) if sp.alt2 => utf8_prefix_len(&t, p),
                            Some(p) => p.min(t.len()),
                            None => t.len(),
                        };
                        let mut s = Vec::new();
                        if conv == b'Q' {
                            s.push(q);
                        }
                        for &c in &t[..len] {
                            s.push(c);
                            if c == q {
                                s.push(q);
                            }
                        }
                        if conv == b'Q' {
                            s.push(q);
                        }
                        s
                    }
                };
                out.extend(pad_utf8(s, sp.width, sp.left, true));
            }
            b'c' => {
                let t = take().to_bytes();
                let ch = t[..utf8_prefix_len(&t, 1)].to_vec();
                let n = sp.precision.unwrap_or(1).max(1);
                let mut s = Vec::with_capacity(ch.len() * n);
                for _ in 0..n {
                    s.extend_from_slice(&ch);
                }
                out.extend(pad_utf8(s, sp.width, sp.left, true));
            }
            b'%' => out.extend(pad(vec![b'%'], sp.width, sp.left)),
            _ => break,
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}
