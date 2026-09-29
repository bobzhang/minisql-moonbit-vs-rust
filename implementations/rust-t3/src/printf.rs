// SQLite-compatible printf() formatting (a port of the relevant parts of
// SQLite's printf.c for the SQL-function case).

use crate::value::Value;

/// Decimal digits of a double (sqlite3FpDecode).
struct FpDecode {
    neg: bool,
    /// Significant digits (ASCII), no trailing zeros except for zero itself.
    z: Vec<u8>,
    /// Position of the decimal point relative to the digits.
    idp: i32,
    /// 0 normal, 1 infinity, 2 NaN.
    special: u8,
}

fn fp_decode(r: f64, mut iround: i32, mxround: i32) -> FpDecode {
    if r.is_nan() {
        return FpDecode { neg: false, z: vec![], idp: 0, special: 2 };
    }
    let neg = r < 0.0;
    let r = r.abs();
    if r.is_infinite() {
        return FpDecode { neg, z: vec![], idp: 0, special: 1 };
    }
    if r == 0.0 {
        return FpDecode { neg: false, z: vec![b'0'], idp: 1, special: 0 };
    }
    let s = format!("{:.29e}", r);
    let (mant, exp) = s.split_once('e').unwrap();
    let exp: i32 = exp.parse().unwrap();
    let mut z: Vec<u8> = mant.bytes().filter(|c| c.is_ascii_digit()).collect();
    let mut idp = exp + 1;
    let mut n = z.len() as i32;
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
        n = iround;
        if z[iround as usize] >= b'5' {
            let mut j = iround as usize - 1;
            loop {
                z[j] += 1;
                if z[j] <= b'9' {
                    break;
                }
                z[j] = b'0';
                if j == 0 {
                    z.insert(0, b'1');
                    n += 1;
                    idp += 1;
                    break;
                }
                j -= 1;
            }
        }
    }
    z.truncate(n.max(0) as usize);
    while z.len() > 1 && *z.last().unwrap() == b'0' {
        z.pop();
    }
    FpDecode { neg, z, idp, special: 0 }
}

/// `%!.<prec>f` of a real, as used by round().
pub fn format_float(r: f64, prec: usize) -> String {
    let mut spec = Spec { precision: prec as i64, altform2: true, ..Spec::default() };
    let out = float_conv(r, b'f', &mut spec);
    String::from_utf8_lossy(&out).into_owned()
}

#[derive(Default)]
struct Spec {
    leftjustify: bool,
    prefix: u8,
    alternateform: bool,
    altform2: bool,
    zeropad: bool,
    thousand: bool,
    width: i64,
    precision: i64,
}

fn float_conv(realvalue: f64, conv: u8, sp: &mut Spec) -> Vec<u8> {
    // conv: f e E g G
    let mut precision = if sp.precision < 0 { 6 } else { sp.precision };
    let generic = conv == b'g' || conv == b'G';
    let iround = if conv == b'f' {
        -(precision.min(100_000) as i32)
    } else if generic {
        if precision == 0 {
            precision = 1;
        }
        precision.min(100_000) as i32
    } else {
        precision.min(100_000) as i32 + 1
    };
    let mut s = fp_decode(realvalue, iround, if sp.altform2 { 26 } else { 16 });
    if s.special == 2 {
        return if sp.zeropad { b"null".to_vec() } else { b"NaN".to_vec() };
    }
    if s.special == 1 {
        if sp.zeropad {
            s.z = vec![b'9'];
            s.idp = 1000;
        } else {
            let mut v = Vec::new();
            if s.neg {
                v.push(b'-');
            } else if sp.prefix != 0 {
                v.push(sp.prefix);
            }
            v.extend_from_slice(b"Inf");
            return v;
        }
    }
    let prefix = if s.neg { b'-' } else { sp.prefix };
    let exp = s.idp - 1;
    let mut is_exp = conv == b'e' || conv == b'E';
    let flag_rtz;
    if generic {
        if precision > 0 {
            precision -= 1;
        }
        flag_rtz = !sp.alternateform;
        if exp < -4 || exp as i64 > precision {
            is_exp = true;
        } else {
            precision -= exp as i64;
        }
    } else {
        flag_rtz = sp.altform2;
    }
    let mut e2: i64 = if is_exp { 0 } else { s.idp as i64 - 1 };
    let flag_dp = precision > 0 || sp.alternateform || sp.altform2;
    let mut buf: Vec<u8> = Vec::new();
    if prefix != 0 {
        buf.push(prefix);
    }
    let z = &s.z;
    let n = z.len();
    let mut j = 0usize;
    let next = |j: &mut usize| {
        if *j < n {
            *j += 1;
            z[*j - 1]
        } else {
            b'0'
        }
    };
    if e2 < 0 {
        buf.push(b'0');
    } else {
        while e2 >= 0 {
            buf.push(next(&mut j));
            if sp.thousand && e2 % 3 == 0 && e2 > 1 {
                buf.push(b',');
            }
            e2 -= 1;
        }
    }
    if flag_dp {
        buf.push(b'.');
    }
    e2 += 1;
    while e2 < 0 && precision > 0 {
        buf.push(b'0');
        precision -= 1;
        e2 += 1;
    }
    while precision > 0 {
        buf.push(next(&mut j));
        precision -= 1;
    }
    if flag_rtz && flag_dp {
        while buf.last() == Some(&b'0') {
            buf.pop();
        }
        if buf.last() == Some(&b'.') {
            if sp.altform2 {
                buf.push(b'0');
            } else {
                buf.pop();
            }
        }
    }
    if is_exp {
        let mut exp = s.idp - 1;
        if z.len() == 1 && z[0] == b'0' {
            exp = 0;
        }
        buf.push(if conv == b'E' || conv == b'G' { b'E' } else { b'e' });
        if exp < 0 {
            buf.push(b'-');
            exp = -exp;
        } else {
            buf.push(b'+');
        }
        if exp >= 100 {
            buf.push(b'0' + (exp / 100) as u8);
            exp %= 100;
        }
        buf.push(b'0' + (exp / 10) as u8);
        buf.push(b'0' + (exp % 10) as u8);
    }
    if sp.zeropad && !sp.leftjustify && (buf.len() as i64) < sp.width {
        let npad = (sp.width - buf.len() as i64) as usize;
        let at = if prefix != 0 { 1 } else { 0 };
        for _ in 0..npad {
            buf.insert(at, b'0');
        }
    }
    buf
}

struct Args<'a> {
    args: &'a [Value],
    i: usize,
}

impl Args<'_> {
    fn next(&mut self) -> Option<&Value> {
        let v = self.args.get(self.i);
        if v.is_some() {
            self.i += 1;
        }
        v
    }
    fn int(&mut self) -> i64 {
        self.next().map(|v| v.to_int()).unwrap_or(0)
    }
    fn real(&mut self) -> f64 {
        self.next().map(|v| v.to_real()).unwrap_or(0.0)
    }
    fn text(&mut self) -> Option<Vec<u8>> {
        self.next().and_then(|v| v.to_bytes())
    }
}

/// Formats `fmt` with SQL values as printf() does. None (SQL NULL) if
/// nothing was ever output, as SQLite does.
pub fn format(fmt: &str, args: &[Value]) -> Option<String> {
    let mut touched = false;
    let f = fmt.as_bytes();
    let mut out: Vec<u8> = Vec::new();
    let mut a = Args { args, i: 0 };
    let mut i = 0;
    'outer: while i < f.len() {
        let c = f[i];
        if c != b'%' {
            let start = i;
            while i < f.len() && f[i] != b'%' {
                i += 1;
            }
            out.extend_from_slice(&f[start..i]);
            touched = true;
            continue;
        }
        i += 1;
        if i >= f.len() {
            out.push(b'%');
            touched = true;
            break;
        }
        let mut sp = Spec { precision: -1, ..Spec::default() };
        // flags, width and precision
        loop {
            let c = if i < f.len() { f[i] } else { 0 };
            match c {
                b'-' => sp.leftjustify = true,
                b'+' => sp.prefix = b'+',
                b' ' => sp.prefix = b' ',
                b'#' => sp.alternateform = true,
                b'!' => sp.altform2 = true,
                b'0' => sp.zeropad = true,
                b',' => sp.thousand = true,
                b'l' => {
                    i += 1;
                    if i < f.len() && f[i] == b'l' {
                        i += 1;
                    }
                    break;
                }
                b'1'..=b'9' => {
                    let mut w: u64 = 0;
                    while i < f.len() && f[i].is_ascii_digit() {
                        w = (w * 10 + (f[i] - b'0') as u64) & 0xffff_ffff;
                        i += 1;
                    }
                    sp.width = (w & 0x7fff_ffff) as i64;
                    if i < f.len() && (f[i] == b'.' || f[i] == b'l') {
                        continue;
                    }
                    break;
                }
                b'*' => {
                    let mut w = a.int();
                    if w < 0 {
                        sp.leftjustify = true;
                        w = if w >= -2147483647 { -w } else { 0 };
                    }
                    sp.width = w.min(i32::MAX as i64);
                    i += 1;
                    if i < f.len() && (f[i] == b'.' || f[i] == b'l') {
                        continue;
                    }
                    break;
                }
                b'.' => {
                    i += 1;
                    if i < f.len() && f[i] == b'*' {
                        let mut p = a.int();
                        if p < 0 {
                            p = if p >= -2147483647 { -p } else { -1 };
                        }
                        sp.precision = p.min(i32::MAX as i64);
                        i += 1;
                    } else {
                        let mut p: u64 = 0;
                        while i < f.len() && f[i].is_ascii_digit() {
                            p = (p * 10 + (f[i] - b'0') as u64) & 0xffff_ffff;
                            i += 1;
                        }
                        sp.precision = (p & 0x7fff_ffff) as i64;
                    }
                    if i < f.len() && f[i] == b'l' {
                        continue;
                    }
                    break;
                }
                _ => break,
            }
            i += 1;
        }
        let conv = if i < f.len() { f[i] } else { 0 };
        i += 1;
        let mut buf: Vec<u8>;
        let mut width = sp.width;
        match conv {
            b'd' | b'i' | b'u' | b'x' | b'X' | b'o' | b'p' | b'r' => {
                let (base, digits, pre): (u64, &[u8], &[u8]) = match conv {
                    b'x' | b'p' => (16, b"0123456789abcdef", b"0x"),
                    b'X' => (16, b"0123456789ABCDEF", b"0X"),
                    b'o' => (8, b"01234567", b"0"),
                    _ => (10, b"0123456789", b""),
                };
                if !matches!(conv, b'd' | b'i' | b'u') {
                    sp.thousand = false;
                }
                let mut prefix = 0u8;
                let mut v: u64;
                if matches!(conv, b'd' | b'i' | b'r') {
                    let x = a.int();
                    if x < 0 {
                        v = x.unsigned_abs();
                        prefix = b'-';
                    } else {
                        v = x as u64;
                        prefix = sp.prefix;
                    }
                } else {
                    v = a.int() as u64;
                }
                let mut alt = sp.alternateform;
                if v == 0 {
                    alt = false;
                }
                let mut precision = sp.precision;
                let has_prefix = (prefix != 0) as i64;
                if sp.zeropad && precision < width - has_prefix {
                    precision = width - has_prefix;
                }
                // build in reverse
                let mut rev: Vec<u8> = Vec::new();
                if conv == b'r' {
                    let mut x = (v % 10) as usize;
                    if x >= 4 || (v / 10) % 10 == 1 {
                        x = 0;
                    }
                    let ord = b"thstndrd";
                    rev.push(ord[x * 2 + 1]);
                    rev.push(ord[x * 2]);
                }
                loop {
                    rev.push(digits[(v % base) as usize]);
                    v /= base;
                    if v == 0 {
                        break;
                    }
                }
                while precision > rev.len() as i64 {
                    rev.push(b'0');
                }
                if sp.thousand {
                    let mut with: Vec<u8> = Vec::new();
                    for (k, d) in rev.iter().enumerate() {
                        if k > 0 && k % 3 == 0 {
                            with.push(b',');
                        }
                        with.push(*d);
                    }
                    rev = with;
                }
                if prefix != 0 {
                    rev.push(prefix);
                }
                if alt && !matches!(conv, b'd' | b'i' | b'u' | b'r') {
                    for &ch in pre.iter().rev() {
                        rev.push(ch);
                    }
                }
                rev.reverse();
                buf = rev;
            }
            b'f' | b'e' | b'E' | b'g' | b'G' => {
                let r = a.real();
                buf = float_conv(r, conv, &mut sp);
            }
            b's' | b'z' => {
                let t = a.text().unwrap_or_default();
                let t = match t.iter().position(|&b| b == 0) {
                    Some(p) => t[..p].to_vec(),
                    None => t,
                };
                let len = if sp.precision >= 0 {
                    if sp.altform2 {
                        let mut k = 0;
                        let mut p = sp.precision;
                        while p > 0 && k < t.len() {
                            k += 1;
                            while k < t.len() && (t[k] & 0xc0) == 0x80 {
                                k += 1;
                            }
                            p -= 1;
                        }
                        k
                    } else {
                        (sp.precision as usize).min(t.len())
                    }
                } else {
                    t.len()
                };
                buf = t[..len].to_vec();
                if sp.altform2 && width > 0 {
                    width += buf.iter().filter(|&&b| (b & 0xc0) == 0x80).count() as i64;
                }
            }
            b'c' => {
                let t = a.text();
                let mut ch: Vec<u8> = Vec::new();
                match t {
                    Some(t) if !t.is_empty() => {
                        ch.push(t[0]);
                        if (t[0] & 0xc0) == 0xc0 {
                            let mut k = 1;
                            while ch.len() < 4 && k < t.len() && (t[k] & 0xc0) == 0x80 {
                                ch.push(t[k]);
                                k += 1;
                            }
                        }
                    }
                    _ => ch.push(0),
                }
                buf = Vec::new();
                let mut precision = sp.precision;
                if precision > 1 {
                    width -= precision - 1;
                    if width > 1 && !sp.leftjustify {
                        out.extend(std::iter::repeat_n(b' ', (width - 1) as usize));
                        width = 0;
                    }
                    out.extend_from_slice(&ch);
                    precision -= 1;
                    while precision > 1 {
                        out.extend_from_slice(&ch);
                        precision -= 1;
                    }
                }
                buf.extend_from_slice(&ch);
                if width > 0 {
                    width += buf.iter().filter(|&&b| (b & 0xc0) == 0x80).count() as i64;
                }
            }
            b'q' | b'Q' | b'w' => {
                let q = if conv == b'w' { b'"' } else { b'\'' };
                let t = a.text();
                let isnull = t.is_none();
                let t = t.unwrap_or_else(|| if conv == b'Q' { b"NULL".to_vec() } else { b"(NULL)".to_vec() });
                let t = match t.iter().position(|&b| b == 0) {
                    Some(p) => t[..p].to_vec(),
                    None => t,
                };
                // precision limits the input used
                let mut end = 0;
                let mut k = sp.precision;
                while k != 0 && end < t.len() {
                    if sp.altform2 && (t[end] & 0xc0) == 0xc0 {
                        while end + 1 < t.len() && (t[end + 1] & 0xc0) == 0x80 {
                            end += 1;
                        }
                    }
                    end += 1;
                    k -= 1;
                }
                let need_quote = !isnull && conv == b'Q';
                buf = Vec::new();
                if need_quote {
                    buf.push(q);
                }
                for &b in &t[..end] {
                    buf.push(b);
                    if b == q {
                        buf.push(b);
                    }
                }
                if need_quote {
                    buf.push(q);
                }
                if sp.altform2 && width > 0 {
                    width += buf.iter().filter(|&&b| (b & 0xc0) == 0x80).count() as i64;
                }
            }
            b'%' => buf = vec![b'%'],
            b'n' => {
                buf = Vec::new();
                width = 0;
            }
            _ => break 'outer,
        }
        touched = true;
        let pad = width - buf.len() as i64;
        if pad > 0 {
            if !sp.leftjustify {
                out.extend(std::iter::repeat_n(b' ', pad as usize));
            }
            out.extend_from_slice(&buf);
            if sp.leftjustify {
                out.extend(std::iter::repeat_n(b' ', pad as usize));
            }
        } else {
            out.extend_from_slice(&buf);
        }
    }
    if !touched {
        return None;
    }
    Some(String::from_utf8_lossy(&out).into_owned())
}
