// Statement execution.


use std::cell::Cell;
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

use crate::ast::*;
use crate::db::{self, key, Check, Column, Database, IdxCol, Index, Table};
use crate::{access, ddl};
use crate::eval::{bind, eval, BExpr, Env, Scope};
use crate::query::{self, plan_query, run_query, table_scope, table_source, Rows};
use crate::value::{apply_affinity, Affinity, Coll, Value};

/// Executes one statement; returns the result rows (possibly empty).
pub fn execute(db: &mut Database, stmt: &Stmt) -> Result<Rows, String> {
    let res = match stmt {
        Stmt::Begin => db.begin().map(|_| Vec::new()),
        Stmt::Commit => db.commit().map(|_| Vec::new()),
        Stmt::Rollback(None) => db.rollback().map(|_| Vec::new()),
        Stmt::Rollback(Some(name)) => db.rollback_to_savepoint(name).map(|_| Vec::new()),
        Stmt::Savepoint(name) => {
            db.savepoint(name);
            Ok(Vec::new())
        }
        Stmt::Release(name) => db.release(name).map(|_| Vec::new()),
        Stmt::Insert(ins) => crate::cte::with_scope(ins.with.as_ref(), || run_dml(db, |db, ctx| insert(db, ins, ctx))),
        Stmt::Update(upd) => crate::cte::with_scope(upd.with.as_ref(), || run_dml(db, |db, ctx| update(db, upd, ctx))),
        Stmt::Delete(del) => crate::cte::with_scope(del.with.as_ref(), || run_dml(db, |db, ctx| delete(db, del, ctx))),
        Stmt::Select(sel) => query::select(db, sel),
        _ => {
            let mark = db.mark();
            let r = ddl::execute(db, stmt);
            if r.is_err() {
                db.rollback_to(mark);
            }
            r.map(|_| Vec::new())
        }
    };
    db.end_statement();
    res
}

// ---------- CREATE TABLE ----------

/// Builds an empty table (with its automatic indexes) from its definition.
pub fn build_table(db: &Database, ct: &CreateTable) -> Result<Table, String> {
    let mut columns: Vec<Column> = Vec::new();
    let mut checks: Vec<Check> = Vec::new();
    // uniqueness constraints in declaration order: (columns with explicit
    // collation, conflict clause, is primary key)
    type Uniq = (Vec<(usize, Option<String>)>, Option<Conflict>, bool);
    let mut uniques: Vec<Uniq> = Vec::new();
    let mut pk_seen = false;
    let mut pk_col_desc = false;
    let mut autoinc = false;
    let more_pk = || format!("table \"{}\" has more than one primary key", ct.name);
    for cd in &ct.columns {
        if columns.iter().any(|c| c.name.eq_ignore_ascii_case(&cd.name)) {
            return Err(format!("duplicate column name: {}", cd.name));
        }
        let ci = columns.len();
        let mut col = Column {
            name: cd.name.clone(),
            decl_type: cd.type_name.clone(),
            affinity: Affinity::from_type(cd.type_name.as_deref()),
            default: None,
            coll: None,
            not_null: None,
        };
        for c in &cd.constraints {
            match c {
                ColumnConstraint::Default(e) => col.default = Some(e.clone()),
                ColumnConstraint::Collate(name) => col.coll = Some(Coll::from_name(name)?),
                ColumnConstraint::NotNull(cl) => col.not_null = Some(*cl),
                ColumnConstraint::PrimaryKey { desc, conflict, autoincrement } => {
                    if pk_seen {
                        return Err(more_pk());
                    }
                    pk_seen = true;
                    pk_col_desc = *desc;
                    autoinc |= *autoincrement;
                    uniques.push((vec![(ci, None)], *conflict, true));
                }
                ColumnConstraint::Unique(cl) => uniques.push((vec![(ci, None)], *cl, false)),
                ColumnConstraint::Check(e, name) => checks.push(Check { name: name.clone(), expr: e.clone() }),
                _ => {}
            }
        }
        columns.push(col);
    }
    let resolve = |cols: &[IndexedColumn]| -> Result<Vec<(usize, Option<String>)>, String> {
        let mut v = Vec::new();
        for ic in cols {
            let name = match &ic.expr {
                Expr::Column { table: None, name, .. } => name,
                Expr::Literal(Value::Text(name)) => name,
                _ => return Err("expressions prohibited in PRIMARY KEY and UNIQUE constraints".to_string()),
            };
            match columns.iter().position(|c| c.name.eq_ignore_ascii_case(name)) {
                Some(i) => v.push((i, ic.collate.clone())),
                None => return Err(format!("no such column: {}", name)),
            }
        }
        Ok(v)
    };
    for tc in &ct.constraints {
        match tc {
            TableConstraint::PrimaryKey { columns: cols, conflict, autoincrement } => {
                if pk_seen {
                    return Err(more_pk());
                }
                pk_seen = true;
                autoinc |= *autoincrement;
                uniques.push((resolve(cols)?, *conflict, true));
            }
            TableConstraint::Unique { columns: cols, conflict } => uniques.push((resolve(cols)?, *conflict, false)),
            TableConstraint::Check(e, name) => checks.push(Check { name: name.clone(), expr: e.clone() }),
            TableConstraint::ForeignKey { .. } => {}
        }
    }
    // INTEGER PRIMARY KEY aliases the rowid
    let mut ipk = None;
    let mut pk_conflict = None;
    if let Some(pos) = uniques.iter().position(|u| u.2) {
        let (cols, conflict, _) = &uniques[pos];
        if cols.len() == 1 {
            let c = &columns[cols[0].0];
            let is_int = c.decl_type.as_deref().is_some_and(|t| t.eq_ignore_ascii_case("INTEGER"));
            let col_level = ct.columns[cols[0].0]
                .constraints
                .iter()
                .any(|k| matches!(k, ColumnConstraint::PrimaryKey { .. }));
            if is_int && !(col_level && pk_col_desc) {
                ipk = Some(cols[0].0);
                pk_conflict = *conflict;
                uniques.remove(pos);
            }
        }
    }
    if autoinc && ipk.is_none() {
        return Err("AUTOINCREMENT is only allowed on an INTEGER PRIMARY KEY".to_string());
    }
    let mut indexes: Vec<Index> = Vec::new();
    for (cols, conflict, _) in uniques {
        let mut idx_cols = Vec::new();
        let mut colls = Vec::new();
        for (ci, coll) in cols {
            let c = match coll {
                Some(name) => Coll::from_name(&name)?,
                None => columns[ci].coll.unwrap_or(Coll::Binary),
            };
            idx_cols.push(ci);
            colls.push(c);
        }
        let same = |i: &Index| {
            i.colls == colls
                && i.cols.len() == idx_cols.len()
                && i.cols.iter().zip(&idx_cols).all(|(a, b)| matches!(a, IdxCol::Col(x) if x == b))
        };
        if let Some(dup) = indexes.iter_mut().find(|i| same(i)) {
            if dup.conflict.is_none() {
                dup.conflict = conflict;
            }
            continue;
        }
        let name = format!("sqlite_autoindex_{}_{}", ct.name, indexes.len() + 1);
        let affs = idx_cols.iter().map(|&c| columns[c].affinity).collect();
        let desc = vec![false; idx_cols.len()];
        indexes.push(Index {
            name,
            auto: true,
            def: None,
            order: 0,
            cols: idx_cols.into_iter().map(IdxCol::Col).collect(),
            colls,
            desc,
            affs,
            pred: None,
            unique: true,
            conflict,
            entries: BTreeSet::new(),
            root: 0,
        });
    }
    let t = Table {
        name: ct.name.clone(),
        columns,
        rows: BTreeMap::new(),
        sql: ct.sql.clone(),
        ipk,
        pk_conflict,
        autoinc,
        checks,
        indexes,
        order: 0,
        temp: ct.temp,
        root: 0,
    };
    // validate CHECK and DEFAULT expressions
    let scope = table_scope(&t, &t.name);
    for c in &t.checks {
        bind(&c.expr, &scope, db)?;
    }
    for c in &t.columns {
        if let Some(d) = &c.default {
            if bind(d, &Scope::empty(), db).is_err() {
                return Err(format!("default value of column [{}] is not constant", c.name));
            }
        }
    }
    Ok(t)
}

// ---------- DML plumbing ----------

#[derive(Default)]
struct Ctx {
    /// Rows changed so far.
    changes: i64,
    /// Execution started (errors before this are "prepare" errors).
    started: bool,
    /// The error came from an OR FAIL conflict: keep earlier changes.
    keep: bool,
    /// The error came from an OR ROLLBACK conflict: end the transaction.
    abort_txn: bool,
}

/// Runs a DML statement with statement atomicity and change counting.
fn run_dml<F>(db: &mut Database, f: F) -> Result<Rows, String>
where
    F: FnOnce(&mut Database, &mut Ctx) -> Result<Rows, String>,
{
    let mark = db.mark();
    let mut ctx = Ctx::default();
    match f(db, &mut ctx) {
        Ok(rows) => {
            db::set_changes(ctx.changes);
            Ok(rows)
        }
        Err(e) => {
            if ctx.keep {
                db::set_changes(ctx.changes);
            } else if ctx.abort_txn && db.abort_txn() {
                db::set_changes(0);
            } else {
                db.rollback_to(mark);
                if ctx.started {
                    db::set_changes(0);
                }
            }
            Err(e)
        }
    }
}

fn is_rowid_name(n: &str) -> bool {
    n.eq_ignore_ascii_case("rowid") || n.eq_ignore_ascii_case("oid") || n.eq_ignore_ascii_case("_rowid_")
}

/// Column assigned by INSERT column lists and SET clauses.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Target {
    Col(usize),
    Rowid,
}

fn resolve_target(t: &Table, name: &str) -> Option<Target> {
    match t.column_index(name) {
        Some(i) if Some(i) == t.ipk => Some(Target::Rowid),
        Some(i) => Some(Target::Col(i)),
        None if is_rowid_name(name) => Some(Target::Rowid),
        None => None,
    }
}

/// Converts a value assigned to the rowid to an integer.
fn to_rowid(v: Value) -> Result<i64, String> {
    match apply_affinity(v, Affinity::Integer) {
        Value::Integer(i) => Ok(i),
        _ => Err("datatype mismatch".to_string()),
    }
}

/// Uniqueness constraint that an upsert targets.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Cons {
    Rowid,
    Index(usize),
}

struct PUpsert {
    target: Option<Cons>,
    /// None = DO NOTHING.
    update: Option<(Vec<(Target, BExpr)>, Option<BExpr>)>,
}

/// Per-statement information about the target table.
struct Meta {
    tkey: String,
    name: String,
    columns: Vec<Column>,
    ipk: Option<usize>,
    pk_conflict: Option<Conflict>,
    checks: Vec<(String, BExpr)>,
    defaults: Vec<Option<BExpr>>,
    /// Per index: unique, conflict clause, error message.
    indexes: Vec<(bool, Option<Conflict>, String)>,
}

impl Meta {
    fn new(t: &Table, db: &Database) -> Result<Meta, String> {
        let scope = table_scope(t, &t.name);
        let empty = Scope::empty();
        let mut checks = Vec::new();
        for c in &t.checks {
            checks.push((c.name.clone(), bind(&c.expr, &scope, db)?));
        }
        let mut defaults = Vec::new();
        for c in &t.columns {
            defaults.push(match &c.default {
                Some(d) => Some(bind(d, &empty, db)?),
                None => None,
            });
        }
        Ok(Meta {
            tkey: key(&t.name),
            name: t.name.clone(),
            columns: t.columns.clone(),
            ipk: t.ipk,
            pk_conflict: t.pk_conflict,
            checks,
            defaults,
            indexes: t.indexes.iter().map(|i| (i.unique, i.conflict, i.unique_err(t))).collect(),
        })
    }

    fn default_value(&self, i: usize, env: &Env) -> Result<Value, String> {
        let v = match &self.defaults[i] {
            Some(d) => eval(d, &[], env)?,
            None => Value::Null,
        };
        Ok(apply_affinity(v, self.columns[i].affinity))
    }

    fn unique_err(&self, cons: Cons) -> String {
        let cols: Vec<String> = match cons {
            Cons::Rowid => match self.ipk {
                Some(i) => vec![format!("{}.{}", self.name, self.columns[i].name)],
                None => vec![format!("{}.rowid", self.name)],
            },
            Cons::Index(i) => return self.indexes[i].2.clone(),
        };
        format!("UNIQUE constraint failed: {}", cols.join(", "))
    }
}

enum Outcome {
    Written(i64, Vec<Value>),
    Upserted(i64, Vec<Value>),
    Skipped,
}

fn constraint_err(ctx: &mut Ctx, mode: Conflict, msg: String) -> Result<Outcome, String> {
    ctx.keep = mode == Conflict::Fail;
    ctx.abort_txn = mode == Conflict::Rollback;
    Err(msg)
}

fn with_rowid(vals: &[Value], rowid: i64) -> Vec<Value> {
    let mut v = Vec::with_capacity(vals.len() + 1);
    v.extend_from_slice(vals);
    v.push(Value::Integer(rowid));
    v
}

/// Applies NOT NULL, CHECK and uniqueness constraints to a new version of a
/// row (`old` is the rowid of the row being updated) and writes it.
#[allow(clippy::too_many_arguments)]
fn write_row(
    db: &mut Database,
    m: &Meta,
    old: Option<i64>,
    rowid: i64,
    mut vals: Vec<Value>,
    or: Option<Conflict>,
    upserts: &[PUpsert],
    ctx: &mut Ctx,
) -> Result<Outcome, String> {
    // NOT NULL
    for (i, col) in m.columns.iter().enumerate() {
        let Some(clause) = col.not_null else { continue };
        if !vals[i].is_null() || Some(i) == m.ipk {
            continue;
        }
        let mode = or.or(clause).unwrap_or(Conflict::Abort);
        if mode == Conflict::Ignore {
            return Ok(Outcome::Skipped);
        }
        if mode == Conflict::Replace && m.defaults[i].is_some() {
            vals[i] = m.default_value(i, &Env::new(db))?;
            if !vals[i].is_null() {
                continue;
            }
        }
        return constraint_err(ctx, mode, format!("NOT NULL constraint failed: {}.{}", m.name, col.name));
    }
    // CHECK
    if !m.checks.is_empty() {
        let row = with_rowid(&vals, rowid);
        for (name, e) in &m.checks {
            if eval(e, &row, &Env::new(db))?.truth() == Some(false) {
                let mode = or.unwrap_or(Conflict::Abort);
                if mode == Conflict::Ignore {
                    return Ok(Outcome::Skipped);
                }
                return constraint_err(ctx, mode, format!("CHECK constraint failed: {}", name));
            }
        }
    }
    // uniqueness: upsert targets first, then non-REPLACE, then REPLACE
    let mode_of = |c: Cons| -> Conflict {
        let own = match c {
            Cons::Rowid => m.pk_conflict,
            Cons::Index(i) => m.indexes[i].1,
        };
        or.or(own).unwrap_or(Conflict::Abort)
    };
    let upsert_of = |c: Cons| upserts.iter().find(|u| u.target.is_none() || u.target == Some(c));
    let mut all: Vec<Cons> = Vec::new();
    if old != Some(rowid) {
        all.push(Cons::Rowid);
    }
    // SQLite checks the most recently created index first
    all.extend((0..m.indexes.len()).rev().filter(|&i| m.indexes[i].0).map(Cons::Index));
    let targeted = |c: Cons| upserts.iter().any(|u| u.target == Some(c));
    let is_replace = |c: Cons| mode_of(c) == Conflict::Replace;
    let mut order: Vec<Cons> = all.iter().copied().filter(|&c| targeted(c)).collect();
    order.extend(all.iter().copied().filter(|&c| !targeted(c) && !is_replace(c)));
    order.extend(all.iter().copied().filter(|&c| !targeted(c) && is_replace(c)));
    for c in order {
        let t = &db.tables[&m.tkey];
        let hit = match c {
            Cons::Rowid => t.rows.contains_key(&rowid).then_some(rowid),
            Cons::Index(i) => match t.indexes[i].key(&vals, rowid)? {
                Some(k) => t.indexes[i].find_conflict(&k, old),
                None => None,
            },
        };
        let Some(other) = hit else { continue };
        if let Some(u) = upsert_of(c) {
            return match &u.update {
                None => Ok(Outcome::Skipped),
                Some((sets, where_)) => upsert_update(db, m, other, &vals, rowid, sets, where_.as_ref(), ctx),
            };
        }
        match mode_of(c) {
            Conflict::Ignore => return Ok(Outcome::Skipped),
            Conflict::Replace => {
                db.delete_row(&m.tkey, other);
            }
            mode => return constraint_err(ctx, mode, m.unique_err(c)),
        }
    }
    if let Some(o) = old {
        db.delete_row(&m.tkey, o);
    }
    db.insert_row(&m.tkey, rowid, vals.clone())?;
    Ok(Outcome::Written(rowid, vals))
}

/// ON CONFLICT DO UPDATE applied to the existing row `target`.
#[allow(clippy::too_many_arguments)]
fn upsert_update(
    db: &mut Database,
    m: &Meta,
    target: i64,
    excluded: &[Value],
    excluded_rowid: i64,
    sets: &[(Target, BExpr)],
    where_: Option<&BExpr>,
    ctx: &mut Ctx,
) -> Result<Outcome, String> {
    let existing = db.tables[&m.tkey].rows[&target].clone();
    let mut row = with_rowid(&existing, target);
    row.extend_from_slice(excluded);
    row.push(Value::Integer(excluded_rowid));
    if let Some(w) = where_ {
        if eval(w, &row, &Env::new(db))?.truth() != Some(true) {
            return Ok(Outcome::Skipped);
        }
    }
    let (new_rowid, vals) = apply_sets(m, &existing, target, sets, &row, &Env::new(db))?;
    Ok(match write_row(db, m, Some(target), new_rowid, vals, Some(Conflict::Abort), &[], ctx)? {
        Outcome::Written(r, v) => Outcome::Upserted(r, v),
        o => o,
    })
}

/// New rowid and values of a row after SET assignments evaluated on `row`.
fn apply_sets(
    m: &Meta,
    old: &[Value],
    old_rowid: i64,
    sets: &[(Target, BExpr)],
    row: &[Value],
    env: &Env,
) -> Result<(i64, Vec<Value>), String> {
    let mut vals = old.to_vec();
    let mut rowid = old_rowid;
    for (tg, e) in sets {
        let v = eval(e, row, env)?;
        match tg {
            Target::Col(i) => vals[*i] = apply_affinity(v, m.columns[*i].affinity),
            Target::Rowid => rowid = to_rowid(v)?,
        }
    }
    if let Some(p) = m.ipk {
        vals[p] = Value::Integer(rowid);
    }
    Ok((rowid, vals))
}

fn bind_sets(t: &Table, sets: &[(String, Expr)], scope: &Scope, db: &Database) -> Result<Vec<(Target, BExpr)>, String> {
    let mut out = Vec::new();
    for (name, e) in sets {
        let tg = resolve_target(t, name).ok_or_else(|| format!("no such column: {}", name))?;
        out.push((tg, bind(e, scope, db)?));
    }
    Ok(out)
}

/// Expands and binds result columns.
fn bind_result_columns(cols: &[ResultColumn], scope: &Scope, db: &Database) -> Result<(Vec<BExpr>, Vec<Option<String>>), String> {
    let mut outs = Vec::new();
    let mut aliases = Vec::new();
    for rc in cols {
        match rc {
            ResultColumn::Star => {
                if scope.sources.is_empty() {
                    return Err("no tables specified".to_string());
                }
                for s in scope.sources.iter().filter(|s| !s.qualified_only) {
                    for (i, c) in s.columns.iter().enumerate() {
                        outs.push(BExpr::Col { idx: s.offset + i, aff: c.aff, coll: c.coll });
                        aliases.push(None);
                    }
                }
            }
            ResultColumn::TableStar(t) => {
                let s = scope.find_source(t).ok_or_else(|| format!("no such table: {}", t))?;
                for (i, c) in s.columns.iter().enumerate() {
                    outs.push(BExpr::Col { idx: s.offset + i, aff: c.aff, coll: c.coll });
                    aliases.push(None);
                }
            }
            ResultColumn::Expr(e, alias, _) => {
                outs.push(bind(e, scope, db)?);
                aliases.push(alias.clone());
            }
        }
    }
    Ok((outs, aliases))
}

fn eval_all(exprs: &[BExpr], row: &[Value], env: &Env) -> Result<Vec<Value>, String> {
    exprs.iter().map(|e| eval(e, row, env)).collect()
}

// ---------- INSERT ----------

/// A row to insert: VALUES expressions are evaluated just before their row
/// is inserted.
enum SrcRow {
    Values(Vec<Value>),
    Exprs(Vec<BExpr>),
}

fn insert(db: &mut Database, ins: &Insert, ctx: &mut Ctx) -> Result<Rows, String> {
    let t = db.table_for_write(&ins.table)?;
    let m = Meta::new(t, db)?;
    let ncols = t.columns.len();
    let targets: Vec<Target> = match &ins.columns {
        None => (0..ncols).map(|i| if Some(i) == t.ipk { Target::Rowid } else { Target::Col(i) }).collect(),
        Some(names) => {
            let mut v = Vec::new();
            for n in names {
                match resolve_target(t, n) {
                    Some(tg) => v.push(tg),
                    None => return Err(format!("table {} has no column named {}", t.name, n)),
                }
            }
            v
        }
    };
    let tname = ins.alias.clone().unwrap_or_else(|| t.name.clone());
    let scope = table_scope(t, &tname);

    // upsert clauses
    let mut upserts = Vec::new();
    for u in &ins.upserts {
        let target = match &u.target {
            None => None,
            Some(cols) => Some(upsert_target(t, cols)?),
        };
        let update = match &u.action {
            UpsertAction::Nothing => None,
            UpsertAction::Update { sets, where_ } => {
                let mut us = scope.clone();
                us.sources.push(table_source(t, "excluded", ncols + 1, true));
                let bsets = bind_sets(t, sets, &us, db)?;
                let bw = match where_ {
                    Some(w) => Some(bind(w, &us, db)?),
                    None => None,
                };
                Some((bsets, bw))
            }
        };
        upserts.push(PUpsert { target, update });
    }
    let (ret, _) = bind_result_columns(&ins.returning, &scope, db)?;

    // source rows
    let count_err = |n: usize| -> String {
        match &ins.columns {
            None => format!("table {} has {} columns but {} values were supplied", t.name, ncols, n),
            Some(_) => format!("{} values for {} columns", n, targets.len()),
        }
    };
    let empty = Scope::empty();
    let src_rows: Vec<SrcRow> = match &ins.source {
        InsertSource::Default => vec![SrcRow::Values(Vec::new())],
        InsertSource::Values(rows) => {
            let mut bound = Vec::new();
            for r in rows {
                if r.len() != targets.len() {
                    return Err(count_err(r.len()));
                }
                let mut br = Vec::new();
                for e in r {
                    br.push(bind(e, &empty, db)?);
                }
                bound.push(SrcRow::Exprs(br));
            }
            // rows whose subqueries read the target table are all computed
            // before the first insert
            let reads_target = rows.iter().flatten().any(|e| query::expr_reads_table(e, &t.name));
            if reads_target && rows.len() > 1 {
                let env = Env::new(db);
                let mut vals = Vec::with_capacity(bound.len());
                for r in bound {
                    match r {
                        SrcRow::Exprs(exprs) => vals.push(SrcRow::Values(eval_all(&exprs, &[], &env)?)),
                        v => vals.push(v),
                    }
                }
                bound = vals;
            }
            bound
        }
        InsertSource::Select(sel) => {
            let plan = plan_query(db, sel, None, Rc::new(Cell::new(0)))?;
            let rows = run_query(&plan, &Env::new(db), None)?;
            let width = plan.columns.len();
            if width != targets.len() {
                return Err(count_err(width));
            }
            rows.into_iter().map(SrcRow::Values).collect()
        }
    };
    let targets: &[Target] = if matches!(ins.source, InsertSource::Default) { &[] } else { &targets };
    ctx.started = true;

    let mut out = Vec::new();
    for srow in src_rows {
        let srow = match srow {
            SrcRow::Values(r) => r,
            SrcRow::Exprs(exprs) => eval_all(&exprs, &[], &Env::new(db))?,
        };
        let mut vals = vec![Value::Null; ncols];
        let mut given = vec![false; ncols];
        let mut rowid_v: Option<Value> = None;
        for (v, tg) in srow.into_iter().zip(targets) {
            match *tg {
                Target::Col(i) => {
                    vals[i] = v;
                    given[i] = true;
                }
                Target::Rowid => rowid_v = Some(v),
            }
        }
        for i in 0..ncols {
            if Some(i) == m.ipk {
                continue;
            }
            vals[i] = if given[i] {
                apply_affinity(std::mem::replace(&mut vals[i], Value::Null), m.columns[i].affinity)
            } else {
                m.default_value(i, &Env::new(db))?
            };
        }
        let rowid = match rowid_v {
            Some(v) if !v.is_null() => to_rowid(v)?,
            _ => db.next_rowid(&m.tkey)?,
        };
        if let Some(p) = m.ipk {
            vals[p] = Value::Integer(rowid);
        }
        match write_row(db, &m, None, rowid, vals, ins.or, &upserts, ctx)? {
            Outcome::Written(r, v) => {
                db::set_last_insert_rowid(r);
                ctx.changes += 1;
                if !ret.is_empty() {
                    out.push(eval_all(&ret, &with_rowid(&v, r), &Env::new(db))?);
                }
            }
            Outcome::Upserted(r, v) => {
                ctx.changes += 1;
                if !ret.is_empty() {
                    out.push(eval_all(&ret, &with_rowid(&v, r), &Env::new(db))?);
                }
            }
            Outcome::Skipped => {}
        }
    }
    Ok(out)
}

/// Resolves an upsert conflict target to a uniqueness constraint.
fn upsert_target(t: &Table, cols: &[IndexedColumn]) -> Result<Cons, String> {
    let err = || "ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint".to_string();
    let mut idxs = Vec::new();
    for ic in cols {
        let name = match &ic.expr {
            Expr::Column { table: None, name, .. } => name,
            _ => return Err(err()),
        };
        let i = t.column_index(name).ok_or_else(|| format!("no such column: {}", name))?;
        let coll = match &ic.collate {
            Some(c) => Some(Coll::from_name(c)?),
            None => None,
        };
        idxs.push((i, coll));
    }
    if idxs.len() == 1 && Some(idxs[0].0) == t.ipk {
        return Ok(Cons::Rowid);
    }
    for (n, idx) in t.indexes.iter().enumerate() {
        if !idx.unique || idx.pred.is_some() || idx.cols.len() != idxs.len() {
            continue;
        }
        let all = idxs.iter().all(|(c, coll)| {
            idx.cols
                .iter()
                .zip(&idx.colls)
                .any(|(ic, icoll)| matches!(ic, IdxCol::Col(x) if x == c) && coll.is_none_or(|x| x == *icoll))
        });
        if all {
            return Ok(Cons::Index(n));
        }
    }
    Err(err())
}

// ---------- UPDATE / DELETE ----------

fn matching_rowids(t: &Table, where_: Option<&BExpr>, env: &Env) -> Result<Vec<i64>, String> {
    let mut terms = Vec::new();
    if let Some(w) = where_ {
        access::conjuncts(w.clone(), &mut terms);
    }
    let acc = access::plan_single(env.db, t, &terms);
    let candidates = access::rowids(t, &acc, &[], env)?;
    let mut ids = Vec::new();
    let mut buf: Vec<Value> = Vec::with_capacity(t.columns.len() + 1);
    for rowid in candidates {
        let Some(r) = t.rows.get(&rowid) else { continue };
        if let Some(w) = where_ {
            buf.clear();
            buf.extend(r.iter().cloned());
            buf.push(Value::Integer(rowid));
            if eval(w, &buf, env)?.truth() != Some(true) {
                continue;
            }
        }
        ids.push(rowid);
    }
    // SQLite collects the rowids first and then visits them in order
    ids.sort_unstable();
    Ok(ids)
}

fn update(db: &mut Database, upd: &Update, ctx: &mut Ctx) -> Result<Rows, String> {
    let t = db.table_for_write(&upd.table)?;
    let m = Meta::new(t, db)?;
    let scope = table_scope(t, upd.alias.as_deref().unwrap_or(&t.name));
    let sets = bind_sets(t, &upd.sets, &scope, db)?;
    let where_ = match &upd.where_ {
        Some(w) => Some(bind(w, &scope, db)?),
        None => None,
    };
    let (ret, _) = bind_result_columns(&upd.returning, &scope, db)?;
    ctx.started = true;
    let ids = matching_rowids(t, where_.as_ref(), &Env::new(db))?;
    let mut out = Vec::new();
    for rowid in ids {
        let Some(old) = db.tables[&m.tkey].rows.get(&rowid).cloned() else { continue };
        let row = with_rowid(&old, rowid);
        let (new_rowid, vals) = apply_sets(&m, &old, rowid, &sets, &row, &Env::new(db))?;
        if let Outcome::Written(r, v) = write_row(db, &m, Some(rowid), new_rowid, vals, upd.or, &[], ctx)? {
            ctx.changes += 1;
            if !ret.is_empty() {
                out.push(eval_all(&ret, &with_rowid(&v, r), &Env::new(db))?);
            }
        }
    }
    Ok(out)
}

fn delete(db: &mut Database, del: &Delete, ctx: &mut Ctx) -> Result<Rows, String> {
    let t = db.table_for_write(&del.table)?;
    let tkey = key(&t.name);
    let scope = table_scope(t, del.alias.as_deref().unwrap_or(&t.name));
    let where_ = match &del.where_ {
        Some(w) => Some(bind(w, &scope, db)?),
        None => None,
    };
    let (ret, _) = bind_result_columns(&del.returning, &scope, db)?;
    ctx.started = true;
    let ids = matching_rowids(t, where_.as_ref(), &Env::new(db))?;
    let mut out = Vec::new();
    for rowid in ids {
        if !ret.is_empty() {
            if let Some(r) = db.tables[&tkey].rows.get(&rowid) {
                out.push(eval_all(&ret, &with_rowid(r, rowid), &Env::new(db))?);
            }
        }
        if db.delete_row(&tkey, rowid).is_some() {
            ctx.changes += 1;
        }
    }
    Ok(out)
}

