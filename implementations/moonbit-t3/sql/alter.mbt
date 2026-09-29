///|
fn Database::alter_table(
  self : Database,
  name : String,
  action : AlterAction,
) -> Unit raise SqlError {
  guard self.find_table(name) is Some(t) else {
    if self.views.contains(fold_name(name)) {
      match action {
        AddColumn(_) => raise err("Cannot add a column to a view")
        _ => raise err("view " + name + " may not be altered")
      }
    }
    raise err("no such table: " + name)
  }
  if fold_name(t.name).has_prefix("sqlite_") {
    raise err("table " + t.name + " may not be altered")
  }
  match action {
    RenameTable(new_name) => self.rename_table(t, new_name)
    RenameColumn(old, new_name) => self.rename_column(t, old, new_name)
    AddColumn(cd) => self.add_column(t, cd)
    DropColumn(col) => self.drop_column(t, col)
  }
}

///|
/// Rewrites every view with the renamer (undoable).
fn Database::rewrite_views(self : Database, r : Renamer) -> Unit {
  for _, v in self.views {
    let old = v.select
    v.select = r.select(old, [])
    self.undo.push(UFn(() => v.select = old))
  }
}

///|
fn Database::rename_table(
  self : Database,
  t : Table,
  new_name : String,
) -> Unit raise SqlError {
  if self.object_kind(new_name) is Some(_) {
    raise err(
      "there is already another table or index with this name: " + new_name,
    )
  }
  check_reserved_name(new_name)
  let old_name = t.name
  let r : Renamer = {
    db: self,
    table: fold_name(old_name),
    old_col: "",
    new_col: "",
    new_table: new_name,
  }
  let valid = self.valid_views()
  self.rewrite_views(r)
  let old_def = t.def
  let set_name = (n : String, def : CreateTable) => {
    self.unregister_table_raw(t)
    t.name = n
    t.def = def
    for idx in t.indexes {
      idx.table = n
      if idx.auto_num > 0 {
        idx.name = "sqlite_autoindex_" + n + "_" + idx.auto_num.to_string()
      }
    }
    self.tables[fold_name(n)] = t
    for idx in t.indexes {
      self.indexes[fold_name(idx.name)] = idx
    }
  }
  set_name(new_name, r.table_def(old_def))
  self.undo.push(UFn(() => set_name(old_name, old_def)))
  let old_f = fold_name(old_name)
  self.rewrite_schema_sql(s => rename_table_sql(s, old_f, new_name))
  self.recheck_views(valid, "rename")
}

///|
/// Replaces `t` by a table built from `def`, with rows transformed by
/// `row_map` and explicit indexes rebuilt from the given definitions.
fn Database::rebuild_table(
  self : Database,
  t : Table,
  def : CreateTable,
  row_map : (Array[Value]) -> Array[Value],
  index_defs : Array[(Index, Array[IndexedCol], Expr?)],
) -> Unit raise SqlError {
  let nt = self.build_table(def, t.sql)
  nt.schema_seq = t.schema_seq
  nt.seq = t.seq
  for idx in nt.indexes {
    let mut seq = -1
    for old in t.indexes {
      if old.auto_num == idx.auto_num {
        seq = old.seq
      }
    }
    idx.seq = if seq >= 0 { seq } else { self.next_seq() }
  }
  for id, r in t.rows {
    nt.raw_put(id, row_map(r))
  }
  for d in index_defs {
    let old = d.0
    let idx = self.build_index(nt, old.name, old.unique, d.1, d.2, old.sql)
    idx.seq = old.seq
    nt.attach_index(idx)
  }
  self.unregister_table_raw(t)
  self.tables[fold_name(nt.name)] = nt
  for idx in nt.indexes {
    self.indexes[fold_name(idx.name)] = idx
  }
  self.undo.push(
    UFn(() => {
      self.unregister_table_raw(nt)
      self.tables[fold_name(t.name)] = t
      for idx in t.indexes {
        self.indexes[fold_name(idx.name)] = idx
      }
    }),
  )
}

///|
fn explicit_index_defs(t : Table) -> Array[(Index, Array[IndexedCol], Expr?)] {
  t.indexes.filter(i => i.auto_num == 0).map(i => (i, i.cols, i.where_))
}

///|
fn Database::rename_column(
  self : Database,
  t : Table,
  old : String,
  new_name : String,
) -> Unit raise SqlError {
  guard t.column_index(old) is Some(_) else {
    raise err("no such column: \"" + old + "\"")
  }
  if t.column_index(new_name) is Some(_) {
    raise err("duplicate column name: " + new_name)
  }
  let r : Renamer = {
    db: self,
    table: fold_name(t.name),
    old_col: fold_name(old),
    new_col: new_name,
    new_table: "",
  }
  let defs = explicit_index_defs(t).map(d => {
    (
      d.0,
      d.1.map(c => { ..c, expr: r.table_expr(c.expr), }),
      d.2.map(w => r.table_expr(w)),
    )
  })
  let valid = self.valid_views()
  self.rebuild_table(t, r.table_def(t.def), row => row, defs)
  self.rewrite_views(r)
  let old_f = fold_name(old)
  if self.find_table(t.name) is Some(nt) {
    nt.sql = t.sql.map(s => {
      rename_column_sql(s, old_f, new_name, from=after_create_name)
    })
    for idx in nt.indexes {
      idx.sql = idx.sql.map(s => {
        rename_column_sql(s, old_f, new_name, from=after_index_table)
      })
    }
  }
  let tf = fold_name(t.name)
  for _, v in self.views {
    if v.sql is Some(s) && !v.temp && sql_mentions(s, tf) {
      let before = v.sql
      v.sql = Some(rename_column_sql(s, old_f, new_name, from=after_view_as))
      self.undo.push(UFn(() => v.sql = before))
    }
  }
  self.recheck_views(valid, "rename")
}

///|
fn Database::add_column(
  self : Database,
  t : Table,
  cd : ColumnDef,
) -> Unit raise SqlError {
  if t.column_index(cd.name) is Some(_) {
    raise err("duplicate column name: " + cd.name)
  }
  if cd.primary_key {
    raise err("Cannot add a PRIMARY KEY column")
  }
  if cd.unique {
    raise err("Cannot add a UNIQUE column")
  }
  let mut dv : Value = Null
  if cd.default is Some(e) {
    let simple = match e {
      Lit(_) | Unary(Neg | Pos, Lit(_)) => true
      _ => false
    }
    if !is_constant_expr(e) || (!simple && t.rows.length() > 0) {
      raise err("Cannot add a column with non-constant default")
    }
    dv = eval(bind_expr(self, Scope::empty(), e), []).apply_affinity(
      affinity_of_type(cd.type_name),
    )
  }
  if cd.not_null && dv is Null && t.rows.length() > 0 {
    raise err("Cannot add a NOT NULL column with default value NULL")
  }
  let def = { ..t.def, columns: [..t.def.columns, cd], }
  self.rebuild_table(t, def, row => [..row, dv], explicit_index_defs(t))
  // CHECK constraints of the new column apply to the existing rows.
  guard self.find_table(t.name) is Some(nt) else { return }
  nt.sql = t.sql.map(s => add_column_sql(s, self.cur_sql))
  if nt.checks.length() > 0 {
    for id, row in nt.rows {
      let full = full_row(row, id)
      for ch in nt.checks {
        if eval(ch.1, full).truth() == Some(false) {
          raise err("CHECK constraint failed")
        }
      }
    }
  }
}

///|
fn Database::drop_column(
  self : Database,
  t : Table,
  col : String,
) -> Unit raise SqlError {
  guard t.column_index(col) is Some(ci) else {
    raise err("no such column: \"" + col + "\"")
  }
  let f = fold_name(col)
  if t.columns.length() == 1 {
    raise err("cannot drop column \"" + col + "\": no other columns exist")
  }
  let cd = t.def.columns[ci]
  if cd.primary_key {
    raise err("cannot drop PRIMARY KEY column: \"" + col + "\"")
  }
  if cd.unique {
    raise err("cannot drop UNIQUE column: \"" + col + "\"")
  }
  for tc in t.def.constraints {
    match tc {
      PrimaryKey(cols, _) =>
        if cols.any(c => fold_name(c.0) == f) {
          raise err("cannot drop PRIMARY KEY column: \"" + col + "\"")
        }
      Unique(cols, _) =>
        if cols.any(c => fold_name(c.0) == f) {
          raise err("cannot drop UNIQUE column: \"" + col + "\"")
        }
      Check(e) =>
        if expr_uses_column(e, f) {
          raise err("error in table " + t.name + " after drop column")
        }
      ForeignKey(cols, _, _) =>
        if cols.any(c => fold_name(c) == f) {
          raise err("error in table " + t.name + " after drop column")
        }
    }
  }
  for i, other in t.def.columns {
    if i != ci && other.checks.any(e => expr_uses_column(e, f)) {
      raise err("error in table " + t.name + " after drop column")
    }
  }
  for idx in t.indexes {
    if idx.cols.any(c => expr_uses_column(c.expr, f)) ||
      (idx.where_ is Some(w) && expr_uses_column(w, f)) {
      raise err("error in index " + idx.name + " after drop column")
    }
  }
  let def = {
    ..t.def,
    columns: t.def.columns.filter(c => fold_name(c.name) != f),
  }
  let valid_views = self.valid_views()
  self.rebuild_table(
    t,
    def,
    row => {
      let out = []
      for i, v in row {
        if i != ci {
          out.push(v)
        }
      }
      out
    },
    explicit_index_defs(t),
  )
  if self.find_table(t.name) is Some(nt) {
    nt.sql = t.sql.map(s => drop_column_sql(s, ci))
  }
  self.recheck_views(valid_views, "drop column")
}

///|
/// Views that currently compile.
fn Database::valid_views(self : Database) -> Array[View] {
  self.views.values().filter(v => self.view_compiles(v)).to_array()
}

///|
/// Fails if a schema change broke one of the given views.
fn Database::recheck_views(
  self : Database,
  views : Array[View],
  what : String,
) -> Unit raise SqlError {
  for v in views {
    if !self.view_compiles(v) {
      raise err("error in view " + v.name + " after " + what)
    }
  }
}

///|
fn Database::view_compiles(self : Database, v : View) -> Bool {
  self.expanding.clear()
  let ok = try {
    self.compile_select(v.select, None, { val: false, }) |> ignore
    true
  } catch {
    _ => false
  }
  self.expanding.clear()
  ok
}

///|
/// Applies `f` to the stored text of every schema object (undoable).
fn Database::rewrite_schema_sql(
  self : Database,
  f : (String) -> String,
) -> Unit {
  for _, t in self.tables {
    if t.sql is Some(s) {
      let n = f(s)
      if n != s {
        t.sql = Some(n)
        self.undo.push(UFn(() => t.sql = Some(s)))
      }
    }
  }
  for _, idx in self.indexes {
    if idx.sql is Some(s) {
      let n = f(s)
      if n != s {
        idx.sql = Some(n)
        self.undo.push(UFn(() => idx.sql = Some(s)))
      }
    }
  }
  for _, v in self.views {
    if v.sql is Some(s) {
      let n = f(s)
      if n != s {
        v.sql = Some(n)
        self.undo.push(UFn(() => v.sql = Some(s)))
      }
    }
  }
}
