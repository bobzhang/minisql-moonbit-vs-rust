///|
pub(all) struct ScopeTable {
  name : String
  columns : Array[TableColumn]
  offset : Int
  /// Row slot holding the rowid, or -1 if the source has none.
  rowid_slot : Int
  /// Only reachable through a qualified name (upsert's `excluded`).
  qualified_only : Bool
  /// Columns merged into a column to their left by USING/NATURAL: hidden
  /// from unqualified lookup and `*`.
  hidden : Array[Bool]
  /// Expressions coalesced with a column (USING columns of RIGHT/FULL joins).
  partners : Array[Array[BExpr]]
  /// Columns (and, last, the rowid) referenced by bound expressions.
  used : Array[Bool]
}

///|
fn ScopeTable::new(
  name : String,
  columns : Array[TableColumn],
  offset : Int,
  rowid_slot : Int,
  qualified_only? : Bool = false,
) -> ScopeTable {
  {
    name,
    columns,
    offset,
    rowid_slot,
    qualified_only,
    hidden: Array::make(columns.length(), false),
    partners: Array::makei(columns.length(), _ => []),
    used: Array::make(columns.length() + 1, false),
  }
}

///|
/// A bound reference to column `i` (the rowid if `i` is the column count).
fn ScopeTable::col_ref(self : ScopeTable, i : Int) -> BExpr {
  self.used[i] = true
  if i == self.columns.length() {
    BCol(self.rowid_slot, AffInteger, CBinary)
  } else {
    let c = self.columns[i]
    BCol(self.offset + i, c.affinity, c.coll)
  }
}

///|
/// The expression for column `i` of a scope table, coalesced with its USING
/// partners.
fn ScopeTable::column_expr(self : ScopeTable, i : Int) -> BExpr {
  let base = self.col_ref(i)
  if self.partners[i].length() == 0 {
    base
  } else {
    BCoalesce([base, ..self.partners[i]])
  }
}

///|
pub(all) struct Scope {
  tables : Array[ScopeTable]
  width : Int
  /// Scope of the enclosing query, for correlated references.
  parent : Scope?
  /// Set when this query references columns of an enclosing query.
  corr : Ref[Bool]
}

///|
pub fn Scope::new(
  tables : Array[ScopeTable],
  width : Int,
  parent? : Scope,
  corr? : Ref[Bool],
) -> Scope {
  {
    tables,
    width,
    parent,
    corr: match corr {
      Some(r) => r
      None => { val: false, }
    },
  }
}

///|
pub fn Scope::empty() -> Scope {
  Scope::new([], 0)
}

///|
fn Scope::find_table(self : Scope, name : String) -> ScopeTable? {
  let f = fold_name(name)
  for t in self.tables {
    if fold_name(t.name) == f {
      return Some(t)
    }
  }
  None
}

///|
/// Finds the first visible (non-hidden) column named `name` among `tables`.
fn find_visible(
  tables : Array[ScopeTable],
  name : String,
) -> (ScopeTable, Int)? {
  let f = fold_name(name)
  for st in tables {
    if st.qualified_only {
      continue
    }
    for i, c in st.columns {
      if !st.hidden[i] && fold_name(c.name) == f {
        return Some((st, i))
      }
    }
  }
  None
}

///|
/// Resolves a column in one scope level (no outer scopes).
fn lookup_column(
  scope : Scope,
  tq : String?,
  name : String,
) -> BExpr? raise SqlError {
  let f = fold_name(name)
  match tq {
    Some(t) => {
      guard scope.find_table(t) is Some(st) else { return None }
      for i, c in st.columns {
        if fold_name(c.name) == f {
          return Some(st.col_ref(i))
        }
      }
      if is_rowid_name(f) && st.rowid_slot >= 0 {
        return Some(st.col_ref(st.columns.length()))
      }
      None
    }
    None => {
      let mut found : BExpr? = None
      for st in scope.tables {
        if st.qualified_only {
          continue
        }
        for i, c in st.columns {
          if !st.hidden[i] && fold_name(c.name) == f {
            if found is Some(_) {
              raise err("ambiguous column name: " + name)
            }
            found = Some(st.column_expr(i))
          }
        }
      }
      if found is None && is_rowid_name(f) {
        for st in scope.tables {
          if st.qualified_only {
            continue
          }
          if st.rowid_slot >= 0 {
            if found is Some(_) {
              raise err("ambiguous column name: " + name)
            }
            found = Some(st.col_ref(st.columns.length()))
          }
        }
      }
      found
    }
  }
}

///|
fn to_outer(b : BExpr, depth : Int) -> BExpr {
  match b {
    BCol(i, a, c) => BOuter(depth, i, a, c)
    BCoalesce(xs) => BCoalesce(xs.map(x => to_outer(x, depth)))
    _ => b
  }
}

///|
fn bind_column(
  scope : Scope,
  tq : String?,
  name : String,
  dq : Bool,
) -> BExpr raise SqlError {
  if lookup_column(scope, tq, name) is Some(b) {
    return b
  }
  let mut s = scope
  let mut depth = 0
  while s.parent is Some(p) {
    depth += 1
    if lookup_column(p, tq, name) is Some(b) {
      let mut m = scope
      for _ in 0..<depth {
        m.corr.val = true
        if m.parent is Some(q) {
          m = q
        }
      }
      return to_outer(b, depth)
    }
    s = p
  }
  match tq {
    Some(t) => raise err("no such column: " + t + "." + name)
    None =>
      if dq {
        BConst(Text(name))
      } else {
        raise err("no such column: " + name)
      }
  }
}

///|
fn bind_cmp(op : BinOp, l : BExpr, r : BExpr) -> BExpr raise SqlError {
  BCmp(
    op,
    l,
    r,
    comparison_affinity(l.affinity(), r.affinity()),
    binary_collation(l, r),
  )
}

///|
/// True if the expression references no columns or subqueries.
fn is_constant_expr(e : Expr) -> Bool {
  match e {
    Lit(_) | Param(_) => true
    AggSlot(_)
    | Column(_, _, _)
    | InSelect(_, _, _)
    | Exists(_, _)
    | Subquery(_) => false
    Unary(_, x) | IsNull(x, _) | Cast(x, _) | Collate(x, _) =>
      is_constant_expr(x)
    Binary(_, l, r) => is_constant_expr(l) && is_constant_expr(r)
    Between(x, l, h, _) =>
      is_constant_expr(x) && is_constant_expr(l) && is_constant_expr(h)
    InList(x, items, _) => is_constant_expr(x) && items.all(is_constant_expr)
    Like(_, l, p, esc, _) =>
      is_constant_expr(l) &&
      is_constant_expr(p) &&
      (match esc {
        Some(x) => is_constant_expr(x)
        None => true
      })
    Case(b, whens, els) =>
      (match b {
        Some(x) => is_constant_expr(x)
        None => true
      }) &&
      whens.all(w => is_constant_expr(w.0) && is_constant_expr(w.1)) &&
      (match els {
        Some(x) => is_constant_expr(x)
        None => true
      })
    Func(fc) => fc.over is None && fc.args.all(is_constant_expr)
  }
}

///|
pub fn bind_expr(
  db : Database,
  scope : Scope,
  e : Expr,
) -> BExpr raise SqlError {
  match e {
    Lit(v) => BConst(v)
    Column(tq, name, dq) => bind_column(scope, tq, name, dq)
    Unary(op, x) => BUnary(op, bind_expr(db, scope, x))
    Binary(op, l, r) => {
      let bl = bind_expr(db, scope, l)
      let br = bind_expr(db, scope, r)
      match op {
        And => BAnd(bl, br)
        Or => BOr(bl, br)
        Eq | Ne | Lt | Le | Gt | Ge | Is | IsNot => bind_cmp(op, bl, br)
        _ => BArith(op, bl, br)
      }
    }
    IsNull(x, neg) => BIsNull(bind_expr(db, scope, x), neg)
    Between(x, lo, hi, neg) => {
      let bx = bind_expr(db, scope, x)
      let bl = bind_expr(db, scope, lo)
      let bh = bind_expr(db, scope, hi)
      let both = BAnd(bind_cmp(Ge, bx, bl), bind_cmp(Le, bx, bh))
      if neg {
        BUnary(Not, both)
      } else {
        both
      }
    }
    InList(x, items, neg) => {
      let bx = bind_expr(db, scope, x)
      let bitems = items.map(i => bind_expr(db, scope, i))
      // Like SQLite, `x IN (const)` is rewritten to `x = +const`.
      if items.length() == 1 && is_constant_expr(items[0]) {
        return bind_cmp(if neg { Ne } else { Eq }, bx, BUnary(Pos, bitems[0]))
      }
      let aff = match bx.affinity() {
        Some(a) => a
        None => AffNone
      }
      BInList(
        bx,
        bitems,
        neg,
        aff,
        check_coll(bx.collation().unwrap_or(CBinary)),
      )
    }
    Case(base, whens, els) => {
      let bbase = base.map(b => bind_expr(db, scope, b))
      let arms = whens.map(w => {
        let bw = bind_expr(db, scope, w.0)
        let bt = bind_expr(db, scope, w.1)
        match bbase {
          Some(b) =>
            (
              bw,
              bt,
              comparison_affinity(b.affinity(), bw.affinity()),
              binary_collation(b, bw),
            )
          None => (bw, bt, AffNone, CBinary)
        }
      })
      BCase(bbase, arms, els.map(x => bind_expr(db, scope, x)))
    }
    Cast(x, t) => BCast(bind_expr(db, scope, x), affinity_of_type(t))
    Collate(x, name) => BCollate(bind_expr(db, scope, x), coll_of_name(name))
    Like(op, lhs, pat, esc, neg) => {
      let fname = op.to_lower()
      let args = [pat, lhs]
      if esc is Some(x) {
        args.push(x)
      }
      let call = bind_function(db, scope, fname, args)
      if neg {
        BUnary(Not, call)
      } else {
        call
      }
    }
    AggSlot(k) => BSlot(scope.width + k)
    Func(fc) => {
      if fc.over is None && is_aggregate_call(fc) {
        raise err("misuse of aggregate function " + fc.name + "()")
      }
      if fc.filter is Some(_) {
        raise err("FILTER may not be used with non-aggregate " + fc.name + "()")
      }
      if fc.order_by.length() > 0 {
        raise err(
          "ORDER BY may not be used with non-aggregate " + fc.name + "()",
        )
      }
      if fc.distinct {
        raise err("DISTINCT aggregates must have exactly one argument")
      }
      if fc.over is Some(_) || is_window_only(fc.name.to_lower()) {
        raise err("misuse of window function " + fc.name + "()")
      }
      if fc.star {
        raise err("unsupported use of function " + fc.name + "()")
      }
      bind_function(db, scope, fc.name, fc.args)
    }
    Subquery(sel) => {
      let (plan, c) = db.compile_subplan(scope, sel)
      if c.names.length() != 1 {
        raise err("sub-select returns \{c.names.length()} columns - expected 1")
      }
      BSubq(plan)
    }
    Exists(sel, neg) => BExists(db.compile_subplan(scope, sel).0, neg)
    InSelect(x, sel, neg) => {
      let bx = bind_expr(db, scope, x)
      let (plan, c) = db.compile_subplan(scope, sel)
      if c.names.length() != 1 {
        raise err("sub-select returns \{c.names.length()} columns - expected 1")
      }
      let rhs = c.exprs[0]
      BInSub(
        bx,
        plan,
        neg,
        comparison_affinity(bx.affinity(), rhs.affinity()),
        binary_collation(bx, rhs),
      )
    }
    Param(_) => raise err("unsupported expression")
  }
}

///|
/// Compiles a subquery nested in an expression bound in `scope`.
fn Database::compile_subplan(
  self : Database,
  scope : Scope,
  sel : Select,
) -> (SubPlan, Compiled) raise SqlError {
  let corr : Ref[Bool] = { val: false, }
  let c = self.compile_select(sel, Some(scope), corr)
  let plan : SubPlan = {
    run: c.run,
    correlated: corr.val,
    aff: if c.exprs.length() > 0 {
      c.exprs[0].affinity()
    } else {
      None
    },
    cache: None,
    keys: None,
    has_null: false,
  }
  (plan, c)
}

///|
fn bind_function(
  db : Database,
  scope : Scope,
  name : String,
  args : Array[Expr],
) -> BExpr raise SqlError {
  let lname = name.to_lower()
  let n = args.length()
  let wrong = () => err("wrong number of arguments to function " + name + "()")
  match lname {
    "coalesce" | "ifnull" => {
      if n < 2 || (lname == "ifnull" && n != 2) {
        raise wrong()
      }
      BCoalesce(args.map(a => bind_expr(db, scope, a)))
    }
    "iif" | "if" => {
      if n < 2 || n > 3 {
        raise wrong()
      }
      let b = args.map(a => bind_expr(db, scope, a))
      BIif(b[0], b[1], if n == 3 { Some(b[2]) } else { None })
    }
    "max" | "min" if n >= 2 => {
      let b = args.map(a => bind_expr(db, scope, a))
      let mut coll = CBinary
      for x in b {
        if x.collation() is Some(c) {
          coll = check_coll(c)
          break
        }
      }
      BMinMax(lname == "max", b, coll)
    }
    "nullif" => {
      if n != 2 {
        raise wrong()
      }
      let l = bind_expr(db, scope, args[0])
      let r = bind_expr(db, scope, args[1])
      // nullif() is an ordinary function: no affinity conversion, but it
      // uses the collation of its leftmost argument that has one.
      let coll = match l.collation() {
        Some(c) => c
        None => r.collation().unwrap_or(CBinary)
      }
      BNullIf(l, r, AffNone, check_coll(coll))
    }
    "likelihood" => {
      if n != 2 {
        raise wrong()
      }
      match args[1] {
        Lit(Real(p)) if p >= 0.0 && p <= 1.0 => ()
        _ =>
          raise err(
            "second argument to likelihood() must be a constant between 0.0 and 1.0",
          )
      }
      BFunc(lname, vals => vals[0], [bind_expr(db, scope, args[0])])
    }
    "changes" | "total_changes" | "last_insert_rowid" => {
      if n != 0 {
        raise wrong()
      }
      BFunc(
        lname,
        _ => {
          Int(
            match lname {
              "changes" => db.changes
              "total_changes" => db.total_changes
              _ => db.last_rowid
            },
          )
        },
        [],
      )
    }
    "current_time" | "current_date" | "current_timestamp" if n == 0 => {
      // No clock is available to the engine; the current time is untested.
      let v = match lname {
        "current_time" => "00:00:00"
        "current_date" => "1970-01-01"
        _ => "1970-01-01 00:00:00"
      }
      BFunc(lname, _ => Text(v), [])
    }
    "likely" | "unlikely" => {
      if n != 1 {
        raise wrong()
      }
      // Planner hints: the value passes through but loses affinity and
      // collation.
      BFunc(lname, vals => vals[0], [bind_expr(db, scope, args[0])])
    }
    _ => {
      let sf = lookup_scalar(name, n)
      BFunc(lname, sf.f, args.map(a => bind_expr(db, scope, a)))
    }
  }
}

///|
/// A compiled query: result column names, the bound result expressions of
/// its (first) core, per-column collations, and a runner.
priv struct Compiled {
  names : Array[String]
  exprs : Array[BExpr]
  colls : Array[Coll?]
  run : () -> Array[Array[Value]] raise SqlError
}

///|
/// A compiled FROM item. Rows produced by `run` use absolute slot numbers:
/// they have length `offset + width`, the first `offset` slots being NULL.
priv struct Source {
  tables : Array[ScopeTable]
  offset : Int
  width : Int
  kind : JoinKind?
  /// WHERE terms pushed down to this step (filled in after binding).
  filters : Array[BExpr]
  run : () -> Array[Array[Value]] raise SqlError
  /// The base table of a plain table source.
  table : Table?
  /// A tiny source (a recursive CTE's working row): probe the other side of
  /// a join through an index rather than hashing it.
  small : Bool
}

///|
let no_slot : Int = 1 << 30

///|
/// Lowest and highest row slot an expression reads (no_slot / -1 if none).
fn slot_range(e : BExpr) -> (Int, Int) {
  match e {
    BCol(i, _, _) => (i, i)
    BSlot(_) => (0, no_slot)
    BSubq(p) | BExists(p, _) =>
      if p.correlated {
        (0, no_slot)
      } else {
        (no_slot, -1)
      }
    _ => {
      let mut lo = no_slot
      let mut hi = -1
      if e is BInSub(_, p, _, _, _) && p.correlated {
        lo = 0
        hi = no_slot
      }
      for c in e.children() {
        let (a, b) = slot_range(c)
        if a < lo {
          lo = a
        }
        if b > hi {
          hi = b
        }
      }
      (lo, hi)
    }
  }
}

///|
fn split_and(e : BExpr, out : Array[BExpr]) -> Unit {
  match e {
    BAnd(l, r) => {
      split_and(l, out)
      split_and(r, out)
    }
    _ => out.push(e)
  }
}

///|
fn all_true(conds : Array[BExpr], row : Array[Value]) -> Bool raise SqlError {
  for c in conds {
    if eval(c, row).truth() != Some(true) {
      return false
    }
  }
  true
}

///|
fn padded(offset : Int, extra : Int) -> Array[Value] {
  let row = Array(capacity=offset + extra)
  for _ in 0..<offset {
    row.push(Null)
  }
  row
}

///|
/// Compiles a FROM item placed at slot `offset`. Steps of the top-level join
/// chain are appended to `chain`.
fn Database::compile_from(
  self : Database,
  item : FromItem,
  offset : Int,
  outer : Scope?,
  corr : Ref[Bool],
  chain : Array[Source],
  deferred : Array[Expr],
  order_ctx? : OrderCtx,
) -> Source raise SqlError {
  match item {
    TableRef(name, alias) => {
      if dml_target.val {
        dml_target.val = false
      } else if find_cte(name) is Some(b) {
        return self.cte_source(b, alias, offset, outer, corr, chain)
      }
      let t = match self.find_table(name) {
        Some(t) => t
        None =>
          match self.views.get(fold_name(name)) {
            Some(v) => {
              let f = fold_name(v.name)
              if self.expanding.contains(f) {
                raise err("view " + v.name + " is circularly defined")
              }
              self.expanding.add(f)
              let c = with_cte_env([], () => {
                self.compile_select(v.select, None, { val: false, })
              }) catch {
                e => {
                  self.expanding.remove(f)
                  raise e
                }
              }
              self.expanding.remove(f)
              if v.columns.length() > 0 &&
                v.columns.length() != c.names.length() {
                raise err(
                  "expected \{v.columns.length()} columns for '\{v.name}' but got \{c.names.length()}",
                )
              }
              let names = if v.columns.length() > 0 {
                v.columns
              } else {
                c.names
              }
              return subquery_source(
                c,
                names,
                alias.unwrap_or(v.name),
                offset,
                chain,
                false,
              )
            }
            None =>
              if is_schema_table_name(name) {
                self.schema_table(name)
              } else if fold_name(name) == "sqlite_sequence" &&
                self.sequence_seq > 0 {
                self.sequence_table(name)
              } else {
                raise err("no such table: " + name)
              }
          }
      }
      let entry = table_scope_entry(t, alias.unwrap_or(t.name), offset)
      let width = t.columns.length() + 1
      let filters = []
      // Access path: an index (or rowid) lookup, else an automatic index for
      // a filter `column-expr = outer-expr`, reused across runs of a
      // correlated subquery while the table is unchanged.
      let mut planned = false
      let mut index_plan : IndexPlan? = None
      let mut reverse = false
      let mut limit_n = -1
      let extra : Array[BExpr] = []
      let mut lookup : (BExpr, BExpr, Affinity, Coll)? = None
      let mut index : Map[String, Array[Array[Value]]] = Map([])
      let mut index_version = -1
      let run = () => {
        if !planned {
          planned = true
          let hint = match order_ctx {
            Some(ctx) => ctx.hint
            None => None
          }
          let (p, r, sat) = choose_access(t, filters, offset, entry.used, hint)
          index_plan = p
          reverse = r
          if order_ctx is Some(ctx) {
            ctx.satisfied = sat
            if sat && hint is Some(h) && !ctx.filtered_later {
              limit_n = h.limit
              if h.nonnull is Some(x) {
                extra.push(BIsNull(x, true))
              }
            }
          }
          if index_plan is None && !sat {
            lookup = find_lookup_key(filters, offset, offset + width)
          }
        }
        let out = []
        // Adds a row if it passes `conds`; false once the limit is reached.
        let take = (id : Int64, r : Array[Value], conds : Array[BExpr]) => {
          let row = Array(capacity=width + offset)
          for _ in 0..<offset {
            row.push(Null)
          }
          for v in r {
            row.push(v)
          }
          row.push(Int(id))
          if all_true(conds, row) && all_true(extra, row) {
            out.push(row)
            if limit_n >= 0 && out.length() >= limit_n {
              return false
            }
          }
          true
        }
        if limit_n == 0 {
          return out
        }
        if index_plan is Some(p) {
          let rest = []
          for fi, f in filters {
            if !p.consumed.contains(fi) {
              rest.push(f)
            }
          }
          run_index_plan(t, p, rev=reverse, (id, r) => take(id, r, rest))
          return out
        }
        if lookup is Some((inner, key, aff, coll)) {
          if index_version != t.version {
            index = Map([])
            for id, r in t.rows {
              let row = padded(offset, width)
              for v in r {
                row.push(v)
              }
              row.push(Int(id))
              let v = eval(inner, row)
              if !(v is Null) {
                index.get_or_init(cmp_key(v, aff, coll), () => []).push(row)
              }
            }
            index_version = t.version
          }
          let kv = eval(key, [])
          if kv is Null {
            return out
          }
          if index.get(cmp_key(kv, aff, coll)) is Some(rows) {
            for row in rows {
              if all_true(filters, row) {
                out.push(row)
              }
            }
          }
          return out
        }
        t.rows.scan(None, None, reverse, (id, r) => take(id, r, filters))
        out
      }
      let src : Source = {
        tables: [entry],
        offset,
        width,
        kind: None,
        filters,
        run,
        table: Some(t),
        small: false,
      }
      chain.push(src)
      src
    }
    SubqueryRef(sel, alias) => {
      let sub_corr : Ref[Bool] = { val: false, }
      let c = self.compile_select(sel, outer, sub_corr)
      if sub_corr.val {
        corr.val = true
      }
      subquery_source(
        c,
        c.names,
        alias.unwrap_or(""),
        offset,
        chain,
        sub_corr.val,
      )
    }
    Join(l, r, kind, natural, on, using_cols) => {
      let ls = self.compile_from(l, offset, outer, corr, chain, deferred)
      let rs = self.compile_from(
        r,
        offset + ls.width,
        outer,
        corr,
        [],
        deferred,
      )
      let tables = [..ls.tables, ..rs.tables]
      let width = ls.width + rs.width
      let scope = Scope::new(tables, offset + width, parent?=outer, corr~)
      if natural && (on is Some(_) || using_cols is Some(_)) {
        raise err("a NATURAL join may not have an ON or USING clause")
      }
      let names : Array[String] = match using_cols {
        Some(u) => u
        None =>
          if natural {
            let common = []
            for st in rs.tables {
              for i, c in st.columns {
                if !st.hidden[i] && find_visible(ls.tables, c.name) is Some(_) {
                  common.push(c.name)
                }
              }
            }
            common
          } else {
            []
          }
      }
      let conds = []
      for n in names {
        guard find_visible(ls.tables, n) is Some((lt, li)) &&
          find_visible(rs.tables, n) is Some((rt, ri)) else {
          raise err(
            "cannot join using column " +
            n +
            " - column not present in both tables",
          )
        }
        let rexpr = rt.column_expr(ri)
        // Compare with the affinity and collation of the leftmost column,
        // even when it is coalesced with USING partners.
        let lprim = lt.col_ref(li)
        let rprim = rt.col_ref(ri)
        conds.push(
          BCmp(
            Eq,
            lt.column_expr(li),
            rexpr,
            comparison_affinity(lprim.affinity(), rprim.affinity()),
            binary_collation(lprim, rprim),
          ),
        )
        rt.hidden[ri] = true
        if kind is (Right | Full) {
          lt.partners[li].push(rexpr)
        }
      }
      if on is Some(e) {
        // An inner join's ON may reference tables to its right; it then
        // acts as a WHERE term.
        let bound = try bind_expr(self, scope, e) catch {
          ex =>
            if kind is (Inner | Cross) {
              deferred.push(e)
              None
            } else {
              raise ex
            }
        } noraise {
          b => Some(b)
        }
        if bound is Some(b) {
          split_and(b, conds)
        }
      }
      let lend = offset + ls.width
      let rw = rs.width
      let filters = []
      let mut nl_planned = false
      let mut nl_plan : IndexPlan? = None
      let mut rev_plan : IndexPlan? = None
      let src : Source = {
        tables,
        offset,
        width,
        kind: Some(kind),
        filters,
        run: () => {
          let inner = kind is (Inner | Cross)
          let jconds = if inner { [..conds, ..filters] } else { conds }
          let post = if inner { [] } else { filters }
          // Index nested-loop join: probe an index of the right table with
          // values from each left row.
          if !nl_planned {
            nl_planned = true
            let no_hash = find_hash_key(jconds, lend) is None
            if kind is (Inner | Cross | Left) &&
              rs.table is Some(rt) &&
              (no_hash || ls.small) {
              nl_plan = choose_index_plan(
                rt,
                [..jconds, ..rs.filters],
                lend,
                rs.tables[0].used,
                probe_limit=(0, lend),
                per_row=true,
              )
            }
            // Otherwise probe the left table with each right row.
            if nl_plan is None &&
              kind is (Inner | Cross) &&
              ls.table is Some(lt) &&
              ((no_hash && rs.table is Some(_)) || rs.small) {
              rev_plan = choose_index_plan(
                lt,
                [..jconds, ..ls.filters],
                offset,
                ls.tables[0].used,
                probe_limit=(lend, lend + rw),
                per_row=true,
              )
            }
          }
          if rev_plan is Some(p) && ls.table is Some(lt) {
            let checks = [..jconds, ..ls.filters]
            let rest = []
            for fi, f in checks {
              if !p.consumed.contains(fi) {
                rest.push(f)
              }
            }
            let out = []
            for rrow in (rs.run)() {
              run_index_plan(lt, p, row=rrow, (id, r) => {
                let row = Array(capacity=lend + rw)
                for _ in 0..<offset {
                  row.push(Null)
                }
                for v in r {
                  row.push(v)
                }
                row.push(Int(id))
                for k in lend..<(lend + rw) {
                  row.push(rrow[k])
                }
                if all_true(rest, row) && all_true(post, row) {
                  out.push(row)
                }
                true
              })
            }
            return out
          }
          let lrows = (ls.run)()
          if nl_plan is Some(p) && rs.table is Some(rt) {
            let checks = [..jconds, ..rs.filters]
            let rest = []
            for fi, f in checks {
              if !p.consumed.contains(fi) {
                rest.push(f)
              }
            }
            let out = []
            for lrow in lrows {
              let mut matched = false
              run_index_plan(rt, p, row=lrow, (id, r) => {
                let row = Array(capacity=lend + rw)
                for v in lrow {
                  row.push(v)
                }
                for v in r {
                  row.push(v)
                }
                row.push(Int(id))
                if all_true(rest, row) {
                  matched = true
                  if all_true(post, row) {
                    out.push(row)
                  }
                }
                true
              })
              if !matched && kind is Left {
                let row = lrow.copy()
                for _ in 0..<rw {
                  row.push(Null)
                }
                if all_true(post, row) {
                  out.push(row)
                }
              }
            }
            return out
          }
          let rrows = (rs.run)()
          let out = []
          let rmatched = Array::make(rrows.length(), false)
          let emit = (row : Array[Value]) => {
            if all_true(post, row) {
              out.push(row)
            }
          }
          let combine = (lrow : Array[Value], rrow : Array[Value]) => {
            let row = Array(capacity=lend + rw)
            for v in lrow {
              row.push(v)
            }
            for k in lend..<(lend + rw) {
              row.push(rrow[k])
            }
            row
          }
          let hash = find_hash_key(jconds, lend)
          match hash {
            Some((lk, rk, aff, coll)) => {
              let index : Map[String, Array[Int]] = Map([])
              for j, rrow in rrows {
                let v = eval(rk, rrow)
                if v is Null {
                  continue
                }
                index.get_or_init(cmp_key(v, aff, coll), () => []).push(j)
              }
              for lrow in lrows {
                let mut matched = false
                let v = eval(lk, lrow)
                if !(v is Null) && index.get(cmp_key(v, aff, coll)) is Some(js) {
                  for j in js {
                    let row = combine(lrow, rrows[j])
                    if all_true(jconds, row) {
                      matched = true
                      rmatched[j] = true
                      emit(row)
                    }
                  }
                }
                if !matched && kind is (Left | Full) {
                  let row = lrow.copy()
                  for _ in 0..<rw {
                    row.push(Null)
                  }
                  emit(row)
                }
              }
            }
            None =>
              for lrow in lrows {
                let mut matched = false
                for j, rrow in rrows {
                  let row = combine(lrow, rrow)
                  if all_true(jconds, row) {
                    matched = true
                    rmatched[j] = true
                    emit(row)
                  }
                }
                if !matched && kind is (Left | Full) {
                  let row = lrow.copy()
                  for _ in 0..<rw {
                    row.push(Null)
                  }
                  emit(row)
                }
              }
          }
          if kind is (Right | Full) {
            for j, rrow in rrows {
              if !rmatched[j] {
                emit(rrow)
              }
            }
          }
          out
        },
        table: None,
        small: false,
      }
      chain.push(src)
      src
    }
  }
}

///|
/// A FROM source reading the rows of a compiled query.
fn subquery_source(
  c : Compiled,
  names : Array[String],
  alias : String,
  offset : Int,
  chain : Array[Source],
  correlated : Bool,
  small? : Bool = false,
) -> Source {
  // Duplicate result names are made unique as "name:N".
  let used : Set[String] = Set([])
  let columns = names.mapi((i, n) => {
    let mut name = n
    let mut k = 0
    while !used.add_and_check(fold_name(name)) {
      k += 1
      name = n + ":" + k.to_string()
    }
    simple_column(
      name,
      affinity=c.exprs[i].affinity().unwrap_or(AffNone),
      coll=c.colls[i].unwrap_or(CBinary),
    )
  })
  let entry = ScopeTable::new(alias, columns, offset, -1)
  let filters = []
  let width = columns.length()
  // Rows of an uncorrelated subquery are reused while no table changes,
  // with an automatic index for a filter `column-expr = outer-expr`.
  let mut cache : Array[Array[Value]]? = None
  let mut cache_version = -1
  let mut planned = false
  let mut lookup : (BExpr, BExpr, Affinity, Coll)? = None
  let mut index : Map[String, Array[Array[Value]]]? = None
  let src : Source = {
    tables: [entry],
    offset,
    width,
    kind: None,
    filters,
    run: () => {
      if !planned {
        planned = true
        if !correlated {
          lookup = find_lookup_key(filters, offset, offset + width)
        }
      }
      let rows = match cache {
        Some(rows) if cache_version == data_version.val => rows
        _ => {
          let rows = []
          for r in (c.run)() {
            let row = padded(offset, r.length())
            for v in r {
              row.push(v)
            }
            rows.push(row)
          }
          if !correlated {
            cache = Some(rows)
            cache_version = data_version.val
            index = None
          }
          rows
        }
      }
      if lookup is Some((inner, key, aff, coll)) {
        let idx = match index {
          Some(m) => m
          None => {
            let m : Map[String, Array[Array[Value]]] = Map([])
            for row in rows {
              let v = eval(inner, row)
              if !(v is Null) {
                m.get_or_init(cmp_key(v, aff, coll), () => []).push(row)
              }
            }
            index = Some(m)
            m
          }
        }
        let out = []
        let kv = eval(key, [])
        if kv is Null {
          return out
        }
        if idx.get(cmp_key(kv, aff, coll)) is Some(matches) {
          for row in matches {
            if all_true(filters, row) {
              out.push(row)
            }
          }
        }
        return out
      }
      if filters.length() == 0 {
        return rows.copy()
      }
      let out = []
      for row in rows {
        if all_true(filters, row) {
          out.push(row)
        }
      }
      out
    },
    table: None,
    small,
  }
  chain.push(src)
  src
}

///|
/// Picks an equality term usable as a hash-join key: one side reads only
/// left slots (< lend), the other only right slots.
fn find_hash_key(
  conds : Array[BExpr],
  lend : Int,
) -> (BExpr, BExpr, Affinity, Coll)? {
  for c in conds {
    if c is BCmp(Eq, a, b, aff, coll) {
      let (alo, ahi) = slot_range(a)
      let (blo, bhi) = slot_range(b)
      if ahi < lend && ahi >= 0 && blo >= lend && bhi < no_slot {
        return Some((a, b, aff, coll))
      }
      if bhi < lend && bhi >= 0 && alo >= lend && ahi < no_slot {
        return Some((b, a, aff, coll))
      }
    }
  }
  None
}

///|
fn has_outer(e : BExpr) -> Bool {
  match e {
    BOuter(_, _, _, _) => true
    _ => e.children().any(has_outer)
  }
}

///|
/// Picks an equality filter usable for an automatic index on a table in
/// slots [lo, hi): one side reads only those slots, the other reads no row
/// slots but depends on an enclosing query's row.
fn find_lookup_key(
  filters : Array[BExpr],
  lo : Int,
  hi : Int,
) -> (BExpr, BExpr, Affinity, Coll)? {
  for c in filters {
    if c is BCmp(Eq, a, b, aff, coll) {
      let (alo, ahi) = slot_range(a)
      let (blo, bhi) = slot_range(b)
      if alo >= lo && ahi < hi && bhi == -1 && blo == no_slot && has_outer(b) {
        return Some((a, b, aff, coll))
      }
      if blo >= lo && bhi < hi && ahi == -1 && alo == no_slot && has_outer(a) {
        return Some((b, a, aff, coll))
      }
    }
  }
  None
}

///|
/// Compiles a FROM clause with its WHERE filter; returns the scope and a
/// runner producing the filtered rows.
fn Database::compile_source(
  self : Database,
  from : FromItem?,
  where_ : Expr?,
  outer : Scope?,
  corr : Ref[Bool],
  order_ctx? : OrderCtx,
) -> (Scope, () -> Array[Array[Value]] raise SqlError) raise SqlError {
  match from {
    None => {
      let scope = Scope::new([], 0, parent?=outer, corr~)
      let w = where_.map(x => bind_expr(self, scope, x))
      (
        scope,
        () => {
          match w {
            Some(x) => if eval(x, []).truth() == Some(true) { [[]] } else { [] }
            None => [[]]
          }
        },
      )
    }
    Some(item) => {
      let chain : Array[Source] = []
      let deferred = []
      let src = match item {
        TableRef(_, _) =>
          self.compile_from(item, 0, outer, corr, chain, deferred, order_ctx?)
        _ => self.compile_from(item, 0, outer, corr, chain, deferred)
      }
      let scope = Scope::new(src.tables, src.width, parent?=outer, corr~)
      let rest = []
      let terms = []
      for e in deferred {
        split_and(bind_expr(self, scope, e), terms)
      }
      if where_ is Some(w) {
        split_and(bind_expr(self, scope, w), terms)
      }
      if terms.length() > 0 {
        for term in terms {
          let (_, hi) = slot_range(term)
          let mut target = -1
          if hi < no_slot {
            for k, st in chain {
              if st.offset + st.width > hi {
                target = k
                break
              }
            }
            for j in (target + 1)..<chain.length() {
              if chain[j].kind is Some(Right | Full) {
                target = -1
              }
            }
          }
          if target >= 0 {
            chain[target].filters.push(term)
          } else {
            rest.push(term)
          }
        }
      }
      if order_ctx is Some(ctx) {
        ctx.filtered_later = rest.length() > 0
      }
      (
        scope,
        () => {
          let rows = (src.run)()
          if rest.length() == 0 {
            return rows
          }
          let out = []
          for r in rows {
            if all_true(rest, r) {
              out.push(r)
            }
          }
          out
        },
      )
    }
  }
}

///|
fn simple_column(
  name : String,
  affinity? : Affinity = AffNone,
  coll? : Coll = CBinary,
) -> TableColumn {
  {
    name,
    type_name: "",
    affinity,
    coll,
    def: {
      name,
      type_name: "",
      primary_key: false,
      pk_desc: false,
      autoincrement: false,
      not_null: false,
      unique: false,
      default: None,
      checks: [],
      collate: None,
      pk_conflict: None,
      nn_conflict: None,
      unique_conflict: None,
    },
  }
}

///|
fn Database::run_select(
  self : Database,
  sel : Select,
) -> QueryResult raise SqlError {
  let c = self.compile_select(sel, None, { val: false, })
  { columns: c.names, rows: (c.run)(), }
}

///|
fn Database::compile_select(
  self : Database,
  sel : Select,
  outer : Scope?,
  corr : Ref[Bool],
) -> Compiled raise SqlError {
  if sel.with_.length() > 0 {
    let env = make_cte_env(sel.with_)
    return with_cte_env(env, () => {
      self.compile_select({ ..sel, with_: [], }, outer, corr)
    })
  }
  if sel.rest.length() == 0 {
    return self.compile_core(
      sel.first,
      sel.order_by,
      sel.limit,
      sel.offset,
      outer,
      corr,
    )
  }
  let parts = [self.compile_core(sel.first, [], None, None, outer, corr)]
  for r in sel.rest {
    let p = self.compile_core(r.1, [], None, None, outer, corr)
    if p.names.length() != parts[0].names.length() {
      let opname = match r.0 {
        Union => "UNION"
        UnionAll => "UNION ALL"
        Intersect => "INTERSECT"
        Except => "EXCEPT"
      }
      raise err(
        "SELECTs to the left and right of " +
        opname +
        " do not have the same number of result columns",
      )
    }
    parts.push(p)
  }
  let ncols = parts[0].names.length()
  // Column collations: the leftmost SELECT (up to each step) with one.
  let step_colls = parts.mapi((k, _) => {
    Array::makei(ncols, i => {
      let mut c : Coll? = None
      for j in 0..<=k {
        if parts[j].colls[i] is Some(x) {
          c = Some(x)
          break
        }
      }
      c
    })
  })
  let final_colls = step_colls[parts.length() - 1]
  let order = sel.order_by.mapi((k, t) => {
    compound_order_term(parts, final_colls, k, t.expr)
  })
  let ops = sel.rest.map(r => r.0)
  let limit = sel.limit
  let offset = sel.offset
  {
    names: parts[0].names,
    exprs: parts[0].exprs,
    colls: final_colls,
    run: () => {
      let mut acc = (parts[0].run)()
      for k, op in ops {
        let right = (parts[k + 1].run)()
        let colls = step_colls[k + 1].map(c => c.unwrap_or(CBinary))
        acc = combine_compound(op, acc, right, colls)
      }
      let keys = acc.map(r => order.map(o => r[o.0]))
      self.finish(
        acc,
        keys,
        order.map(o => o.1),
        sel.order_by,
        false,
        [],
        limit,
        offset,
      )
    },
  }
}

///|
/// Resolves a compound ORDER BY term to a result column and collation.
fn compound_order_term(
  parts : Array[Compiled],
  colls : Array[Coll?],
  k : Int,
  e : Expr,
) -> (Int, Coll) raise SqlError {
  let n = parts[0].names.length()
  match e {
    Collate(inner, name) => {
      let (i, _) = compound_order_term(parts, colls, k, inner)
      return (i, check_coll(coll_of_name(name)))
    }
    Lit(Int(v)) => {
      if v < 1L || v > n.to_int64() {
        raise err(
          "\{k + 1}\{ordinal_suffix(k + 1)} ORDER BY term out of range - should be between 1 and \{n}",
        )
      }
      let i = v.to_int() - 1
      return (i, colls[i].unwrap_or(CBinary))
    }
    Column(_, name, _) => {
      let f = fold_name(name)
      for p in parts {
        for i, nm in p.names {
          if fold_name(nm) == f {
            return (i, colls[i].unwrap_or(CBinary))
          }
        }
      }
    }
    _ => ()
  }
  raise err(
    "\{k + 1}\{ordinal_suffix(k + 1)} ORDER BY term does not match any column in the result set",
  )
}

///|
fn row_key(row : Array[Value], colls : Array[Coll]) -> String {
  let sb = StringBuilder()
  for i, v in row {
    write_value_key(sb, v, colls[i])
  }
  sb.to_string()
}

///|
/// Combines two compound operands. Distinct results come out sorted, as
/// SQLite reads them back from a temporary index.
fn combine_compound(
  op : CompoundOp,
  left : Array[Array[Value]],
  right : Array[Array[Value]],
  colls : Array[Coll],
) -> Array[Array[Value]] {
  let m : Map[String, Array[Value]] = Map([])
  match op {
    UnionAll => return [..left, ..right]
    Union => {
      for r in left {
        m[row_key(r, colls)] = r
      }
      for r in right {
        m[row_key(r, colls)] = r
      }
    }
    Intersect => {
      let rk : Set[String] = Set([])
      for r in right {
        rk.add(row_key(r, colls))
      }
      for r in left {
        let k = row_key(r, colls)
        if rk.contains(k) {
          m[k] = r
        }
      }
    }
    Except => {
      for r in left {
        m[row_key(r, colls)] = r
      }
      for r in right {
        m.remove(row_key(r, colls))
      }
    }
  }
  let out = m.values().to_array()
  out.sort_by((a, b) => {
    for i, c in colls {
      let x = compare_values_coll(a[i], b[i], c)
      if x != 0 {
        return x
      }
    }
    0
  })
  out
}

///|
fn Database::compile_core(
  self : Database,
  core : SelectCore,
  order_by : Array[OrderTerm],
  limit : Expr?,
  offset : Expr?,
  outer : Scope?,
  corr : Ref[Bool],
) -> Compiled raise SqlError {
  match core {
    Values(rows) => {
      let scope = Scope::new([], 0, parent?=outer, corr~)
      let bound = rows.map(r => r.map(e => bind_expr(self, scope, e)))
      let ncols = if rows.length() > 0 { rows[0].length() } else { 0 }
      let names = Array::makei(ncols, i => "column" + (i + 1).to_string())
      {
        names,
        exprs: bound[0],
        colls: Array::make(ncols, None),
        run: () => {
          let out = bound.map(r => r.map(e => eval(e, [])))
          self.finish(out, [], [], [], false, [], limit, offset)
        },
      }
    }
    Simple(s) => self.compile_simple(s, order_by, limit, offset, outer, corr)
  }
}

///|
fn Database::eval_limit(self : Database, e : Expr) -> Int64 raise SqlError {
  let b = bind_expr(self, Scope::empty(), e)
  match eval(b, []).apply_affinity(AffNumeric) {
    Int(i) => i
    _ => raise err("datatype mismatch")
  }
}

///|
/// Applies DISTINCT, ORDER BY and LIMIT/OFFSET to computed result rows.
/// `keys[i]` holds the ORDER BY key values of `out[i]`, sorted under
/// `terms` with collations `ocolls`.
fn Database::finish(
  self : Database,
  out : Array[Array[Value]],
  keys : Array[Array[Value]],
  ocolls : Array[Coll],
  terms : Array[OrderTerm],
  distinct : Bool,
  dcolls : Array[Coll],
  limit_e : Expr?,
  offset_e : Expr?,
) -> Array[Array[Value]] raise SqlError {
  let mut limit = -1L
  let mut offset = 0L
  if limit_e is Some(l) {
    limit = self.eval_limit(l)
  }
  if offset_e is Some(o) {
    offset = self.eval_limit(o)
    if offset < 0L {
      offset = 0L
    }
  }
  let mut idx = Array::makei(out.length(), i => i)
  if distinct {
    let seen : Set[String] = Set([])
    idx = idx.filter(i => seen.add_and_check(row_key(out[i], dcolls)))
  }
  if ocolls.length() > 0 {
    idx.sort_by((a, b) => {
      let c = compare_order_keys(terms, ocolls, keys[a], keys[b])
      if c != 0 {
        c
      } else {
        a - b
      }
    })
  }
  let start = if offset > idx.length().to_int64() {
    idx.length()
  } else {
    offset.to_int()
  }
  let mut end = idx.length()
  if limit >= 0L && limit < (end - start).to_int64() {
    end = start + limit.to_int()
  }
  let rows = []
  for i in start..<end {
    rows.push(out[idx[i]])
  }
  rows
}

///|
/// Compares two ORDER BY key tuples under the given terms and collations.
fn compare_order_keys(
  terms : Array[OrderTerm],
  colls : Array[Coll],
  xs : Array[Value],
  ys : Array[Value],
) -> Int {
  for k, t in terms {
    let x = xs[k]
    let y = ys[k]
    let nulls_first = t.nulls_first.unwrap_or(!t.desc)
    let c = match (x, y) {
      (Null, Null) => 0
      (Null, _) => if nulls_first { -1 } else { 1 }
      (_, Null) => if nulls_first { 1 } else { -1 }
      _ => {
        let c = compare_values_coll(x, y, colls[k])
        if t.desc {
          -c
        } else {
          c
        }
      }
    }
    if c != 0 {
      return c
    }
  }
  0
}

///|
/// Expands and binds result columns, returning expressions and names.
fn Database::bind_result_columns(
  self : Database,
  scope : Scope,
  columns : Array[ResultCol],
) -> (Array[BExpr], Array[String]) raise SqlError {
  let exprs : Array[BExpr] = []
  let names : Array[String] = []
  for rc in columns {
    match rc {
      Star => {
        if scope.tables.length() == 0 {
          raise err("no tables specified")
        }
        let seen : Set[String] = Set([])
        for st in scope.tables {
          if st.name != "" && !seen.add_and_check(fold_name(st.name)) {
            raise err("ambiguous column name: " + st.name + ".*")
          }
        }
        for st in scope.tables {
          if st.qualified_only {
            continue
          }
          for i, c in st.columns {
            if !st.hidden[i] {
              exprs.push(st.column_expr(i))
              names.push(c.name)
            }
          }
        }
      }
      TableStar(tn) => {
        guard scope.find_table(tn) is Some(st) else {
          raise err("no such table: " + tn)
        }
        for i, c in st.columns {
          exprs.push(st.col_ref(i))
          names.push(c.name)
        }
      }
      ExprCol(e, alias) => {
        exprs.push(bind_expr(self, scope, e))
        names.push(
          match alias {
            Some(a) => a
            None =>
              match e {
                Column(_, n, _) => n
                _ => "?"
              }
          },
        )
      }
    }
  }
  (exprs, names)
}

///|
fn Database::compile_simple(
  self : Database,
  core : SimpleSelect,
  order_by : Array[OrderTerm],
  limit : Expr?,
  offset : Expr?,
  outer : Scope?,
  corr : Ref[Bool],
) -> Compiled raise SqlError {
  let order_ctx : OrderCtx = {
    hint: None,
    satisfied: false,
    filtered_later: false,
  }
  let (scope, produce) = self.compile_source(
    core.from,
    core.where_,
    outer,
    corr,
    order_ctx~,
  )
  // Named windows are replaced by their definitions.
  let core = {
    ..core,
    columns: core.columns.map(rc => {
      match rc {
        ExprCol(e, a) => ExprCol(resolve_windows(e, core.windows), a)
        _ => rc
      }
    }),
  }
  let order_by = order_by.map(t => {
    ..t,
    expr: resolve_windows(t.expr, core.windows),
  })
  // Pull aggregate calls out of the result columns, HAVING and ORDER BY.
  let aggs : Array[FuncCall] = []
  let columns = core.columns.map(rc => {
    match rc {
      ExprCol(e, alias) => ExprCol(extract_aggregates(e, aggs, db=self), alias)
      _ => rc
    }
  })
  let having = match core.having {
    Some(h) =>
      Some(
        extract_aggregates(
          substitute_aliases(h, scope, core.columns),
          aggs,
          db=self,
        ),
      )
    None => None
  }
  let order_exprs = order_by.map(t => extract_aggregates(t.expr, aggs, db=self))
  // Then window function calls.
  let wins : Array[FuncCall] = []
  let columns = columns.map(rc => {
    match rc {
      ExprCol(e, a) => ExprCol(extract_windows(e, wins, aggs.length()), a)
      _ => rc
    }
  })
  let order_exprs = order_exprs.map(e => extract_windows(e, wins, aggs.length()))
  if core.group_by.length() > 0 || aggs.length() > 0 {
    return self.compile_aggregate(
      core, order_by, limit, offset, scope, produce, columns, having, order_exprs,
      aggs, order_ctx, wins,
    )
  }
  if having is Some(_) {
    raise err("HAVING clause on a non-aggregate query")
  }
  let (exprs, names) = self.bind_result_columns(scope, columns)
  let order = order_exprs.mapi((k, e) => {
    bind_order_term(self, scope, columns, exprs, k, e)
  })
  let wgroups = self.compile_windows(scope, wins, scope.width)
  let ocolls = order.map(o => check_coll(o.collation().unwrap_or(CBinary)))
  let dcolls = if core.distinct {
    exprs.map(x => check_coll(x.collation().unwrap_or(CBinary)))
  } else {
    []
  }
  if wgroups.length() > 0 {
    ()
  } else if order.length() > 0 {
    order_ctx.hint = Some({
      terms: order.mapi((k, o) => {
        (o, order_by[k].desc, order_by[k].nulls_first, ocolls[k])
      }),
      kind: 0,
      ncols: exprs.length(),
      has_limit: limit is Some(_),
      limit: if core.distinct {
        -1
      } else {
        constant_limit(limit, offset)
      },
      nonnull: None,
    })
  } else if core.distinct {
    order_ctx.hint = Some({
      terms: exprs.mapi((k, x) => (x, false, None, dcolls[k])),
      kind: 2,
      ncols: exprs.length(),
      has_limit: limit is Some(_),
      limit: -1,
      nonnull: None,
    })
  }
  {
    names,
    exprs,
    colls: exprs.map(x => x.collation()),
    run: () => {
      let out : Array[Array[Value]] = []
      let keys : Array[Array[Value]] = []
      let rows = if wgroups.length() > 0 {
        run_windows(wgroups, produce(), scope.width, wins.length())
      } else {
        produce()
      }
      for row in rows {
        out.push(exprs.map(x => eval(x, row)))
        if order.length() > 0 {
          keys.push(order.map(o => eval(o, row)))
        }
      }
      self.finish(
        out,
        keys,
        ocolls,
        order_by,
        core.distinct,
        dcolls,
        limit,
        offset,
      )
    },
  }
}

///|
fn ordinal_suffix(n : Int) -> String {
  if n % 100 >= 11 && n % 100 <= 13 {
    "th"
  } else {
    match n % 10 {
      1 => "st"
      2 => "nd"
      3 => "rd"
      _ => "th"
    }
  }
}

///|
/// Binds an ORDER BY term: an integer constant selects a result column,
/// a bare identifier matching a result alias refers to that column,
/// anything else is an expression over the FROM scope.
fn bind_order_term(
  db : Database,
  scope : Scope,
  columns : Array[ResultCol],
  exprs : Array[BExpr],
  k : Int,
  e : Expr,
) -> BExpr raise SqlError {
  match e {
    Collate(inner, name) =>
      return BCollate(
        bind_order_term(db, scope, columns, exprs, k, inner),
        coll_of_name(name),
      )
    Lit(Int(n)) => {
      if n < 1L || n > exprs.length().to_int64() {
        raise err(
          "\{k + 1}\{ordinal_suffix(k + 1)} ORDER BY term out of range - should be between 1 and \{exprs.length()}",
        )
      }
      return exprs[n.to_int() - 1]
    }
    Column(None, name, _) => {
      let f = fold_name(name)
      // Only explicit aliases take precedence over FROM columns.
      let mut pos = 0
      for rc in columns {
        match rc {
          ExprCol(_, Some(alias)) => {
            if fold_name(alias) == f {
              return exprs[pos]
            }
            pos += 1
          }
          ExprCol(_, None) => pos += 1
          _ => return bind_expr(db, scope, e)
        }
      }
    }
    _ => ()
  }
  bind_expr(db, scope, e)
}

///|
/// LIMIT plus OFFSET when both are integer literals, else -1.
fn constant_limit(limit : Expr?, offset : Expr?) -> Int {
  let lim = match limit {
    Some(Lit(Int(n))) if n >= 0L && n < 1000000000L => n.to_int()
    _ => return -1
  }
  match offset {
    None => lim
    Some(Lit(Int(m))) if m >= 0L && m < 1000000000L => lim + m.to_int()
    _ => -1
  }
}
