// Schema objects: indexes, views, DROP, ALTER TABLE and sqlite_schema.

///|
pub fn Database::find_view(self : Database, name : String) -> View? {
  self.views.get(name_key(name))
}

///|
/// The table owning the index `name` and the index's position.
fn Database::find_index(self : Database, name : String) -> (Table, Int)? {
  for _, t in self.tables {
    for j, idx in t.indexes {
      if idx.name.equal_ignore_ascii_case(name) {
        return Some((t, j))
      }
    }
  }
  None
}

///|
fn is_reserved_name(name : String) -> Bool {
  name.to_lower().has_prefix("sqlite_")
}

// ---------------------------------------------------------------------------
// DROP TABLE / CREATE INDEX / DROP INDEX / CREATE VIEW / DROP VIEW
// ---------------------------------------------------------------------------

///|
fn Database::drop_table(
  self : Database,
  name : String,
  if_exists : Bool,
) -> Unit raise SqlError {
  if is_schema_table_name(name) {
    raise SqlError("table sqlite_master may not be dropped")
  }
  match self.find_table(name) {
    Some(_) => self.tables.remove(name_key(name))
    None =>
      if self.find_view(name) is Some(_) {
        raise SqlError("use DROP VIEW to delete view \{name}")
      } else if !if_exists {
        raise SqlError("no such table: \{name}")
      }
  }
}

///|
fn Database::create_index(
  self : Database,
  ci : CreateIndex,
) -> Unit raise SqlError {
  let t = match self.find_table(ci.table) {
    Some(t) => t
    None =>
      if self.find_view(ci.table) is Some(_) {
        raise SqlError("views may not be indexed")
      } else if is_schema_table_name(ci.table) {
        raise SqlError("table sqlite_master may not be indexed")
      } else {
        raise SqlError("no such table: main.\{ci.table}")
      }
  }
  if is_reserved_name(ci.name) {
    raise SqlError("object name reserved for internal use: \{ci.name}")
  }
  if self.find_table(ci.name) is Some(_) || self.find_view(ci.name) is Some(_) {
    raise SqlError("there is already a table named \{ci.name}")
  }
  if self.find_index(ci.name) is Some(_) {
    if ci.if_not_exists {
      return
    }
    raise SqlError("index \{ci.name} already exists")
  }
  let idx = build_index(
    t,
    ci.name,
    unique=ci.unique,
    origin=0,
    conflict=CDefault,
    parts=ci.parts,
    where_src=ci.where_,
    sql=Some(ci.sql),
    seq=next_schema_seq(),
  )
  idx.populate(t)
  let list = t.indexes.copy()
  list.push(idx)
  t.indexes = list
}

///|
fn Database::drop_index(
  self : Database,
  name : String,
  if_exists : Bool,
) -> Unit raise SqlError {
  match self.find_index(name) {
    Some((t, j)) => {
      if t.indexes[j].origin != 0 {
        raise SqlError(
          "index associated with UNIQUE or PRIMARY KEY constraint cannot be dropped",
        )
      }
      let list = t.indexes.copy()
      ignore(list.remove(j))
      t.indexes = list
    }
    None => if !if_exists { raise SqlError("no such index: \{name}") }
  }
}

///|
fn Database::create_view(
  self : Database,
  cv : CreateView,
) -> Unit raise SqlError {
  if is_reserved_name(cv.name) {
    raise SqlError("object name reserved for internal use: \{cv.name}")
  }
  if self.find_table(cv.name) is Some(_) {
    if cv.if_not_exists {
      return
    }
    raise SqlError("table \{cv.name} already exists")
  }
  if self.find_view(cv.name) is Some(_) {
    if cv.if_not_exists {
      return
    }
    raise SqlError("view \{cv.name} already exists")
  }
  if self.find_index(cv.name) is Some(_) {
    raise SqlError("there is already an index named \{cv.name}")
  }
  self.views[name_key(cv.name)] = {
    name: cv.name,
    cols: cv.cols,
    query: cv.query,
    sql: cv.sql,
    schema_seq: next_schema_seq(),
  }
}

///|
fn Database::drop_view(
  self : Database,
  name : String,
  if_exists : Bool,
) -> Unit raise SqlError {
  match self.find_view(name) {
    Some(_) => self.views.remove(name_key(name))
    None =>
      if self.find_table(name) is Some(_) {
        raise SqlError("use DROP TABLE to delete table \{name}")
      } else if !if_exists {
        raise SqlError("no such view: \{name}")
      }
  }
}

///|
/// Views being expanded (to detect circular definitions).
let expanding_views : Array[String] = []

///|
/// Prepares the query of a view used in FROM.
fn Database::prepare_view(self : Database, v : View) -> Prepared raise SqlError {
  let key = name_key(v.name)
  if expanding_views.contains(key) {
    raise SqlError("view \{v.name} is circularly defined")
  }
  expanding_views.push(key)
  defer ignore(expanding_views.pop())
  let p = without_ctes(() => self.prepare_query(v.query, None)) catch {
    SqlError(msg) =>
      if msg.has_prefix("no such table: ") &&
        !msg.has_prefix("no such table: main.") {
        raise SqlError("no such table: main." + msg[15:].to_owned())
      } else {
        raise SqlError(msg)
      }
  }
  match v.cols {
    Some(cols) => {
      if cols.length() != p.names.length() {
        raise SqlError(
          "expected \{cols.length()} columns for '\{v.name}' but got \{p.names.length()}",
        )
      }
      { ..p, names: cols, }
    }
    None => p
  }
}

// ---------------------------------------------------------------------------
// sqlite_schema
// ---------------------------------------------------------------------------

///|
fn Database::schema_rows(self : Database) -> Array[Array[Value]] {
  let rows : Array[(Int, Array[Value])] = []
  for _, t in self.tables {
    rows.push(
      (
        t.schema_seq,
        [
          Text("table"),
          Text(t.name),
          Text(t.name),
          Int(t.rootpage.to_int64()),
          Text(t.sql),
        ],
      ),
    )
    for idx in t.indexes {
      rows.push(
        (
          idx.seq,
          [
            Text("index"),
            Text(idx.name),
            Text(t.name),
            Int(idx.rootpage.to_int64()),
            match idx.sql {
              Some(s) => Text(s)
              None => Null
            },
          ],
        ),
      )
    }
  }
  if self.sequence_seq > 0 {
    rows.push(
      (
        self.sequence_seq,
        [
          Text("table"),
          Text("sqlite_sequence"),
          Text("sqlite_sequence"),
          Int(self.sequence_root.to_int64()),
          Text("CREATE TABLE sqlite_sequence(name,seq)"),
        ],
      ),
    )
  }
  for _, v in self.views {
    rows.push(
      (
        v.schema_seq,
        [Text("view"), Text(v.name), Text(v.name), Int(0L), Text(v.sql)],
      ),
    )
  }
  rows.sort_by((a, b) => a.0 - b.0)
  rows.map(r => r.1)
}

///|
/// Rows of sqlite_sequence: AUTOINCREMENT tables that have had rows.
fn Database::sequence_rows(self : Database) -> Array[Array[Value]] {
  let ts = self.tables.values().filter(t => t.autoinc && t.seq != 0L).to_array()
  ts.sort_by((a, b) => a.schema_seq - b.schema_seq)
  ts.map(t => [Text(t.name), Int(t.seq)])
}

///|
fn Database::sequence_prepared(self : Database) -> Prepared {
  {
    names: ["name", "seq"],
    affs: [None, None],
    colls: [None, None],
    run: _ => self.sequence_rows(),
    correlated: { val: false, },
  }
}

///|
fn Database::schema_prepared(self : Database) -> Prepared {
  let names = ["type", "name", "tbl_name", "rootpage", "sql"]
  {
    names,
    affs: [
      Some(AffText),
      Some(AffText),
      Some(AffText),
      Some(AffInteger),
      Some(AffText),
    ],
    colls: [None, None, None, None, None],
    run: _ => self.schema_rows(),
    correlated: { val: false, },
  }
}

// ---------------------------------------------------------------------------
// ALTER TABLE
// ---------------------------------------------------------------------------

///|
fn Database::alter_table(
  self : Database,
  name : String,
  action : AlterAction,
) -> Unit raise SqlError {
  if is_schema_table_name(name) {
    raise SqlError("table sqlite_master may not be altered")
  }
  let t = match self.find_table(name) {
    Some(t) => t
    None =>
      if self.find_view(name) is Some(_) {
        raise SqlError(
          match action {
            RenameTo(_) => "view \{name} may not be altered"
            RenameColumn(_, _) => "cannot rename columns of view \"\{name}\""
            AddColumn(_, _) => "Cannot add a column to a view"
            DropColumn(_) => "cannot drop column from view \"\{name}\""
          },
        )
      } else {
        raise SqlError("no such table: \{name}")
      }
  }
  match action {
    RenameTo(new_name) => self.rename_table(t, new_name)
    RenameColumn(old, new_name) => self.rename_column(t, old, new_name)
    AddColumn(cd, text) => self.add_column(t, cd, text)
    DropColumn(c) => self.drop_column(t, c)
  }
}

///|
/// Re-binds CHECK constraints and rebuilds the indexes after the columns
/// (and rows) changed.
fn rebind_table(t : Table, defs : Array[CheckDef]) -> Unit raise SqlError {
  t.checks = bind_checks(t, defs)
  let list : Array[Index] = []
  for idx in t.indexes {
    let n = build_index(
      t,
      idx.name,
      unique=idx.unique,
      origin=idx.origin,
      conflict=idx.conflict,
      parts=idx.parts,
      where_src=idx.where_src,
      sql=idx.sql,
      seq=idx.seq,
    )
    n.populate(t)
    list.push(n)
  }
  t.indexes = list
}

///|
fn Database::rename_table(
  self : Database,
  t : Table,
  new_name : String,
) -> Unit raise SqlError {
  if is_reserved_name(new_name) {
    raise SqlError("object name reserved for internal use: \{new_name}")
  }
  if self.find_table(new_name) is Some(_) ||
    self.find_view(new_name) is Some(_) ||
    self.find_index(new_name) is Some(_) {
    raise SqlError(
      "there is already another table or index with this name: \{new_name}",
    )
  }
  let old = t.name
  self.tables.remove(name_key(old))
  t.name = new_name
  self.tables[name_key(new_name)] = t
  let prefix = "sqlite_autoindex_" + old + "_"
  t.indexes = t.indexes.map(idx => {
    if idx.origin != 0 && idx.name.has_prefix(prefix) {
      let suffix = idx.name[prefix.length():].to_owned()
      {
        ..idx,
        name: "sqlite_autoindex_" + new_name + "_" + suffix,
        entries: idx.entries.copy(),
      }
    } else {
      {
        ..idx,
        sql: idx.sql.map(s => sql_rename_table_refs(s, old, new_name)),
        entries: idx.entries.copy(),
      }
    }
  })
  t.sql = sql_rename_table_def(t.sql, new_name)
  let rw : Rewriter = { table: old, new_table: Some(new_name), col: None, }
  self.rewrite_views(rw)
  self.check_views()
}

///|
fn Database::rewrite_views(
  self : Database,
  rw : Rewriter,
) -> Unit raise SqlError {
  let updated : Array[(String, View)] = []
  for k, v in self.views {
    let sql = match (rw.new_table, rw.col) {
      (Some(nt), _) => sql_rename_table_refs(v.sql, rw.table, nt)
      (None, Some((old, nw))) if sql_mentions(v.sql, rw.table) =>
        sql_rename_column(v.sql, old, nw)
      _ => v.sql
    }
    updated.push((k, { ..v, query: rw.select(v.query, []), sql, }))
  }
  for u in updated {
    self.views[u.0] = u.1
  }
}

///|
fn Database::rename_column(
  self : Database,
  t : Table,
  old : String,
  new_name : String,
) -> Unit raise SqlError {
  guard t.find_column(old) is Some(ci) else {
    raise SqlError("no such column: \"\{old}\"")
  }
  if t.find_column(new_name) is Some(_) {
    raise SqlError("duplicate column name: \{new_name}")
  }
  let cols = t.columns.copy()
  let c = cols[ci]
  cols[ci] = { ..c, name: new_name, def: { ..c.def, name: new_name, }, }
  t.columns = cols
  let rw : Rewriter = {
    table: t.name,
    new_table: None,
    col: Some((old, new_name)),
  }
  let quals = [t.name]
  let defs = t.checks.map(ck => {
    let d = ck.def
    {
      ..d,
      expr: rw.expr(d.expr, quals, true),
      text: rename_in_text(d.text, old, new_name),
    }
  })
  t.checks = bind_checks(t, defs)
  t.indexes = t.indexes.map(idx => {
    ..idx,
    parts: idx.parts.map(p => { ..p, expr: rw.expr(p.expr, quals, true), }),
    where_src: match idx.where_src {
      Some(w) => Some(rw.expr(w, quals, true))
      None => None
    },
    sql: idx.sql.map(s => sql_rename_column(s, old, new_name)),
    entries: idx.entries.copy(),
  })
  t.sql = sql_rename_column(t.sql, old, new_name)
  self.rewrite_views(rw)
  self.check_views()
}

///|
/// Replaces identifier tokens `old` (not function names or qualifiers) in
/// the source text of an expression.
fn rename_in_text(text : String, old : String, new_name : String) -> String {
  let toks = tokenize(text) catch { _ => return text }
  let sb = StringBuilder()
  let mut last = 0
  for i, tk in toks {
    if !(tk.kind is (TIdent | TQuoted | TBracket)) ||
      !tk.text.equal_ignore_ascii_case(old) {
      continue
    }
    if i + 1 < toks.length() {
      let nx = toks[i + 1]
      if nx.kind == TOp && (nx.text == "(" || nx.text == ".") {
        continue
      }
    }
    let len = if tk.kind == TIdent {
      tk.text.length()
    } else {
      tk.text.length() + 2
    }
    sb.write_view(text[last:tk.pos])
    if tk.kind == TIdent {
      sb.write_string(new_name)
    } else {
      sb.write_view(text[tk.pos:tk.pos + 1])
      sb.write_string(new_name)
      sb.write_view(text[tk.pos + len - 1:tk.pos + len])
    }
    last = tk.pos + len
  }
  sb.write_view(text[last:])
  sb.to_string()
}

///|
fn Database::add_column(
  self : Database,
  t : Table,
  cd : ColumnDef,
  text : String,
) -> Unit raise SqlError {
  ignore(self)
  if t.find_column(cd.name) is Some(_) {
    raise SqlError("duplicate column name: \{cd.name}")
  }
  if cd.primary_key {
    raise SqlError("Cannot add a PRIMARY KEY column")
  }
  if cd.unique {
    raise SqlError("Cannot add a UNIQUE column")
  }
  let col = make_column(cd)
  if cd.default is Some(d) && !is_literal_default(d) && t.rows.length() > 0 {
    raise SqlError("Cannot add a column with non-constant default")
  }
  let dv = match cd.default {
    Some(d) => apply_affinity(eval_const(d), col.aff)
    None => Null
  }
  if cd.not_null && dv is Null && t.rows.length() > 0 {
    raise SqlError("Cannot add a NOT NULL column with default value NULL")
  }
  let cols = t.columns.copy()
  cols.push(col)
  t.columns = cols
  if t.rows.length() > 0 {
    let rows = new_rows()
    t.rows.each_while((rowid, vals) => {
      let nv = vals.copy()
      nv.push(dv)
      rows.set(rowid, nv)
      true
    })
    t.rows = rows
    t.version = next_version()
  }
  let defs = t.checks.map(ck => ck.def)
  for ck in cd.checks {
    defs.push(ck)
  }
  rebind_table(t, defs)
  t.sql = sql_add_column(t.sql, text)
}

///|
/// Defaults SQLite can store as a value (literals, possibly signed).
fn is_literal_default(e : Expr) -> Bool {
  match e {
    Lit(_) => true
    Unary(Neg | Pos, x) => is_literal_default(x)
    _ => false
  }
}

///|
fn Database::drop_column(
  self : Database,
  t : Table,
  name : String,
) -> Unit raise SqlError {
  guard t.find_column(name) is Some(ci) else {
    raise SqlError("no such column: \"\{name}\"")
  }
  let cname = t.columns[ci].name
  if t.ipk == ci {
    raise SqlError("cannot drop PRIMARY KEY column: \"\{cname}\"")
  }
  for idx in t.indexes {
    if idx.origin == 2 && idx.cols.contains(ci) {
      raise SqlError("cannot drop PRIMARY KEY column: \"\{cname}\"")
    }
    if idx.origin == 1 && idx.cols.contains(ci) {
      raise SqlError("cannot drop UNIQUE column: \"\{cname}\"")
    }
  }
  if t.columns.length() == 1 {
    raise SqlError("cannot drop column \"\{cname}\": no other columns exist")
  }
  // CHECK constraints of the dropped column go with it
  let own = t.columns[ci].def.checks
  let defs = t.checks
    .filter(ck => !own.any(o => physical_equal(o, ck.def)))
    .map(ck => ck.def)
  let cols = t.columns.copy()
  ignore(cols.remove(ci))
  t.columns = cols
  if t.ipk > ci {
    t.ipk -= 1
  }
  let rows = new_rows()
  t.rows.each_while((rowid, vals) => {
    let nv = vals.copy()
    ignore(nv.remove(ci))
    rows.set(rowid, nv)
    true
  })
  t.rows = rows
  t.version = next_version()
  t.sql = sql_drop_column(t.sql, ci)
  rebind_table(t, defs) catch {
    SqlError(msg) =>
      raise SqlError("error in table \{t.name} after drop column: \{msg}")
  }
  self.check_views()
}

///|
/// After a rename or a dropped column every view must still resolve (as in
/// SQLite, a broken view makes the ALTER TABLE fail).
fn Database::check_views(self : Database) -> Unit raise SqlError {
  for _, v in self.views {
    ignore(self.prepare_view(v)) catch {
      SqlError(msg) => raise SqlError("error in view \{v.name}: \{msg}")
    }
  }
}

// ---------------------------------------------------------------------------
// Rewriting names in stored queries and expressions
// ---------------------------------------------------------------------------

///|
/// Renames a table (`new_table`) or one of its columns (`col`) in unbound
/// queries and expressions.
priv struct Rewriter {
  table : String
  new_table : String?
  col : (String, String)?
}

///|
fn Rewriter::expr(
  self : Rewriter,
  e : Expr,
  quals : Array[String],
  unq : Bool,
) -> Expr raise SqlError {
  match e {
    Col(tbl~, name~, dq~) => {
      let mut t = tbl
      let mut n = name
      match tbl {
        Some(q) if quals.any(x => x.equal_ignore_ascii_case(q)) => {
          if self.col is Some((old, nw)) && name.equal_ignore_ascii_case(old) {
            n = nw
          }
          if self.new_table is Some(nt) && q.equal_ignore_ascii_case(self.table) {
            t = Some(nt)
          }
        }
        None =>
          if unq &&
            self.col is Some((old, nw)) &&
            name.equal_ignore_ascii_case(old) {
            n = nw
          }
        _ => ()
      }
      Col(tbl=t, name=n, dq~)
    }
    Subquery(s) => Subquery(self.select(s, quals))
    Exists(s) => Exists(self.select(s, quals))
    InSelect(x, s, neg) =>
      InSelect(self.expr(x, quals, unq), self.select(s, quals), neg)
    _ => e.map_children(x => self.expr(x, quals, unq))
  }
}

///|
/// Qualifiers referring to the table in a FROM clause.
fn Rewriter::from_quals(
  self : Rewriter,
  f : FromItem,
  out : Array[String],
) -> Unit {
  match f {
    TableRef(name~, as_name~) =>
      if name.equal_ignore_ascii_case(self.table) {
        out.push(as_name.unwrap_or(name))
      }
    SubqueryRef(..) => ()
    Join(left~, right~, ..) => {
      self.from_quals(left, out)
      self.from_quals(right, out)
    }
  }
}

///|
fn Rewriter::from(
  self : Rewriter,
  f : FromItem,
  quals : Array[String],
  unq : Bool,
) -> FromItem raise SqlError {
  match f {
    TableRef(name~, as_name~) =>
      match self.new_table {
        Some(nt) if name.equal_ignore_ascii_case(self.table) =>
          TableRef(name=nt, as_name~)
        _ => f
      }
    SubqueryRef(query~, as_name~) =>
      SubqueryRef(query=self.select(query, []), as_name~)
    Join(left~, right~, kind~, natural~, on~, using_cols~) =>
      Join(
        left=self.from(left, quals, unq),
        right=self.from(right, quals, unq),
        kind~,
        natural~,
        on=match on {
          Some(x) => Some(self.expr(x, quals, unq))
          None => None
        },
        using_cols=match (using_cols, self.col) {
          (Some(us), Some((old, nw))) if unq =>
            Some(
              us.map(u => if u.equal_ignore_ascii_case(old) { nw } else { u }),
            )
          _ => using_cols
        },
      )
  }
}

///|
fn Rewriter::core(
  self : Rewriter,
  sel : Select,
  outer : Array[String],
) -> Select raise SqlError {
  let quals = outer.copy()
  let mut unq = outer.length() > 0
  if sel.from is Some(f) {
    let here : Array[String] = []
    self.from_quals(f, here)
    if here.length() > 0 {
      unq = true
    }
    quals.append(here)
  }
  let fx = fn(e : Expr) raise SqlError { self.expr(e, quals, unq) }
  let fo = fn(e : Expr?) raise SqlError {
    match e {
      Some(x) => Some(fx(x))
      None => None
    }
  }
  {
    ..sel,
    columns: sel.columns.map(rc => {
      match rc {
        ExprCol(e, a, text) => ExprCol(fx(e), a, text)
        _ => rc
      }
    }),
    from: match sel.from {
      Some(f) => Some(self.from(f, quals, unq))
      None => None
    },
    where_: fo(sel.where_),
    group_by: sel.group_by.map(fx),
    having: fo(sel.having),
    values: match sel.values {
      Some(rows) => Some(rows.map(r => r.map(fx)))
      None => None
    },
    order_by: sel.order_by.map(t => { ..t, expr: fx(t.expr), }),
  }
}

///|
fn Rewriter::select(
  self : Rewriter,
  sel : Select,
  outer : Array[String],
) -> Select raise SqlError {
  let first = self.core(sel, outer)
  {
    ..first,
    compound: sel.compound.map(p => (p.0, self.core(p.1, outer))),
    with_: sel.with_.map(c => { ..c, query: self.select(c.query, []), }),
  }
}
