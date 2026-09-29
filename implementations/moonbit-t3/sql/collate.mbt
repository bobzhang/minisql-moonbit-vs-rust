///|
/// Collating sequences for text comparison.
pub(all) enum Coll {
  CBinary
  CNoCase
  CRTrim
  /// An unknown name: only an error if a comparison actually uses it.
  CUnknown(String)
} derive(Eq, Debug)

///|
pub fn coll_of_name(name : String) -> Coll {
  match name.to_upper() {
    "BINARY" => CBinary
    "NOCASE" => CNoCase
    "RTRIM" => CRTrim
    _ => CUnknown(name)
  }
}

///|
/// Raises if the collation is unknown; returns it otherwise.
pub fn check_coll(c : Coll) -> Coll raise SqlError {
  match c {
    CUnknown(name) => raise err("no such collation sequence: " + name)
    _ => c
  }
}

///|
fn fold_ascii(u : Int) -> Int {
  if u >= 'A'.to_int() && u <= 'Z'.to_int() {
    u + 32
  } else {
    u
  }
}

///|
fn compare_text_nocase(a : String, b : String) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = fold_ascii(a[i].to_int())
    let y = fold_ascii(b[i].to_int())
    if x != y {
      return map_code_unit(x) - map_code_unit(y)
    }
  }
  a.length() - b.length()
}

///|
fn rtrim_spaces(s : String) -> String {
  let mut end = s.length()
  while end > 0 && s[end - 1] == ' ' {
    end -= 1
  }
  if end == s.length() {
    s
  } else {
    s[:end].to_owned()
  }
}

///|
pub fn compare_text_coll(a : String, b : String, coll : Coll) -> Int {
  match coll {
    CBinary => compare_text(a, b)
    CNoCase => compare_text_nocase(a, b)
    CRTrim => compare_text(rtrim_spaces(a), rtrim_spaces(b))
    CUnknown(_) => compare_text(a, b)
  }
}

///|
/// Total order of values under a collation (the collation only affects
/// TEXT-vs-TEXT comparisons).
pub fn compare_values_coll(a : Value, b : Value, coll : Coll) -> Int {
  match (a, b) {
    (Text(x), Text(y)) => compare_text_coll(x, y, coll)
    _ => compare_values(a, b)
  }
}
