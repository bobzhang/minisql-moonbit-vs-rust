///|
fn is_rowid_name(folded : String) -> Bool {
  folded == "rowid" || folded == "oid" || folded == "_rowid_"
}

///|
fn table_scope_entry(
  t : Table,
  name : String,
  offset : Int,
  qualified_only? : Bool = false,
) -> ScopeTable {
  ScopeTable::new(
    name,
    t.columns,
    offset,
    offset + t.columns.length(),
    qualified_only~,
  )
}

///|
fn table_scope(t : Table, name : String) -> Scope {
  Scope::new([table_scope_entry(t, name, 0)], t.columns.length() + 1)
}

///|
/// Resolves a column name used as an assignment target; -1 = the rowid of a
/// table without an INTEGER PRIMARY KEY.
fn Table::target_column(self : Table, n : String) -> Int raise SqlError {
  match self.column_index(n) {
    Some(i) => i
    None =>
      if is_rowid_name(fold_name(n)) {
        if self.ipk >= 0 {
          self.ipk
        } else {
          -1
        }
      } else {
        raise err("table " + self.name + " has no column named " + n)
      }
  }
}

///|
fn Database::bind_returning(
  self : Database,
  scope : Scope,
  cols : Array[ResultCol],
) -> Array[BExpr] raise SqlError {
  let out = []
  for rc in cols {
    match rc {
      Star | TableStar(_) =>
        for st in scope.tables {
          for i, _ in st.columns {
            out.push(st.col_ref(i))
          }
          break
        }
      ExprCol(e, _) => out.push(bind_expr(self, scope, e))
    }
  }
  out
}

///|
fn full_row(row : Array[Value], rowid : Int64) -> Array[Value] {
  [..row, Int(rowid)]
}

///|
fn Database::conflict_error(
  self : Database,
  action : String,
  msg : String,
) -> SqlError {
  if action == "FAIL" {
    self.fail_keep = true
  }
  if action == "ROLLBACK" {
    self.rollback_txn = true
  }
  err(msg)
}

///|
/// Enforces NOT NULL and CHECK constraints on a candidate row. Returns false
/// when the row must be skipped (IGNORE). REPLACE substitutes defaults for
/// NULLs.
fn Database::check_basic(
  self : Database,
  t : Table,
  row : Array[Value],
  rowid : Int64,
  or_action : String?,
) -> Bool raise SqlError {
  for i, c in t.columns {
    if i == t.ipk || !c.def.not_null || !(row[i] is Null) {
      continue
    }
    let msg = "NOT NULL constraint failed: " + t.name + "." + c.name
    let action = match or_action {
      Some(a) => a
      None => c.def.nn_conflict.unwrap_or("ABORT")
    }
    match action {
      "IGNORE" => return false
      "REPLACE" => {
        let dv = match t.defaults[i] {
          Some(d) => eval(d, []).apply_affinity(c.affinity)
          None => Null
        }
        if dv is Null {
          raise self.conflict_error("ABORT", msg)
        }
        row[i] = dv
      }
      a => raise self.conflict_error(a, msg)
    }
  }
  if t.checks.length() > 0 {
    let full = full_row(row, rowid)
    for ch in t.checks {
      if eval(ch.1, full).truth() == Some(false) {
        let msg = if ch.0 == "" {
          "CHECK constraint failed"
        } else {
          "CHECK constraint failed: " + ch.0
        }
        match or_action.unwrap_or("ABORT") {
          "IGNORE" => return false
          "REPLACE" => raise self.conflict_error("ABORT", msg)
          a => raise self.conflict_error(a, msg)
        }
      }
    }
  }
  true
}

///|
priv enum UniqResult {
  UProceed
  USkip
  /// Index of the matching upsert clause and the conflicting rowid.
  UUpsert(Int, Int64)
}

///|
fn Table::unique_error(self : Table, id : Int) -> String {
  let names = if id < 0 {
    if self.ipk >= 0 {
      [self.columns[self.ipk].name]
    } else {
      ["rowid"]
    }
  } else {
    return self.unique_error_for(self.uniques[id])
  }
  "UNIQUE constraint failed: " + names.map(n => self.name + "." + n).join(", ")
}

///|
fn Table::unique_error_for(self : Table, idx : Index) -> String {
  if idx.is_expression() {
    return "UNIQUE constraint failed: index '" + idx.name + "'"
  }
  "UNIQUE constraint failed: " +
  idx.col_idx.map(c => self.name + "." + self.columns[c].name).join(", ")
}

///|
/// Checks the rowid and unique constraints. `targets` holds, per upsert
/// clause, the constraint it covers (-1 rowid, k = uniques[k], -2 any).
fn Database::check_unique(
  self : Database,
  t : Table,
  row : Array[Value],
  rowid : Int64,
  self_rowid : Int64?,
  or_action : String?,
  targets : Array[Int],
) -> UniqResult raise SqlError {
  let action_of = (id : Int) => {
    match or_action {
      Some(a) => a
      None => {
        let c = if id < 0 { t.ipk_conflict } else { t.uniques[id].conflict }
        c.unwrap_or("ABORT")
      }
    }
  }
  let order : Array[Int] = []
  for u in targets {
    if u != -2 && !order.contains(u) {
      order.push(u)
    }
  }
  for replace_pass in [false, true] {
    for id in -1..<t.uniques.length() {
      if !order.contains(id) && (action_of(id) == "REPLACE") == replace_pass {
        order.push(id)
      }
    }
  }
  let full = full_row(row, rowid)
  for id in order {
    let conflict : Int64? = if id < 0 {
      if self_rowid == Some(rowid) {
        None
      } else if t.rows.contains(rowid) {
        Some(rowid)
      } else {
        None
      }
    } else {
      t.uniques[id].find_conflict(full, self_rowid)
    }
    guard conflict is Some(c) else { continue }
    for ui, ut in targets {
      if ut == -2 || ut == id {
        return UUpsert(ui, c)
      }
    }
    match action_of(id) {
      "IGNORE" => return USkip
      "REPLACE" => self.row_delete(t, c)
      a => raise self.conflict_error(a, t.unique_error(id))
    }
  }
  UProceed
}

///|
fn Database::new_rowid(self : Database, t : Table) -> Int64 raise SqlError {
  ignore(self)
  let mut m = t.current_max_rowid()
  if t.autoinc && t.seq > m {
    m = t.seq
  }
  if m < @int64.MAX_VALUE {
    return m + 1L
  }
  if t.autoinc {
    raise err("database or disk full")
  }
  let mut c = 1L
  while t.rows.contains(c) {
    c += 1L
  }
  c
}

///|
fn rowid_of_value(v : Value) -> Int64 raise SqlError {
  match v.apply_affinity(AffInteger) {
    Int(i) => i
    _ => raise err("datatype mismatch")
  }
}

///|
/// Replaces row `rowid` with `row` after constraint checks. Returns the new
/// rowid, or None if the change was skipped.
fn Database::update_row(
  self : Database,
  t : Table,
  rowid : Int64,
  row : Array[Value],
  rowid_val : Value?,
  or_action : String?,
) -> Int64? raise SqlError {
  for i, c in t.columns {
    row[i] = row[i].apply_affinity(c.affinity)
  }
  let mut nid = rowid
  if t.ipk >= 0 {
    nid = rowid_of_value(row[t.ipk])
  } else if rowid_val is Some(v) {
    nid = rowid_of_value(v)
  }
  if !self.check_basic(t, row, nid, or_action) {
    return None
  }
  match self.check_unique(t, row, nid, Some(rowid), or_action, []) {
    USkip => None
    _ => {
      self.row_delete(t, rowid)
      self.row_insert(t, nid, row)
      Some(nid)
    }
  }
}

///|
/// Resolves an upsert target to the constraint it names.
fn Table::upsert_target(
  self : Table,
  cols : Array[String],
) -> Int raise SqlError {
  let idx = cols.map(n => self.target_column(n))
  let set : Set[Int] = Set([])
  for i in idx {
    set.add(i)
  }
  if set.length() == 1 && (idx[0] == -1 || idx[0] == self.ipk) {
    return -1
  }
  for k, u in self.uniques {
    if u.pred is None &&
      !u.is_expression() &&
      u.col_idx.length() == set.length() &&
      u.col_idx.all(c => set.contains(c)) {
      return k
    }
  }
  raise err(
    "ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint",
  )
}

///|
fn Database::exec_insert(
  self : Database,
  ins : Insert,
) -> QueryResult raise SqlError {
  let t = self.writable_table(ins.table)
  let ncols = t.columns.length()
  let targets : Array[Int] = match ins.columns {
    _ if ins.source is InsDefault => []
    Some(names) => names.map(n => t.target_column(n))
    None => Array::makei(ncols, i => i)
  }
  let empty = Scope::empty()
  let source_rows : Array[Array[Value]] = match ins.source {
    InsValues(rows) => {
      let out = []
      for r in rows {
        if r.length() != targets.length() {
          if ins.columns is Some(_) {
            raise err("\{r.length()} values for \{targets.length()} columns")
          } else {
            raise err(
              "table \{t.name} has \{ncols} columns but \{r.length()} values were supplied",
            )
          }
        }
        let bound = r.map(e => bind_expr(self, empty, e))
        out.push(bound.map(b => eval(b, [])))
      }
      out
    }
    InsSelect(sel) => {
      let res = self.run_select(sel)
      if res.columns.length() != targets.length() {
        raise err(
          "table \{t.name} has \{ncols} columns but \{res.columns.length()} values were supplied",
        )
      }
      res.rows
    }
    InsDefault => [[]]
  }
  let name = ins.alias.unwrap_or(t.name)
  let scope = table_scope(t, name)
  let up_scope = Scope::new(
    [
      table_scope_entry(t, name, 0),
      table_scope_entry(t, "excluded", ncols + 1, qualified_only=true),
    ],
    2 * ncols + 2,
  )
  let up_targets = []
  let up_actions = []
  for u in ins.upserts {
    up_targets.push(
      match u.target {
        Some(cols) => t.upsert_target(cols)
        None => -2
      },
    )
    up_actions.push(
      match u.action {
        DoNothing => None
        DoUpdate(sets, w) =>
          Some(
            (
              sets.map(s => {
                (t.target_column(s.0), bind_expr(self, up_scope, s.1))
              }),
              w.map(x => bind_expr(self, up_scope, x)),
            ),
          )
      },
    )
  }
  let returning = self.bind_returning(scope, ins.returning)
  let out = []
  self.in_dml = true
  for src in source_rows {
    let row = Array::make(ncols, Null)
    let supplied = Array::make(ncols, false)
    let mut rowid_val : Value = Null
    for k, ci in targets {
      if ci < 0 {
        rowid_val = src[k]
      } else {
        row[ci] = src[k]
        supplied[ci] = true
      }
    }
    for i, c in t.columns {
      if !supplied[i] {
        row[i] = match t.defaults[i] {
          Some(d) => eval(d, [])
          None => Null
        }
      }
      row[i] = row[i].apply_affinity(c.affinity)
    }
    let rv = if t.ipk >= 0 { row[t.ipk] } else { rowid_val }
    let rowid = match rv {
      Null => self.new_rowid(t)
      v => rowid_of_value(v)
    }
    if t.ipk >= 0 {
      row[t.ipk] = Int(rowid)
    }
    if !self.check_basic(t, row, rowid, ins.or_action) {
      continue
    }
    match self.check_unique(t, row, rowid, None, ins.or_action, up_targets) {
      USkip => continue
      UProceed => {
        self.row_insert(t, rowid, row)
        if t.autoinc && rowid > t.seq {
          self.set_seq(t, rowid)
        }
        self.last_rowid = rowid
        self.stmt_changes += 1L
        if returning.length() > 0 {
          let full = full_row(row, rowid)
          out.push(returning.map(e => eval(e, full)))
        }
      }
      UUpsert(ui, crow) =>
        match up_actions[ui] {
          None => continue
          Some((sets, w)) => {
            guard t.rows.get(crow) is Some(old) else { continue }
            let combined = [..old, Int(crow), ..row, Int(rowid)]
            if w is Some(x) && eval(x, combined).truth() != Some(true) {
              continue
            }
            let newrow = old.copy()
            let mut nrv : Value? = None
            for s in sets {
              let v = eval(s.1, combined)
              if s.0 < 0 {
                nrv = Some(v)
              } else {
                newrow[s.0] = v
              }
            }
            match self.update_row(t, crow, newrow, nrv, Some("ABORT")) {
              Some(nid) => {
                self.stmt_changes += 1L
                if returning.length() > 0 {
                  let full = full_row(newrow, nid)
                  out.push(returning.map(e => eval(e, full)))
                }
              }
              None => ()
            }
          }
        }
    }
  }
  { columns: [], rows: out, }
}

///|
fn Database::exec_update(
  self : Database,
  upd : Update,
) -> QueryResult raise SqlError {
  let t = self.writable_table(upd.table)
  dml_target.val = true
  let (scope, produce) = self.compile_source(
    Some(TableRef(t.name, upd.alias)),
    upd.where_,
    None,
    { val: false, },
  )
  let sets = upd.sets.map(s => {
    let ci = match t.column_index(s.0) {
      Some(i) => i
      None =>
        if is_rowid_name(fold_name(s.0)) {
          if t.ipk >= 0 {
            t.ipk
          } else {
            -1
          }
        } else {
          raise err("no such column: " + s.0)
        }
    }
    (ci, bind_expr(self, scope, s.1))
  })
  let returning = self.bind_returning(scope, upd.returning)
  self.in_dml = true
  let ncols = t.columns.length()
  let ids = produce().map(r => r[ncols].as_int64())
  ids.sort()
  let out = []
  for id in ids {
    guard t.rows.get(id) is Some(old) else { continue }
    let full = full_row(old, id)
    let newrow = old.copy()
    let mut rv : Value? = None
    for s in sets {
      let v = eval(s.1, full)
      if s.0 < 0 {
        rv = Some(v)
      } else {
        newrow[s.0] = v
      }
    }
    match self.update_row(t, id, newrow, rv, upd.or_action) {
      Some(nid) => {
        self.stmt_changes += 1L
        if returning.length() > 0 {
          let f = full_row(newrow, nid)
          out.push(returning.map(e => eval(e, f)))
        }
      }
      None => ()
    }
  }
  { columns: [], rows: out, }
}

///|
fn Database::exec_delete(
  self : Database,
  del : Delete,
) -> QueryResult raise SqlError {
  let t = self.writable_table(del.table)
  dml_target.val = true
  let (scope, produce) = self.compile_source(
    Some(TableRef(t.name, del.alias)),
    del.where_,
    None,
    { val: false, },
  )
  let returning = self.bind_returning(scope, del.returning)
  self.in_dml = true
  let ncols = t.columns.length()
  let ids = produce().map(r => r[ncols].as_int64())
  ids.sort()
  let out = []
  for id in ids {
    guard t.rows.get(id) is Some(old) else { continue }
    if returning.length() > 0 {
      let f = full_row(old, id)
      out.push(returning.map(e => eval(e, f)))
    }
    self.row_delete(t, id)
    self.stmt_changes += 1L
  }
  { columns: [], rows: out, }
}

///|
/// The table targeted by INSERT, UPDATE or DELETE.
fn Database::writable_table(
  self : Database,
  name : String,
) -> Table raise SqlError {
  match self.find_table(name) {
    Some(t) => t
    None =>
      if self.views.contains(fold_name(name)) {
        raise err("cannot modify " + name + " because it is a view")
      } else if is_schema_table_name(name) {
        raise err("table sqlite_master may not be modified")
      } else {
        raise err("no such table: " + name)
      }
  }
}
