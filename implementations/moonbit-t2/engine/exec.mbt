///|
priv struct Source {
  name : String
  /// Column metadata (a pseudo-table for subqueries in FROM).
  table : Table
  offset : Int
  /// Only reachable through a qualified name (upsert's `excluded`).
  hidden : Bool
  /// A subquery in FROM providing the rows.
  sub : Prepared?
  /// Join operator connecting this source to the ones on its left.
  kind : JoinKind
  /// ON condition (including USING/NATURAL equalities), bound.
  mut on : Expr?
  /// Columns merged into a left column by USING/NATURAL: hidden from
  /// unqualified references and `*`.
  merged : Array[Bool]
  /// Expressions used instead of the column for unqualified references
  /// (coalesced USING columns of RIGHT/FULL joins).
  overrides : Map[Int, Expr]
  /// Estimated row count of a subquery source.
  est_rows : Double?
}

///|
fn new_source(
  name : String,
  table : Table,
  offset : Int,
  hidden? : Bool = false,
  sub? : Prepared,
  kind? : JoinKind = JInner,
  est_rows? : Double,
) -> Source {
  {
    est_rows,
    name,
    table,
    offset,
    hidden,
    sub,
    kind,
    on: None,
    merged: Array::make(table.columns.length(), false),
    overrides: Map([]),
  }
}

///|
priv struct Scope {
  sources : Array[Source]
  parent : Scope?
  /// Result-column aliases usable as a fallback (ORDER BY).
  aliases : Array[(String, Expr)]
  /// Set when a name resolves beyond this query (shared by all scopes of
  /// one query).
  correlated : Ref[Bool]
  /// Aggregates of this query, when it is an aggregate query (shared).
  agg_ctx : Ref[AggCtx?]
}

///|
fn new_scope(
  sources : Array[Source],
  parent : Scope?,
  aliases? : Array[(String, Expr)] = [],
  correlated? : Ref[Bool] = { val: false, },
  agg_ctx? : Ref[AggCtx?] = { val: None, },
) -> Scope {
  { sources, parent, aliases, correlated, agg_ctx, }
}

///|
fn bind_column(
  scope : Scope?,
  tbl : String?,
  name : String,
  dq : Bool,
) -> Expr raise SqlError {
  let mut depth = 0
  let mut sc = scope
  while sc is Some(s) {
    let mut found : Expr? = None
    for src in s.sources {
      match tbl {
        Some(t) => if !src.name.equal_ignore_ascii_case(t) { continue }
        None => if src.hidden { continue }
      }
      match src.table.find_column(name) {
        Some(i) => {
          if tbl is None && src.merged[i] {
            continue
          }
          if found is Some(_) {
            raise SqlError("ambiguous column name: \{name}")
          }
          let c = src.table.columns[i]
          found = match src.overrides.get(i) {
            Some(o) if tbl is None => Some(shift_depth(o, depth))
            _ => Some(Slot(depth~, idx=src.offset + i, aff=c.aff, coll=c.coll))
          }
        }
        None =>
          if is_rowid_name(name) && src.sub is None {
            if found is None {
              found = Some(
                Slot(
                  depth~,
                  idx=src.offset + src.table.columns.length(),
                  aff=AffInteger,
                  coll=None,
                ),
              )
            }
          }
      }
    }
    if found is Some(f) {
      return f
    }
    if tbl is None && depth == 0 {
      for a in s.aliases {
        if a.0.equal_ignore_ascii_case(name) {
          return a.1
        }
      }
    }
    s.correlated.val = true
    depth += 1
    sc = s.parent
  }
  if dq && tbl is None {
    return Lit(Text(name))
  }
  match tbl {
    Some(t) => raise SqlError("no such column: \{t}.\{name}")
    None => raise SqlError("no such column: \{name}")
  }
}

///|
fn is_rowid_name(n : String) -> Bool {
  n.equal_ignore_ascii_case("rowid") ||
  n.equal_ignore_ascii_case("oid") ||
  n.equal_ignore_ascii_case("_rowid_")
}

///|
fn bind_expr(e : Expr, scope : Scope?) -> Expr raise SqlError {
  match e {
    Lit(_) | Slot(..) => e
    Col(tbl~, name~, dq~) => bind_column(scope, tbl, name, dq)
    Unary(op, x) => Unary(op, bind_expr(x, scope))
    Binary(op, l, r) => Binary(op, bind_expr(l, scope), bind_expr(r, scope))
    IsNull(x, n) => IsNull(bind_expr(x, scope), n)
    Is(l, r, n) => Is(bind_expr(l, scope), bind_expr(r, scope), n)
    Between(x, lo, hi, n) =>
      Between(
        bind_expr(x, scope),
        bind_expr(lo, scope),
        bind_expr(hi, scope),
        n,
      )
    InList(x, items, n) =>
      InList(bind_expr(x, scope), items.map(i => bind_expr(i, scope)), n)
    Like(op, x, p, esc, n) =>
      Like(
        op,
        bind_expr(x, scope),
        bind_expr(p, scope),
        match esc {
          Some(z) => Some(bind_expr(z, scope))
          None => None
        },
        n,
      )
    Func(name~, args~, distinct~, star~, filter~, order~) => {
      if is_aggregate_call(name, args.length()) &&
        outer_aggregate(e, scope) is Some(r) {
        return r
      }
      if is_window_only(name) {
        raise SqlError("misuse of window function \{name}()")
      }
      check_function_call(name, args)
      if filter is Some(_) {
        raise SqlError("FILTER may not be used with non-aggregate \{name}()")
      }
      if order.length() > 0 {
        raise SqlError("ORDER BY may not be used with non-aggregate \{name}()")
      }
      Func(
        name~,
        args=args.map(a => bind_expr(a, scope)),
        distinct~,
        star~,
        filter~,
        order~,
      )
    }
    AggRef(..) => e
    Case(base, whens, els) =>
      Case(
        match base {
          Some(b) => Some(bind_expr(b, scope))
          None => None
        },
        whens.map(w => (bind_expr(w.0, scope), bind_expr(w.1, scope))),
        match els {
          Some(x) => Some(bind_expr(x, scope))
          None => None
        },
      )
    Cast(x, t) => Cast(bind_expr(x, scope), t)
    Collate(x, c) => Collate(bind_expr(x, scope), check_collation(c))
    Subquery(sel) => {
      let p = cur_db().prepare_query(sel, scope)
      p.expect_one_column()
      ScalarQ(p.to_subquery())
    }
    Exists(sel) => ExistsQ(cur_db().prepare_query(sel, scope).to_subquery())
    InSelect(x, sel, n) => {
      let bx = bind_expr(x, scope)
      let p = cur_db().prepare_query(sel, scope)
      p.expect_one_column()
      InQ(bx, p.to_subquery(), n)
    }
    ScalarQ(_) | ExistsQ(_) | InQ(_, _, _) => e
    WinFunc(f, _) =>
      raise SqlError("misuse of window function \{func_name(f)}()")
  }
}

///|
fn func_name(f : Expr) -> String {
  match f {
    Func(name~, ..) => name
    _ => ""
  }
}

///|
let empty_env : Env = { row: [], parent: None, }

///|
fn eval_const(e : Expr) -> Value raise SqlError {
  eval(bind_expr(e, None), empty_env)
}

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

///|
pub fn Database::execute(
  self : Database,
  st : Stmt,
) -> Array[Array[Value]] raise SqlError {
  cur_db_ref.val = Some(self)
  match st {
    CreateTableStmt(ct) => self.create_table(ct)
    DropTableStmt(name, if_exists) => self.drop_table(name, if_exists)
    CreateIndexStmt(ci) => self.create_index(ci)
    DropIndexStmt(name, if_exists) => self.drop_index(name, if_exists)
    CreateViewStmt(cv) => self.create_view(cv)
    DropViewStmt(name, if_exists) => self.drop_view(name, if_exists)
    AlterStmt(name, action) => self.alter_table(name, action)
    BeginStmt
    | CommitStmt
    | RollbackStmt(_)
    | SavepointStmt(_)
    | ReleaseStmt(_) => self.txn_control(st)
    InsertStmt(ins) => return self.run_dml(() => self.insert(ins))
    UpdateStmt(up) => return self.run_dml(() => self.update(up))
    DeleteStmt(del) => return self.run_dml(() => self.delete(del))
    SelectStmt(sel) => return (self.prepare_query(sel, None).run)(empty_env)
    WithStmt(ctes, inner) => return with_ctes(ctes, () => self.execute(inner))
  }
  []
}

///|
/// Runs a data-changing statement, maintaining changes() counters.
fn Database::run_dml(
  self : Database,
  body : () -> Array[Array[Value]] raise SqlError,
) -> Array[Array[Value]] raise SqlError {
  self.stmt_changes = 0L
  self.keep_on_error = false
  self.exec_started = false
  let rows = {
    // errors while preparing the statement leave changes() alone
    errdefer (if self.keep_on_error {
      conn.changes = self.stmt_changes
      conn.total_changes += self.stmt_changes
    } else if self.exec_started {
      conn.changes = 0L
    })
    body()
  }
  conn.changes = self.stmt_changes
  conn.total_changes += self.stmt_changes
  rows
}

///|
fn Database::create_table(
  self : Database,
  ct : CreateTable,
) -> Unit raise SqlError {
  if ct.name.to_lower().has_prefix("sqlite_") {
    raise SqlError("object name reserved for internal use: \{ct.name}")
  }
  if self.find_table(ct.name) is Some(_) {
    if ct.if_not_exists {
      return
    }
    raise SqlError("table \{ct.name} already exists")
  }
  if self.find_view(ct.name) is Some(_) {
    if ct.if_not_exists {
      return
    }
    raise SqlError("view \{ct.name} already exists")
  }
  if self.find_index(ct.name) is Some(_) {
    raise SqlError("there is already an index named \{ct.name}")
  }
  let cols : Array[Column] = []
  for cd in ct.columns {
    for c in cols {
      if c.name.equal_ignore_ascii_case(cd.name) {
        raise SqlError("duplicate column name: \{cd.name}")
      }
    }
    cols.push(make_column(cd))
  }
  let find = fn(n : String) raise SqlError {
    for i, c in cols {
      if c.name.equal_ignore_ascii_case(n) {
        return i
      }
    }
    raise SqlError("no such column: \{n}")
  }
  // PRIMARY KEY and UNIQUE constraints, in order of appearance:
  // (columns, conflict, is primary key, autoincrement, desc)
  let specs : Array[(Array[Int], Conflict, Bool, Bool, Bool)] = []
  let mut has_pk = false
  for i, cd in ct.columns {
    if cd.primary_key {
      if has_pk {
        raise SqlError("table \"\{ct.name}\" has more than one primary key")
      }
      has_pk = true
      specs.push(([i], cd.pk_conflict, true, cd.autoincrement, cd.pk_desc))
    }
    if cd.unique {
      specs.push(([i], cd.unique_conflict, false, false, false))
    }
  }
  for tc in ct.constraints {
    match tc {
      PrimaryKey(names, c, autoinc) => {
        if has_pk {
          raise SqlError("table \"\{ct.name}\" has more than one primary key")
        }
        has_pk = true
        let idx : Array[Int] = []
        for n in names {
          idx.push(find(n))
        }
        specs.push((idx, c, true, autoinc, false))
      }
      Unique(names, c) => {
        let idx : Array[Int] = []
        for n in names {
          idx.push(find(n))
        }
        specs.push((idx, c, false, false, false))
      }
      _ => ()
    }
  }
  let mut ipk = -1
  let mut ipk_conflict = CDefault
  let mut autoinc = false
  let unique_specs : Array[(Array[Int], Conflict, Bool)] = []
  for sp in specs {
    let (idx, c, is_pk, ai, desc) = sp
    if is_pk &&
      idx.length() == 1 &&
      cols[idx[0]].decl_type.to_upper() == "INTEGER" &&
      !desc {
      ipk = idx[0]
      ipk_conflict = c
      autoinc = ai
      continue
    }
    if ai {
      raise SqlError("AUTOINCREMENT is only allowed on an INTEGER PRIMARY KEY")
    }
    // identical constraints are merged, as SQLite does
    if unique_specs.any(u => u.0 == idx) {
      continue
    }
    unique_specs.push((idx, c, is_pk))
  }
  let t : Table = {
    name: ct.name,
    columns: cols,
    rows: new_rows(),
    ipk,
    ipk_conflict,
    autoinc,
    seq: 0L,
    indexes: [],
    checks: [],
    schema_seq: next_schema_seq(),
    rootpage: 0,
    version: next_version(),
    sql: ct.sql,
  }
  let indexes : Array[Index] = []
  for k, u in unique_specs {
    indexes.push(
      build_index(
        t,
        "sqlite_autoindex_\{t.name}_\{k + 1}",
        unique=true,
        origin=if u.2 { 2 } else { 1 },
        conflict=u.1,
        parts=u.0.map(i => {
          expr: Col(tbl=None, name=cols[i].name, dq=false),
          coll: None,
          desc: false,
        }),
        where_src=None,
        sql=None,
        seq=next_schema_seq(),
      ),
    )
  }
  t.indexes = indexes
  let defs : Array[CheckDef] = []
  for cd in ct.columns {
    for ck in cd.checks {
      defs.push(ck)
    }
  }
  for tc in ct.constraints {
    if tc is Check(ck) {
      defs.push(ck)
    }
  }
  t.checks = bind_checks(t, defs)
  self.tables[name_key(t.name)] = t
  if autoinc && self.sequence_seq == 0 {
    self.sequence_seq = next_schema_seq()
  }
}

///|
fn make_column(cd : ColumnDef) -> Column raise SqlError {
  {
    name: cd.name,
    decl_type: cd.decl_type,
    aff: affinity_of_type(cd.decl_type),
    coll: match cd.collate {
      Some(c) => Some(check_collation(c))
      None => None
    },
    def: cd,
  }
}

///|
/// Binds CHECK constraints against the table's own row.
fn bind_checks(
  t : Table,
  defs : Array[CheckDef],
) -> Array[CheckCons] raise SqlError {
  let scope = new_scope([new_source(t.name, t, 0)], None)
  defs.map(cd => {
    expr: bind_expr(cd.expr, Some(scope)),
    label: cd.name.unwrap_or(cd.text),
    def: cd,
  })
}

// ---------------------------------------------------------------------------
// SELECT
// ---------------------------------------------------------------------------

///|
fn ordinal_suffix(n : Int) -> String {
  match n % 10 {
    1 if n % 100 != 11 => "st"
    2 if n % 100 != 12 => "nd"
    3 if n % 100 != 13 => "rd"
    _ => "th"
  }
}

///|
/// Expands result columns into bound expressions, their aliases and their
/// column names.
fn expand_result_cols(
  cols : Array[ResultCol],
  scope : Scope,
  agg? : AggCtx,
  win? : WinCtx,
) -> (Array[Expr], Array[String?], Array[String]) raise SqlError {
  let sources = scope.sources
  let exprs : Array[Expr] = []
  let aliases : Array[String?] = []
  let names : Array[String] = []
  for rc in cols {
    match rc {
      Star => {
        if sources.length() == 0 {
          raise SqlError("no tables specified")
        }
        for src in sources {
          if src.hidden {
            continue
          }
          for i, c in src.table.columns {
            if src.merged[i] {
              continue
            }
            exprs.push(
              match src.overrides.get(i) {
                Some(o) => o
                None =>
                  Slot(depth=0, idx=src.offset + i, aff=c.aff, coll=c.coll)
              },
            )
            aliases.push(None)
            names.push(c.name)
          }
        }
      }
      TableStar(tn) => {
        let mut found = false
        for src in sources {
          if src.name.equal_ignore_ascii_case(tn) {
            found = true
            for i, c in src.table.columns {
              exprs.push(
                Slot(depth=0, idx=src.offset + i, aff=c.aff, coll=c.coll),
              )
              aliases.push(None)
              names.push(c.name)
            }
          }
        }
        if !found {
          raise SqlError("no such table: \{tn}")
        }
      }
      ExprCol(e, as_name, text) => {
        let pre = match agg {
          Some(ctx) => extract_aggs(e, ctx)
          None => e
        }
        let pre = match win {
          Some(w) => extract_wins(pre, w)
          None => pre
        }
        exprs.push(bind_expr(pre, Some(scope)))
        aliases.push(as_name)
        names.push(
          match (as_name, e) {
            (Some(a), _) => a
            (None, Col(name~, ..)) => name
            _ => text
          },
        )
      }
    }
  }
  (exprs, aliases, names)
}

///|
/// The row layout of a table in an environment: column values then rowid.
fn row_with_rowid(vals : Array[Value], rowid : Int64) -> Array[Value] {
  let n = vals.length()
  let r = Array::make(n + 1, Null)
  for i in 0..<n {
    r[i] = vals[i]
  }
  r[n] = Int(rowid)
  r
}

///|
/// Evaluates a LIMIT/OFFSET expression to an integer.
fn eval_limit(e : Expr) -> Int64 raise SqlError {
  let v = eval_const(e)
  let n = match v {
    Text(s) =>
      match parse_numeric_text(s) {
        Some(x) => x
        None => v
      }
    _ => v
  }
  match n {
    Int(i) => i
    Real(d) =>
      match real_to_int_exact(d) {
        Some(i) => i
        None => raise SqlError("datatype mismatch")
      }
    _ => raise SqlError("datatype mismatch")
  }
}

///|
priv struct SortKey {
  expr : Expr // bound; a result-column expression for ordinals and aliases
  result_idx : Int // >= 0 when the key is a result column
  desc : Bool
  nulls : Int
  coll : String
}

///|
fn compare_sort_keys(
  keys : Array[SortKey],
  ka : Array[Value],
  kb : Array[Value],
) -> Int {
  for k, key in keys {
    let va = ka[k]
    let vb = kb[k]
    let mut c = 0
    if va is Null || vb is Null {
      let na = if va is Null { 0 } else { 1 }
      let nb = if vb is Null { 0 } else { 1 }
      c = na - nb
      if key.nulls == 0 {
        if key.desc {
          c = -c
        }
      } else if key.nulls == 2 {
        c = -c
      }
    } else {
      c = value_compare_coll(va, vb, key.coll)
      if key.desc {
        c = -c
      }
    }
    if c != 0 {
      return c
    }
  }
  0
}

///|
/// Binds an ORDER BY term; `exprs`/`aliases` are the result columns.
fn bind_order_term(
  i : Int,
  t : OrderTerm,
  exprs : Array[Expr],
  aliases : Array[String?],
  order_scope : Scope,
  agg : AggCtx?,
  win? : WinCtx,
) -> SortKey raise SqlError {
  let mut term = t.expr
  let mut explicit : String? = None
  while term is Collate(inner, c) {
    if explicit is None {
      explicit = Some(check_collation(c))
    }
    term = inner
  }
  let mut result_idx = -1
  let ordinal = match term {
    Lit(Int(k)) => Some(k)
    Unary(Pos, Lit(Int(k))) => Some(k)
    Unary(Neg, Lit(Int(k))) => Some(-k)
    _ => None
  }
  match term {
    _ if ordinal is Some(k) => {
      if k < 1L || k > exprs.length().to_int64() {
        raise SqlError(
          "\{i + 1}\{ordinal_suffix(i + 1)} ORDER BY term out of range - should be between 1 and \{exprs.length()}",
        )
      }
      result_idx = k.to_int() - 1
    }
    Col(tbl=None, name~, ..) =>
      for j, a in aliases {
        if a is Some(an) && an.equal_ignore_ascii_case(name) {
          result_idx = j
          break
        }
      }
    _ => ()
  }
  let bound = if result_idx >= 0 {
    exprs[result_idx]
  } else {
    let pre = match agg {
      Some(ctx) => extract_aggs(term, ctx)
      None => term
    }
    let pre = match win {
      Some(w) => extract_wins(pre, w)
      None => pre
    }
    bind_expr(pre, Some(order_scope))
  }
  make_sort_key(bound, explicit, result_idx, t)
}

// ---------------------------------------------------------------------------
// Script driver
// ---------------------------------------------------------------------------

///|
pub fn run_script(db : Database, input : String) -> Unit {
  for stmt_text in split_statements(input) {
    let out = StringBuilder()
    try {
      let st = parse_statement(stmt_text.trim().to_owned())
      let rows = db.execute_atomic(st)
      for r in rows {
        for i, v in r {
          if i > 0 {
            out.write_char('|')
          }
          out.write_string(v.to_output())
        }
        out.write_char('\n')
      }
    } catch {
      SqlError(msg) => {
        out.reset()
        out.write_string("Error: " + msg.replace_all(old="\n", new=" ") + "\n")
      }
    }
    @io.write_stdout(out.to_string())
  }
}
