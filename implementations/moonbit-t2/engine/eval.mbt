///|
/// Runtime environment: the current row of each scope level.
pub(all) struct Env {
  row : Array[Value]
  parent : Env?
}

///|
fn Env::lookup(self : Env, depth : Int, idx : Int) -> Value {
  let mut e = self
  for _ in 0..<depth {
    match e.parent {
      Some(p) => e = p
      None => return Null
    }
  }
  e.row[idx]
}

///|
/// Affinity of an expression: None when it has no affinity (literals and
/// most computed values); column references and CASTs have one.
pub fn expr_aff_opt(e : Expr) -> Affinity? {
  match e {
    Slot(aff=AffUnset, ..) => None
    Slot(aff~, ..) => Some(aff)
    ScalarQ(q) => q.aff
    Cast(_, ty) => Some(affinity_of_type(ty))
    Collate(inner, _) => expr_aff_opt(inner)
    _ => None
  }
}

///|
pub fn expr_affinity(e : Expr) -> Affinity {
  expr_aff_opt(e).unwrap_or(AffNone)
}

///|
fn is_numeric_aff(a : Affinity) -> Bool {
  a is (AffNumeric | AffInteger | AffReal)
}

///|
/// Affinity to apply to both operands of a comparison.
fn comparison_affinity(l : Expr, r : Expr) -> Affinity {
  combine_aff(expr_aff_opt(l), expr_aff_opt(r))
}

///|
fn combine_aff(a : Affinity?, b : Affinity?) -> Affinity {
  match (a, b) {
    (Some(a), Some(b)) =>
      if is_numeric_aff(a) || is_numeric_aff(b) {
        AffNumeric
      } else {
        AffNone
      }
    (Some(a), None) => a
    (None, Some(b)) => b
    (None, None) => AffNone
  }
}

///|
fn apply_cmp_affinity(v : Value, aff : Affinity) -> Value {
  match aff {
    AffNumeric | AffInteger | AffReal =>
      match v {
        Text(s) =>
          match parse_numeric_text(s) {
            Some(x) => x
            None => v
          }
        _ => v
      }
    AffText =>
      match v {
        Int(_) | Real(_) => Text(v.to_text())
        _ => v
      }
    AffNone | AffUnset => v
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
fn add_checked(a : Int64, b : Int64) -> Int64? {
  let r = a + b
  if ((a ^ r) & (b ^ r)) < 0L {
    None
  } else {
    Some(r)
  }
}

///|
fn sub_checked(a : Int64, b : Int64) -> Int64? {
  let r = a - b
  if ((a ^ b) & (a ^ r)) < 0L {
    None
  } else {
    Some(r)
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
pub fn arith(op : BinOp, a : Value, b : Value) -> Value {
  if a is Null || b is Null {
    return Null
  }
  let x = to_numeric(a)
  let y = to_numeric(b)
  match (x, y) {
    (Int(i), Int(j)) =>
      match op {
        Add =>
          match add_checked(i, j) {
            Some(r) => Int(r)
            None => real_result(i.to_double() + j.to_double())
          }
        Sub =>
          match sub_checked(i, j) {
            Some(r) => Int(r)
            None => real_result(i.to_double() - j.to_double())
          }
        Mul =>
          match mul_checked(i, j) {
            Some(r) => Int(r)
            None => real_result(i.to_double() * j.to_double())
          }
        Div =>
          if j == 0L {
            Null
          } else if i == @int64.MIN_VALUE && j == -1L {
            Real(9223372036854775808.0)
          } else {
            Int(i / j)
          }
        Rem =>
          if j == 0L {
            Null
          } else if j == -1L {
            Int(0L)
          } else {
            Int(i % j)
          }
        _ => Null
      }
    _ => {
      let dx = value_to_double(x)
      let dy = value_to_double(y)
      match op {
        Add => real_result(dx + dy)
        Sub => real_result(dx - dy)
        Mul => real_result(dx * dy)
        Div => if dy == 0.0 { Null } else { real_result(dx / dy) }
        Rem => {
          let ix = double_to_int64(dx)
          let iy = double_to_int64(dy)
          if iy == 0L {
            Null
          } else if iy == -1L {
            Real(0.0)
          } else {
            Real((ix % iy).to_double())
          }
        }
        _ => Null
      }
    }
  }
}

///|
fn negate(v : Value) -> Value {
  match to_numeric(v) {
    Null => Null
    Int(i) =>
      if i == @int64.MIN_VALUE {
        Real(9223372036854775808.0)
      } else {
        Int(-i)
      }
    Real(d) => Real(-d)
    _ => Null
  }
}

///|
fn bit_op(op : BinOp, a : Value, b : Value) -> Value {
  if a is Null || b is Null {
    return Null
  }
  let x = value_to_int64(a)
  let y = value_to_int64(b)
  match op {
    BitAnd => Int(x & y)
    BitOr => Int(x | y)
    Shl => Int(shift_left(x, y))
    Shr => Int(shift_left(x, -y))
    _ => Null
  }
}

///|
fn shift_left(x : Int64, n : Int64) -> Int64 {
  if n >= 64L {
    0L
  } else if n >= 0L {
    x << n.to_int()
  } else if n <= -64L {
    if x < 0L {
      -1L
    } else {
      0L
    }
  } else {
    x >> (-n).to_int()
  }
}

///|
/// Compares after applying comparison affinity; None if either is NULL.
fn cmp_with_affinity(
  a : Value,
  b : Value,
  aff : Affinity,
  coll : String,
) -> Int? {
  if a is Null || b is Null {
    return None
  }
  let x = apply_cmp_affinity(a, aff)
  let y = apply_cmp_affinity(b, aff)
  Some(value_compare_coll(x, y, coll))
}

///|
/// Compares the values of two expressions with SQLite's binary-comparison
/// affinity and collation rules.
fn cmp_exprs(l : Expr, r : Expr, a : Value, b : Value) -> Int? {
  cmp_with_affinity(a, b, comparison_affinity(l, r), binary_coll(l, r))
}

///|
pub fn eval(e : Expr, env : Env) -> Value raise SqlError {
  match e {
    Lit(v) => v
    Slot(depth~, idx~, ..) => env.lookup(depth, idx)
    Col(name~, ..) => raise SqlError("no such column: \{name}")
    WinFunc(f, _) =>
      raise SqlError("misuse of window function \{func_name(f)}()")
    Unary(op, x) => {
      let v = eval(x, env)
      match op {
        Neg => negate(v)
        Pos => v
        BitNot => if v is Null { Null } else { Int(value_to_int64(v).lnot()) }
        Not =>
          match truthy(v) {
            None => Null
            Some(b) => bool_val(!b)
          }
      }
    }
    Binary(op, l, r) =>
      match op {
        And => {
          let a = truthy(eval(l, env))
          if a == Some(false) {
            return bool_val(false)
          }
          let b = truthy(eval(r, env))
          match (a, b) {
            (_, Some(false)) => bool_val(false)
            (Some(true), Some(true)) => bool_val(true)
            _ => Null
          }
        }
        Or => {
          let a = truthy(eval(l, env))
          if a == Some(true) {
            return bool_val(true)
          }
          let b = truthy(eval(r, env))
          match (a, b) {
            (_, Some(true)) => bool_val(true)
            (Some(false), Some(false)) => bool_val(false)
            _ => Null
          }
        }
        Add | Sub | Mul | Div | Rem => arith(op, eval(l, env), eval(r, env))
        BitAnd | BitOr | Shl | Shr => bit_op(op, eval(l, env), eval(r, env))
        Concat => {
          let a = eval(l, env)
          let b = eval(r, env)
          if a is Null || b is Null {
            Null
          } else {
            Text(a.to_text() + b.to_text())
          }
        }
        Eq | Ne | Lt | Le | Gt | Ge => {
          let a = eval(l, env)
          let b = eval(r, env)
          match cmp_exprs(l, r, a, b) {
            None => Null
            Some(c) =>
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
    IsNull(x, neg) => {
      let v = eval(x, env)
      bool_val((v is Null) != neg)
    }
    Is(l, r, neg) => {
      let a = eval(l, env)
      let b = eval(r, env)
      let same = match (a, b) {
        (Null, Null) => true
        (Null, _) | (_, Null) => false
        _ => cmp_exprs(l, r, a, b) == Some(0)
      }
      bool_val(same != neg)
    }
    Between(x, lo, hi, neg) => {
      let v = eval(x, env)
      let a = eval(lo, env)
      let b = eval(hi, env)
      let c1 = cmp_exprs(x, lo, v, a)
      let c2 = cmp_exprs(x, hi, v, b)
      let ge = c1.map(c => c >= 0)
      let le = c2.map(c => c <= 0)
      let r = match (ge, le) {
        (Some(false), _) | (_, Some(false)) => Some(false)
        (Some(true), Some(true)) => Some(true)
        _ => None
      }
      match r {
        None => Null
        Some(b) => bool_val(b != neg)
      }
    }
    InList(x, items, neg) => {
      let v = eval(x, env)
      if items.length() == 0 {
        return bool_val(neg)
      }
      if v is Null {
        return Null
      }
      if items.length() == 1 && is_constant_expr(items[0]) {
        // SQLite rewrites `x IN (const)` as `x = +const`.
        let rhs = Unary(Pos, items[0])
        return match cmp_exprs(x, rhs, v, eval(items[0], env)) {
          None => Null
          Some(c) => bool_val((c == 0) != neg)
        }
      }
      let mut saw_null = false
      let aff = expr_affinity(x)
      let coll = match expr_coll(x) {
        Some((c, _)) => c
        None => "BINARY"
      }
      for it in items {
        let w = eval(it, env)
        match cmp_with_affinity(v, w, aff, coll) {
          None => saw_null = true
          Some(0) => return bool_val(!neg)
          _ => ()
        }
      }
      if saw_null {
        Null
      } else {
        bool_val(neg)
      }
    }
    Case(base, whens, els) => {
      match base {
        Some(b) => {
          let bv = eval(b, env)
          for w in whens {
            let wv = eval(w.0, env)
            if cmp_exprs(b, w.0, bv, wv) == Some(0) {
              return eval(w.1, env)
            }
          }
        }
        None =>
          for w in whens {
            if truthy(eval(w.0, env)) == Some(true) {
              return eval(w.1, env)
            }
          }
      }
      match els {
        Some(x) => eval(x, env)
        None => Null
      }
    }
    Cast(x, ty) => cast_value(eval(x, env), ty)
    Collate(x, _) => eval(x, env)
    Like(op, x, p, esc, neg) => {
      let r = eval_like(
        op,
        eval(p, env),
        eval(x, env),
        match esc {
          Some(z) => Some(eval(z, env))
          None => None
        },
      )
      match r {
        Null => Null
        Int(i) => bool_val((i != 0L) != neg)
        v => v
      }
    }
    Func(name~, args~, distinct~, star~, ..) =>
      call_function(name, args, distinct, star, env)
    AggRef(depth~, idx~, ..) => env.lookup(depth, idx)
    Subquery(_) | Exists(_) | InSelect(_, _, _) =>
      raise SqlError("unbound subquery")
    ScalarQ(q) => {
      let rows = q.rows(env)
      if rows.length() == 0 {
        Null
      } else {
        rows[0][0]
      }
    }
    ExistsQ(q) => bool_val(q.rows(env).length() > 0)
    InQ(x, q, neg) => {
      let v = eval(x, env)
      let rows = q.rows(env)
      if rows.length() == 0 {
        return bool_val(neg)
      }
      if v is Null {
        return Null
      }
      let aff = combine_aff(expr_aff_opt(x), q.aff)
      let coll = binary_coll_opt(expr_coll(x), q.coll)
      let keys = match q.in_keys {
        Some(k) if !q.correlated => k
        _ => {
          let k : Set[String] = Set([])
          q.in_null = false
          for r in rows {
            let w = r[0]
            if w is Null {
              q.in_null = true
            } else {
              let sb = StringBuilder()
              value_key(sb, apply_cmp_affinity(w, aff), coll)
              k.add(sb.to_string())
            }
          }
          q.in_keys = Some(k)
          k
        }
      }
      let sb = StringBuilder()
      value_key(sb, apply_cmp_affinity(v, aff), coll)
      if keys.contains(sb.to_string()) {
        bool_val(!neg)
      } else if q.in_null {
        Null
      } else {
        bool_val(neg)
      }
    }
  }
}

///|
pub fn cast_value(v : Value, ty : String) -> Value {
  if v is Null {
    return Null
  }
  match affinity_of_type(ty) {
    AffNone | AffUnset =>
      if ty.trim().length() == 0 {
        v
      } else {
        Blob(v.to_blob())
      }
    AffText => Text(v.to_text())
    AffReal =>
      match v {
        Int(i) => Real(i.to_double())
        Real(_) => v
        Text(_) | Blob(_) => Real(value_to_double(v))
        Null => Null
      }
    AffInteger =>
      match v {
        Int(_) => v
        Real(d) => Int(double_to_int64(d))
        Text(_) | Blob(_) => Int(value_to_int64(v))
        Null => Null
      }
    AffNumeric =>
      match v {
        Int(_) | Real(_) => v
        Text(_) | Blob(_) =>
          match to_numeric(v) {
            Real(d) =>
              match real_to_int_exact(d) {
                Some(i) if i >= -2251799813685248L && i < 2251799813685248L =>
                  Int(i)
                _ => Real(d)
              }
            x => x
          }
        Null => Null
      }
  }
}

///|
/// True if the expression refers to no columns.
fn is_constant_expr(e : Expr) -> Bool {
  match e {
    Lit(_) => true
    Col(..) | Slot(..) | AggRef(..) | WinFunc(_, _) => false
    Subquery(_)
    | Exists(_)
    | InSelect(_, _, _)
    | ScalarQ(_)
    | ExistsQ(_)
    | InQ(_, _, _) => false
    Unary(_, x) | Cast(x, _) | Collate(x, _) | IsNull(x, _) =>
      is_constant_expr(x)
    Binary(_, l, r) | Is(l, r, _) => is_constant_expr(l) && is_constant_expr(r)
    Between(x, lo, hi, _) =>
      is_constant_expr(x) && is_constant_expr(lo) && is_constant_expr(hi)
    InList(x, items, _) => is_constant_expr(x) && items.all(is_constant_expr)
    Like(_, x, p, esc, _) =>
      is_constant_expr(x) &&
      is_constant_expr(p) &&
      (match esc {
        Some(z) => is_constant_expr(z)
        None => true
      })
    Func(args~, ..) => args.all(is_constant_expr)
    Case(base, whens, els) =>
      (match base {
        Some(b) => is_constant_expr(b)
        None => true
      }) &&
      whens.all(w => is_constant_expr(w.0) && is_constant_expr(w.1)) &&
      (match els {
        Some(z) => is_constant_expr(z)
        None => true
      })
  }
}
