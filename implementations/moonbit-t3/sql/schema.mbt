///|
/// True if the expression contains a subquery.
fn has_subquery(e : Expr) -> Bool {
  let mut found = false
  walk_expr(e, x => {
    if x is (Subquery(_) | Exists(_, _) | InSelect(_, _, _)) {
      found = true
    }
  })
  found
}

///|
/// Calls `f` on every expression node (not descending into subqueries).
fn walk_expr(e : Expr, f : (Expr) -> Unit) -> Unit {
  f(e)
  match e {
    Lit(_) | Column(_, _, _) | Param(_) | AggSlot(_) => ()
    Subquery(_) | Exists(_, _) => ()
    InSelect(x, _, _) => walk_expr(x, f)
    Unary(_, x) | IsNull(x, _) | Cast(x, _) | Collate(x, _) => walk_expr(x, f)
    Binary(_, l, r) => {
      walk_expr(l, f)
      walk_expr(r, f)
    }
    Between(x, l, h, _) => {
      walk_expr(x, f)
      walk_expr(l, f)
      walk_expr(h, f)
    }
    InList(x, items, _) => {
      walk_expr(x, f)
      for i in items {
        walk_expr(i, f)
      }
    }
    Like(_, l, p, esc, _) => {
      walk_expr(l, f)
      walk_expr(p, f)
      if esc is Some(x) {
        walk_expr(x, f)
      }
    }
    Case(b, whens, els) => {
      if b is Some(x) {
        walk_expr(x, f)
      }
      for w in whens {
        walk_expr(w.0, f)
        walk_expr(w.1, f)
      }
      if els is Some(x) {
        walk_expr(x, f)
      }
    }
    Func(fc) => {
      for a in fc.args {
        walk_expr(a, f)
      }
      if fc.filter is Some(x) {
        walk_expr(x, f)
      }
    }
  }
}

///|
/// True if the expression references column `col` (folded) of the table.
fn expr_uses_column(e : Expr, col : String) -> Bool {
  let mut found = false
  walk_expr(e, x => {
    if x is Column(_, n, _) && fold_name(n) == col {
      found = true
    }
  })
  found
}

///|
/// Builds an index over `t` from its definition and fills it with the
/// table's rows.
fn Database::build_index(
  self : Database,
  t : Table,
  name : String,
  unique : Bool,
  cols : Array[IndexedCol],
  where_ : Expr?,
  sql : String?,
) -> Index raise SqlError {
  let scope = table_scope(t, t.name)
  let keys = []
  let colls = []
  let col_idx = []
  for c in cols {
    if has_subquery(c.expr) {
      raise err("subqueries prohibited in index expressions")
    }
    let b = bind_expr(self, scope, c.expr)
    if slot_range(b).1 >= t.columns.length() {
      raise err("no such column: rowid")
    }
    col_idx.push(
      match b {
        BCol(i, _, _) if i < t.columns.length() => i
        _ => -1
      },
    )
    colls.push(
      match c.collate {
        Some(n) => check_coll(coll_of_name(n))
        None => check_coll(b.collation().unwrap_or(CBinary))
      },
    )
    keys.push(b)
  }
  let pred = match where_ {
    Some(w) => {
      if has_subquery(w) {
        raise err("subqueries prohibited in partial index WHERE clauses")
      }
      let b = bind_expr(self, scope, w)
      if slot_range(b).1 >= t.columns.length() {
        raise err("no such column: rowid")
      }
      Some(b)
    }
    None => None
  }
  let idx : Index = {
    name,
    table: t.name,
    unique,
    auto_num: 0,
    conflict: None,
    cols,
    where_,
    col_idx,
    colls,
    descs: cols.map(c => c.desc),
    keys,
    pred,
    tree: SortedChunks::new(),
    seq: 0,
    sql,
  }
  for id, r in t.rows {
    let full = full_row(r, id)
    if unique && idx.find_conflict(full, None) is Some(_) {
      raise err(t.unique_error_for(idx))
    }
    idx.add_row(full, id, r)
  }
  idx
}

///|
/// Attaches an explicit index to its table (newest unique index is checked
/// first, as in SQLite).
fn Table::attach_index(self : Table, idx : Index) -> Unit {
  self.indexes.push(idx)
  if idx.unique {
    self.uniques.insert(0, idx)
  }
}

///|
fn Table::detach_index(self : Table, idx : Index) -> Unit {
  self.indexes.retain(x => !physical_equal(x, idx))
  self.uniques.retain(x => !physical_equal(x, idx))
}

///|
fn Database::create_index(
  self : Database,
  ci : CreateIndex,
) -> Unit raise SqlError {
  match self.object_kind(ci.name) {
    Some("index") => {
      if ci.if_not_exists {
        return
      }
      raise err("index " + ci.name + " already exists")
    }
    Some(kind) => raise err("there is already a " + kind + " named " + ci.name)
    None => ()
  }
  check_reserved_name(ci.name)
  guard self.find_table(ci.table) is Some(t) else {
    if self.views.contains(fold_name(ci.table)) {
      raise err("views may not be indexed")
    }
    raise err("no such table: main." + ci.table)
  }
  if fold_name(t.name).has_prefix("sqlite_") {
    raise err("table " + t.name + " may not be indexed")
  }
  let idx = self.build_index(
    t,
    ci.name,
    ci.unique,
    ci.cols,
    ci.where_,
    Some(normalize_create_sql(self.cur_sql)),
  )
  idx.seq = self.next_seq()
  t.attach_index(idx)
  self.indexes[fold_name(idx.name)] = idx
  self.undo.push(
    UFn(() => {
      t.detach_index(idx)
      self.indexes.remove(fold_name(idx.name))
    }),
  )
}

///|
fn Database::drop_index(
  self : Database,
  name : String,
  if_exists : Bool,
) -> Unit raise SqlError {
  guard self.indexes.get(fold_name(name)) is Some(idx) else {
    if if_exists {
      return
    }
    raise err("no such index: " + name)
  }
  if idx.auto_num > 0 {
    raise err(
      "index associated with UNIQUE or PRIMARY KEY constraint cannot be dropped",
    )
  }
  guard self.find_table(idx.table) is Some(t) else { return }
  let pos = t.indexes.search_by(x => physical_equal(x, idx))
  let upos = t.uniques.search_by(x => physical_equal(x, idx))
  t.detach_index(idx)
  self.indexes.remove(fold_name(idx.name))
  self.undo.push(
    UFn(() => {
      if pos is Some(p) {
        t.indexes.insert(p, idx)
      }
      if upos is Some(p) {
        t.uniques.insert(p, idx)
      }
      self.indexes[fold_name(idx.name)] = idx
    }),
  )
}

///|
fn Database::create_view(
  self : Database,
  cv : CreateView,
) -> Unit raise SqlError {
  match self.object_kind(cv.name) {
    Some("index") => raise err("there is already an index named " + cv.name)
    Some(kind) => {
      if cv.if_not_exists {
        return
      }
      raise err(kind + " " + cv.name + " already exists")
    }
    None => ()
  }
  check_reserved_name(cv.name)
  let v : View = {
    name: cv.name,
    temp: cv.temp,
    columns: cv.columns,
    select: cv.select,
    seq: self.next_seq(),
    sql: Some(normalize_create_sql(self.cur_sql)),
  }
  let f = fold_name(cv.name)
  self.views[f] = v
  self.undo.push(UFn(() => self.views.remove(f)))
}

///|
fn Database::drop_view(
  self : Database,
  name : String,
  if_exists : Bool,
) -> Unit raise SqlError {
  let f = fold_name(name)
  guard self.views.get(f) is Some(v) else {
    if self.tables.contains(f) {
      raise err("use DROP TABLE to delete table " + name)
    }
    if if_exists {
      return
    }
    raise err("no such view: " + name)
  }
  self.views.remove(f)
  self.undo.push(UFn(() => self.views[f] = v))
}

///|
/// Rows of sqlite_schema: type, name, tbl_name, rootpage, sql.
fn Database::schema_rows(
  self : Database,
  temp? : Bool = false,
) -> Array[Array[Value]] {
  let entries : Array[(Int, Array[Value])] = []
  let sql_value = (s : String?) => {
    match s {
      Some(x) => Text(x)
      None => Null
    }
  }
  for _, t in self.tables {
    if t.def.temp != temp {
      continue
    }
    entries.push(
      (
        t.schema_seq,
        [Text("table"), Text(t.name), Text(t.name), Int(0L), sql_value(t.sql)],
      ),
    )
  }
  for _, idx in self.indexes {
    let idx_temp = match self.find_table(idx.table) {
      Some(t) => t.def.temp
      None => false
    }
    if idx_temp != temp {
      continue
    }
    entries.push(
      (
        idx.seq,
        [
          Text("index"),
          Text(idx.name),
          Text(idx.table),
          Int(0L),
          sql_value(idx.sql),
        ],
      ),
    )
  }
  for _, v in self.views {
    if v.temp != temp {
      continue
    }
    entries.push(
      (
        v.seq,
        [Text("view"), Text(v.name), Text(v.name), Int(0L), sql_value(v.sql)],
      ),
    )
  }
  if self.sequence_seq > 0 && !temp {
    entries.push(
      (
        self.sequence_seq,
        [
          Text("table"),
          Text("sqlite_sequence"),
          Text("sqlite_sequence"),
          Int(0L),
          Text("CREATE TABLE sqlite_sequence(name,seq)"),
        ],
      ),
    )
  }
  entries.sort_by((a, b) => a.0 - b.0)
  let rootpage = 1L
  entries.mapi((i, e) => {
    let row = e.1
    row[3] = if row[0] is Text("view") {
      Int(0L)
    } else {
      Int(rootpage + i.to_int64() + 1L)
    }
    row
  })
}

///|
/// A read-only table holding the current contents of sqlite_schema.
fn Database::schema_table(self : Database, name : String) -> Table {
  virtual_table(
    name,
    ["type", "name", "tbl_name", "rootpage", "sql"],
    [AffText, AffText, AffText, AffInteger, AffText],
    self.schema_rows(temp=fold_name(name).has_prefix("sqlite_temp")),
  )
}

///|
/// A read-only table holding the contents of sqlite_sequence.
fn Database::sequence_table(self : Database, name : String) -> Table {
  let tables = self.tables
    .values()
    .filter(t => t.autoinc && t.seq != 0L)
    .to_array()
  tables.sort_by((a, b) => a.schema_seq - b.schema_seq)
  virtual_table(
    name,
    ["name", "seq"],
    [AffNone, AffNone],
    tables.map(t => [Text(t.name), Int(t.seq)]),
  )
}

///|
fn virtual_table(
  name : String,
  names : Array[String],
  affs : Array[Affinity],
  data : Array[Array[Value]],
) -> Table {
  let ct : CreateTable = {
    name,
    if_not_exists: false,
    temp: false,
    columns: names.map(n => simple_column(n).def),
    constraints: [],
  }
  let columns = ct.columns.mapi((i, cd) => {
    name: cd.name,
    type_name: "",
    affinity: affs[i],
    coll: CBinary,
    def: cd,
  })
  let rows = SortedChunks::new()
  for i, r in data {
    rows.set(i.to_int64() + 1L, r)
  }
  {
    name,
    columns,
    def: ct,
    rows,
    max_rowid: rows.length().to_int64(),
    max_dirty: false,
    ipk: -1,
    ipk_conflict: None,
    autoinc: false,
    seq: 0L,
    uniques: [],
    indexes: [],
    checks: [],
    defaults: Array::make(names.length(), None),
    version: 0,
    schema_seq: 0,
    sql: None,
  }
}

///|
fn is_schema_table_name(name : String) -> Bool {
  let f = fold_name(name)
  f == "sqlite_schema" ||
  f == "sqlite_master" ||
  f == "sqlite_temp_schema" ||
  f == "sqlite_temp_master"
}
