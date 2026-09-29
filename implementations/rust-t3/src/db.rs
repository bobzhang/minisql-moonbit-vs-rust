// In-memory database storage.

use std::cell::Cell;
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};

use crate::ast::{Conflict, CreateIndex, Expr, Select};
use crate::eval::{eval, BExpr, Env};
use crate::value::{compare, Affinity, Coll, Value};

#[derive(Debug, Clone)]
pub struct Column {
    pub name: String,
    pub decl_type: Option<String>,
    pub affinity: Affinity,
    pub default: Option<Expr>,
    pub coll: Option<Coll>,
    /// `Some(clause)` if the column is NOT NULL (clause None = default ABORT).
    pub not_null: Option<Option<Conflict>>,
}

#[derive(Debug, Clone)]
pub struct Check {
    /// Constraint name, or the expression text.
    pub name: String,
    pub expr: Expr,
}

/// A value used as an index key: text is normalized for the index collation
/// so that plain comparison matches the collation.
#[derive(Debug, Clone)]
pub struct KeyVal(pub Value);

impl PartialEq for KeyVal {
    fn eq(&self, o: &Self) -> bool {
        self.cmp(o) == Ordering::Equal
    }
}
impl Eq for KeyVal {}
impl PartialOrd for KeyVal {
    fn partial_cmp(&self, o: &Self) -> Option<Ordering> {
        Some(self.cmp(o))
    }
}
impl Ord for KeyVal {
    fn cmp(&self, o: &Self) -> Ordering {
        compare(&self.0, &o.0)
    }
}

pub fn key_val(v: &Value, coll: Coll) -> KeyVal {
    match (v, coll) {
        (Value::Text(s), Coll::NoCase) => KeyVal(Value::Text(s.to_ascii_lowercase())),
        (Value::Text(s), Coll::Rtrim) => KeyVal(Value::Text(s.trim_end_matches(' ').to_string())),
        _ => KeyVal(v.clone()),
    }
}

/// One component of an index key: a value in index order (the flag marks
/// a DESC column), or a sentinel above every value.
#[derive(Debug, Clone)]
pub enum IKey {
    Val(KeyVal, bool),
    Max,
}

impl PartialEq for IKey {
    fn eq(&self, o: &Self) -> bool {
        self.cmp(o) == Ordering::Equal
    }
}
impl Eq for IKey {}
impl PartialOrd for IKey {
    fn partial_cmp(&self, o: &Self) -> Option<Ordering> {
        Some(self.cmp(o))
    }
}
impl Ord for IKey {
    fn cmp(&self, o: &Self) -> Ordering {
        match (self, o) {
            (IKey::Max, IKey::Max) => Ordering::Equal,
            (_, IKey::Max) => Ordering::Less,
            (IKey::Max, _) => Ordering::Greater,
            (IKey::Val(a, desc), IKey::Val(b, _)) => {
                let c = a.cmp(b);
                if *desc {
                    c.reverse()
                } else {
                    c
                }
            }
        }
    }
}

impl IKey {
    pub fn is_null(&self) -> bool {
        matches!(self, IKey::Val(v, _) if v.0.is_null())
    }
}

/// An indexed column: a table column or an expression over the row
/// (bound against the table's columns followed by the rowid).
#[derive(Debug, Clone)]
pub enum IdxCol {
    Col(usize),
    Expr(BExpr),
}

pub type IndexEntries = BTreeSet<(Vec<IKey>, i64)>;

#[derive(Debug, Clone)]
pub struct Index {
    pub name: String,
    /// Created by a UNIQUE or PRIMARY KEY constraint.
    pub auto: bool,
    /// The CREATE INDEX statement (explicit indexes only).
    pub def: Option<CreateIndex>,
    /// Position in the schema (creation order).
    pub order: u64,
    pub cols: Vec<IdxCol>,
    pub colls: Vec<Coll>,
    pub desc: Vec<bool>,
    /// Affinity of each indexed column or expression.
    pub affs: Vec<Affinity>,
    /// WHERE clause of a partial index.
    pub pred: Option<BExpr>,
    pub unique: bool,
    pub conflict: Option<Conflict>,
    pub entries: IndexEntries,
    /// Root page in the database file (0 if not stored there).
    pub root: i64,
}

impl Index {
    fn has_exprs(&self) -> bool {
        self.pred.is_some() || self.cols.iter().any(|c| matches!(c, IdxCol::Expr(_)))
    }

    /// Key of a row, or None for a row outside a partial index.
    pub fn key(&self, row: &[Value], rowid: i64) -> Result<Option<Vec<IKey>>, String> {
        if !self.has_exprs() {
            let k = self
                .cols
                .iter()
                .zip(&self.colls)
                .zip(&self.desc)
                .map(|((c, &coll), &d)| match c {
                    IdxCol::Col(i) => IKey::Val(key_val(&row[*i], coll), d),
                    IdxCol::Expr(_) => unreachable!(),
                })
                .collect();
            return Ok(Some(k));
        }
        let empty = Database::default();
        let env = Env::new(&empty);
        let mut full = Vec::with_capacity(row.len() + 1);
        full.extend_from_slice(row);
        full.push(Value::Integer(rowid));
        if let Some(p) = &self.pred {
            if eval(p, &full, &env)?.truth() != Some(true) {
                return Ok(None);
            }
        }
        let mut k = Vec::with_capacity(self.cols.len());
        for ((c, &coll), &d) in self.cols.iter().zip(&self.colls).zip(&self.desc) {
            let v = match c {
                IdxCol::Col(i) => full[*i].clone(),
                IdxCol::Expr(e) => eval(e, &full, &env)?,
            };
            k.push(IKey::Val(key_val(&v, coll), d));
        }
        Ok(Some(k))
    }

    /// The values stored in the index record of a row (before the rowid).
    pub fn raw_key(&self, row: &[Value], rowid: i64) -> Result<Vec<Value>, String> {
        let empty = Database::default();
        let env = Env::new(&empty);
        let mut full = Vec::with_capacity(row.len() + 1);
        full.extend_from_slice(row);
        full.push(Value::Integer(rowid));
        let mut k = Vec::with_capacity(self.cols.len());
        for c in &self.cols {
            k.push(match c {
                IdxCol::Col(i) => full[*i].clone(),
                IdxCol::Expr(e) => eval(e, &full, &env)?,
            });
        }
        Ok(k)
    }

    /// A row other than `except` with the same key (never for keys
    /// containing NULL).
    pub fn find_conflict(&self, k: &[IKey], except: Option<i64>) -> Option<i64> {
        if k.iter().any(|v| v.is_null()) {
            return None;
        }
        let lo = (k.to_vec(), i64::MIN);
        let hi = (k.to_vec(), i64::MAX);
        self.entries.range(lo..=hi).map(|(_, r)| *r).find(|r| Some(*r) != except)
    }

    /// Error message for a uniqueness violation.
    pub fn unique_err(&self, t: &Table) -> String {
        let mut names = Vec::new();
        for c in &self.cols {
            match c {
                IdxCol::Col(i) => names.push(format!("{}.{}", t.name, t.columns[*i].name)),
                IdxCol::Expr(_) => return format!("UNIQUE constraint failed: index '{}'", self.name),
            }
        }
        format!("UNIQUE constraint failed: {}", names.join(", "))
    }
}

#[derive(Debug, Clone)]
pub struct Table {
    pub name: String,
    pub columns: Vec<Column>,
    /// Rows keyed by rowid.
    pub rows: BTreeMap<i64, Vec<Value>>,
    pub sql: String,
    /// Column that aliases the rowid (INTEGER PRIMARY KEY).
    pub ipk: Option<usize>,
    /// Conflict clause of the INTEGER PRIMARY KEY.
    pub pk_conflict: Option<Conflict>,
    pub autoinc: bool,
    pub checks: Vec<Check>,
    pub indexes: Vec<Index>,
    /// Position in the schema (creation order).
    pub order: u64,
    /// A TEMP table (listed in sqlite_temp_schema).
    pub temp: bool,
    /// Root page in the database file (0 if not stored there).
    pub root: i64,
}

impl Table {
    pub fn column_index(&self, name: &str) -> Option<usize> {
        self.columns.iter().position(|c| c.name.eq_ignore_ascii_case(name))
    }

    /// Chooses a rowid for a new row (`seq`: the AUTOINCREMENT counter).
    pub fn next_rowid(&self, seq: i64) -> Result<i64, String> {
        let max = self.rows.keys().next_back().copied().unwrap_or(0);
        if self.autoinc {
            let top = max.max(seq);
            return if top == i64::MAX { Err("database or disk is full".to_string()) } else { Ok(top + 1) };
        }
        if max < i64::MAX {
            return Ok(max.max(0) + 1);
        }
        // all large rowids used: search for a free one
        let mut x: u64 = 0x9E37_79B9_7F4A_7C15 ^ self.rows.len() as u64;
        for _ in 0..1000 {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            let cand = (x >> 1) as i64;
            if cand > 0 && !self.rows.contains_key(&cand) {
                return Ok(cand);
            }
        }
        Err("database or disk is full".to_string())
    }

    /// Adds a row and its index entries.
    pub fn add_row(&mut self, rowid: i64, row: Vec<Value>) -> Result<(), String> {
        let mut keys = Vec::with_capacity(self.indexes.len());
        for idx in &self.indexes {
            keys.push(idx.key(&row, rowid)?);
        }
        for (idx, k) in self.indexes.iter_mut().zip(keys) {
            if let Some(k) = k {
                idx.entries.insert((k, rowid));
            }
        }
        self.rows.insert(rowid, row);
        Ok(())
    }

    fn remove_row(&mut self, rowid: i64) -> Option<Vec<Value>> {
        let row = self.rows.remove(&rowid)?;
        for idx in &mut self.indexes {
            if let Ok(Some(k)) = idx.key(&row, rowid) {
                idx.entries.remove(&(k, rowid));
            }
        }
        Some(row)
    }

    /// Fills an index from the table's rows, enforcing uniqueness.
    pub fn build_index(&self, idx: &mut Index) -> Result<(), String> {
        idx.entries.clear();
        for (rowid, row) in &self.rows {
            if let Some(k) = idx.key(row, *rowid)? {
                if idx.unique && idx.find_conflict(&k, None).is_some() {
                    return Err(idx.unique_err(self));
                }
                idx.entries.insert((k, *rowid));
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone)]
pub struct View {
    pub name: String,
    pub columns: Option<Vec<String>>,
    pub select: Select,
    pub sql: String,
    pub order: u64,
    pub temp: bool,
}

/// One undoable change.
#[derive(Debug)]
enum Undo {
    Insert { table: String, rowid: i64 },
    Delete { table: String, rowid: i64, row: Vec<Value> },
    /// A table slot's previous content.
    Table { key: String, old: Option<Table> },
    View { key: String, old: Option<View> },
    IndexAdded { table: String, name: String },
    IndexDropped { table: String, pos: usize, index: Index },
}

#[derive(Debug)]
struct Txn {
    /// Savepoint names and their undo-log positions.
    savepoints: Vec<(String, usize)>,
    /// Started by SAVEPOINT rather than BEGIN.
    implicit: bool,
}

#[derive(Debug, Default)]
pub struct Database {
    /// Tables keyed by ASCII-lowercased name.
    pub tables: BTreeMap<String, Table>,
    /// Views keyed by ASCII-lowercased name.
    pub views: BTreeMap<String, View>,
    undo: Vec<Undo>,
    txn: Option<Txn>,
    next_order: u64,
    /// Committed changes not yet written to the database file.
    pub dirty: bool,
    /// Whether any of those changes touched the schema.
    pub schema_dirty: bool,
}

pub fn key(name: &str) -> String {
    name.to_ascii_lowercase()
}

thread_local! {
    static CHANGES: Cell<i64> = const { Cell::new(0) };
    static TOTAL_CHANGES: Cell<i64> = const { Cell::new(0) };
    static LAST_ROWID: Cell<i64> = const { Cell::new(0) };
}

pub fn changes() -> i64 {
    CHANGES.with(|c| c.get())
}

pub fn total_changes() -> i64 {
    TOTAL_CHANGES.with(|c| c.get())
}

pub fn last_insert_rowid() -> i64 {
    LAST_ROWID.with(|c| c.get())
}

pub fn set_last_insert_rowid(r: i64) {
    LAST_ROWID.with(|c| c.set(r));
}

/// Records the change count of a completed DML statement.
pub fn set_changes(n: i64) {
    CHANGES.with(|c| c.set(n));
    TOTAL_CHANGES.with(|c| c.set(c.get() + n));
}

/// Key of the table holding AUTOINCREMENT counters.
pub const SEQ_TABLE: &str = "sqlite_sequence";

/// Whether `name` refers to the schema table.
pub fn is_schema_table(name: &str) -> bool {
    ["sqlite_schema", "sqlite_master", "sqlite_temp_schema", "sqlite_temp_master"]
        .iter()
        .any(|n| n.eq_ignore_ascii_case(name))
}

/// Whether `name` refers to the TEMP schema table.
pub fn is_temp_schema_table(name: &str) -> bool {
    ["sqlite_temp_schema", "sqlite_temp_master"].iter().any(|n| n.eq_ignore_ascii_case(name))
}

impl Database {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn table(&self, name: &str) -> Result<&Table, String> {
        self.tables.get(&key(name)).ok_or_else(|| format!("no such table: {}", name))
    }

    /// A table that DML may modify.
    pub fn table_for_write(&self, name: &str) -> Result<&Table, String> {
        if is_schema_table(name) {
            return Err(format!("table {} may not be modified", "sqlite_master"));
        }
        if self.views.contains_key(&key(name)) {
            return Err(format!("cannot modify {} because it is a view", name));
        }
        self.table(name)
    }

    /// The index named `name`: (table key, position).
    pub fn find_index(&self, name: &str) -> Option<(String, usize)> {
        for (k, t) in &self.tables {
            if let Some(i) = t.indexes.iter().position(|x| x.name.eq_ignore_ascii_case(name)) {
                return Some((k.clone(), i));
            }
        }
        None
    }

    pub fn next_order(&mut self) -> u64 {
        self.next_order += 1;
        self.next_order
    }

    pub fn insert_row(&mut self, tkey: &str, rowid: i64, row: Vec<Value>) -> Result<(), String> {
        let t = self.tables.get_mut(tkey).expect("table");
        t.add_row(rowid, row)?;
        self.undo.push(Undo::Insert { table: tkey.to_string(), rowid });
        if t.autoinc {
            let name = t.name.clone();
            if rowid > self.seq_of(&name) {
                self.set_seq(&name, rowid)?;
            }
        }
        Ok(())
    }

    /// The row of sqlite_sequence for a table.
    fn seq_row(&self, name: &str) -> Option<(i64, &Vec<Value>)> {
        let st = self.tables.get(SEQ_TABLE)?;
        st.rows.iter().find(|(_, r)| matches!(&r[0], Value::Text(n) if n == name)).map(|(k, r)| (*k, r))
    }

    /// The AUTOINCREMENT counter of a table.
    pub fn seq_of(&self, name: &str) -> i64 {
        match self.seq_row(name) {
            Some((_, r)) => match &r[1] {
                Value::Integer(i) => *i,
                Value::Real(f) => *f as i64,
                v => v.to_int(),
            },
            None => 0,
        }
    }

    pub fn set_seq(&mut self, name: &str, v: i64) -> Result<(), String> {
        if !self.tables.contains_key(SEQ_TABLE) {
            return Ok(());
        }
        let row = vec![Value::Text(name.to_string()), Value::Integer(v)];
        match self.seq_row(name).map(|(k, _)| k) {
            Some(k) => {
                self.delete_row(SEQ_TABLE, k);
                self.insert_row(SEQ_TABLE, k, row)
            }
            None => {
                let k = self.tables[SEQ_TABLE].next_rowid(0)?;
                self.insert_row(SEQ_TABLE, k, row)
            }
        }
    }

    /// Follows a table rename in sqlite_sequence.
    pub fn rename_seq(&mut self, old: &str, new: &str) -> Result<(), String> {
        if let Some((k, r)) = self.seq_row(old) {
            let mut row = r.clone();
            row[0] = Value::Text(new.to_string());
            self.delete_row(SEQ_TABLE, k);
            self.insert_row(SEQ_TABLE, k, row)?;
        }
        Ok(())
    }

    /// Removes a table's sqlite_sequence row.
    pub fn drop_seq(&mut self, name: &str) {
        if let Some((k, _)) = self.seq_row(name) {
            self.delete_row(SEQ_TABLE, k);
        }
    }

    /// Chooses a rowid for a new row of a table.
    pub fn next_rowid(&self, tkey: &str) -> Result<i64, String> {
        let t = &self.tables[tkey];
        let seq = if t.autoinc { self.seq_of(&t.name) } else { 0 };
        t.next_rowid(seq)
    }

    pub fn delete_row(&mut self, tkey: &str, rowid: i64) -> Option<Vec<Value>> {
        let t = self.tables.get_mut(tkey).expect("table");
        let row = t.remove_row(rowid)?;
        self.undo.push(Undo::Delete { table: tkey.to_string(), rowid, row: row.clone() });
        Some(row)
    }

    /// Stores a table under its name (replacing any table there).
    pub fn put_table(&mut self, t: Table) {
        let k = key(&t.name);
        let old = self.tables.insert(k.clone(), t);
        self.undo.push(Undo::Table { key: k, old });
    }

    pub fn remove_table(&mut self, k: &str) {
        let old = self.tables.remove(k);
        self.undo.push(Undo::Table { key: k.to_string(), old });
    }

    pub fn put_view(&mut self, v: View) {
        let k = key(&v.name);
        let old = self.views.insert(k.clone(), v);
        self.undo.push(Undo::View { key: k, old });
    }

    pub fn remove_view(&mut self, k: &str) {
        let old = self.views.remove(k);
        self.undo.push(Undo::View { key: k.to_string(), old });
    }

    pub fn add_index(&mut self, tkey: &str, idx: Index) {
        let name = idx.name.clone();
        self.tables.get_mut(tkey).expect("table").indexes.push(idx);
        self.undo.push(Undo::IndexAdded { table: tkey.to_string(), name });
    }

    pub fn drop_index(&mut self, tkey: &str, pos: usize) {
        let index = self.tables.get_mut(tkey).expect("table").indexes.remove(pos);
        self.undo.push(Undo::IndexDropped { table: tkey.to_string(), pos, index });
    }

    /// Position in the undo log, for `rollback_to`.
    pub fn mark(&self) -> usize {
        self.undo.len()
    }

    /// Undoes every change made after `mark`.
    pub fn rollback_to(&mut self, mark: usize) {
        while self.undo.len() > mark {
            match self.undo.pop().unwrap() {
                Undo::Insert { table, rowid } => {
                    if let Some(t) = self.tables.get_mut(&table) {
                        t.remove_row(rowid);
                    }
                }
                Undo::Delete { table, rowid, row } => {
                    if let Some(t) = self.tables.get_mut(&table) {
                        let _ = t.add_row(rowid, row);
                    }
                }
                Undo::Table { key, old } => {
                    match old {
                        Some(t) => self.tables.insert(key, t),
                        None => self.tables.remove(&key),
                    };
                }
                Undo::View { key, old } => {
                    match old {
                        Some(v) => self.views.insert(key, v),
                        None => self.views.remove(&key),
                    };
                }
                Undo::IndexAdded { table, name } => {
                    if let Some(t) = self.tables.get_mut(&table) {
                        t.indexes.retain(|i| i.name != name);
                    }
                }
                Undo::IndexDropped { table, pos, index } => {
                    if let Some(t) = self.tables.get_mut(&table) {
                        let pos = pos.min(t.indexes.len());
                        t.indexes.insert(pos, index);
                    }
                }
            }
        }
    }

    // ---------- transactions ----------

    /// Ends a statement: outside a transaction its changes become permanent.
    pub fn end_statement(&mut self) {
        if self.txn.is_none() {
            self.settle();
        }
    }

    /// Makes the logged changes permanent, noting that the file must change.
    fn settle(&mut self) {
        if !self.undo.is_empty() {
            self.dirty = true;
            let schema = self.undo.iter().any(|u| !matches!(u, Undo::Insert { .. } | Undo::Delete { .. }));
            self.schema_dirty |= schema;
        }
        self.undo.clear();
    }

    pub fn begin(&mut self) -> Result<(), String> {
        if self.txn.is_some() {
            return Err("cannot start a transaction within a transaction".to_string());
        }
        self.undo.clear();
        self.txn = Some(Txn { savepoints: Vec::new(), implicit: false });
        Ok(())
    }

    pub fn commit(&mut self) -> Result<(), String> {
        if self.txn.take().is_none() {
            return Err("cannot commit - no transaction is active".to_string());
        }
        self.settle();
        Ok(())
    }

    pub fn rollback(&mut self) -> Result<(), String> {
        if self.txn.take().is_none() {
            return Err("cannot rollback - no transaction is active".to_string());
        }
        self.rollback_to(0);
        Ok(())
    }

    /// Rolls back the whole transaction, if any (ON CONFLICT ROLLBACK).
    pub fn abort_txn(&mut self) -> bool {
        if self.txn.take().is_some() {
            self.rollback_to(0);
            true
        } else {
            false
        }
    }

    pub fn savepoint(&mut self, name: &str) {
        if self.txn.is_none() {
            self.undo.clear();
            self.txn = Some(Txn { savepoints: Vec::new(), implicit: true });
        }
        let mark = self.undo.len();
        self.txn.as_mut().unwrap().savepoints.push((name.to_string(), mark));
    }

    fn find_savepoint(&self, name: &str) -> Result<usize, String> {
        self.txn
            .as_ref()
            .and_then(|t| t.savepoints.iter().rposition(|(n, _)| n.eq_ignore_ascii_case(name)))
            .ok_or_else(|| format!("no such savepoint: {}", name))
    }

    pub fn release(&mut self, name: &str) -> Result<(), String> {
        let i = self.find_savepoint(name)?;
        let txn = self.txn.as_mut().unwrap();
        txn.savepoints.truncate(i);
        if txn.savepoints.is_empty() && txn.implicit {
            self.txn = None;
            self.settle();
        }
        Ok(())
    }

    pub fn rollback_to_savepoint(&mut self, name: &str) -> Result<(), String> {
        let i = self.find_savepoint(name)?;
        let txn = self.txn.as_mut().unwrap();
        let mark = txn.savepoints[i].1;
        txn.savepoints.truncate(i + 1);
        self.rollback_to(mark);
        Ok(())
    }
}
