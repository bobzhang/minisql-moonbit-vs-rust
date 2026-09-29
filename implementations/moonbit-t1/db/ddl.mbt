// Schema statements (CREATE/DROP of tables, indexes and views, ALTER TABLE)
// and transaction control.

///|
fn check_reserved(name : String) -> Unit raise SqlError {
  if name.to_lower().has_prefix("sqlite_") {
    raise sql_err("object name reserved for internal use: \{name}")
  }
}

///|
fn Database::run_ddl(self : Database, st : Stmt) -> Unit raise SqlError {
  match st {
    CreateTable(name~, if_not_exists~, cols~, constraints~, sql~) => {
      match self.object_kind(name) {
        Some(kind) => {
          if if_not_exists {
            return
          }
          if kind == "index" {
            raise sql_err("there is already an index named \{name}")
          }
          raise sql_err("\{kind} \{name} already exists")
        }
        None => ()
      }
      check_reserved(name)
      let seq = self.next_seq
      let t = build_table(name, cols, constraints, sql, seq)
      ignore(self.take_seq(t.indexes.length() + 1))
      self.tables[key_of(name)] = t
      if t.autoinc && self.seq_table is None {
        self.seq_table = Some(self.take_seq(1))
      }
    }
    DropTable(name~, if_exists~) => {
      if self.views.get(key_of(name)) is Some(v) {
        raise sql_err("use DROP VIEW to delete view \{v.name}")
      }
      if !self.tables.contains(key_of(name)) {
        if is_schema_name(name) {
          raise sql_err("table \{name} may not be dropped")
        }
        if if_exists {
          return
        }
        raise sql_err("no such table: \{name}")
      }
      self.tables.remove(key_of(name))
    }
    CreateIndex(name~, table~, unique~, if_not_exists~, cols~, where_~, sql~) => {
      match self.object_kind(name) {
        Some("index") => {
          if if_not_exists {
            return
          }
          raise sql_err("index \{name} already exists")
        }
        Some(kind) => raise sql_err("there is already a \{kind} named \{name}")
        None => ()
      }
      check_reserved(name)
      if self.views.contains(key_of(table)) {
        raise sql_err("views may not be indexed")
      }
      guard self.tables.get(key_of(table)) is Some(t) else {
        if is_schema_name(table) {
          raise sql_err("table \{table} may not be indexed")
        }
        raise sql_err("no such table: main.\{table}")
      }
      let ix = make_index(
        t,
        name,
        unique,
        { cols, where_, sql, },
        self.next_seq,
      )
      fill_index(t, ix)
      ignore(self.take_seq(1))
      t.indexes.insert(0, ix)
    }
    DropIndex(name~, if_exists~) =>
      match self.find_index(name) {
        None => {
          if if_exists {
            return
          }
          raise sql_err("no such index: \{name}")
        }
        Some((t, i)) => {
          if t.indexes[i].def is None {
            raise sql_err(
              "index associated with UNIQUE or PRIMARY KEY constraint cannot be dropped",
            )
          }
          ignore(t.indexes.remove(i))
        }
      }
    CreateView(name~, if_not_exists~, cols~, query~, sql~) => {
      match self.object_kind(name) {
        Some(kind) => {
          if if_not_exists {
            return
          }
          if kind == "index" {
            raise sql_err("there is already an index named \{name}")
          }
          raise sql_err("\{kind} \{name} already exists")
        }
        None => ()
      }
      check_reserved(name)
      let seq = self.take_seq(1)
      self.views[key_of(name)] = { name, cols, query, sql, seq, }
    }
    DropView(name~, if_exists~) => {
      if self.tables.get(key_of(name)) is Some(t) {
        raise sql_err("use DROP TABLE to delete table \{t.name}")
      }
      if !self.views.contains(key_of(name)) {
        if if_exists {
          return
        }
        raise sql_err("no such view: \{name}")
      }
      self.views.remove(key_of(name))
    }
    AlterRename(table~, new_name~) => {
      let t = self.alter_target(table, "altered")
      if self.object_kind(new_name) is Some(_) {
        raise sql_err(
          "there is already another table or index with this name: \{new_name}",
        )
      }
      check_reserved(new_name)
      let defs = index_defs(t).map(p => {
        (
          p.0,
          { ..p.1, sql: sql_rename_index_table(p.1.sql, new_name), },
          p.2,
          p.3,
        )
      })
      let nt = rebuild_table(
        t,
        new_name,
        sql_rename_create_table(t.sql, new_name),
        t.cols,
        t.constraints,
        defs,
        v => v,
      )
      self.tables.remove(key_of(t.name))
      self.tables[key_of(new_name)] = nt
      let views : Array[(String, View)] = []
      for k, v in self.views {
        views.push((k, v))
      }
      for p in views {
        self.views[p.0] = {
          ..p.1,
          query: rename_table_in_query(p.1.query, t.name, new_name),
          sql: sql_rename_table_refs(p.1.sql, t.name, new_name),
        }
      }
    }
    AlterRenameCol(table~, old~, new_name~) => {
      let t = self.alter_target(table, "altered")
      guard t.col_index(old) is Some(ci) else {
        raise sql_err("no such column: \"\{old}\"")
      }
      if t.col_index(new_name) is Some(_) {
        raise sql_err("duplicate column name: \{new_name}")
      }
      let old_name = t.cols[ci].name
      let ren = (e : Expr) => {
        rename_col_in_expr(e, old_name, new_name, [t.name])
      }
      let cols = t.cols.mapi((i, c) => {
        ..c,
        name: if i == ci {
          new_name
        } else {
          c.name
        },
        checks: c.checks.map(ren),
      })
      let ren_names = (names : Array[String]) => {
        names.map(n => if same_name(n, old_name) { new_name } else { n })
      }
      let constraints = t.constraints.map(tc => {
        match tc {
          TPrimaryKey(names, c) => TPrimaryKey(ren_names(names), c)
          TUnique(names, c) => TUnique(ren_names(names), c)
          TCheck(e) => TCheck(ren(e))
          TForeignKey => TForeignKey
        }
      })
      let defs = index_defs(t).map(p => {
        let d = p.1
        (
          p.0,
          {
            ..d,
            cols: d.cols.map(c => { ..c, expr: ren(c.expr), }),
            where_: d.where_.map(ren),
            sql: sql_rename_column_in_index(d.sql, old_name, new_name),
          },
          p.2,
          p.3,
        )
      })
      let nsql = sql_rename_column_in_table(t.sql, old_name, new_name)
      let nt = rebuild_table(t, t.name, nsql, cols, constraints, defs, v => v)
      self.tables[key_of(t.name)] = nt
      let views : Array[(String, View)] = []
      for k, v in self.views {
        views.push((k, v))
      }
      for p in views {
        self.views[p.0] = {
          ..p.1,
          query: rename_col_in_query(p.1.query, t.name, old_name, new_name, []),
          sql: sql_rename_column_in_view(p.1.sql, t.name, old_name, new_name),
        }
      }
    }
    AlterAdd(table~, col~, sql~) => {
      if self.views.contains(key_of(table)) {
        raise sql_err("Cannot add a column to a view")
      }
      let t = self.alter_target(table, "altered")
      if t.col_index(col.name) is Some(_) {
        raise sql_err("duplicate column name: \{col.name}")
      }
      if col.primary_key {
        raise sql_err("Cannot add a PRIMARY KEY column")
      }
      if col.unique {
        raise sql_err("Cannot add a UNIQUE column")
      }
      match col.default_ {
        None | Some(Lit(_)) | Some(BigIntLit) => ()
        Some(Unary(Neg | Pos, Lit(Int(_) | Real(_)) | BigIntLit)) => ()
        _ => raise sql_err("Cannot add a column with non-constant default")
      }
      let dv = eval_default(col)
      if col.not_null && dv is Null && t.rows.length() > 0 {
        raise sql_err("Cannot add a NOT NULL column with default value NULL")
      }
      let cols = t.cols.copy()
      cols.push(col)
      let nsql = sql_add_column(t.sql, sql)
      let nt = rebuild_table(
        t,
        t.name,
        nsql,
        cols,
        t.constraints,
        index_defs(t),
        v => {
          let nv = v.copy()
          nv.push(dv)
          nv
        },
      )
      self.tables[key_of(t.name)] = nt
    }
    AlterDrop(table~, col~) => {
      let t = self.alter_target(table, "altered")
      guard t.col_index(col) is Some(ci) else {
        raise sql_err("no such column: \"\{col}\"")
      }
      let cd = t.cols[ci]
      if cd.primary_key {
        raise sql_err("cannot drop PRIMARY KEY column: \"\{cd.name}\"")
      }
      if cd.unique {
        raise sql_err("cannot drop UNIQUE column: \"\{cd.name}\"")
      }
      for tc in t.constraints {
        match tc {
          TPrimaryKey(names, _) =>
            if names.any(n => same_name(n, cd.name)) {
              raise sql_err("cannot drop PRIMARY KEY column: \"\{cd.name}\"")
            }
          TUnique(names, _) =>
            if names.any(n => same_name(n, cd.name)) {
              raise sql_err("cannot drop UNIQUE column: \"\{cd.name}\"")
            }
          TCheck(e) =>
            if ast_refs_col(e, cd.name) {
              raise sql_err(
                "error in table \{t.name} after drop column: no such column: \{cd.name}",
              )
            }
          TForeignKey => ()
        }
      }
      if t.cols.length() == 1 {
        raise sql_err(
          "cannot drop column \"\{cd.name}\": no other columns exist",
        )
      }
      let defs = index_defs(t)
      for p in defs {
        let d = p.1
        if d.cols.any(c => ast_refs_col(c.expr, cd.name)) ||
          (d.where_ is Some(w) && ast_refs_col(w, cd.name)) {
          raise sql_err(
            "error in index \{p.0} after drop column: no such column: \{cd.name}",
          )
        }
      }
      let cols = t.cols.copy()
      ignore(cols.remove(ci))
      let nsql = sql_drop_column(t.sql, cd.name)
      let nt = rebuild_table(t, t.name, nsql, cols, t.constraints, defs, v => {
        let nv = v.copy()
        ignore(nv.remove(ci))
        nv
      })
      self.tables[key_of(t.name)] = nt
    }
    _ => ()
  }
}

///|
fn Database::alter_target(
  self : Database,
  name : String,
  what : String,
) -> Table raise SqlError {
  if self.views.get(key_of(name)) is Some(v) {
    raise sql_err("view \{v.name} may not be \{what}")
  }
  match self.tables.get(key_of(name)) {
    Some(t) => t
    None =>
      if is_schema_name(name) {
        raise sql_err("table \{name} may not be \{what}")
      } else {
        raise sql_err("no such table: \{name}")
      }
  }
}

///|
/// Explicit indexes of a table in checking order: (name, definition, unique, seq).
fn index_defs(t : Table) -> Array[(String, IndexDef, Bool, Int)] {
  let out : Array[(String, IndexDef, Bool, Int)] = []
  for ix in t.indexes {
    if ix.def is Some(d) {
      out.push((ix.name, d, ix.unique, ix.seq))
    }
  }
  out
}

///|
/// A new table with a changed definition, holding the old rows transformed
/// by `f`, with its indexes rebuilt.
fn rebuild_table(
  t : Table,
  name : String,
  sql : String,
  cols : Array[ColumnDef],
  constraints : Array[TableConstraint],
  defs : Array[(String, IndexDef, Bool, Int)],
  f : (Array[Value]) -> Array[Value],
) -> Table raise SqlError {
  let nt = build_table(name, cols, constraints, sql, t.seq)
  nt.seq_val = t.seq_val
  for i, p in defs {
    nt.indexes.insert(i, make_index(nt, p.0, p.2, p.1, p.3))
  }
  for p in t.rows.to_array() {
    nt.insert_row(p.0, f(p.1))
  }
  nt
}

// ---------------------------------------------------------------------------
// Rewriting syntax trees (for renames)
// ---------------------------------------------------------------------------

///|
/// Rebuild an unbound expression: `f` may replace a node; subqueries are
/// passed to `fq`.
fn map_ast(e : Expr, f : (Expr) -> Expr?, fq : (Query) -> Query) -> Expr {
  if f(e) is Some(r) {
    return r
  }
  let m = (x : Expr) => map_ast(x, f, fq)
  match e {
    Unary(op, x) => Unary(op, m(x))
    Binary(op, l, r) => Binary(op, m(l), m(r))
    Cmp(op, l, r, i) => Cmp(op, m(l), m(r), i)
    IsNull(x, n) => IsNull(m(x), n)
    Collate(x, c) => Collate(m(x), c)
    Cast(x, a) => Cast(m(x), a)
    Between(x, lo, hi, n, i1, i2) => Between(m(x), m(lo), m(hi), n, i1, i2)
    InList(x, items, n, i) => InList(m(x), items.map(m), n, i)
    Like(glob~, lhs~, pat~, esc~, neg~) =>
      Like(glob~, lhs=m(lhs), pat=m(pat), esc=esc.map(m), neg~)
    Case(base~, whens~, else_~, infos~) =>
      Case(
        base=base.map(m),
        whens=whens.map(w => (m(w.0), m(w.1))),
        else_=else_.map(m),
        infos~,
      )
    Func(name~, args~, star~, distinct~, coll~, filter~, order~) =>
      Func(
        name~,
        args=args.map(m),
        star~,
        distinct~,
        coll~,
        filter=filter.map(m),
        order=order.map(t => { ..t, expr: m(t.expr), }),
      )
    SubQ(q) => SubQ(fq(q))
    ExistsQ(q) => ExistsQ(fq(q))
    InQ(x, q, n) => InQ(m(x), fq(q), n)
    WinCall(w) =>
      WinCall({
        ..w,
        args: w.args.map(m),
        filter: w.filter.map(m),
        order: w.order.map(t => { ..t, expr: m(t.expr), }),
        over: match w.over {
          OverDef(d) => OverDef(map_windef(d, m))
          o => o
        },
      })
    _ => e
  }
}

///|
fn map_windef(d : WinDef, m : (Expr) -> Expr) -> WinDef {
  let mb = (b : FrameBound) => {
    match b {
      Pre(x) => Pre(m(x))
      Fol(x) => Fol(m(x))
      _ => b
    }
  }
  {
    ..d,
    partition: d.partition.map(m),
    order: d.order.map(t => { ..t, expr: m(t.expr), }),
    frame: d.frame.map(f => { ..f, start: mb(f.start), end: mb(f.end), }),
  }
}

///|
/// Apply expression mappers to every clause of a query. `fe_for` gives the
/// mapper for a SELECT (None: VALUES rows and compound-level clauses);
/// `ffrom` rewrites FROM items (their ON clauses are mapped afterwards).
fn walk_query(
  q : Query,
  fe_for : (Select?) -> (Expr) -> Expr,
  ffrom : (Select, FromItem) -> FromItem,
) -> Query {
  match q {
    QSelect(sel) => {
      let fe = fe_for(Some(sel))
      let from = sel.from.map(fi => {
        let fi2 = ffrom(sel, fi)
        { ..fi2, on: fi2.on.map(fe), }
      })
      QSelect({
        ..sel,
        cols: sel.cols.map(c => {
          match c {
            ExprCol(e, a, t) => ExprCol(fe(e), a, t)
            _ => c
          }
        }),
        from,
        where_: sel.where_.map(fe),
        group_by: sel.group_by.map(fe),
        having: sel.having.map(fe),
        order_by: sel.order_by.map(t => { ..t, expr: fe(t.expr), }),
        limit: sel.limit.map(fe),
        offset: sel.offset.map(fe),
        windows: sel.windows.map(w => (w.0, map_windef(w.1, fe))),
      })
    }
    QValues(rows) => {
      let fe = fe_for(None)
      QValues(rows.map(r => r.map(fe)))
    }
    QCompound(first~, rest~, order_by~, limit~, offset~) => {
      let fe = fe_for(None)
      QCompound(
        first=walk_query(first, fe_for, ffrom),
        rest=rest.map(p => (p.0, walk_query(p.1, fe_for, ffrom))),
        order_by~,
        limit=limit.map(fe),
        offset=offset.map(fe),
      )
    }
    QWith(ctes~, body~) =>
      QWith(
        ctes=ctes.map(c => { ..c, query: walk_query(c.query, fe_for, ffrom), }),
        body=walk_query(body, fe_for, ffrom),
      )
  }
}

///|
fn rename_table_in_query(q : Query, old : String, new : String) -> Query {
  let fq = (sq : Query) => rename_table_in_query(sq, old, new)
  walk_query(q, _ => e => map_ast(e, _ => None, fq), (_, fi) => {
    match fi.src {
      FTable(n) if same_name(n, old) =>
        { ..fi, src: FTable(new), as_name: Some(fi.as_name.unwrap_or(n)), }
      FSub(sq) => { ..fi, src: FSub(fq(sq)), }
      _ => fi
    }
  })
}

///|
/// Rename column references `old` -> `new` that may refer to a table known
/// in the current scope under one of the names in `ctx`.
fn rename_col_in_expr(
  e : Expr,
  old : String,
  new : String,
  ctx : Array[String],
) -> Expr {
  map_ast(
    e,
    x => {
      match x {
        Column(tbl~, name~, dq~) if same_name(name, old) => {
          let hit = match tbl {
            None => ctx.length() > 0
            Some(q) => ctx.any(c => same_name(c, q))
          }
          if hit {
            Some(Column(tbl~, name=new, dq~))
          } else {
            None
          }
        }
        _ => None
      }
    },
    q => q,
  )
}

///|
fn rename_col_in_query(
  q : Query,
  table : String,
  old : String,
  new : String,
  ctx : Array[String],
) -> Query {
  let ctx_of = (sel : Select?) => {
    let names : Array[String] = []
    if sel is Some(s) {
      for fi in s.from {
        if fi.src is FTable(n) && same_name(n, table) {
          names.push(fi.as_name.unwrap_or(n))
        }
      }
    }
    for c in ctx {
      names.push(c)
    }
    names
  }
  walk_query(
    q,
    sel => {
      let c = ctx_of(sel)
      e => {
        map_ast(
          e,
          x => {
            match x {
              Column(tbl~, name~, dq~) if same_name(name, old) => {
                let hit = match tbl {
                  None => c.length() > 0
                  Some(qn) => c.any(n => same_name(n, qn))
                }
                if hit {
                  Some(Column(tbl~, name=new, dq~))
                } else {
                  None
                }
              }
              _ => None
            }
          },
          sq => rename_col_in_query(sq, table, old, new, c),
        )
      }
    },
    (sel, fi) => {
      let c = ctx_of(Some(sel))
      let fi2 = match fi.src {
        FSub(sq) =>
          { ..fi, src: FSub(rename_col_in_query(sq, table, old, new, ctx)), }
        _ => fi
      }
      match fi2.using_ {
        Some(names) if c.length() > 0 =>
          {
            ..fi2,
            using_: Some(
              names.map(n => if same_name(n, old) { new } else { n }),
            ),
          }
        _ => fi2
      }
    },
  )
}

///|
fn ast_refs_col(e : Expr, name : String) -> Bool {
  match e {
    Column(name=n, ..) => same_name(n, name)
    _ => expr_children(e).any(c => ast_refs_col(c, name))
  }
}

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------

///|
fn Database::run_txn(self : Database, st : Stmt) -> Unit raise SqlError {
  match st {
    Begin => {
      if self.txn is Some(_) {
        raise sql_err("cannot start a transaction within a transaction")
      }
      self.txn = Some(self.snapshot())
      self.txn_by_savepoint = false
    }
    Commit => {
      if self.txn is None {
        raise sql_err("cannot commit - no transaction is active")
      }
      self.end_txn()
    }
    Rollback(None) => {
      guard self.txn is Some(s) else {
        raise sql_err("cannot rollback - no transaction is active")
      }
      self.restore(s)
      self.end_txn()
    }
    Rollback(Some(name)) => {
      guard self.find_savepoint(name) is Some(i) else {
        raise sql_err("no such savepoint: \{name}")
      }
      self.restore(self.savepoints[i].1)
      self.savepoints.truncate(i + 1)
    }
    Savepoint(name) => {
      if self.txn is None {
        self.txn = Some(self.snapshot())
        self.txn_by_savepoint = true
      }
      self.savepoints.push((name, self.snapshot()))
    }
    Release(name) => {
      guard self.find_savepoint(name) is Some(i) else {
        raise sql_err("no such savepoint: \{name}")
      }
      self.savepoints.truncate(i)
      if i == 0 && self.txn_by_savepoint {
        self.end_txn()
      }
    }
    _ => ()
  }
}

///|
fn Database::end_txn(self : Database) -> Unit {
  self.txn = None
  self.txn_by_savepoint = false
  self.savepoints.clear()
}

///|
fn Database::find_savepoint(self : Database, name : String) -> Int? {
  for i = self.savepoints.length() - 1; i >= 0; i = i - 1 {
    if same_name(self.savepoints[i].0, name) {
      return Some(i)
    }
  }
  None
}
