// INSERT, UPDATE and DELETE with constraint enforcement.

///|
/// The conflict algorithm in force: the statement's OR clause, else the
/// constraint's own clause, else ABORT.
fn resolve_conflict(stmt : Conflict, cons : Conflict) -> Conflict {
  if stmt != CDefault {
    stmt
  } else if cons != CDefault {
    cons
  } else {
    CAbort
  }
}

///|
fn Database::conflict_error(
  self : Database,
  algo : Conflict,
  msg : String,
) -> SqlError {
  if algo == CFail {
    self.keep_on_error = true
  }
  if algo == CRollback {
    self.rollback_txn = true
  }
  SqlError(msg)
}

///|
fn table_scope(t : Table, name : String) -> Scope {
  new_scope([new_source(name, t, 0)], None)
}

///|
/// Applies NOT NULL and CHECK constraints to a candidate row. Returns false
/// when the row must be skipped (IGNORE); may fill in defaults (REPLACE).
fn Database::check_row(
  self : Database,
  t : Table,
  rowid : Int64,
  vals : Array[Value],
  or_conflict : Conflict,
) -> Bool raise SqlError {
  for i, col in t.columns {
    if col.def.not_null && vals[i] is Null {
      let algo = resolve_conflict(or_conflict, col.def.nn_conflict)
      let msg = "NOT NULL constraint failed: \{t.name}.\{col.name}"
      match algo {
        CIgnore => return false
        CReplace => {
          let d = match col.def.default {
            Some(d) => apply_affinity(eval_const(d), col.aff)
            None => Null
          }
          if d is Null {
            raise SqlError(msg)
          }
          vals[i] = d
        }
        _ => raise self.conflict_error(algo, msg)
      }
    }
  }
  if t.checks.length() > 0 {
    let env : Env = { row: row_with_rowid(vals, rowid), parent: None, }
    for ck in t.checks {
      if truthy(eval(ck.expr, env)) == Some(false) {
        let algo = if or_conflict == CDefault { CAbort } else { or_conflict }
        let msg = "CHECK constraint failed: \{ck.label}"
        match algo {
          CIgnore => return false
          CReplace => raise SqlError(msg)
          _ => raise self.conflict_error(algo, msg)
        }
      }
    }
  }
  true
}

///|
/// Uniqueness conflicts of a candidate row: (constraint, conflicting rowid)
/// where constraint -1 is the rowid itself and j >= 0 is `t.indexes[j]`.
/// Indexes are checked most recent first, as SQLite does.
fn find_conflicts(
  t : Table,
  rowid : Int64,
  vals : Array[Value],
  self_rowid : Int64?,
) -> Array[(Int, Int64)] raise SqlError {
  let out : Array[(Int, Int64)] = []
  if Some(rowid) != self_rowid && t.rows.contains(rowid) {
    out.push((-1, rowid))
  }
  for j = t.indexes.length() - 1; j >= 0; j = j - 1 {
    let idx = t.indexes[j]
    if !idx.unique {
      continue
    }
    if idx.key_of(vals, rowid) is Some(k) &&
      idx.conflict_with(k, self_rowid) is Some(r) {
      out.push((j, r))
    }
  }
  out
}

///|
fn constraint_conflict(t : Table, j : Int) -> Conflict {
  if j < 0 {
    t.ipk_conflict
  } else {
    t.indexes[j].conflict
  }
}

///|
fn constraint_msg(t : Table, j : Int) -> String {
  if j < 0 {
    "UNIQUE constraint failed: \{t.rowid_label()}"
  } else {
    "UNIQUE constraint failed: \{t.indexes[j].label(t)}"
  }
}

///|
/// Resolves uniqueness conflicts that are not handled by an upsert.
/// Returns false if the row must be skipped; deletes rows for REPLACE.
fn Database::resolve_unique(
  self : Database,
  t : Table,
  conflicts : Array[(Int, Int64)],
  or_conflict : Conflict,
) -> Bool raise SqlError {
  let mut replace = false
  for c in conflicts {
    let algo = resolve_conflict(or_conflict, constraint_conflict(t, c.0))
    match algo {
      CReplace => replace = true
      CIgnore => return false
      _ => raise self.conflict_error(algo, constraint_msg(t, c.0))
    }
  }
  if replace {
    for c in conflicts {
      self.delete_row(t, c.1)
    }
  }
  true
}

///|
/// Converts a value given for the rowid to an integer rowid.
fn rowid_of_value(v : Value) -> Int64? raise SqlError {
  match apply_affinity(v, AffInteger) {
    Null => None
    Int(i) => Some(i)
    _ => raise SqlError("datatype mismatch")
  }
}

///|
fn Database::new_rowid(self : Database, t : Table) -> Int64 raise SqlError {
  ignore(self)
  let max = match t.rows.max() {
    Some((k, _)) => k
    None => 0L
  }
  let base = if t.autoinc && t.seq > max { t.seq } else { max }
  if base < @int64.MAX_VALUE {
    return if base < 0L && !t.autoinc { 1L } else { base + 1L }
  }
  if t.autoinc {
    raise SqlError("database or disk is full")
  }
  // The largest rowid is taken: look for an unused one.
  let mut cand = 1L
  while t.rows.contains(cand) {
    cand += 1L
  }
  cand
}

///|
fn Database::record_insert(
  self : Database,
  t : Table,
  rowid : Int64,
  vals : Array[Value],
) -> Unit raise SqlError {
  self.insert_row(t, rowid, vals)
  self.stmt_changes += 1L
  conn.last_rowid = rowid
}

///|
/// Replaces row `old_rowid` by `new_vals` (and possibly a new rowid) after
/// checking constraints. Returns false if the row was skipped.
fn Database::update_row(
  self : Database,
  t : Table,
  old_rowid : Int64,
  new_rowid : Int64,
  new_vals : Array[Value],
  or_conflict : Conflict,
) -> Bool raise SqlError {
  if t.ipk >= 0 {
    new_vals[t.ipk] = Int(new_rowid)
  }
  if !self.check_row(t, new_rowid, new_vals, or_conflict) {
    return false
  }
  let conflicts = find_conflicts(t, new_rowid, new_vals, Some(old_rowid))
  if !self.resolve_unique(t, conflicts, or_conflict) {
    return false
  }
  self.delete_row(t, old_rowid)
  t.raw_insert(new_rowid, new_vals)
  self.stmt_changes += 1L
  true
}

///|
/// A compiled upsert clause.
priv struct UpsertPlan {
  targets : Array[Int]? // constraint indexes (-1 = rowid); None = any
  action : UpsertAction
  sets : Array[(Int, Expr)]
  where_ : Expr?
}

///|
fn same_columns(a : Array[Int], b : Array[Int]) -> Bool {
  a.length() == b.length() && a.all(x => b.contains(x))
}

///|
fn Database::insert(
  self : Database,
  ins : Insert,
) -> Array[Array[Value]] raise SqlError {
  let t = self.table_for_write(ins.table)
  let tname = ins.as_name.unwrap_or(t.name)
  let ncols = t.columns.length()
  // target columns; -1 is the rowid
  let targets : Array[Int] = match ins.columns {
    Some(names) => {
      let out = []
      for n in names {
        match t.find_column(n) {
          Some(i) => out.push(i)
          None =>
            if is_rowid_name(n) {
              out.push(t.ipk)
            } else {
              raise SqlError("table \{t.name} has no column named \{n}")
            }
        }
      }
      out
    }
    None => Array::makei(ncols, i => i)
  }
  let check_width = fn(width : Int) raise SqlError {
    if width != targets.length() {
      match ins.columns {
        Some(_) =>
          raise SqlError("\{width} values for \{targets.length()} columns")
        None =>
          raise SqlError(
            "table \{t.name} has \{ncols} columns but \{width} values were supplied",
          )
      }
    }
  }
  // source rows
  let mut value_rows : Array[Array[Expr]] = []
  let mut select_plan : Prepared? = None
  match ins.source {
    Values(rows) => {
      let width = rows[0].length()
      for r in rows {
        if r.length() != width {
          raise SqlError("all VALUES must have the same number of terms")
        }
      }
      check_width(width)
      value_rows = rows.map(r => r.map(e => bind_expr(e, None)))
    }
    FromSelect(sel) => {
      let p = self.prepare_query(sel, None)
      check_width(p.names.length())
      select_plan = Some(p)
    }
    DefaultValues => ()
  }
  // upsert clauses
  let upserts : Array[UpsertPlan] = []
  let up_scope = new_scope(
    [new_source(tname, t, 0), new_source("excluded", t, ncols + 1, hidden=true)],
    None,
  )
  for i, u in ins.upsert {
    let tg = match u.target {
      None => {
        if i != ins.upsert.length() - 1 {
          raise SqlError(
            "ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint",
          )
        }
        None
      }
      Some(names) => {
        let idx : Array[Int] = []
        for n in names {
          match t.find_column(n) {
            Some(ci) => idx.push(ci)
            None =>
              if is_rowid_name(n) && t.ipk >= 0 {
                idx.push(t.ipk)
              } else {
                raise SqlError("no such column: \{n}")
              }
          }
        }
        let found : Array[Int] = []
        if t.ipk >= 0 && same_columns(idx, [t.ipk]) {
          found.push(-1)
        }
        for j, uq in t.indexes {
          if uq.unique &&
            uq.where_ is None &&
            uq.cols.all(c => c >= 0) &&
            same_columns(idx, uq.cols) {
            found.push(j)
          }
        }
        if found.length() == 0 {
          raise SqlError(
            "ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint",
          )
        }
        Some(found)
      }
    }
    let (sets, w) = match u.action {
      DoNothing => ([], None)
      DoUpdate(sets, w) => {
        let out : Array[(Int, Expr)] = []
        for s in sets {
          let ci = match t.find_column(s.0) {
            Some(ci) => ci
            None =>
              if is_rowid_name(s.0) {
                t.ipk
              } else {
                raise SqlError("no such column: \{s.0}")
              }
          }
          out.push((ci, bind_expr(s.1, Some(up_scope))))
        }
        (
          out,
          match w {
            Some(e) => Some(bind_expr(e, Some(up_scope)))
            None => None
          },
        )
      }
    }
    upserts.push({ targets: tg, action: u.action, sets, where_: w, })
  }
  // RETURNING
  let ret_scope = table_scope(t, tname)
  let (ret_exprs, _, _) = expand_result_cols(ins.returning, ret_scope)
  let out_rows : Array[Array[Value]] = []
  let emit = fn(rowid : Int64) raise SqlError {
    if ret_exprs.length() > 0 {
      match t.rows.get(rowid) {
        Some(vals) => {
          let env : Env = { row: row_with_rowid(vals, rowid), parent: None, }
          out_rows.push(ret_exprs.map(e => eval(e, env)))
        }
        None => ()
      }
    }
  }
  let insert_one = fn(given : Array[Value]?) raise SqlError {
    let vals : Array[Value] = Array::make(ncols, Null)
    let is_given = Array::make(ncols, false)
    let mut rowid_val : Value = Null
    match given {
      Some(g) =>
        for k, v in g {
          let ci = targets[k]
          if ci < 0 {
            rowid_val = v
          } else if !is_given[ci] {
            vals[ci] = v
            is_given[ci] = true
          }
        }
      None => ()
    }
    for i in 0..<ncols {
      let col = t.columns[i]
      if !is_given[i] {
        match col.def.default {
          Some(d) => vals[i] = eval_const(d)
          None => ()
        }
      }
      vals[i] = apply_affinity(vals[i], col.aff)
    }
    if t.ipk >= 0 {
      rowid_val = vals[t.ipk]
    }
    let rowid = match rowid_of_value(rowid_val) {
      Some(r) => r
      None => self.new_rowid(t)
    }
    if t.ipk >= 0 {
      vals[t.ipk] = Int(rowid)
    }
    if !self.check_row(t, rowid, vals, ins.or_conflict) {
      return
    }
    let conflicts = find_conflicts(t, rowid, vals, None)
    if conflicts.length() > 0 && upserts.length() > 0 {
      for c in conflicts {
        for up in upserts {
          let hit = match up.targets {
            None => true
            Some(tg) => tg.contains(c.0)
          }
          if !hit {
            continue
          }
          match up.action {
            DoNothing => return
            DoUpdate(_, _) => {
              let old_rowid = c.1
              guard t.rows.get(old_rowid) is Some(old) else { return }
              let env_row = row_with_rowid(old, old_rowid)
              for v in row_with_rowid(vals, rowid) {
                env_row.push(v)
              }
              let env : Env = { row: env_row, parent: None, }
              if up.where_ is Some(w) && truthy(eval(w, env)) != Some(true) {
                return
              }
              let nv = old.copy()
              let mut new_rowid = old_rowid
              for s in up.sets {
                let v = eval(s.1, env)
                if s.0 < 0 {
                  new_rowid = match rowid_of_value(v) {
                    Some(r) => r
                    None => raise SqlError("datatype mismatch")
                  }
                } else {
                  nv[s.0] = apply_affinity(v, t.columns[s.0].aff)
                  if s.0 == t.ipk {
                    new_rowid = match rowid_of_value(nv[s.0]) {
                      Some(r) => r
                      None => raise SqlError("datatype mismatch")
                    }
                  }
                }
              }
              if self.update_row(t, old_rowid, new_rowid, nv, CAbort) {
                emit(new_rowid)
              }
              return
            }
          }
        }
      }
    }
    if !self.resolve_unique(t, conflicts, ins.or_conflict) {
      return
    }
    self.record_insert(t, rowid, vals)
    emit(rowid)
  }
  self.exec_started = true
  let select_rows = match select_plan {
    Some(p) => (p.run)(empty_env)
    None => []
  }
  match ins.source {
    Values(_) =>
      for r in value_rows {
        insert_one(Some(r.map(e => eval(e, empty_env))))
      }
    FromSelect(_) =>
      for r in select_rows {
        insert_one(Some(r))
      }
    DefaultValues => insert_one(None)
  }
  out_rows
}

///|
fn Database::update(
  self : Database,
  up : Update,
) -> Array[Array[Value]] raise SqlError {
  let t = self.table_for_write(up.table)
  let scope = table_scope(t, up.as_name.unwrap_or(t.name))
  let sets : Array[(Int, Expr)] = []
  for s in up.sets {
    let ci = match t.find_column(s.0) {
      Some(ci) => ci
      None =>
        if is_rowid_name(s.0) {
          t.ipk
        } else {
          raise SqlError("no such column: \{s.0}")
        }
    }
    sets.push((ci, bind_expr(s.1, Some(scope))))
  }
  let where_ = match up.where_ {
    Some(w) => Some(bind_expr(w, Some(scope)))
    None => None
  }
  let (ret_exprs, _, _) = expand_result_cols(up.returning, scope)
  self.exec_started = true
  let ids = matching_rowids(scope, where_)
  let out_rows : Array[Array[Value]] = []
  for rowid in ids {
    guard t.rows.get(rowid) is Some(old) else { continue }
    let env : Env = { row: row_with_rowid(old, rowid), parent: None, }
    let nv = old.copy()
    let mut new_rowid = rowid
    for s in sets {
      let v = eval(s.1, env)
      if s.0 < 0 {
        new_rowid = match rowid_of_value(v) {
          Some(r) => r
          None => raise SqlError("datatype mismatch")
        }
      } else {
        nv[s.0] = apply_affinity(v, t.columns[s.0].aff)
        if s.0 == t.ipk {
          new_rowid = match rowid_of_value(nv[s.0]) {
            Some(r) => r
            None => raise SqlError("datatype mismatch")
          }
        }
      }
    }
    if self.update_row(t, rowid, new_rowid, nv, up.or_conflict) &&
      ret_exprs.length() > 0 {
      let renv : Env = { row: row_with_rowid(nv, new_rowid), parent: None, }
      out_rows.push(ret_exprs.map(e => eval(e, renv)))
    }
  }
  out_rows
}

///|
fn Database::delete(
  self : Database,
  del : Delete,
) -> Array[Array[Value]] raise SqlError {
  let t = self.table_for_write(del.table)
  let scope = table_scope(t, del.as_name.unwrap_or(t.name))
  let where_ = match del.where_ {
    Some(w) => Some(bind_expr(w, Some(scope)))
    None => None
  }
  let (ret_exprs, _, _) = expand_result_cols(del.returning, scope)
  self.exec_started = true
  let ids = matching_rowids(scope, where_)
  let out_rows : Array[Array[Value]] = []
  if ret_exprs.length() > 0 {
    for rowid in ids {
      if t.rows.get(rowid) is Some(vals) {
        let env : Env = { row: row_with_rowid(vals, rowid), parent: None, }
        out_rows.push(ret_exprs.map(e => eval(e, env)))
      }
    }
  }
  for rowid in ids {
    self.delete_row(t, rowid)
    self.stmt_changes += 1L
  }
  out_rows
}

///|
fn is_schema_table_name(name : String) -> Bool {
  let n = name.to_lower()
  n == "sqlite_schema" ||
  n == "sqlite_master" ||
  n == "sqlite_temp_schema" ||
  n == "sqlite_temp_master"
}

///|
/// The table targeted by INSERT, UPDATE or DELETE.
fn Database::table_for_write(
  self : Database,
  name : String,
) -> Table raise SqlError {
  if is_schema_table_name(name) {
    raise SqlError("table sqlite_master may not be modified")
  }
  match self.find_table(name) {
    Some(t) => t
    None =>
      if self.find_view(name) is Some(_) {
        raise SqlError("cannot modify \{name} because it is a view")
      } else {
        raise SqlError("no such table: \{name}")
      }
  }
}

///|
/// Rowids of the rows of the scope's single table satisfying `where_`.
fn matching_rowids(
  scope : Scope,
  where_ : Expr?,
) -> Array[Int64] raise SqlError {
  let src = scope.sources[0]
  let n = src.table.columns.length()
  let ids : Array[Int64] = []
  if where_ is None {
    src.table.rows.each_while((rowid, _) => {
      ids.push(rowid)
      true
    })
    return ids
  }
  plan_scan(scope.sources, where_).run(empty_env, env => {
    if env.row[n] is Int(r) {
      ids.push(r)
    }
  })
  ids
}
