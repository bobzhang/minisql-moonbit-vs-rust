///|
/// Rewrites stored ASTs after ALTER TABLE ... RENAME: either a table rename
/// (`new_table` non-empty) or a column rename of table `table`.
priv struct Renamer {
  db : Database
  /// Folded name of the table being altered (its old name for RENAME TO).
  table : String
  /// Folded old column name ("" for a table rename).
  old_col : String
  new_col : String
  new_table : String
}

///|
/// One FROM source visible to an expression: folded qualifier, whether it
/// is the altered table, and the folded table name (None for subqueries).
priv struct RSource {
  qual : String
  target : Bool
  table : String?
}

///|
fn Renamer::source_has_column(
  self : Renamer,
  s : RSource,
  col : String,
) -> Bool {
  if s.target {
    return true
  }
  match s.table {
    Some(tn) =>
      match self.db.find_table(tn) {
        Some(t) => t.column_index(col) is Some(_)
        None => false
      }
    None => false
  }
}

///|
fn Renamer::column(
  self : Renamer,
  q : String?,
  n : String,
  dq : Bool,
  frames : Array[Array[RSource]],
) -> Expr {
  let e = Column(q, n, dq)
  if self.new_table != "" {
    guard q is Some(qq) && fold_name(qq) == self.table else { return e }
    for i = frames.length() - 1; i >= 0; i = i - 1 {
      for s in frames[i] {
        if s.qual == self.table {
          return if s.target { Column(Some(self.new_table), n, dq) } else { e }
        }
      }
    }
    return e
  }
  if fold_name(n) != self.old_col {
    return e
  }
  match q {
    Some(qq) => {
      let fq = fold_name(qq)
      for i = frames.length() - 1; i >= 0; i = i - 1 {
        for s in frames[i] {
          if s.qual == fq {
            return if s.target { Column(q, self.new_col, dq) } else { e }
          }
        }
      }
      e
    }
    None => {
      for i = frames.length() - 1; i >= 0; i = i - 1 {
        for s in frames[i] {
          if self.source_has_column(s, n) {
            return if s.target { Column(q, self.new_col, dq) } else { e }
          }
        }
      }
      e
    }
  }
}

///|
fn Renamer::expr(
  self : Renamer,
  e : Expr,
  frames : Array[Array[RSource]],
) -> Expr {
  let r = (x : Expr) => self.expr(x, frames)
  match e {
    Lit(_) | Param(_) | AggSlot(_) => e
    Column(q, n, dq) => self.column(q, n, dq, frames)
    Unary(op, x) => Unary(op, r(x))
    Binary(op, a, b) => Binary(op, r(a), r(b))
    IsNull(x, neg) => IsNull(r(x), neg)
    Between(x, lo, hi, neg) => Between(r(x), r(lo), r(hi), neg)
    InList(x, items, neg) => InList(r(x), items.map(r), neg)
    InSelect(x, sel, neg) => InSelect(r(x), self.select(sel, frames), neg)
    Like(op, a, p, esc, neg) => Like(op, r(a), r(p), esc.map(r), neg)
    Case(b, whens, els) =>
      Case(b.map(r), whens.map(w => (r(w.0), r(w.1))), els.map(r))
    Cast(x, t) => Cast(r(x), t)
    Collate(x, c) => Collate(r(x), c)
    Func(fc) =>
      Func({
        ..fc,
        args: fc.args.map(r),
        filter: fc.filter.map(r),
        order_by: fc.order_by.map(t => { ..t, expr: r(t.expr), }),
        over: fc.over.map(w => self.window(w, frames)),
      })
    Exists(sel, neg) => Exists(self.select(sel, frames), neg)
    Subquery(sel) => Subquery(self.select(sel, frames))
  }
}

///|
fn Renamer::window(
  self : Renamer,
  w : WindowSpec,
  frames : Array[Array[RSource]],
) -> WindowSpec {
  let bound = (b : FrameBound) => {
    match b {
      Preceding(x) => Preceding(self.expr(x, frames))
      Following(x) => Following(self.expr(x, frames))
      _ => b
    }
  }
  {
    ..w,
    partition_by: w.partition_by.map(x => self.expr(x, frames)),
    order_by: w.order_by.map(t => { ..t, expr: self.expr(t.expr, frames), }),
    frame: w.frame.map(f => { ..f, start: bound(f.start), end: bound(f.end), }),
  }
}

///|
fn Renamer::from_sources(
  self : Renamer,
  item : FromItem,
  out : Array[RSource],
) -> Unit {
  match item {
    TableRef(name, al) => {
      let f = fold_name(name)
      out.push({
        qual: fold_name(al.unwrap_or(name)),
        target: f == self.table,
        table: Some(f),
      })
    }
    SubqueryRef(_, al) =>
      out.push({
        qual: fold_name(al.unwrap_or("")),
        target: false,
        table: None,
      })
    Join(l, r, _, _, _, _) => {
      self.from_sources(l, out)
      self.from_sources(r, out)
    }
  }
}

///|
fn Renamer::from_item(
  self : Renamer,
  item : FromItem,
  outer : Array[Array[RSource]],
  inner : Array[Array[RSource]],
) -> FromItem {
  match item {
    TableRef(name, al) =>
      if self.new_table != "" && fold_name(name) == self.table {
        TableRef(self.new_table, al)
      } else {
        item
      }
    SubqueryRef(sel, al) => SubqueryRef(self.select(sel, outer), al)
    Join(l, r, kind, natural, on, using_cols) => {
      let has_target = inner[inner.length() - 1].any(s => s.target)
      Join(
        self.from_item(l, outer, inner),
        self.from_item(r, outer, inner),
        kind,
        natural,
        on.map(e => self.expr(e, inner)),
        using_cols.map(names => {
          names.map(n => {
            if self.old_col != "" && has_target && fold_name(n) == self.old_col {
              self.new_col
            } else {
              n
            }
          })
        }),
      )
    }
  }
}

///|
fn Renamer::core(
  self : Renamer,
  core : SelectCore,
  frames : Array[Array[RSource]],
) -> (SelectCore, Array[Array[RSource]]) {
  match core {
    Values(rows) =>
      (Values(rows.map(r => r.map(e => self.expr(e, frames)))), frames)
    Simple(s) => {
      let srcs = []
      if s.from is Some(f) {
        self.from_sources(f, srcs)
      }
      let inner = [..frames, srcs]
      let r = (x : Expr) => self.expr(x, inner)
      let columns = s.columns.map(rc => {
        match rc {
          ExprCol(e, a) => ExprCol(r(e), a)
          TableStar(tn) =>
            if self.new_table != "" &&
              fold_name(tn) == self.table &&
              srcs.any(x => x.qual == self.table && x.target) {
              TableStar(self.new_table)
            } else {
              rc
            }
          Star => rc
        }
      })
      let simple : SimpleSelect = {
        distinct: s.distinct,
        columns,
        from: s.from.map(f => self.from_item(f, frames, inner)),
        where_: s.where_.map(r),
        group_by: s.group_by.map(r),
        having: s.having.map(r),
        windows: s.windows.map(w => (w.0, self.window(w.1, inner))),
      }
      (Simple(simple), inner)
    }
  }
}

///|
fn Renamer::select(
  self : Renamer,
  sel : Select,
  frames : Array[Array[RSource]],
) -> Select {
  let (first, inner) = self.core(sel.first, frames)
  let rest = sel.rest.map(x => (x.0, self.core(x.1, frames).0))
  let order_frames = if sel.rest.length() == 0 { inner } else { frames }
  {
    with_: sel.with_.map(c => { ..c, select: self.select(c.select, frames), }),
    recursive: sel.recursive,
    first,
    rest,
    order_by: sel.order_by.map(t => {
      ..t,
      expr: self.expr(t.expr, order_frames),
    }),
    limit: sel.limit.map(x => self.expr(x, frames)),
    offset: sel.offset.map(x => self.expr(x, frames)),
  }
}

///|
/// Frames for expressions stored with the table itself (CHECK, index keys).
fn Renamer::table_frames(self : Renamer) -> Array[Array[RSource]] {
  [[{ qual: self.table, target: true, table: None, }]]
}

///|
fn Renamer::table_expr(self : Renamer, e : Expr) -> Expr {
  self.expr(e, self.table_frames())
}

///|
fn Renamer::name(self : Renamer, n : String) -> String {
  if self.old_col != "" && fold_name(n) == self.old_col {
    self.new_col
  } else {
    n
  }
}

///|
/// Rewrites a table definition.
fn Renamer::table_def(self : Renamer, ct : CreateTable) -> CreateTable {
  let key_cols = (cols : Array[(String, String?, Bool)]) => {
    cols.map(c => (self.name(c.0), c.1, c.2))
  }
  {
    name: if self.new_table != "" {
      self.new_table
    } else {
      ct.name
    },
    if_not_exists: ct.if_not_exists,
    temp: ct.temp,
    columns: ct.columns.map(cd => {
      ..cd,
      name: self.name(cd.name),
      checks: cd.checks.map(e => self.table_expr(e)),
    }),
    constraints: ct.constraints.map(tc => {
      match tc {
        PrimaryKey(cols, c) => PrimaryKey(key_cols(cols), c)
        Unique(cols, c) => Unique(key_cols(cols), c)
        Check(e) => Check(self.table_expr(e))
        ForeignKey(cols, t, rc) =>
          ForeignKey(cols.map(n => self.name(n)), t, rc)
      }
    }),
  }
}
