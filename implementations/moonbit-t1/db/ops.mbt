// CAST, LIKE and GLOB.

///|
/// UTF-8 bytes of a value's text form (blobs as is). None for NULL.
fn Value::to_bytes(self : Value) -> Bytes? {
  match self {
    Null => None
    Blob(b) => Some(b)
    Text(s) => Some(@utf8.encode(s))
    _ => Some(@utf8.encode(self.to_text().unwrap()))
  }
}

///|
/// Real value of the longest numeric prefix of a text (0.0 if none).
fn text_to_real(s : String) -> Double {
  let r = scan_number(s)
  if r.has_num {
    r.rval
  } else {
    0.0
  }
}

///|
/// sqlite3RealSameAsInt: exact and small enough to be shown as an integer.
fn real_same_as_int(d : Double) -> Int64? {
  if d == 0.0 {
    return Some(0L)
  }
  if d > -2251799813685248.0 && d < 2251799813685248.0 {
    let i = d.to_int64()
    if i.to_double() == d {
      return Some(i)
    }
  }
  None
}

///|
/// CAST(text AS NUMERIC).
fn text_numerify(s : String) -> Value {
  let r = scan_number(s)
  if !r.has_num {
    Int(0L)
  } else if r.int_ok {
    Int(r.ival)
  } else {
    match real_same_as_int(r.rval) {
      Some(i) => Int(i)
      None => Real(r.rval)
    }
  }
}

///|
fn blob_text(b : Bytes) -> String {
  @utf8.decode_lossy(b[:])
}

///|
fn cast_value(v : Value, aff : Affinity) -> Value {
  if v is Null {
    return Null
  }
  match aff {
    AffNone =>
      match v {
        Blob(_) => v
        _ => Blob(v.to_bytes().unwrap())
      }
    AffText => Text(v.to_text().unwrap())
    AffInteger => Int(v.to_int64())
    AffReal =>
      match v {
        Int(i) => Real(i.to_double())
        Real(_) => v
        Text(s) => Real(text_to_real(s))
        Blob(b) => Real(text_to_real(blob_text(b)))
        Null => Null
      }
    AffNumeric =>
      match v {
        Int(_) | Real(_) => v
        Text(s) => text_numerify(s)
        Blob(b) => text_numerify(blob_text(b))
        Null => Null
      }
  }
}

///|
fn code_points(s : String) -> Array[Int] {
  let out : Array[Int] = []
  for c in s {
    out.push(c.to_int())
  }
  out
}

///|
/// Evaluate LIKE (glob=false) or GLOB with the given pattern, subject and
/// optional escape value.
fn like_values(
  glob : Bool,
  pat : Value,
  subject : Value,
  esc : Value?,
) -> Value raise SqlError {
  let mut escape = -1
  match esc {
    Some(ev) => {
      guard ev.to_text() is Some(es) else { return Null }
      let cps = code_points(es)
      if cps.length() != 1 {
        raise sql_err("ESCAPE expression must be a single character")
      }
      escape = cps[0]
    }
    None => ()
  }
  guard pat.to_text() is Some(p) else { return Null }
  guard subject.to_text() is Some(x) else { return Null }
  bool_val(pattern_match(glob, p, x, escape))
}

///|
fn pattern_match(glob : Bool, p : String, x : String, escape : Int) -> Bool {
  let m : PatMatcher = if glob {
    {
      p: code_points(p),
      s: code_points(x),
      match_all: '*'.to_int(),
      match_one: '?'.to_int(),
      match_other: '['.to_int(),
      glob: true,
    }
  } else {
    let mut all = '%'.to_int()
    let mut one = '_'.to_int()
    if escape == all {
      all = -2
    }
    if escape == one {
      one = -2
    }
    {
      p: code_points(p),
      s: code_points(x),
      match_all: all,
      match_one: one,
      match_other: escape,
      glob: false,
    }
  }
  m.compare(0, 0) == 0
}

///|
priv struct PatMatcher {
  p : Array[Int]
  s : Array[Int]
  match_all : Int
  match_one : Int
  match_other : Int // escape char (LIKE) or '[' (GLOB); -1 if none
  glob : Bool
}

///|
fn lower_ascii(c : Int) -> Int {
  if c >= 'A'.to_int() && c <= 'Z'.to_int() {
    c + 32
  } else {
    c
  }
}

///|
fn PatMatcher::pat_at(self : PatMatcher, i : Int) -> Int {
  if i < self.p.length() {
    self.p[i]
  } else {
    0
  }
}

///|
fn PatMatcher::chars_eq(self : PatMatcher, c : Int, c2 : Int) -> Bool {
  c == c2 ||
  (!self.glob && c < 128 && c2 < 128 && lower_ascii(c) == lower_ascii(c2))
}

///|
/// SQLite's patternCompare: 0 = match, 1 = no match, 2 = no match and no
/// later wildcard can match either.
fn PatMatcher::compare(self : PatMatcher, pi0 : Int, si0 : Int) -> Int {
  let plen = self.p.length()
  let slen = self.s.length()
  let mut pi = pi0
  let mut si = si0
  let mut escaped = -1
  while pi < plen {
    let mut c = self.p[pi]
    pi += 1
    if c == self.match_all {
      let mut next = -1
      while pi < plen {
        let c1 = self.p[pi]
        pi += 1
        if c1 == self.match_all {
          continue
        }
        if c1 == self.match_one {
          if si >= slen {
            return 2
          }
          si += 1
          continue
        }
        next = c1
        break
      }
      if next == -1 {
        return 0
      }
      c = next
      if c == self.match_other {
        if !self.glob {
          if pi >= plen {
            return 2
          }
          c = self.p[pi]
          pi += 1
        } else {
          while si < slen {
            let b = self.compare(pi - 1, si)
            if b != 1 {
              return b
            }
            si += 1
          }
          return 2
        }
      }
      while si < slen {
        let c2 = self.s[si]
        si += 1
        if !self.chars_eq(c, c2) {
          continue
        }
        let b = self.compare(pi, si)
        if b != 1 {
          return b
        }
      }
      return 2
    }
    if c == self.match_other {
      if !self.glob {
        if pi >= plen {
          return 1
        }
        c = self.p[pi]
        pi += 1
        escaped = pi
      } else {
        if si >= slen {
          return 1
        }
        let ch = self.s[si]
        si += 1
        let mut prior = 0
        let mut seen = false
        let mut invert = false
        let mut c2 = self.pat_at(pi)
        pi += 1
        if c2 == '^'.to_int() {
          invert = true
          c2 = self.pat_at(pi)
          pi += 1
        }
        if c2 == ']'.to_int() {
          if ch == ']'.to_int() {
            seen = true
          }
          c2 = self.pat_at(pi)
          pi += 1
        }
        while c2 != 0 && c2 != ']'.to_int() {
          let nx = self.pat_at(pi)
          if c2 == '-'.to_int() && nx != ']'.to_int() && nx != 0 && prior > 0 {
            c2 = nx
            pi += 1
            if ch >= prior && ch <= c2 {
              seen = true
            }
            prior = 0
          } else {
            if ch == c2 {
              seen = true
            }
            prior = c2
          }
          c2 = self.pat_at(pi)
          pi += 1
        }
        if c2 == 0 || seen == invert {
          return 1
        }
        continue
      }
    }
    if si >= slen {
      return 1
    }
    let c2 = self.s[si]
    si += 1
    if self.chars_eq(c, c2) {
      continue
    }
    if c == self.match_one && pi != escaped {
      continue
    }
    return 1
  }
  if si >= slen {
    0
  } else {
    1
  }
}
