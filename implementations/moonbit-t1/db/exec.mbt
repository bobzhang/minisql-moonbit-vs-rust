// ---------------------------------------------------------------------------
// Name resolution
// ---------------------------------------------------------------------------

///|
priv struct Source {
  name : String // as_name or table name
  cols : Array[ColumnDef]
  offset : Int // slot of the first column; rowid at offset + ncols
  hidden : Bool // only reachable with a table qualifier (upsert "excluded")
  table : Table? // base table
  sub : QPlan? // subquery in FROM
  join : JoinKind
  mut on : Expr?
  /// Columns merged into an earlier table by USING/NATURAL: not visible to
  /// unqualified names or `*`.
  hide : Array[Bool]
  /// Replacement for unqualified references (RIGHT/FULL USING columns).
  over : Array[Expr?]
  /// Columns referenced by the query.
  used : Array[Bool]
  /// The source is a view (its rows depend only on table contents).
  mut view : Bool
  /// The recursive reference of a recursive CTE: rows come from here.
  mut rec : Ref[Array[Array[Value]]]?
}

///|
fn table_source(
  name : String,
  t : Table,
  offset : Int,
  hidden : Bool,
) -> Source {
  new_source(name, t.cols, offset, hidden, Some(t), None, JInner)
}

///|
fn new_source(
  name : String,
  cols : Array[ColumnDef],
  offset : Int,
  hidden : Bool,
  table : Table?,
  sub : QPlan?,
  join : JoinKind,
) -> Source {
  {
    name,
    cols,
    offset,
    hidden,
    table,
    sub,
    join,
    on: None,
    hide: Array::make(cols.length(), false),
    over: Array::make(cols.length(), None),
    used: Array::make(cols.length(), false),
    view: false,
    rec: None,
  }
}

///|
fn Source::col_index(self : Source, name : String) -> Int? {
  col_index_in(self.cols, name)
}

///|
fn Source::col_expr(self : Source, i : Int) -> Expr {
  self.used[i] = true
  let cd = self.cols[i]
  Slot(self.offset + i, cd.affinity, col_coll(cd))
}

///|
priv struct Scope {
  sources : Array[Source]
  /// Result-column aliases usable as a fallback (ORDER BY).
  aliases : Array[(String, Expr)]
  /// Where aggregate calls are collected (None: aggregates not allowed).
  agg : AggCtx?
  /// Scope of the enclosing query (for correlated references).
  outer : Scope?
  /// Nesting depth of the query; outer references use level differences.
  level : Int
  /// Set when the query refers to an enclosing query's row.
  corr : Ref[Bool]
  /// Set (to the function name) when an aggregate of an enclosing query is
  /// used in this WHERE clause.
  wflag : Ref[String]?
  /// Where window function calls are collected (None: not allowed).
  win : WinCtx?
}

///|
fn simple_scope(sources : Array[Source]) -> Scope {
  {
    sources,
    aliases: [],
    agg: None,
    outer: None,
    level: 0,
    corr: { val: false, },
    wflag: None,
    win: None,
  }
}

///|
/// Active aggregate-argument trackers: (owner level, innermost level referenced).
let agg_trackers : Array[(Int, Ref[Int])] = []

///|
fn is_rowid_name(n : String) -> Bool {
  let l = n.to_lower()
  l == "rowid" || l == "oid" || l == "_rowid_"
}

///|
/// Look a column up among this query's own sources.
fn Scope::resolve_local(
  self : Scope,
  tbl : String?,
  name : String,
) -> Expr? raise SqlError {
  match tbl {
    Some(t) => {
      for k, s in self.sources {
        if same_name(s.name, t) {
          for k2 in (k + 1)..<self.sources.length() {
            if same_name(self.sources[k2].name, t) {
              raise sql_err("ambiguous column name: \{t}.\{name}")
            }
          }
          match s.col_index(name) {
            Some(i) => return Some(s.col_expr(i))
            None =>
              if is_rowid_name(name) && s.table is Some(_) {
                return Some(
                  Slot(s.offset + s.cols.length(), AffInteger, CBinary),
                )
              }
          }
          return None
        }
      }
      None
    }
    None => {
      let mut found : Expr? = None
      for s in self.sources {
        if s.hidden {
          continue
        }
        match s.col_index(name) {
          Some(i) if !s.hide[i] => {
            if found is Some(_) {
              raise sql_err("ambiguous column name: \{name}")
            }
            found = Some(
              match s.over[i] {
                Some(e) => e
                None => s.col_expr(i)
              },
            )
          }
          _ => ()
        }
      }
      if found is Some(_) {
        return found
      }
      let visible = self.sources.filter(s => !s.hidden)
      if is_rowid_name(name) &&
        visible.length() == 1 &&
        visible[0].table is Some(_) {
        let s = visible[0]
        return Some(Slot(s.offset + s.cols.length(), AffInteger, CBinary))
      }
      None
    }
  }
}

///|
/// Record that a column of the query at `level` was referenced.
fn note_ref(level : Int) -> Unit {
  for t in agg_trackers {
    if level <= t.0 && level > t.1.val {
      t.1.val = level
    }
  }
}

///|
/// Mark the queries between this scope and `level` as correlated.
fn Scope::mark_corr(self : Scope, level : Int) -> Unit {
  let mut cur : Scope? = Some(self)
  while cur is Some(c) && c.level > level {
    c.corr.val = true
    cur = c.outer
  }
}

///|
fn Scope::resolve(
  self : Scope,
  tbl : String?,
  name : String,
  dq : Bool,
) -> Expr raise SqlError {
  match self.resolve_local(tbl, name) {
    Some(e) => {
      note_ref(self.level)
      return e
    }
    None => ()
  }
  if tbl is None {
    for a in self.aliases {
      if same_name(a.0, name) {
        if self.wflag is Some(_) && contains_agg(a.1) {
          raise sql_err("misuse of aggregate: \{name}")
        }
        if self.win is None && contains_win(a.1) {
          raise sql_err("misuse of aliased window function \{name}")
        }
        return a.1
      }
    }
  }
  let mut cur = self.outer
  while cur is Some(sc) {
    match sc.resolve_local(tbl, name) {
      Some(e) => {
        note_ref(sc.level)
        self.mark_corr(sc.level)
        return Outer(self.level - sc.level, e)
      }
      None => ()
    }
    cur = sc.outer
  }
  match tbl {
    Some(t) => raise sql_err("no such column: \{t}.\{name}")
    None =>
      if dq {
        Lit(Text(name))
      } else {
        raise sql_err("no such column: \{name}")
      }
  }
}

///|
fn col_coll(c : ColumnDef) -> Coll {
  match c.collate {
    Some(n) => coll_of_name(n) catch { _ => CBinary }
    None => CBinary
  }
}

///|
fn is_constant_expr(e : Expr) -> Bool {
  match e {
    Slot(_, _, _) | Column(..) | Outer(_, _) => false
    SubQ(_)
    | ExistsQ(_)
    | InQ(_, _, _)
    | SubScalar(_)
    | SubExists(_)
    | SubIn(_, _, _, _) => false
    _ => expr_children(e).all(is_constant_expr)
  }
}

///|
fn Scope::bind(self : Scope, e : Expr) -> Expr raise SqlError {
  match e {
    Lit(_)
    | BigIntLit
    | Slot(_, _, _)
    | AggRef(_)
    | Outer(_, _)
    | SubScalar(_)
    | SubExists(_)
    | SubIn(_, _, _, _)
    | WinRef(_, _) => e
    WinCall(w) => self.bind_window(w)
    SubQ(q) => SubScalar(self.bind_subquery(q, true))
    ExistsQ(q) => SubExists(self.bind_subquery(q, false))
    InQ(x, q, neg) => {
      let bx = self.bind(x)
      let sp = self.bind_subquery(q, true)
      SubIn(bx, sp, neg, cmp_info_col(bx, sp.info))
    }
    Column(tbl~, name~, dq~) => self.resolve(tbl, name, dq)
    Unary(op, x) => Unary(op, self.bind(x))
    Binary(op, l, r) | Cmp(op, l, r, _) => {
      let bl = self.bind(l)
      let br = self.bind(r)
      if is_cmp_op(op) {
        Cmp(op, bl, br, cmp_info(bl, br))
      } else {
        Binary(op, bl, br)
      }
    }
    IsNull(x, n) => IsNull(self.bind(x), n)
    Collate(x, c) => Collate(self.bind(x), c)
    Cast(x, a) => Cast(self.bind(x), a)
    Between(x, lo, hi, neg, _, _) => {
      let bx = self.bind(x)
      let blo = self.bind(lo)
      let bhi = self.bind(hi)
      Between(bx, blo, bhi, neg, cmp_info(bx, blo), cmp_info(bx, bhi))
    }
    InList(x, items, neg, _) => {
      let bx = self.bind(x)
      let bitems : Array[Expr] = []
      for it in items {
        bitems.push(self.bind(it))
      }
      // like SQLite, "x IN (constant)" becomes "x = +constant"
      if bitems.length() == 1 && is_constant_expr(bitems[0]) {
        let rhs = Unary(Pos, bitems[0])
        let eq = Cmp(Eq, bx, rhs, cmp_info(bx, rhs))
        return if neg { Unary(Not, eq) } else { eq }
      }
      InList(bx, bitems, neg, {
        aff: expr_affinity(bx),
        coll: expr_coll(bx).unwrap_or(CBinary),
      })
    }
    Like(glob~, lhs~, pat~, esc~, neg~) => {
      let besc = match esc {
        Some(x) => Some(self.bind(x))
        None => None
      }
      Like(glob~, lhs=self.bind(lhs), pat=self.bind(pat), esc=besc, neg~)
    }
    Case(base~, whens~, else_~, ..) => {
      let bbase = match base {
        Some(b) => Some(self.bind(b))
        None => None
      }
      let bwhens : Array[(Expr, Expr)] = []
      let infos : Array[CmpInfo] = []
      for w in whens {
        let c = self.bind(w.0)
        bwhens.push((c, self.bind(w.1)))
        if bbase is Some(b) {
          infos.push(cmp_info(b, c))
        }
      }
      let belse = match else_ {
        Some(x) => Some(self.bind(x))
        None => None
      }
      Case(base=bbase, whens=bwhens, else_=belse, infos~)
    }
    Func(name~, args~, star~, distinct~, filter~, order~, ..) => {
      if is_aggregate_call(name, args.length()) {
        return self.bind_aggregate(name, args, star, distinct, filter, order)
      }
      if filter is Some(_) {
        raise sql_err(
          "FILTER may not be used with non-aggregate \{name.to_lower()}()",
        )
      }
      if order.length() > 0 {
        raise sql_err(
          "ORDER BY may not be used with non-aggregate \{name.to_lower()}()",
        )
      }
      check_function(name, args, star)
      let bargs : Array[Expr] = []
      for a in args {
        bargs.push(self.bind(a))
      }
      Func(
        name~,
        args=bargs,
        star~,
        distinct~,
        coll=first_coll(bargs),
        filter=None,
        order=[],
      )
    }
  }
}

///|
fn first_coll(args : Array[Expr]) -> Coll {
  for a in args {
    if expr_coll(a) is Some(c) {
      return c
    }
  }
  CBinary
}

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

///|
fn empty_scope() -> Scope {
  simple_scope([])
}

///|
/// Execute one statement; returns the result rows.
pub fn Database::execute(
  self : Database,
  sql : String,
) -> Array[Array[Value]] raise SqlError {
  let st = parse_statement(sql)
  cur_db.val = Some(self)
  cte_stack.clear()
  match st {
    WithDml(ctes, inner) => {
      let base = push_ctes(ctes)
      let rows = self.execute_dml(inner) catch {
        e => {
          cte_stack.truncate(base)
          raise e
        }
      }
      cte_stack.truncate(base)
      rows
    }
    Insert(..) | Update(..) | Delete(..) => self.execute_dml(st)
    SelectStmt(q) => self.run_query(q).0
    Begin | Commit | Rollback(_) | Savepoint(_) | Release(_) => {
      self.run_txn(st)
      []
    }
    _ => {
      let snap = self.snapshot()
      self.run_ddl(st) catch {
        e => {
          self.restore(snap)
          raise e
        }
      }
      []
    }
  }
}

///|
/// Run an INSERT/UPDATE/DELETE atomically and maintain changes().
fn Database::execute_dml(
  self : Database,
  st : Stmt,
) -> Array[Array[Value]] raise SqlError {
  let snap = self.snapshot()
  self.stmt_changes = 0L
  self.dml_started = false
  self.fail_keep = false
  self.rollback_all = false
  let rows = self.run_dml(st) catch {
    e => {
      if self.rollback_all && self.txn is Some(s) {
        self.restore(s)
        self.end_txn()
        if self.dml_started {
          conn.changes = 0L
        }
      } else if self.fail_keep {
        conn.changes = self.stmt_changes
        conn.total_changes += self.stmt_changes
      } else {
        self.restore(snap)
        if self.dml_started {
          conn.changes = 0L
        }
      }
      raise e
    }
  }
  conn.changes = self.stmt_changes
  conn.total_changes += self.stmt_changes
  rows
}

///|
fn Database::run_dml(
  self : Database,
  st : Stmt,
) -> Array[Array[Value]] raise SqlError {
  match st {
    Insert(table~, as_name~, cols~, src~, or_~, upserts~, returning~) =>
      self.run_insert(table, as_name, cols, src, or_, upserts, returning)
    Update(table~, as_name~, or_~, sets~, where_~, returning~) =>
      self.run_update(table, as_name, or_, sets, where_, returning)
    Delete(table~, as_name~, where_~, returning~) =>
      self.run_delete(table, as_name, where_, returning)
    _ => []
  }
}

// ---------------------------------------------------------------------------
// SELECT
// ---------------------------------------------------------------------------

///|
/// Stable merge sort.
fn[T] stable_sort(arr : Array[T], cmp : (T, T) -> Int) -> Unit {
  let n = arr.length()
  if n < 2 {
    return
  }
  let tmp = arr.copy()
  let mut width = 1
  while width < n {
    let mut lo = 0
    while lo < n {
      let mid = if lo + width < n { lo + width } else { n }
      let hi = if lo + 2 * width < n { lo + 2 * width } else { n }
      let mut i = lo
      let mut j = mid
      let mut k = lo
      while i < mid && j < hi {
        if cmp(arr[j], arr[i]) < 0 {
          tmp[k] = arr[j]
          j += 1
        } else {
          tmp[k] = arr[i]
          i += 1
        }
        k += 1
      }
      while i < mid {
        tmp[k] = arr[i]
        i += 1
        k += 1
      }
      while j < hi {
        tmp[k] = arr[j]
        j += 1
        k += 1
      }
      lo = hi
    }
    for x in 0..<n {
      arr[x] = tmp[x]
    }
    width *= 2
  }
}

///|
/// Run a whole script and return the output text.
pub fn run_script(db : Database, script : String) -> String {
  let sb = StringBuilder()
  for stmt in split_statements(script) {
    let rows = db.execute(stmt) catch {
      SqlError(msg) => {
        sb.write_string("Error: ")
        sb.write_string(msg.replace_all(old="\n", new=" "))
        sb.write_char('\n')
        continue
      }
    }
    for r in rows {
      for i, v in r {
        if i > 0 {
          sb.write_char('|')
        }
        sb.write_string(v.display())
      }
      sb.write_char('\n')
    }
  }
  sb.to_string()
}
