// Expression evaluation over a flat row of values.

///|
/// Affinity of an expression for comparisons; None means "no affinity".
fn expr_affinity(e : Expr) -> Affinity? {
  match e {
    Slot(_, aff, _) => Some(aff)
    Outer(_, inner) => expr_affinity(inner)
    SubScalar(sp) => sp.info.aff
    Collate(inner, _) => expr_affinity(inner)
    Cast(_, aff) => Some(aff)
    _ => None
  }
}

///|
fn is_numeric_aff(a : Affinity) -> Bool {
  a is (AffNumeric | AffInteger | AffReal)
}

///|
/// Affinity to apply to both operands of a comparison (None: no conversion).
fn comparison_affinity(l : Expr, r : Expr) -> Affinity? {
  match (expr_affinity(l), expr_affinity(r)) {
    (Some(a), Some(b)) =>
      if is_numeric_aff(a) || is_numeric_aff(b) {
        Some(AffNumeric)
      } else {
        None
      }
    (Some(a), None) | (None, Some(a)) =>
      if a == AffNone {
        None
      } else {
        Some(a)
      }
    (None, None) => None
  }
}

///|
fn is_cmp_op(op : BinOp) -> Bool {
  op is (Eq | Ne | Lt | Le | Gt | Ge | Is | IsNot)
}

///|
/// True if the expression contains an explicit COLLATE operator.
fn has_explicit_coll(e : Expr) -> Bool {
  match e {
    Collate(_, _) => true
    Unary(_, x) | IsNull(x, _) | Cast(x, _) => has_explicit_coll(x)
    Binary(_, l, r) | Cmp(_, l, r, _) =>
      has_explicit_coll(l) || has_explicit_coll(r)
    Between(x, lo, hi, _, _, _) =>
      has_explicit_coll(x) || has_explicit_coll(lo) || has_explicit_coll(hi)
    InList(x, items, _, _) =>
      has_explicit_coll(x) || items.any(has_explicit_coll)
    Like(lhs~, pat~, esc~, ..) =>
      has_explicit_coll(lhs) ||
      has_explicit_coll(pat) ||
      (esc is Some(x) && has_explicit_coll(x))
    Case(base~, whens~, else_~, ..) =>
      (base is Some(b) && has_explicit_coll(b)) ||
      whens.any(w => has_explicit_coll(w.0) || has_explicit_coll(w.1)) ||
      (else_ is Some(x) && has_explicit_coll(x))
    Func(args~, ..) => args.any(has_explicit_coll)
    _ => false
  }
}

///|
/// Children of an expression, in order (for collation lookup).
fn expr_children(e : Expr) -> Array[Expr] {
  match e {
    Unary(_, x) | IsNull(x, _) | Cast(x, _) | Collate(x, _) => [x]
    Binary(_, l, r) | Cmp(_, l, r, _) => [l, r]
    Between(x, lo, hi, _, _, _) => [x, lo, hi]
    InList(x, items, _, _) => [x, ..items]
    SubIn(x, _, _, _) | InQ(x, _, _) => [x]
    Like(lhs~, pat~, esc~, ..) =>
      match esc {
        Some(x) => [lhs, pat, x]
        None => [lhs, pat]
      }
    Case(base~, whens~, else_~, ..) => {
      let out : Array[Expr] = []
      if base is Some(b) {
        out.push(b)
      }
      for w in whens {
        out.push(w.0)
        out.push(w.1)
      }
      if else_ is Some(x) {
        out.push(x)
      }
      out
    }
    Func(args~, ..) => args
    _ => []
  }
}

///|
/// Collating sequence of an expression (SQLite's sqlite3ExprCollSeq).
fn expr_coll(e : Expr) -> Coll? {
  match e {
    Collate(_, c) => Some(c)
    Slot(_, _, c) => Some(c)
    Outer(_, x) => expr_coll(x)
    Unary(Pos, x) | Cast(x, _) => expr_coll(x)
    _ =>
      if has_explicit_coll(e) {
        for c in expr_children(e) {
          if has_explicit_coll(c) {
            return expr_coll(c)
          }
        }
        None
      } else {
        None
      }
  }
}

///|
/// Collation used by a binary comparison.
fn binary_coll(l : Expr, r : Expr) -> Coll {
  if has_explicit_coll(l) {
    expr_coll(l).unwrap_or(CBinary)
  } else if has_explicit_coll(r) {
    expr_coll(r).unwrap_or(CBinary)
  } else {
    match expr_coll(l) {
      Some(c) => c
      None => expr_coll(r).unwrap_or(CBinary)
    }
  }
}

///|
fn cmp_info(l : Expr, r : Expr) -> CmpInfo {
  { aff: comparison_affinity(l, r), coll: binary_coll(l, r), }
}

///|
fn num_to_text(v : Value) -> Value {
  match v {
    Int(_) | Real(_) => Text(v.to_text().unwrap())
    _ => v
  }
}

///|
/// Apply comparison affinity to both operands.
fn cmp_prepare(a : Value, b : Value, aff : Affinity?) -> (Value, Value) {
  match aff {
    Some(AffText) =>
      if a is Text(_) || b is Text(_) {
        (num_to_text(a), num_to_text(b))
      } else {
        (a, b)
      }
    Some(AffNumeric) | Some(AffInteger) | Some(AffReal) =>
      (apply_numeric_cmp(a), apply_numeric_cmp(b))
    _ => (a, b)
  }
}

///|
/// Compare two values under a collation.
fn compare_coll(a : Value, b : Value, coll : Coll) -> Int {
  match (a, b, coll) {
    (Text(x), Text(y), CNoCase) => compare_text_nocase(x, y)
    (Text(x), Text(y), CRTrim) => compare_text(rtrim_spaces(x), rtrim_spaces(y))
    _ => compare_values(a, b)
  }
}

///|
fn rtrim_spaces(s : String) -> String {
  let mut n = s.length()
  while n > 0 && s[n - 1] == ' ' {
    n -= 1
  }
  if n == s.length() {
    s
  } else {
    s[:n].to_owned()
  }
}

///|
fn ascii_lower_cu(c : Int) -> Int {
  if c >= 'A'.to_int() && c <= 'Z'.to_int() {
    c + 32
  } else {
    c
  }
}

///|
fn compare_text_nocase(a : String, b : String) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = ascii_lower_cu(a[i].to_int())
    let y = ascii_lower_cu(b[i].to_int())
    if x != y {
      return fix_cu(x) - fix_cu(y)
    }
  }
  a.length() - b.length()
}

///|
/// Result of a comparison operator applied to two evaluated operands.
fn compare_op(op : BinOp, a : Value, b : Value, info : CmpInfo) -> Value {
  let (a, b) = cmp_prepare(a, b, info.aff)
  match op {
    Is => bool_val(equal_nullsafe_coll(a, b, info.coll))
    IsNot => bool_val(!equal_nullsafe_coll(a, b, info.coll))
    _ => {
      if a is Null || b is Null {
        return Null
      }
      let c = compare_coll(a, b, info.coll)
      bool_val(
        match op {
          Eq => c == 0
          Ne => c != 0
          Lt => c < 0
          Le => c <= 0
          Gt => c > 0
          _ => c >= 0
        },
      )
    }
  }
}

///|
fn equal_nullsafe_coll(a : Value, b : Value, coll : Coll) -> Bool {
  match (a, b) {
    (Null, Null) => true
    (Null, _) | (_, Null) => false
    _ => compare_coll(a, b, coll) == 0
  }
}

///|
fn bool_val(b : Bool) -> Value {
  Int(if b { 1L } else { 0L })
}

///|
fn real_result(d : Double) -> Value {
  if d.is_nan() {
    Null
  } else {
    Real(d)
  }
}

///|
fn arith(op : BinOp, a : Value, b : Value) -> Value {
  if a is Null || b is Null {
    return Null
  }
  let na = a.to_number()
  let nb = b.to_number()
  match (na, nb) {
    (Int(x), Int(y)) =>
      match op {
        Add => {
          let r = x + y
          if ((x ^ r) & (y ^ r)) < 0L {
            Real(x.to_double() + y.to_double())
          } else {
            Int(r)
          }
        }
        Sub => {
          let r = x - y
          if ((x ^ y) & (x ^ r)) < 0L {
            Real(x.to_double() - y.to_double())
          } else {
            Int(r)
          }
        }
        Mul =>
          match mul_checked(x, y) {
            Some(r) => Int(r)
            None => Real(x.to_double() * y.to_double())
          }
        Div =>
          if y == 0L {
            Null
          } else if x == @int64.MIN_VALUE && y == -1L {
            Real(-x.to_double())
          } else {
            Int(x / y)
          }
        Mod =>
          if y == 0L {
            Null
          } else if y == -1L {
            Int(0L)
          } else {
            Int(x % y)
          }
        _ => Null
      }
    _ => {
      if op == Mod {
        let x = a.to_int64()
        let mut y = b.to_int64()
        if y == 0L {
          return Null
        }
        if y == -1L {
          y = 1L
        }
        return Real((x % y).to_double())
      }
      let x = na.to_double()
      let y = nb.to_double()
      match op {
        Add => real_result(x + y)
        Sub => real_result(x - y)
        Mul => real_result(x * y)
        Div => if y == 0.0 { Null } else { real_result(x / y) }
        _ => Null
      }
    }
  }
}

///|
fn mul_checked(a : Int64, b : Int64) -> Int64? {
  if a == 0L || b == 0L {
    return Some(0L)
  }
  if (a == -1L && b == @int64.MIN_VALUE) || (b == -1L && a == @int64.MIN_VALUE) {
    return None
  }
  let r = a * b
  if r / b != a {
    None
  } else {
    Some(r)
  }
}

///|
fn shift_left(x : Int64, n : Int64) -> Int64 {
  if n < 0L {
    shift_right(x, -n)
  } else if n >= 64L {
    0L
  } else {
    x << n.to_int()
  }
}

///|
fn shift_right(x : Int64, n : Int64) -> Int64 {
  if n < 0L {
    shift_left(x, -n)
  } else if n >= 64L {
    if x < 0L {
      -1L
    } else {
      0L
    }
  } else {
    x >> n.to_int()
  }
}

///|
fn eval(e : Expr, row : Array[Value]) -> Value raise SqlError {
  match e {
    Lit(v) => v
    BigIntLit => Real(9223372036854775808.0)
    Slot(i, _, _) => row[i]
    Column(name~, ..) => raise sql_err("no such column: \{name}")
    Unary(op, inner) =>
      match op {
        Neg =>
          match inner {
            BigIntLit => Int(@int64.MIN_VALUE)
            _ =>
              match eval(inner, row).to_number() {
                Int(i) =>
                  if i == @int64.MIN_VALUE {
                    Real(-i.to_double())
                  } else {
                    Int(-i)
                  }
                Real(d) => Real(-d)
                _ => Null
              }
          }
        Pos => eval(inner, row)
        Not =>
          match eval(inner, row).truth() {
            None => Null
            Some(b) => bool_val(!b)
          }
        BitNot => {
          let v = eval(inner, row)
          if v is Null {
            Null
          } else {
            Int(v.to_int64().lnot())
          }
        }
      }
    Binary(op, l, r) => eval_binary(op, l, r, row)
    Cmp(op, l, r, info) => compare_op(op, eval(l, row), eval(r, row), info)
    Collate(inner, _) => eval(inner, row)
    Cast(inner, aff) => cast_value(eval(inner, row), aff)
    IsNull(inner, neg) => {
      let v = eval(inner, row)
      bool_val(v.is_null() != neg)
    }
    Between(x, lo, hi, neg, i1, i2) => {
      let xv = eval(x, row)
      let a = compare_op(Ge, xv, eval(lo, row), i1)
      let b = compare_op(Le, xv, eval(hi, row), i2)
      let r = and3(a, b)
      if neg {
        not3(r)
      } else {
        r
      }
    }
    InList(x, items, neg, info) => {
      if items.length() == 0 {
        return bool_val(neg)
      }
      let xv = eval(x, row)
      if xv is Null {
        return Null
      }
      let mut has_null = false
      for it in items {
        let v = eval(it, row)
        if v is Null {
          has_null = true
          continue
        }
        let (a, b) = cmp_prepare(xv, v, info.aff)
        if compare_coll(a, b, info.coll) == 0 {
          return bool_val(!neg)
        }
      }
      if has_null {
        Null
      } else {
        bool_val(neg)
      }
    }
    Like(glob~, lhs~, pat~, esc~, neg~) => {
      let xv = eval(lhs, row)
      let pv = eval(pat, row)
      let ev = match esc {
        Some(e) => Some(eval(e, row))
        None => None
      }
      let r = like_values(glob, pv, xv, ev)
      if neg {
        not3(r)
      } else {
        r
      }
    }
    Case(base~, whens~, else_~, infos~) => {
      match base {
        Some(b) => {
          let bv = eval(b, row)
          for i, w in whens {
            let wv = eval(w.0, row)
            if compare_op(Eq, bv, wv, infos[i]) is Int(1L) {
              return eval(w.1, row)
            }
          }
        }
        None =>
          for w in whens {
            if eval(w.0, row).truth() is Some(true) {
              return eval(w.1, row)
            }
          }
      }
      match else_ {
        Some(x) => eval(x, row)
        None => Null
      }
    }
    Func(name~, args~, coll~, ..) => call_function(name, args, coll, row)
    AggRef(i) => row[i]
    WinRef(i, base) => row[base.val + i]
    WinCall(w) =>
      raise sql_err("misuse of window function \{w.name.to_lower()}()")
    Outer(d, inner) => eval_outer(d, inner)
    SubScalar(sp) => {
      let rows = sp.rows(row, 1L)
      if rows.length() == 0 {
        Null
      } else {
        rows[0][0]
      }
    }
    SubExists(sp) => bool_val(sp.rows(row, 1L).length() > 0)
    SubIn(x, sp, neg, info) => eval_sub_in(x, sp, neg, info, row)
    SubQ(_) | ExistsQ(_) | InQ(_, _, _) => raise sql_err("unbound subquery")
  }
}

///|
fn and3(a : Value, b : Value) -> Value {
  match (a.truth(), b.truth()) {
    (Some(false), _) | (_, Some(false)) => bool_val(false)
    (Some(true), Some(true)) => bool_val(true)
    _ => Null
  }
}

///|
fn not3(a : Value) -> Value {
  match a.truth() {
    None => Null
    Some(b) => bool_val(!b)
  }
}

///|
fn eval_binary(
  op : BinOp,
  l : Expr,
  r : Expr,
  row : Array[Value],
) -> Value raise SqlError {
  match op {
    And => {
      let a = eval(l, row).truth()
      if a is Some(false) {
        return bool_val(false)
      }
      let b = eval(r, row).truth()
      match (a, b) {
        (_, Some(false)) => bool_val(false)
        (Some(true), Some(true)) => bool_val(true)
        _ => Null
      }
    }
    Or => {
      let a = eval(l, row).truth()
      if a is Some(true) {
        return bool_val(true)
      }
      let b = eval(r, row).truth()
      match (a, b) {
        (_, Some(true)) => bool_val(true)
        (Some(false), Some(false)) => bool_val(false)
        _ => Null
      }
    }
    Add | Sub | Mul | Div | Mod => arith(op, eval(l, row), eval(r, row))
    Concat => {
      let a = eval(l, row)
      let b = eval(r, row)
      match (a.to_text(), b.to_text()) {
        (Some(x), Some(y)) => Text(x + y)
        _ => Null
      }
    }
    BitAnd | BitOr | Shl | Shr => {
      let a = eval(l, row)
      let b = eval(r, row)
      if a is Null || b is Null {
        return Null
      }
      let x = a.to_int64()
      let y = b.to_int64()
      Int(
        match op {
          BitAnd => x & y
          BitOr => x | y
          Shl => shift_left(x, y)
          _ => shift_right(x, y)
        },
      )
    }
    Eq | Ne | Lt | Le | Gt | Ge | Is | IsNot =>
      compare_op(op, eval(l, row), eval(r, row), cmp_info(l, r))
  }
}
