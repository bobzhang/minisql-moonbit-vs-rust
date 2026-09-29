///|
/// A bound (name-resolved) expression, evaluated against a flat row.
pub(all) enum BExpr {
  BConst(Value)
  /// Row slot index, the column's affinity and collation.
  BCol(Int, Affinity, Coll)
  /// Explicit COLLATE operator.
  BCollate(BExpr, Coll)
  BCast(BExpr, Affinity)
  BUnary(UnOp, BExpr)
  BArith(BinOp, BExpr, BExpr)
  /// Comparison operator with the affinity and collation to apply.
  BCmp(BinOp, BExpr, BExpr, Affinity, Coll)
  BAnd(BExpr, BExpr)
  BOr(BExpr, BExpr)
  BIsNull(BExpr, Bool)
  BInList(BExpr, Array[BExpr], Bool, Affinity, Coll)
  /// Simple CASE arms carry the affinity/collation of `base = when`.
  BCase(BExpr?, Array[(BExpr, BExpr, Affinity, Coll)], BExpr?)
  BFunc(String, (Array[Value]) -> Value raise SqlError, Array[BExpr])
  BCoalesce(Array[BExpr])
  BIif(BExpr, BExpr, BExpr?)
  /// Scalar max (true) / min (false) with the collation to use.
  BMinMax(Bool, Array[BExpr], Coll)
  BNullIf(BExpr, BExpr, Affinity, Coll)
  /// Row slot without affinity or collation (aggregate results).
  BSlot(Int)
  /// Column of an enclosing query: nesting depth (1 = parent), slot,
  /// affinity and collation.
  BOuter(Int, Int, Affinity, Coll)
  /// Scalar subquery.
  BSubq(SubPlan)
  /// [NOT] EXISTS (true = NOT).
  BExists(SubPlan, Bool)
  /// x [NOT] IN (SELECT ...) with the comparison affinity and collation.
  BInSub(BExpr, SubPlan, Bool, Affinity, Coll)
}

///|
/// A compiled subquery used inside an expression.
pub(all) struct SubPlan {
  run : () -> Array[Array[Value]] raise SqlError
  /// True if the subquery references columns of enclosing queries.
  correlated : Bool
  /// Affinity of the first result column.
  aff : Affinity?
  mut cache : Array[Array[Value]]?
  mut keys : Set[String]?
  mut has_null : Bool
}

///|
/// Rows of the enclosing queries, innermost last, while subqueries run.
let outer_rows : Array[Array[Value]] = []

///|
fn run_subplan(
  p : SubPlan,
  row : Array[Value],
) -> Array[Array[Value]] raise SqlError {
  if !p.correlated && p.cache is Some(c) {
    return c
  }
  outer_rows.push(row)
  errdefer outer_rows.pop() |> ignore
  let res = (p.run)()
  outer_rows.pop() |> ignore
  if !p.correlated {
    p.cache = Some(res)
  }
  res
}

///|
/// Affinity of an expression for comparison purposes (None = no affinity).
pub fn BExpr::affinity(self : BExpr) -> Affinity? {
  match self {
    BCol(_, a, _) | BOuter(_, _, a, _) => Some(a)
    BCast(_, a) => Some(a)
    BSubq(p) => p.aff
    BCollate(x, _) => x.affinity()
    _ => None
  }
}

///|
fn BExpr::children(self : BExpr) -> Array[BExpr] {
  match self {
    BConst(_) | BCol(_, _, _) | BSlot(_) | BOuter(_, _, _, _) => []
    BSubq(_) | BExists(_, _) => []
    BInSub(x, _, _, _, _) => [x]
    BCollate(x, _) | BCast(x, _) | BUnary(_, x) | BIsNull(x, _) => [x]
    BArith(_, l, r) | BCmp(_, l, r, _, _) | BAnd(l, r) | BOr(l, r) => [l, r]
    BNullIf(l, r, _, _) => [l, r]
    BInList(x, items, _, _, _) => [x, ..items]
    BCase(base, arms, els) => {
      let out = []
      if base is Some(b) {
        out.push(b)
      }
      for a in arms {
        out.push(a.0)
        out.push(a.1)
      }
      if els is Some(e) {
        out.push(e)
      }
      out
    }
    BFunc(_, _, args) | BCoalesce(args) | BMinMax(_, args, _) => args
    BIif(c, t, e) =>
      match e {
        Some(x) => [c, t, x]
        None => [c, t]
      }
  }
}

///|
/// True if an explicit COLLATE appears anywhere in the expression
/// (SQLite's EP_Collate flag).
pub fn BExpr::has_collate(self : BExpr) -> Bool {
  match self {
    BCollate(_, _) => true
    _ => self.children().any(c => c.has_collate())
  }
}

///|
/// The collating sequence of an expression, if it has one.
pub fn BExpr::collation(self : BExpr) -> Coll? {
  match self {
    BCol(_, _, c) | BOuter(_, _, _, c) => Some(c)
    BCollate(_, c) => Some(c)
    BCast(x, _) | BUnary(Pos, x) => x.collation()
    _ =>
      if self.has_collate() {
        for c in self.children() {
          if c.has_collate() {
            return c.collation()
          }
        }
        None
      } else {
        None
      }
  }
}

///|
/// Collation used by a binary comparison between two expressions.
pub fn binary_collation(l : BExpr, r : BExpr) -> Coll raise SqlError {
  check_coll(binary_collation_unchecked(l, r))
}

///|
fn binary_collation_unchecked(l : BExpr, r : BExpr) -> Coll {
  if l.has_collate() {
    l.collation().unwrap_or(CBinary)
  } else if r.has_collate() {
    r.collation().unwrap_or(CBinary)
  } else {
    match l.collation() {
      Some(c) => c
      None => r.collation().unwrap_or(CBinary)
    }
  }
}

///|
fn is_numeric_aff(a : Affinity) -> Bool {
  a is (AffNumeric | AffInteger | AffReal)
}

///|
/// The affinity applied to both operands of a comparison.
pub fn comparison_affinity(a : Affinity?, b : Affinity?) -> Affinity {
  match (a, b) {
    (Some(x), Some(y)) =>
      if is_numeric_aff(x) || is_numeric_aff(y) {
        AffNumeric
      } else {
        AffNone
      }
    (Some(x), None) | (None, Some(x)) => x
    (None, None) => AffNone
  }
}

///|
fn apply_cmp_affinity(v : Value, aff : Affinity) -> Value {
  match aff {
    AffNone => v
    AffText =>
      match v {
        Int(_) | Real(_) => Text(v.to_text())
        _ => v
      }
    _ =>
      match v {
        Text(s) =>
          match text_to_numeric_strict(s) {
            Some(n) => n
            None => v
          }
        _ => v
      }
  }
}

///|
/// Compares two values after applying comparison affinity; None if either is NULL.
fn compare_with_affinity(
  a : Value,
  b : Value,
  aff : Affinity,
  coll : Coll,
) -> Int? {
  if a is Null || b is Null {
    return None
  }
  Some(
    compare_values_coll(
      apply_cmp_affinity(a, aff),
      apply_cmp_affinity(b, aff),
      coll,
    ),
  )
}

///|
/// Hash key of a non-NULL value for equality under a comparison affinity
/// and collation.
fn cmp_key(v : Value, aff : Affinity, coll : Coll) -> String {
  let sb = StringBuilder()
  write_value_key(sb, apply_cmp_affinity(v, aff), coll)
  sb.to_string()
}

///|
fn bool_value(b : Bool) -> Value {
  if b {
    Int(1L)
  } else {
    Int(0L)
  }
}

///|
fn real_result(r : Double) -> Value {
  if r.is_nan() {
    Null
  } else {
    Real(r)
  }
}

///|
pub fn arith(op : BinOp, a : Value, b : Value) -> Value {
  if a is Null || b is Null {
    return Null
  }
  let x = a.to_numeric()
  let y = b.to_numeric()
  match (x, y) {
    (Int(i), Int(j)) =>
      match op {
        Add => {
          let r = i + j
          if ((i ^ r) & (j ^ r)) < 0L {
            real_result(i.to_double() + j.to_double())
          } else {
            Int(r)
          }
        }
        Sub => {
          let r = i - j
          if ((i ^ j) & (i ^ r)) < 0L {
            real_result(i.to_double() - j.to_double())
          } else {
            Int(r)
          }
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
            Real(-i.to_double())
          } else {
            Int(i / j)
          }
        Mod =>
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
      let p = x.as_double()
      let q = y.as_double()
      match op {
        Add => real_result(p + q)
        Sub => real_result(p - q)
        Mul => real_result(p * q)
        Div => if q == 0.0 { Null } else { real_result(p / q) }
        Mod => {
          let ii = double_to_int64(p)
          let jj = double_to_int64(q)
          if jj == 0L {
            Null
          } else if jj == -1L {
            Real(0.0)
          } else {
            Real((ii % jj).to_double())
          }
        }
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
fn bit_op(op : BinOp, a : Value, b : Value) -> Value {
  if a is Null || b is Null {
    return Null
  }
  let x = a.to_int64_cast()
  let y = b.to_int64_cast()
  match op {
    BitAnd => Int(x & y)
    BitOr => Int(x | y)
    Shl => Int(shift_left(x, y))
    Shr => Int(shift_left(x, if y == @int64.MIN_VALUE { 64L } else { -y }))
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
fn concat_values(a : Value, b : Value) -> Value {
  if a is Null || b is Null {
    return Null
  }
  Text(a.to_text() + b.to_text())
}

///|
fn negate(v : Value) -> Value {
  match v.to_numeric() {
    Null => Null
    Int(i) => if i == @int64.MIN_VALUE { Real(-i.to_double()) } else { Int(-i) }
    Real(r) => Real(-r)
    _ => Null
  }
}

///|
fn cmp_result(op : BinOp, c : Int) -> Bool {
  match op {
    Eq => c == 0
    Ne => c != 0
    Lt => c < 0
    Le => c <= 0
    Gt => c > 0
    Ge => c >= 0
    _ => false
  }
}

///|
pub fn eval(e : BExpr, row : Array[Value]) -> Value raise SqlError {
  match e {
    BConst(v) => v
    BCol(i, _, _) => row[i]
    BSlot(i) => row[i]
    BOuter(d, i, _, _) => outer_rows[outer_rows.length() - d][i]
    BSubq(p) => {
      let rows = run_subplan(p, row)
      if rows.length() == 0 {
        Null
      } else {
        rows[0][0]
      }
    }
    BExists(p, neg) => bool_value((run_subplan(p, row).length() > 0) != neg)
    BInSub(x, p, neg, aff, coll) => {
      let v = eval(x, row)
      let rows = run_subplan(p, row)
      if rows.length() == 0 {
        return bool_value(neg)
      }
      if v is Null {
        return Null
      }
      if !p.correlated {
        let keys = match p.keys {
          Some(k) => k
          None => {
            let k : Set[String] = Set([])
            for r in rows {
              if r[0] is Null {
                p.has_null = true
              } else {
                k.add(cmp_key(r[0], aff, coll))
              }
            }
            p.keys = Some(k)
            k
          }
        }
        return if keys.contains(cmp_key(v, aff, coll)) {
          bool_value(!neg)
        } else if p.has_null {
          Null
        } else {
          bool_value(neg)
        }
      }
      let mut saw_null = false
      for r in rows {
        match compare_with_affinity(v, r[0], aff, coll) {
          Some(0) => return bool_value(!neg)
          None => saw_null = true
          _ => ()
        }
      }
      if saw_null {
        Null
      } else {
        bool_value(neg)
      }
    }
    BCollate(x, _) => eval(x, row)
    BCast(x, aff) => cast_value(eval(x, row), aff)
    BUnary(op, x) => {
      let v = eval(x, row)
      match op {
        Neg => negate(v)
        Pos => v
        Not =>
          match v.truth() {
            None => Null
            Some(t) => bool_value(!t)
          }
        BitNot =>
          match v {
            Null => Null
            _ => Int(v.to_int64_cast().lnot())
          }
      }
    }
    BArith(op, l, r) => {
      let a = eval(l, row)
      let b = eval(r, row)
      match op {
        Add | Sub | Mul | Div | Mod => arith(op, a, b)
        Concat => concat_values(a, b)
        BitAnd | BitOr | Shl | Shr => bit_op(op, a, b)
        _ => Null
      }
    }
    BCmp(op, l, r, aff, coll) => {
      let a = eval(l, row)
      let b = eval(r, row)
      match op {
        Is | IsNot => {
          let same = match (a, b) {
            (Null, Null) => true
            (Null, _) | (_, Null) => false
            _ => compare_with_affinity(a, b, aff, coll) == Some(0)
          }
          bool_value(if op is Is { same } else { !same })
        }
        _ =>
          match compare_with_affinity(a, b, aff, coll) {
            None => Null
            Some(c) => bool_value(cmp_result(op, c))
          }
      }
    }
    BAnd(l, r) => {
      let a = eval(l, row).truth()
      if a == Some(false) {
        return Int(0L)
      }
      let b = eval(r, row).truth()
      match (a, b) {
        (_, Some(false)) => Int(0L)
        (Some(true), Some(true)) => Int(1L)
        _ => Null
      }
    }
    BOr(l, r) => {
      let a = eval(l, row).truth()
      if a == Some(true) {
        return Int(1L)
      }
      let b = eval(r, row).truth()
      match (a, b) {
        (_, Some(true)) => Int(1L)
        (Some(false), Some(false)) => Int(0L)
        _ => Null
      }
    }
    BIsNull(x, neg) => {
      let v = eval(x, row)
      bool_value(v.is_null() != neg)
    }
    BInList(x, items, neg, aff, coll) => {
      let v = eval(x, row)
      if items.length() == 0 {
        return bool_value(neg)
      }
      if v is Null {
        return Null
      }
      let mut saw_null = false
      for item in items {
        let w = eval(item, row)
        match compare_with_affinity(v, w, aff, coll) {
          Some(0) => return bool_value(!neg)
          None => saw_null = true
          _ => ()
        }
      }
      if saw_null {
        Null
      } else {
        bool_value(neg)
      }
    }
    BCase(base, arms, els) => {
      match base {
        Some(b) => {
          let v = eval(b, row)
          for arm in arms {
            let c = eval(arm.0, row)
            if compare_with_affinity(v, c, arm.2, arm.3) == Some(0) {
              return eval(arm.1, row)
            }
          }
        }
        None =>
          for arm in arms {
            if eval(arm.0, row).truth() == Some(true) {
              return eval(arm.1, row)
            }
          }
      }
      match els {
        Some(x) => eval(x, row)
        None => Null
      }
    }
    BFunc(_, f, args) => {
      let vals = args.map(a => eval(a, row))
      f(vals)
    }
    BCoalesce(args) => {
      for a in args {
        let v = eval(a, row)
        if !(v is Null) {
          return v
        }
      }
      Null
    }
    BIif(c, t, f) =>
      if eval(c, row).truth() == Some(true) {
        eval(t, row)
      } else {
        match f {
          Some(x) => eval(x, row)
          None => Null
        }
      }
    BMinMax(is_max, args, coll) => {
      let vals = args.map(a => eval(a, row))
      let mut best = vals[0]
      for v in vals {
        if v is Null {
          return Null
        }
      }
      for i in 1..<vals.length() {
        let c = compare_values_coll(best, vals[i], coll)
        if (is_max && c < 0) || (!is_max && c >= 0) {
          best = vals[i]
        }
      }
      best
    }
    BNullIf(l, r, aff, coll) => {
      let a = eval(l, row)
      let b = eval(r, row)
      if compare_with_affinity(a, b, aff, coll) == Some(0) {
        Null
      } else {
        a
      }
    }
  }
}

///|
/// CAST(v AS type) where the type has affinity `aff`.
pub fn cast_value(v : Value, aff : Affinity) -> Value {
  if v is Null {
    return Null
  }
  match aff {
    AffText => Text(v.to_text())
    AffNone =>
      match v {
        Blob(_) => v
        _ => Blob(@utf8.encode(v.to_text()))
      }
    AffInteger => Int(v.to_int64_cast())
    AffReal => Real(v.as_double())
    AffNumeric =>
      match v {
        Int(_) | Real(_) => v
        _ =>
          match v.to_numeric() {
            Real(r) =>
              match real_to_exact_int(r) {
                Some(i) => Int(i)
                None => Real(r)
              }
            n => n
          }
      }
  }
}
