// INSERT, UPDATE and DELETE with constraint checking and conflict resolution.

///|
priv enum Outcome {
  Written
  Skipped
  UpsertHit(Int, Int64) // upsert clause, rowid of the conflicting row
}

///|
/// How upsert clauses map onto uniqueness constraints (-1 = rowid,
/// i >= 0 = t.indexes[i]).
priv struct UpsertPlan {
  by_constraint : Map[Int, Int]
  catch_all : Int?
  first : Array[Int] // constraints named by targets, checked first
}

///|
fn pick_conflict(stmt : Conflict?, own : Conflict?) -> Conflict {
  match stmt {
    Some(c) => c
    None =>
      match own {
        Some(c) => c
        None => CAbort
      }
  }
}

///|
fn unique_error(t : Table, c : Int) -> SqlError {
  let names = if c < 0 {
    match t.rowid_alias {
      Some(ai) => [t.cols[ai].name]
      None => ["rowid"]
    }
  } else {
    return unique_index_error(t, t.indexes[c])
  }
  let parts = names.map(n => "\{t.name}.\{n}")
  sql_err("UNIQUE constraint failed: " + parts.join(", "))
}

///|
fn Database::raise_conflict(
  self : Database,
  mode : Conflict,
  err : SqlError,
) -> Unit raise SqlError {
  if mode == CFail {
    self.fail_keep = true
  }
  if mode == CRollback {
    self.rollback_all = true
  }
  raise err
}

///|
fn find_unique_conflict(
  t : Table,
  c : Int,
  rowid : Int64,
  vals : Array[Value],
  old : Int64?,
) -> Int64? raise SqlError {
  if c < 0 {
    if old is Some(o) && o == rowid {
      return None
    }
    match t.rows.find(rowid) {
      Some(_) => Some(rowid)
      None => None
    }
  } else {
    t.indexes[c].find_conflict(vals, rowid, old)
  }
}

///|
fn eval_default(c : ColumnDef) -> Value raise SqlError {
  match c.default_ {
    Some(d) => apply_affinity(eval(empty_scope().bind(d), []), c.affinity)
    None => Null
  }
}

///|
/// Check constraints for a new version of a row and store it. `old` is the
/// rowid of the row being updated (None for an insert).
fn Database::write_row(
  self : Database,
  t : Table,
  rowid : Int64,
  vals : Array[Value],
  old : Int64?,
  or_ : Conflict?,
  plan : UpsertPlan?,
) -> Outcome raise SqlError {
  // NOT NULL
  for i, c in t.cols {
    if !c.not_null || t.rowid_alias == Some(i) || !(vals[i] is Null) {
      continue
    }
    let mode = pick_conflict(or_, c.nn_conflict)
    let err = sql_err("NOT NULL constraint failed: \{t.name}.\{c.name}")
    match mode {
      CIgnore => return Skipped
      CReplace => {
        vals[i] = eval_default(c)
        if vals[i] is Null {
          raise err
        }
      }
      _ => self.raise_conflict(mode, err)
    }
  }
  // CHECK
  if t.checks.length() > 0 {
    let row = vals.copy()
    row.push(Int(rowid))
    for chk in t.checks {
      if eval(chk, row).truth() is Some(false) {
        let mode = pick_conflict(or_, None)
        let err = sql_err("CHECK constraint failed: \{t.name}")
        match mode {
          CIgnore => return Skipped
          CFail | CRollback => self.raise_conflict(mode, err)
          _ => raise err
        }
      }
    }
  }
  // uniqueness: targets of upsert clauses first, then the rowid, then indexes
  let order : Array[Int] = []
  if plan is Some(p) {
    for c in p.first {
      order.push(c)
    }
  }
  if !order.contains(-1) {
    order.push(-1)
  }
  for i in 0..<t.indexes.length() {
    if t.indexes[i].unique && !order.contains(i) {
      order.push(i)
    }
  }
  let replace_list : Array[Int] = []
  for c in order {
    let upsert = match plan {
      Some(p) =>
        match p.by_constraint.get(c) {
          Some(u) => Some(u)
          None => p.catch_all
        }
      None => None
    }
    let own = if c < 0 { t.rowid_conflict } else { t.indexes[c].conflict }
    let mode = pick_conflict(or_, own)
    if upsert is None && mode == CReplace {
      replace_list.push(c)
      continue
    }
    match find_unique_conflict(t, c, rowid, vals, old) {
      None => ()
      Some(other) =>
        match upsert {
          Some(u) => return UpsertHit(u, other)
          None =>
            match mode {
              CIgnore => return Skipped
              _ => self.raise_conflict(mode, unique_error(t, c))
            }
        }
    }
  }
  for c in replace_list {
    while find_unique_conflict(t, c, rowid, vals, old) is Some(other) {
      t.delete_row(other)
    }
  }
  if old is Some(o) {
    t.delete_row(o)
  }
  t.insert_row(rowid, vals)
  Written
}

///|
fn same_col_set(a : Array[Int], b : Array[Int]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let x = a.copy()
  let y = b.copy()
  x.sort()
  y.sort()
  x == y
}

///|
fn build_upsert_plan(
  t : Table,
  upserts : Array[Upsert],
) -> UpsertPlan? raise SqlError {
  if upserts.length() == 0 {
    return None
  }
  let by_constraint : Map[Int, Int] = Map([])
  let first : Array[Int] = []
  let mut catch_all : Int? = None
  for ui, u in upserts {
    match u.target {
      None => if catch_all is None { catch_all = Some(ui) }
      Some(names) => {
        let idxs : Array[Int] = []
        for n in names {
          match t.col_index(n) {
            Some(i) => idxs.push(i)
            None => raise sql_err("no such column: \{n}")
          }
        }
        let mut found : Int? = None
        if idxs.length() == 1 && t.rowid_alias == Some(idxs[0]) {
          found = Some(-1)
        } else {
          for i, ix in t.indexes {
            if ix.unique &&
              ix.where_ is None &&
              ix.cols.all(c => c >= 0) &&
              same_col_set(ix.cols, idxs) {
              found = Some(i)
              break
            }
          }
        }
        guard found is Some(c) else {
          raise sql_err(
            "ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint",
          )
        }
        if !by_constraint.contains(c) {
          by_constraint[c] = ui
          first.push(c)
        }
      }
    }
  }
  Some({ by_constraint, catch_all, first, })
}

///|
/// Bind SET assignments: (column index or -1 for the rowid, expression).
fn bind_sets(
  t : Table,
  sets : Array[(String, Expr)],
  scope : Scope,
) -> Array[(Int, Expr)] raise SqlError {
  let out : Array[(Int, Expr)] = []
  for s in sets {
    let ci = match t.col_index(s.0) {
      Some(i) => i
      None =>
        if is_rowid_name(s.0) {
          -1
        } else {
          raise sql_err("no such column: \{s.0}")
        }
    }
    out.push((ci, scope.bind(s.1)))
  }
  out
}

///|
/// Apply SET assignments to a row; all right-hand sides see `env`.
fn apply_sets(
  t : Table,
  sets : Array[(Int, Expr)],
  oldvals : Array[Value],
  oldrowid : Int64,
  env : Array[Value],
) -> (Int64, Array[Value]) raise SqlError {
  let computed = sets.map(s => eval(s.1, env))
  let newvals = oldvals.copy()
  let mut rowid_v : Value? = None
  let mut alias_set = false
  for i, s in sets {
    if s.0 < 0 {
      rowid_v = Some(apply_affinity(computed[i], AffInteger))
    } else {
      newvals[s.0] = apply_affinity(computed[i], t.cols[s.0].affinity)
      if t.rowid_alias == Some(s.0) {
        alias_set = true
      }
    }
  }
  let mut newrowid = oldrowid
  if t.rowid_alias is Some(ai) && alias_set {
    match newvals[ai] {
      Int(i) => newrowid = i
      _ => raise sql_err("datatype mismatch")
    }
  }
  if rowid_v is Some(v) {
    match v {
      Int(i) => {
        newrowid = i
        if t.rowid_alias is Some(ai) {
          newvals[ai] = Int(i)
        }
      }
      _ => raise sql_err("datatype mismatch")
    }
  }
  (newrowid, newvals)
}

///|
fn single_scope(t : Table, as_name : String?) -> Scope {
  let name = match as_name {
    Some(a) => a
    None => t.name
  }
  simple_scope([table_source(name, t, 0, false)])
}

///|
fn bind_returning(
  t : Table,
  scope : Scope,
  returning : Array[ResultCol]?,
) -> Array[Expr]? raise SqlError {
  guard returning is Some(cols) else { return None }
  let out : Array[Expr] = []
  for c in cols {
    match c {
      Star =>
        for i, cd in t.cols {
          out.push(Slot(i, cd.affinity, col_coll(cd)))
        }
      TableStar(_) =>
        raise sql_err("RETURNING may not use \"TABLE.*\" wildcards")
      ExprCol(e, _, _) => out.push(scope.bind(e))
    }
  }
  Some(out)
}

///|
fn row_with_rowid(vals : Array[Value], rowid : Int64) -> Array[Value] {
  let row = vals.copy()
  row.push(Int(rowid))
  row
}

///|
fn push_returning(
  out : Array[Array[Value]],
  ret : Array[Expr]?,
  vals : Array[Value],
  rowid : Int64,
) -> Unit raise SqlError {
  if ret is Some(exprs) {
    let row = row_with_rowid(vals, rowid)
    out.push(exprs.map(e => eval(e, row)))
  }
}

///|
fn Table::new_rowid(self : Table) -> Int64 raise SqlError {
  let mut base = self.rows.max_key().unwrap_or(0L)
  if self.autoinc && self.seq_val > base {
    base = self.seq_val
  }
  if base < @int64.MAX_VALUE {
    return base + 1L
  }
  if !self.autoinc {
    // like SQLite, fall back to a pseudo-random unused rowid
    for _ in 0..<100 {
      rng_state.val = rng_state.val * 6364136223846793005L +
        1442695040888963407L
      let cand = (rng_state.val >> 1) & @int64.MAX_VALUE
      if cand > 0L && self.rows.find(cand) is None {
        return cand
      }
    }
  }
  raise sql_err("database or disk is full")
}

///|
let rng_state : Ref[Int64] = { val: 88172645463325252L, }

///|
fn Database::run_insert(
  self : Database,
  tname : String,
  as_name : String?,
  cols : Array[String]?,
  src : InsertSource,
  or_ : Conflict?,
  upserts : Array[Upsert],
  returning : Array[ResultCol]?,
) -> Array[Array[Value]] raise SqlError {
  let t = self.writable_table(tname)
  let ncols = t.cols.length()
  // target column indexes (-1 = rowid)
  let targets : Array[Int] = match cols {
    Some(names) => {
      let out : Array[Int] = []
      for n in names {
        match t.col_index(n) {
          Some(i) => out.push(i)
          None =>
            if is_rowid_name(n) {
              out.push(-1)
            } else {
              raise sql_err("table \{t.name} has no column named \{n}")
            }
        }
      }
      out
    }
    None => Array::makei(ncols, i => i)
  }
  let plan = build_upsert_plan(t, upserts)
  let scope = single_scope(t, as_name)
  // DO UPDATE clauses see the existing row and, qualified, "excluded"
  let uscope = simple_scope([
    scope.sources[0],
    table_source("excluded", t, ncols + 1, true),
  ])
  let usets : Array[Array[(Int, Expr)]?] = []
  let uwheres : Array[Expr?] = []
  for u in upserts {
    match u.sets {
      None => {
        usets.push(None)
        uwheres.push(None)
      }
      Some(sets) => {
        usets.push(Some(bind_sets(t, sets, uscope)))
        uwheres.push(
          match u.where_ {
            Some(w) => Some(uscope.bind(w))
            None => None
          },
        )
      }
    }
  }
  let ret = bind_returning(t, single_scope(t, None), returning)
  // source rows
  let value_rows : Array[Array[Expr]] = []
  let mut select_rows : Array[Array[Value]] = []
  match src {
    Values(rows) => {
      let w = rows[0].length()
      for r in rows {
        if r.length() != w {
          raise sql_err("all VALUES must have the same number of terms")
        }
      }
      check_width(t, cols, targets.length(), w)
      let empty = empty_scope()
      for r in rows {
        value_rows.push(r.map(e => empty.bind(e)))
      }
    }
    SelectSrc(q) => {
      let (rows, w) = self.run_query(q)
      check_width(t, cols, targets.length(), w)
      select_rows = rows
    }
    DefaultValues => select_rows = [[]]
  }
  let nrows = value_rows.length() + select_rows.length()
  let out : Array[Array[Value]] = []
  self.dml_started = true
  for r in 0..<nrows {
    let vals = if value_rows.length() > 0 {
      value_rows[r].map(e => eval(e, []))
    } else {
      select_rows[r]
    }
    let rowvals : Array[Value] = Array::make(ncols, Null)
    let assigned = Array::make(ncols, false)
    let mut rowid_v : Value = Null
    for k, ti in targets {
      if k >= vals.length() {
        break
      }
      if ti < 0 {
        rowid_v = apply_affinity(vals[k], AffInteger)
      } else if !assigned[ti] {
        rowvals[ti] = apply_affinity(vals[k], t.cols[ti].affinity)
        assigned[ti] = true
      }
    }
    for i in 0..<ncols {
      if !assigned[i] && t.rowid_alias != Some(i) {
        rowvals[i] = eval_default(t.cols[i])
      }
    }
    if t.rowid_alias is Some(ai) && assigned[ai] {
      rowid_v = rowvals[ai]
    }
    let rowid = match rowid_v {
      Int(i) => i
      Null => t.new_rowid()
      _ => raise sql_err("datatype mismatch")
    }
    if t.autoinc && rowid > t.seq_val {
      t.seq_val = rowid
    }
    if t.rowid_alias is Some(ai) {
      rowvals[ai] = Int(rowid)
    }
    match self.write_row(t, rowid, rowvals, None, or_, plan) {
      Written => {
        self.stmt_changes += 1L
        conn.last_rowid = rowid
        push_returning(out, ret, rowvals, rowid)
      }
      Skipped => ()
      UpsertHit(u, other) => {
        guard usets[u] is Some(sets) else { continue }
        guard t.rows.find(other) is Some(oldvals) else { continue }
        let env = row_with_rowid(oldvals, other)
        for v in rowvals {
          env.push(v)
        }
        env.push(Int(rowid))
        if uwheres[u] is Some(w) && !(eval(w, env).truth() is Some(true)) {
          continue
        }
        let (newrowid, newvals) = apply_sets(t, sets, oldvals, other, env)
        match
          self.write_row(t, newrowid, newvals, Some(other), Some(CAbort), None) {
          Written => {
            self.stmt_changes += 1L
            push_returning(out, ret, newvals, newrowid)
          }
          _ => ()
        }
      }
    }
  }
  out
}

///|
fn check_width(
  t : Table,
  cols : Array[String]?,
  ntargets : Int,
  w : Int,
) -> Unit raise SqlError {
  if w != ntargets {
    match cols {
      Some(_) => raise sql_err("\{w} values for \{ntargets} columns")
      None =>
        raise sql_err(
          "table \{t.name} has \{ntargets} columns but \{w} values were supplied",
        )
    }
  }
}

///|
/// Rowids of the rows matching an optional WHERE clause, in rowid order.
fn matching_rowids(t : Table, where_ : Expr?) -> Array[Int64] raise SqlError {
  let ids : Array[Int64] = []
  let parts : Array[Expr] = []
  if where_ is Some(w) {
    split_and(w, parts)
  }
  let acc = choose_access(t, 0, parts, None, None, false)
  let rows = match acc {
    AScan => t.rows.to_array()
    _ => fetch_access(acc, t, [])
  }
  for pair in rows {
    let (rid, vals) = pair
    match where_ {
      Some(w) => {
        let row = row_with_rowid(vals, rid)
        if eval(w, row).truth() is Some(true) {
          ids.push(rid)
        }
      }
      None => ids.push(rid)
    }
  }
  ids
}

///|
fn Database::run_update(
  self : Database,
  tname : String,
  as_name : String?,
  or_ : Conflict?,
  sets : Array[(String, Expr)],
  where_ : Expr?,
  returning : Array[ResultCol]?,
) -> Array[Array[Value]] raise SqlError {
  let t = self.writable_table(tname)
  let scope = single_scope(t, as_name)
  let bsets = bind_sets(t, sets, scope)
  let bwhere = match where_ {
    Some(w) => Some(scope.bind(w))
    None => None
  }
  let ret = bind_returning(t, single_scope(t, None), returning)
  let ids = matching_rowids(t, bwhere)
  let out : Array[Array[Value]] = []
  self.dml_started = true
  for rid in ids {
    guard t.rows.find(rid) is Some(oldvals) else { continue }
    let env = row_with_rowid(oldvals, rid)
    let (newrowid, newvals) = apply_sets(t, bsets, oldvals, rid, env)
    match self.write_row(t, newrowid, newvals, Some(rid), or_, None) {
      Written => {
        self.stmt_changes += 1L
        push_returning(out, ret, newvals, newrowid)
      }
      _ => ()
    }
  }
  out
}

///|
fn Database::run_delete(
  self : Database,
  tname : String,
  as_name : String?,
  where_ : Expr?,
  returning : Array[ResultCol]?,
) -> Array[Array[Value]] raise SqlError {
  let t = self.writable_table(tname)
  let scope = single_scope(t, as_name)
  let bwhere = match where_ {
    Some(w) => Some(scope.bind(w))
    None => None
  }
  let ret = bind_returning(t, single_scope(t, None), returning)
  let ids = matching_rowids(t, bwhere)
  let out : Array[Array[Value]] = []
  self.dml_started = true
  for rid in ids {
    guard t.rows.find(rid) is Some(oldvals) else { continue }
    push_returning(out, ret, oldvals, rid)
    t.delete_row(rid)
    self.stmt_changes += 1L
  }
  out
}
