///|
fn like_fold(c : Char) -> Char {
  if c >= 'A' && c <= 'Z' {
    (c.to_int() + 32).unsafe_to_char()
  } else {
    c
  }
}

///|
/// SQLite's patternCompare for LIKE (case-insensitive for ASCII, `%`, `_`,
/// optional escape) and GLOB (`*`, `?`, `[...]`).
fn pattern_match(
  pat : Array[Char],
  pi : Int,
  s : Array[Char],
  si : Int,
  glob : Bool,
  esc : Char?,
) -> Bool {
  let np = pat.length()
  let ns = s.length()
  let mut pi = pi
  let mut si = si
  while pi < np {
    let c = pat[pi]
    if !glob && esc is Some(e) && c == e {
      pi += 1
      if pi >= np || si >= ns || like_fold(pat[pi]) != like_fold(s[si]) {
        return false
      }
      pi += 1
      si += 1
      continue
    }
    let any_many = if glob { '*' } else { '%' }
    let any_one = if glob { '?' } else { '_' }
    if c == any_many {
      // Collapse runs of wildcards; each single-char wildcard consumes one.
      while pi < np && (pat[pi] == any_many || pat[pi] == any_one) {
        if pat[pi] == any_one {
          if si >= ns {
            return false
          }
          si += 1
        }
        pi += 1
      }
      if pi >= np {
        return true
      }
      for k = si; k <= ns; k = k + 1 {
        if pattern_match(pat, pi, s, k, glob, esc) {
          return true
        }
      }
      return false
    }
    if si >= ns {
      return false
    }
    if c == any_one {
      pi += 1
      si += 1
      continue
    }
    if glob && c == '[' {
      let ch = s[si]
      let mut j = pi + 1
      let mut invert = false
      if j < np && pat[j] == '^' {
        invert = true
        j += 1
      }
      let mut seen = false
      if j < np && pat[j] == ']' {
        if ch == ']' {
          seen = true
        }
        j += 1
      }
      let mut prior : Char? = None
      while j < np && pat[j] != ']' {
        if pat[j] == '-' && prior is Some(lo) && j + 1 < np && pat[j + 1] != ']' {
          if ch >= lo && ch <= pat[j + 1] {
            seen = true
          }
          prior = None
          j += 2
        } else {
          if pat[j] == ch {
            seen = true
          }
          prior = Some(pat[j])
          j += 1
        }
      }
      if j >= np {
        return false
      }
      if seen == invert {
        return false
      }
      pi = j + 1
      si += 1
      continue
    }
    let matches = if glob {
      c == s[si]
    } else {
      like_fold(c) == like_fold(s[si])
    }
    if !matches {
      return false
    }
    pi += 1
    si += 1
  }
  si == ns
}

///|
pub fn like_text(pattern : String, s : String, esc : Char?) -> Bool {
  pattern_match(pattern.to_array(), 0, s.to_array(), 0, false, esc)
}

///|
pub fn glob_text(pattern : String, s : String) -> Bool {
  pattern_match(pattern.to_array(), 0, s.to_array(), 0, true, None)
}
