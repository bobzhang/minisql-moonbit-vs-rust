// Statement execution.


use crate::ast::*;
use crate::db::{is_rowid_name, is_schema_table, key, Database, Table};
use crate::error::{err, Result};
use crate::eval::{bind, eval, Cx, Scope, Source};
use crate::func::update_conn_state;
use crate::parser::parse_statement;
use crate::value::{Affinity, Collation, Value};

pub type Row = Vec<Value>;

/// One entry of the undo log.
#[derive(Clone, Debug)]
pub enum Undo {
    /// The row at `rowid` of table `table` was `old` before the change.
    Row { table: String, rowid: i64, old: Option<Row> },
    /// The AUTOINCREMENT counter of `table` was `old`.
    Seq { table: String, old: i64 },
    /// The whole catalog before a schema change.
    Catalog(Box<Database>),
}

/// A uniqueness constraint of a table: the rowid or unique `indexes[i]`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Cons {
    Rowid,
    Unique(usize),
}

/// How a constraint violation is resolved.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Action {
    Conflict(Conflict),
    UpsertNothing,
    UpsertUpdate(usize),
}

enum BoundUpsertAction {
    Nothing,
    /// Assignments (column index, or `ncols` for the rowid) and filter,
    /// bound against `[target row, rowid, excluded row, rowid]`.
    Update { sets: Vec<(usize, Expr)>, where_: Option<Expr> },
}

struct BoundUpsert {
    /// None = matches every constraint.
    target: Option<Vec<Cons>>,
    action: BoundUpsertAction,
}

/// Per-statement context for writing rows into one table.
struct WriteCtx<'a> {
    tkey: &'a str,
    or: Option<Conflict>,
    /// CHECK constraints bound against `[columns..., rowid]`.
    checks: &'a [Expr],
    upserts: &'a [BoundUpsert],
}

#[derive(Default)]
pub struct Engine {
    pub db: Database,
    /// Undo log of the current statement, or of the whole transaction.
    pub(crate) undo: Vec<Undo>,
    pub(crate) in_txn: bool,
    /// Savepoint stack: (name, undo log length when created).
    savepoints: Vec<(String, usize)>,
    /// The transaction was opened by SAVEPOINT (releasing it commits).
    txn_by_savepoint: bool,
    /// Rows changed by the current statement.
    stmt_changes: i64,
    /// The current statement failed with FAIL resolution (keep its changes).
    stmt_fail: bool,
    /// The current statement failed with ROLLBACK resolution.
    stmt_rollback: bool,
    /// The current statement started changing data.
    stmt_started: bool,
    /// Page size and header of the database file loaded, if any.
    pub file_page_size: usize,
    pub file_header: Option<Vec<u8>>,
    /// Schema (type, name, tbl_name, sql) as loaded from the file.
    pub file_schema: Vec<String>,
    /// A statement changed data or schema since the file was loaded.
    pub dirty: bool,
}

impl Engine {
    pub fn new() -> Engine {
        Engine::default()
    }

    /// Execute one SQL statement, returning its result rows.
    pub fn execute(&mut self, sql: &str) -> Result<Vec<Row>> {
        let stmt = parse_statement(sql)?;
        match stmt {
            Stmt::Select(sel) => self.select(&sel),
            Stmt::CreateTable(ct) => self.run_ddl(|e| e.create_table(ct, sql)),
            Stmt::DropTable { name, if_exists } => self.run_ddl(|e| e.drop_table(&name, if_exists)),
            Stmt::CreateIndex(ci) => self.run_ddl(|e| e.create_index(ci, sql)),
            Stmt::DropIndex { name, if_exists } => self.run_ddl(|e| e.drop_index(&name, if_exists)),
            Stmt::CreateView(cv) => self.run_ddl(|e| e.create_view(cv, sql)),
            Stmt::DropView { name, if_exists } => self.run_ddl(|e| e.drop_view(&name, if_exists)),
            Stmt::Alter { table, action } => self.run_ddl(|e| e.alter(&table, action, sql)),
            Stmt::Insert(ins) => self.run_dml(|e| e.insert(&ins)),
            Stmt::Update(upd) => self.run_dml(|e| e.update(&upd)),
            Stmt::Delete(del) => self.run_dml(|e| e.delete(&del)),
            Stmt::Begin => {
                if self.in_txn {
                    return err!("cannot start a transaction within a transaction");
                }
                self.in_txn = true;
                self.txn_by_savepoint = false;
                Ok(vec![])
            }
            Stmt::Commit => {
                if !self.in_txn {
                    return err!("cannot commit - no transaction is active");
                }
                self.end_txn();
                Ok(vec![])
            }
            Stmt::Rollback => {
                if !self.in_txn {
                    return err!("cannot rollback - no transaction is active");
                }
                self.rollback_to(0);
                self.end_txn();
                Ok(vec![])
            }
            Stmt::Savepoint(name) => {
                if !self.in_txn {
                    self.in_txn = true;
                    self.txn_by_savepoint = true;
                }
                self.savepoints.push((name, self.undo.len()));
                Ok(vec![])
            }
            Stmt::Release(name) => {
                let Some(pos) = self.find_savepoint(&name) else {
                    return err!("no such savepoint: {}", name);
                };
                self.savepoints.truncate(pos);
                if self.savepoints.is_empty() && self.txn_by_savepoint {
                    self.end_txn();
                }
                Ok(vec![])
            }
            Stmt::RollbackTo(name) => {
                let Some(pos) = self.find_savepoint(&name) else {
                    return err!("no such savepoint: {}", name);
                };
                let mark = self.savepoints[pos].1;
                self.rollback_to(mark);
                self.savepoints.truncate(pos + 1);
                Ok(vec![])
            }
        }
    }

    /// Roll back a transaction left open (at exit).
    pub fn abort_txn(&mut self) {
        if self.in_txn {
            self.rollback_to(0);
            self.end_txn();
        }
    }

    /// Schema entries compared to detect schema changes.
    pub fn schema_signature(&self) -> Vec<String> {
        self.db
            .schema_rows()
            .into_iter()
            .map(|mut r| {
                r.remove(3);
                format!("{:?}", r)
            })
            .collect()
    }

    /// Write the committed database to `path`.
    pub fn save(&mut self, path: &str, existed: bool) {
        self.abort_txn();
        if !self.dirty {
            if !existed {
                crate::io::write_file(path, &[]);
            }
            return;
        }
        let ps = if self.file_page_size == 0 { 4096 } else { self.file_page_size };
        let changed = self.schema_signature() != self.file_schema;
        let data = crate::write::build_file(&self.db, ps, self.file_header.as_deref(), changed);
        crate::io::write_file(path, &data);
    }

    fn find_savepoint(&self, name: &str) -> Option<usize> {
        self.savepoints.iter().rposition(|(n, _)| n.eq_ignore_ascii_case(name))
    }

    /// Commit (the undo log is simply dropped).
    fn end_txn(&mut self) {
        self.undo.clear();
        self.savepoints.clear();
        self.in_txn = false;
        self.txn_by_savepoint = false;
    }

    /// Run a schema-changing statement atomically.
    fn run_ddl(&mut self, f: impl FnOnce(&mut Engine) -> Result<()>) -> Result<Vec<Row>> {
        let start = self.undo.len();
        self.undo.push(Undo::Catalog(Box::new(self.db.clone())));
        let res = f(self);
        if res.is_err() {
            self.rollback_to(start);
        } else {
            self.dirty = true;
        }
        if !self.in_txn {
            self.undo.clear();
        }
        res.map(|_| vec![])
    }

    /// Run a data-changing statement atomically and maintain the change
    /// counters.
    fn run_dml(&mut self, f: impl FnOnce(&mut Engine) -> Result<Vec<Row>>) -> Result<Vec<Row>> {
        let start = self.undo.len();
        self.stmt_changes = 0;
        self.stmt_fail = false;
        self.stmt_rollback = false;
        self.stmt_started = false;
        let res = f(self);
        let keep = res.is_ok() || self.stmt_fail;
        if keep {
            self.dirty = true;
            let n = self.stmt_changes;
            update_conn_state(|c| {
                c.changes = n;
                c.total_changes += n;
            });
        } else {
            self.rollback_to(start);
            if self.stmt_started {
                update_conn_state(|c| c.changes = 0);
            }
        }
        if res.is_err() && self.stmt_rollback && self.in_txn {
            self.rollback_to(0);
            self.end_txn();
        }
        if !self.in_txn {
            self.undo.clear();
        }
        res
    }

    pub(crate) fn rollback_to(&mut self, start: usize) {
        while self.undo.len() > start {
            match self.undo.pop().unwrap() {
                Undo::Row { table, rowid, old } => {
                    if let Some(t) = self.db.table_mut(&table) {
                        t.remove_row(rowid);
                        if let Some(r) = old {
                            t.insert_row(rowid, r);
                        }
                    }
                }
                Undo::Seq { table, old } => {
                    if let Some(t) = self.db.table_mut(&table) {
                        t.seq = old;
                    }
                }
                Undo::Catalog(db) => self.db = *db,
            }
        }
    }

    // ---- logged row mutations ----

    fn put_row(&mut self, tkey: &str, rowid: i64, row: Row) {
        let t = self.db.table_mut(tkey).unwrap();
        let old = t.remove_row(rowid);
        t.insert_row(rowid, row);
        self.undo.push(Undo::Row { table: tkey.to_string(), rowid, old });
    }

    fn del_row(&mut self, tkey: &str, rowid: i64) -> Option<Row> {
        let t = self.db.table_mut(tkey).unwrap();
        let old = t.remove_row(rowid)?;
        self.undo.push(Undo::Row { table: tkey.to_string(), rowid, old: Some(old.clone()) });
        Some(old)
    }

    // ---- row writing with constraint checks ----

    /// Resolution for a violated uniqueness constraint.
    fn unique_action(&self, w: &WriteCtx, t: &Table, c: Cons) -> Action {
        for (i, u) in w.upserts.iter().enumerate() {
            let hit = match &u.target {
                None => true,
                Some(ts) => ts.contains(&c),
            };
            if hit {
                return match u.action {
                    BoundUpsertAction::Nothing => Action::UpsertNothing,
                    BoundUpsertAction::Update { .. } => Action::UpsertUpdate(i),
                };
            }
        }
        let own = match c {
            Cons::Rowid => t.rowid_conflict,
            Cons::Unique(i) => t.indexes[i].conflict,
        };
        Action::Conflict(w.or.or(own).unwrap_or(Conflict::Abort))
    }

    /// Record FAIL resolution so the statement keeps its earlier changes.
    fn fail_with<T>(&mut self, c: Conflict, msg: String) -> Result<T> {
        if c == Conflict::Fail {
            self.stmt_fail = true;
        }
        if c == Conflict::Rollback {
            self.stmt_rollback = true;
        }
        Err(crate::error::Error::new(msg))
    }

    /// Write a row (insert when `old_rowid` is None, else update the row at
    /// `old_rowid`) after checking every constraint. `rowid` None means
    /// allocate one. Returns the written row, or None if it was skipped.
    fn write_row(
        &mut self,
        w: &WriteCtx,
        old_rowid: Option<i64>,
        rowid: Option<i64>,
        mut row: Row,
    ) -> Result<Option<(i64, Row)>> {
        let t = self.db.tables.get(w.tkey).unwrap();
        let tname = t.name.clone();
        let rowid = match rowid {
            Some(r) => r,
            None => match t.next_rowid() {
                Some(r) => r,
                None => return err!("database or disk is full"),
            },
        };
        if let Some(a) = t.rowid_alias {
            row[a] = Value::Int(rowid);
        }
        // AUTOINCREMENT remembers every rowid an insert attempted.
        if old_rowid.is_none() && t.autoincrement && rowid > t.seq {
            let old = t.seq;
            self.db.table_mut(w.tkey).unwrap().seq = rowid;
            self.undo.push(Undo::Seq { table: w.tkey.to_string(), old });
        }
        let t = self.db.tables.get(w.tkey).unwrap();

        // NOT NULL, in column order.
        for i in 0..t.columns.len() {
            let col = &t.columns[i];
            if !row[i].is_null() || t.rowid_alias == Some(i) {
                continue;
            }
            let Some(own) = col.not_null else { continue };
            let msg = format!("NOT NULL constraint failed: {}.{}", tname, col.name);
            match w.or.unwrap_or(own) {
                Conflict::Ignore => return Ok(None),
                Conflict::Replace if col.default.is_some() => {
                    let empty = Database::default();
                    let v = eval(&bind(col.default.as_ref().unwrap(), &Scope::default())?, &[], &Cx::new(&empty))?;
                    let v = v.apply_affinity(col.affinity);
                    if v.is_null() {
                        return err!("{}", msg);
                    }
                    row[i] = v;
                }
                Conflict::Replace => return err!("{}", msg),
                c => return self.fail_with(c, msg),
            }
        }

        // CHECK constraints.
        if !w.checks.is_empty() {
            let mut buf = row.clone();
            buf.push(Value::Int(rowid));
            let empty = Database::default();
            let cx = Cx::new(&empty);
            for c in w.checks {
                if eval(c, &buf, &cx)?.truthy() == Some(false) {
                    let msg = format!("CHECK constraint failed: {}", tname);
                    match w.or.unwrap_or(Conflict::Abort) {
                        Conflict::Ignore => return Ok(None),
                        Conflict::Replace => return err!("{}", msg),
                        c => return self.fail_with(c, msg),
                    }
                }
            }
        }

        // Uniqueness: upsert targets first, then the rowid, then the other
        // keys most recently declared first; REPLACE resolutions last.
        let t = self.db.tables.get(w.tkey).unwrap();
        let mut order: Vec<Cons> = Vec::new();
        for u in w.upserts {
            if let Some(ts) = &u.target {
                for c in ts {
                    if !order.contains(c) {
                        order.push(*c);
                    }
                }
            }
        }
        if !order.contains(&Cons::Rowid) {
            order.push(Cons::Rowid);
        }
        for i in (0..t.indexes.len()).rev() {
            if t.indexes[i].unique && !order.contains(&Cons::Unique(i)) {
                order.push(Cons::Unique(i));
            }
        }
        let mut checks: Vec<(Cons, Action)> = order.into_iter().map(|c| (c, self.unique_action(w, t, c))).collect();
        checks.sort_by_key(|(_, a)| *a == Action::Conflict(Conflict::Replace));
        for (c, act) in checks {
            let t = self.db.tables.get(w.tkey).unwrap();
            let hit = match c {
                Cons::Rowid => {
                    if old_rowid != Some(rowid) && t.rows.contains_key(&rowid) {
                        Some(rowid)
                    } else {
                        None
                    }
                }
                Cons::Unique(i) => t.indexes[i].find(&row, rowid, old_rowid),
            };
            let Some(hit) = hit else { continue };
            let msg = || {
                let cols = match c {
                    Cons::Rowid => {
                        let n = t.rowid_alias.map(|a| t.columns[a].name.as_str()).unwrap_or("rowid");
                        format!("{}.{}", tname, n)
                    }
                    Cons::Unique(i) => match t.indexes[i].plain_cols() {
                        Some(cols) => cols
                            .iter()
                            .map(|&c| format!("{}.{}", tname, t.columns[c].name))
                            .collect::<Vec<_>>()
                            .join(", "),
                        None => format!("index '{}'", t.indexes[i].name),
                    },
                };
                format!("UNIQUE constraint failed: {}", cols)
            };
            match act {
                Action::Conflict(Conflict::Ignore) | Action::UpsertNothing => return Ok(None),
                Action::UpsertUpdate(k) => return self.upsert_update(w, k, hit, rowid, row),
                Action::Conflict(Conflict::Replace) => {
                    self.del_row(w.tkey, hit);
                }
                Action::Conflict(cf) => {
                    let m = msg();
                    return self.fail_with(cf, m);
                }
            }
        }

        // Write.
        if let Some(o) = old_rowid {
            if o != rowid {
                self.del_row(w.tkey, o);
            }
        }
        self.put_row(w.tkey, rowid, row.clone());
        if old_rowid.is_none() {
            update_conn_state(|c| c.last_insert_rowid = rowid);
        }
        self.stmt_changes += 1;
        Ok(Some((rowid, row)))
    }

    /// Upsert DO UPDATE of the existing row `target` with the proposed
    /// (excluded) row.
    fn upsert_update(
        &mut self,
        w: &WriteCtx,
        k: usize,
        target: i64,
        prop_rowid: i64,
        prop: Row,
    ) -> Result<Option<(i64, Row)>> {
        let BoundUpsertAction::Update { sets, where_ } = &w.upserts[k].action else { unreachable!() };
        let t = self.db.tables.get(w.tkey).unwrap();
        let existing = t.rows[&target].clone();
        let mut buf = existing.clone();
        buf.push(Value::Int(target));
        buf.extend(prop);
        buf.push(Value::Int(prop_rowid));
        let cx = Cx::new(&self.db);
        if let Some(wh) = where_ {
            if eval(wh, &buf, &cx)?.truthy() != Some(true) {
                return Ok(None);
            }
        }
        let (new_rowid, new_row) = assign(t, target, existing, sets, &buf, &cx)?;
        let ctx = WriteCtx { tkey: w.tkey, or: Some(Conflict::Abort), checks: w.checks, upserts: &[] };
        self.write_row(&ctx, Some(target), Some(new_rowid), new_row)
    }

    fn bind_checks(t: &Table) -> Result<Vec<Expr>> {
        let scope = Scope::with_sources(vec![table_source(t, None, 0)]);
        t.checks.iter().map(|c| bind(&c.expr, &scope)).collect()
    }

    /// RETURNING expressions resolve against the table name (not an alias).
    fn bind_returning(&self, t: &Table, cols: &Option<Vec<ResultCol>>) -> Result<Option<Vec<Expr>>> {
        let Some(cols) = cols else { return Ok(None) };
        let scope = Scope { sources: vec![table_source(t, None, 0)], db: Some(&self.db), ..Default::default() };
        let mut out = Vec::new();
        for rc in cols {
            match rc {
                ResultCol::Star => {
                    for (i, c) in t.columns.iter().enumerate() {
                        out.push(Expr::Col { idx: i, aff: c.affinity, coll: c.coll() });
                    }
                }
                ResultCol::TableStar(_) => return err!("RETURNING may not use \"TABLE.*\" wildcards"),
                ResultCol::Expr { expr, .. } => out.push(bind(expr, &scope)?),
            }
        }
        Ok(Some(out))
    }

    // ---- INSERT ----

    fn insert(&mut self, ins: &Insert) -> Result<Vec<Row>> {
        let tkey = key(&ins.table);
        self.check_writable(&ins.table)?;
        let table = match self.db.tables.get(&tkey) {
            Some(t) => t,
            None => return err!("no such table: {}", ins.table),
        };
        let ncols = table.columns.len();
        // Target positions: Some(column index) or None for the rowid.
        let targets: Vec<Option<usize>> = match &ins.columns {
            None => (0..ncols).map(Some).collect(),
            Some(names) => {
                let mut t = Vec::new();
                for n in names {
                    match table.column_index(n) {
                        Some(i) => t.push(Some(i)),
                        None if is_rowid_name(n) => t.push(None),
                        None => return err!("table {} has no column named {}", table.name, n),
                    }
                }
                t
            }
        };
        let checks = Self::bind_checks(table)?;
        let returning = self.bind_returning(table, &ins.returning)?;
        let upserts = self.bind_upserts(table, ins)?;
        let empty = Scope::default();
        let ctes = crate::query::with_env(&ins.with, None)?;
        let values_scope = Scope { db: Some(&self.db), ctes: ctes.clone(), ..Default::default() };
        let defaults: Vec<Option<Expr>> = table
            .columns
            .iter()
            .map(|c| c.default.as_ref().map(|d| bind(d, &empty)).transpose())
            .collect::<Result<_>>()?;
        let alias = table.rowid_alias;
        let affs: Vec<Affinity> = table.columns.iter().map(|c| c.affinity).collect();

        enum Src {
            Exprs(Vec<Vec<Expr>>),
            Rows(Vec<Row>),
        }
        let source = match &ins.source {
            InsertSource::Values(rows) => {
                let width = rows[0].len();
                if rows.iter().any(|r| r.len() != width) {
                    return err!("all VALUES must have the same number of terms");
                }
                check_width(table, &ins.columns, targets.len(), width)?;
                let bound = rows
                    .iter()
                    .map(|r| r.iter().map(|e| bind(e, &values_scope)).collect::<Result<Vec<_>>>())
                    .collect::<Result<Vec<_>>>()?;
                Src::Exprs(bound)
            }
            InsertSource::Select(sel) => {
                let rows = self.select_in(sel, ctes.clone())?;
                let width = rows.first().map(|r| r.len()).unwrap_or(targets.len());
                check_width(self.db.tables.get(&tkey).unwrap(), &ins.columns, targets.len(), width)?;
                Src::Rows(rows)
            }
            InsertSource::Default => Src::Rows(vec![vec![]]),
        };
        let targets = if matches!(ins.source, InsertSource::Default) { vec![] } else { targets };
        let nrows = match &source {
            Src::Exprs(r) => r.len(),
            Src::Rows(r) => r.len(),
        };

        self.stmt_started = true;
        let w = WriteCtx { tkey: &tkey, or: ins.or, checks: &checks, upserts: &upserts };
        let mut out = Vec::new();
        let no_db = Database::default();
        let dcx = Cx::new(&no_db);
        // Source rows are computed before any row is written.
        let source: Vec<Row> = match source {
            Src::Exprs(r) => {
                let cx = Cx::new(&self.db);
                r.iter().map(|r| r.iter().map(|e| eval(e, &[], &cx)).collect::<Result<Row>>()).collect::<Result<_>>()?
            }
            Src::Rows(r) => r,
        };
        for src in source.into_iter().take(nrows) {
            let mut row: Vec<Option<Value>> = vec![None; ncols];
            let mut explicit_rowid: Option<Value> = None;
            for (t, v) in targets.iter().zip(src) {
                // The first mention of a column wins.
                match t {
                    Some(i) => {
                        if row[*i].is_none() {
                            row[*i] = Some(v);
                        }
                    }
                    None => {
                        if explicit_rowid.is_none() {
                            explicit_rowid = Some(v);
                        }
                    }
                }
            }
            let mut full = Vec::with_capacity(ncols);
            for (i, v) in row.into_iter().enumerate() {
                let v = match v {
                    Some(v) => v,
                    None => match &defaults[i] {
                        Some(d) => eval(d, &[], &dcx)?,
                        None => Value::Null,
                    },
                };
                full.push(v.apply_affinity(affs[i]));
            }
            if let Some(a) = alias {
                if !full[a].is_null() {
                    explicit_rowid = Some(full[a].clone());
                }
            }
            let rowid = match explicit_rowid {
                None | Some(Value::Null) => None,
                Some(v) => Some(to_rowid(v)?),
            };
            if let Some((r, row)) = self.write_row(&w, None, rowid, full)? {
                if let Some(ret) = &returning {
                    out.push(eval_row(ret, row, r, &Cx::new(&self.db))?);
                }
            }
        }
        Ok(out)
    }

    fn bind_upserts(&self, t: &Table, ins: &Insert) -> Result<Vec<BoundUpsert>> {
        let n = t.columns.len();
        let mut out = Vec::new();
        for u in &ins.upserts {
            let target = match &u.target {
                None => None,
                Some(cols) => {
                    // (column, explicit collation)
                    let mut idx: Vec<(usize, Option<Collation>)> = Vec::new();
                    for c in cols {
                        let coll = match &c.collate {
                            Some(name) => match Collation::from_name(name) {
                                Some(x) => Some(x),
                                None => return err!("no such collation sequence: {}", name),
                            },
                            None => None,
                        };
                        match &c.expr {
                            Expr::Column { table: None, name, .. } => match t.column_index(name) {
                                Some(i) => idx.push((i, coll)),
                                None if is_rowid_name(name) => idx.push((n, coll)),
                                None => return err!("no such column: {}", name),
                            },
                            _ => return err!("ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint"),
                        }
                    }
                    let mut hits = Vec::new();
                    if idx.len() == 1 && (Some(idx[0].0) == t.rowid_alias || idx[0].0 == n) {
                        hits.push(Cons::Rowid);
                    }
                    for (i, uk) in t.indexes.iter().enumerate() {
                        let Some(ucols) = uk.plain_cols().filter(|_| uk.unique && uk.where_.is_none()) else {
                            continue;
                        };
                        // Every key column named once, with a matching collation.
                        let matches = ucols.len() == idx.len()
                            && ucols.iter().zip(&uk.cols).all(|(c, ic)| {
                                idx.iter().any(|(x, icoll)| x == c && icoll.is_none_or(|y| y == ic.coll))
                            })
                            && idx.iter().all(|(x, _)| ucols.contains(x));
                        if matches {
                            hits.push(Cons::Unique(i));
                        }
                    }
                    if hits.is_empty() {
                        return err!("ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint");
                    }
                    Some(hits)
                }
            };
            let action = match &u.action {
                UpsertAction::Nothing => BoundUpsertAction::Nothing,
                UpsertAction::Update { sets, where_ } => {
                    let mut ex = table_source(t, Some("excluded"), n + 1);
                    ex.qualified_only = true;
                    let scope = Scope::with_sources(vec![table_source(t, ins.alias.as_deref(), 0), ex]);
                    let sets = bind_sets(t, sets, &scope)?;
                    let where_ = where_.as_ref().map(|e| bind(e, &scope)).transpose()?;
                    BoundUpsertAction::Update { sets, where_ }
                }
            };
            out.push(BoundUpsert { target, action });
        }
        Ok(out)
    }

    // ---- UPDATE ----

    fn update(&mut self, upd: &Update) -> Result<Vec<Row>> {
        let tkey = key(&upd.table);
        self.check_writable(&upd.table)?;
        let t = match self.db.tables.get(&tkey) {
            Some(t) => t,
            None => return err!("no such table: {}", upd.table),
        };
        let scope = Scope {
            sources: vec![table_source(t, upd.alias.as_deref(), 0)],
            db: Some(&self.db),
            ctes: crate::query::with_env(&upd.with, None)?,
            ..Default::default()
        };
        let sets = bind_sets(t, &upd.sets, &scope)?;
        let where_ = upd.where_.as_ref().map(|e| bind(e, &scope)).transpose()?;
        let checks = Self::bind_checks(t)?;
        let returning = self.bind_returning(t, &upd.returning)?;
        let ids = matching_rowids(t, &where_, &Cx::new(&self.db))?;

        self.stmt_started = true;
        let w = WriteCtx { tkey: &tkey, or: upd.or, checks: &checks, upserts: &[] };
        let mut out = Vec::new();
        for id in ids {
            let t = self.db.tables.get(&tkey).unwrap();
            let Some(row) = t.rows.get(&id) else { continue };
            let mut buf = row.clone();
            buf.push(Value::Int(id));
            let (new_rowid, new_row) = assign(t, id, row.clone(), &sets, &buf, &Cx::new(&self.db))?;
            if let Some((r, row)) = self.write_row(&w, Some(id), Some(new_rowid), new_row)? {
                if let Some(ret) = &returning {
                    out.push(eval_row(ret, row, r, &Cx::new(&self.db))?);
                }
            }
        }
        Ok(out)
    }

    // ---- DELETE ----

    fn delete(&mut self, del: &Delete) -> Result<Vec<Row>> {
        let tkey = key(&del.table);
        self.check_writable(&del.table)?;
        let t = match self.db.tables.get(&tkey) {
            Some(t) => t,
            None => return err!("no such table: {}", del.table),
        };
        let scope = Scope {
            sources: vec![table_source(t, del.alias.as_deref(), 0)],
            db: Some(&self.db),
            ctes: crate::query::with_env(&del.with, None)?,
            ..Default::default()
        };
        let where_ = del.where_.as_ref().map(|e| bind(e, &scope)).transpose()?;
        let returning = self.bind_returning(t, &del.returning)?;
        let ids = matching_rowids(t, &where_, &Cx::new(&self.db))?;

        self.stmt_started = true;
        let mut out = Vec::new();
        for id in ids {
            if let Some(row) = self.del_row(&tkey, id) {
                self.stmt_changes += 1;
                if let Some(ret) = &returning {
                    out.push(eval_row(ret, row, id, &Cx::new(&self.db))?);
                }
            }
        }
        Ok(out)
    }

    fn check_writable(&self, name: &str) -> Result<()> {
        if self.db.table(name).is_none() {
            if self.db.view(name).is_some() {
                return err!("cannot modify {} because it is a view", name);
            }
            if is_schema_table(name) {
                return err!("table sqlite_master may not be modified");
            }
        }
        Ok(())
    }

    // ---- SELECT ----

    pub fn select(&self, sel: &Select) -> Result<Vec<Row>> {
        self.select_in(sel, None)
    }

    /// Run a query that sees the given CTEs.
    fn select_in(&self, sel: &Select, ctes: Option<std::rc::Rc<crate::query::CteEnv>>) -> Result<Vec<Row>> {
        let scope = Scope { db: Some(&self.db), ctes, ..Default::default() };
        let plan = crate::query::plan_select(sel, &scope)?;
        crate::query::exec_query(&plan, &Cx::new(&self.db), None)
    }
}

/// Name-resolution source for a table whose rows are laid out as
/// `[columns..., rowid]` starting at `offset`.
pub fn table_source(t: &Table, alias: Option<&str>, offset: usize) -> Source {
    Source::new(
        alias.map(|a| a.to_string()).unwrap_or_else(|| t.name.clone()),
        t.columns.iter().map(|c| (c.name.clone(), c.affinity, c.coll())).collect(),
        offset,
        Some(offset + t.columns.len()),
    )
}

fn check_width(table: &Table, cols: &Option<Vec<String>>, ntargets: usize, width: usize) -> Result<()> {
    if width != ntargets {
        return match cols {
            None => err!("table {} has {} columns but {} values were supplied", table.name, ntargets, width),
            Some(_) => err!("{} values for {} columns", width, ntargets),
        };
    }
    Ok(())
}


/// Bind `SET` assignments: (column index, or ncols for the rowid, expr).
fn bind_sets(t: &Table, sets: &[(String, Expr)], scope: &Scope) -> Result<Vec<(usize, Expr)>> {
    let mut out = Vec::new();
    for (name, e) in sets {
        let idx = match t.column_index(name) {
            Some(i) => i,
            None if is_rowid_name(name) => t.columns.len(),
            None => return err!("no such column: {}", name),
        };
        out.push((idx, bind(e, scope)?));
    }
    Ok(out)
}

/// Apply assignments to `row` (the row at `rowid`), evaluating them on
/// `buf`. Returns the new rowid and row.
fn assign(t: &Table, rowid: i64, mut row: Row, sets: &[(usize, Expr)], buf: &[Value], cx: &Cx) -> Result<(i64, Row)> {
    let n = t.columns.len();
    let mut new_rowid = rowid;
    for (i, e) in sets {
        let v = eval(e, buf, cx)?;
        if *i == n || Some(*i) == t.rowid_alias {
            new_rowid = match v {
                Value::Null => return err!("datatype mismatch"),
                v => to_rowid(v)?,
            };
        } else {
            row[*i] = v.apply_affinity(t.columns[*i].affinity);
        }
    }
    Ok((new_rowid, row))
}

/// Convert an explicit rowid value to an integer.
fn to_rowid(v: Value) -> Result<i64> {
    match v.apply_affinity(Affinity::Integer) {
        Value::Int(i) => Ok(i),
        _ => err!("datatype mismatch"),
    }
}

/// Evaluate RETURNING expressions for a row.
fn eval_row(exprs: &[Expr], mut row: Row, rowid: i64, cx: &Cx) -> Result<Row> {
    row.push(Value::Int(rowid));
    exprs.iter().map(|e| eval(e, &row, cx)).collect()
}

/// Rowids of the rows satisfying `where_` (rowid order for full scans,
/// index order for index lookups).
fn matching_rowids(t: &Table, where_: &Option<Expr>, cx: &Cx) -> Result<Vec<i64>> {
    let Some(w) = where_ else { return Ok(t.rows.keys().copied().collect()) };
    let mut conjs = Vec::new();
    crate::access::conjuncts(w, &mut conjs);
    let access = crate::access::plan_access(t, 0, &conjs, false);
    let candidates = crate::access::lookup_rowids(t, &access, &[], cx)?;
    let mut ids = Vec::new();
    let mut buf: Vec<Value> = Vec::with_capacity(t.columns.len() + 1);
    for id in candidates {
        let Some(row) = t.rows.get(&id) else { continue };
        buf.clear();
        buf.extend(row.iter().cloned());
        buf.push(Value::Int(id));
        if eval(w, &buf, cx)?.truthy() == Some(true) {
            ids.push(id);
        }
    }
    Ok(ids)
}
