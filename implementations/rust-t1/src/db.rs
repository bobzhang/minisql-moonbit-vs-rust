// In-memory catalog and table storage.

use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

use crate::ast::{Conflict, Expr, Select};
use crate::eval::{eval, Cx};
use crate::value::{compare, Affinity, Collation, Value};

#[derive(Clone, Debug)]
pub struct Column {
    pub name: String,
    pub decl_type: String,
    pub affinity: Affinity,
    pub not_null: Option<Conflict>,
    pub default: Option<Expr>,
    pub collation: Option<String>,
}

impl Column {
    pub fn coll(&self) -> Collation {
        self.collation.as_deref().and_then(Collation::from_name).unwrap_or(Collation::Binary)
    }
}

/// Index key: values normalized for their collation, compared with the
/// BINARY total order.
#[derive(Clone, Debug)]
pub struct IdxKey(pub Vec<Value>);

impl PartialEq for IdxKey {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}
impl Eq for IdxKey {}
impl PartialOrd for IdxKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for IdxKey {
    fn cmp(&self, other: &Self) -> Ordering {
        for (a, b) in self.0.iter().zip(&other.0) {
            let c = compare(a, b);
            if c != Ordering::Equal {
                return c;
            }
        }
        self.0.len().cmp(&other.0.len())
    }
}

/// Index entry key: like IdxKey, but components whose bit is set in the
/// mask (DESC index columns) sort in reverse.
#[derive(Clone, Debug)]
pub struct IxKey(pub Vec<Value>, pub u64);

impl PartialEq for IxKey {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}
impl Eq for IxKey {}
impl PartialOrd for IxKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for IxKey {
    fn cmp(&self, other: &Self) -> Ordering {
        for (i, (a, b)) in self.0.iter().zip(&other.0).enumerate() {
            let c = compare(a, b);
            if c != Ordering::Equal {
                return if i < 64 && self.1 & (1 << i) != 0 { c.reverse() } else { c };
            }
        }
        self.0.len().cmp(&other.0.len())
    }
}

/// Normalize a value so that BINARY comparison matches `coll`.
pub fn normalize(v: &Value, coll: Collation) -> Value {
    match (v, coll) {
        (Value::Text(s), Collation::NoCase) => Value::Text(s.to_ascii_lowercase()),
        (Value::Text(s), Collation::Rtrim) => Value::Text(s.trim_end_matches(' ').to_string()),
        _ => v.clone(),
    }
}

/// What one index column holds.
#[derive(Clone, Debug)]
pub enum IdxColKind {
    /// A table column.
    Col(usize),
    /// An expression: its source (for renames and rebinding) and its form
    /// bound against `[columns..., rowid]`.
    Expr { ast: Expr, bound: Expr },
}

#[derive(Clone, Debug)]
pub struct IndexCol {
    pub kind: IdxColKind,
    pub coll: Collation,
    /// Explicit COLLATE name, if any.
    pub coll_name: Option<String>,
    pub desc: bool,
    /// Affinity of the indexed values (None for expressions without one).
    pub aff: Option<Affinity>,
}

/// An index: automatic (UNIQUE / PRIMARY KEY constraint) or created with
/// CREATE INDEX.
#[derive(Clone, Debug)]
pub struct Index {
    pub name: String,
    pub cols: Vec<IndexCol>,
    pub unique: bool,
    /// Backs a UNIQUE or PRIMARY KEY constraint.
    pub auto: bool,
    pub primary: bool,
    pub conflict: Option<Conflict>,
    /// Partial index predicate: source and bound form.
    pub where_ast: Option<Expr>,
    pub where_: Option<Expr>,
    /// Keys (normalized values followed by the rowid) of the covered rows.
    pub entries: BTreeSet<IxKey>,
    pub seq: u64,
    /// Stored CREATE INDEX text (None for automatic indexes).
    pub sql: Option<String>,
}

thread_local! {
    static EMPTY_DB: &'static Database = Box::leak(Box::default());
}

pub fn empty_db() -> &'static Database {
    EMPTY_DB.with(|d| *d)
}

impl Index {
    /// Key values of a row (without the rowid), or None if the partial
    /// index does not cover it.
    pub fn values_of(&self, row: &[Value], rowid: i64) -> Option<Vec<Value>> {
        let mut k = self.raw_values_of(row, rowid)?;
        for (v, c) in k.iter_mut().zip(&self.cols) {
            if c.coll != Collation::Binary {
                *v = normalize(v, c.coll);
            }
        }
        Some(k)
    }

    /// Key values of a row as stored in the index (not normalized for the
    /// collation), or None if the partial index does not cover it.
    pub fn raw_values_of(&self, row: &[Value], rowid: i64) -> Option<Vec<Value>> {
        let needs_buf = self.where_.is_some() || self.cols.iter().any(|c| matches!(c.kind, IdxColKind::Expr { .. }));
        let buf: Vec<Value> = if needs_buf {
            let mut b = row.to_vec();
            b.push(Value::Int(rowid));
            b
        } else {
            vec![]
        };
        let cx = Cx::new(empty_db());
        if let Some(w) = &self.where_ {
            match eval(w, &buf, &cx) {
                Ok(v) if v.truthy() == Some(true) => {}
                _ => return None,
            }
        }
        let mut k = Vec::with_capacity(self.cols.len() + 1);
        for c in &self.cols {
            let v = match &c.kind {
                IdxColKind::Col(i) => row[*i].clone(),
                IdxColKind::Expr { bound, .. } => eval(bound, &buf, &cx).unwrap_or(Value::Null),
            };
            k.push(v);
        }
        Some(k)
    }

    pub fn insert(&mut self, row: &[Value], rowid: i64) {
        if let Some(mut k) = self.values_of(row, rowid) {
            k.push(Value::Int(rowid));
            let m = self.desc_mask();
            self.entries.insert(IxKey(k, m));
        }
    }

    pub fn remove(&mut self, row: &[Value], rowid: i64) {
        if let Some(mut k) = self.values_of(row, rowid) {
            k.push(Value::Int(rowid));
            let m = self.desc_mask();
            self.entries.remove(&IxKey(k, m));
        }
    }

    /// Rowid of a row other than `exclude` whose key equals that of `row`
    /// (unique indexes; NULLs never conflict).
    pub fn find(&self, row: &[Value], rowid: i64, exclude: Option<i64>) -> Option<i64> {
        let k = self.values_of(row, rowid)?;
        if k.iter().any(|v| v.is_null()) {
            return None;
        }
        let mut lo = k.clone();
        lo.push(Value::Int(i64::MIN));
        let mut hi = k;
        hi.push(Value::Int(i64::MAX));
        let m = self.desc_mask();
        for key in self.entries.range(IxKey(lo, m)..=IxKey(hi, m)) {
            if let Some(Value::Int(r)) = key.0.last() {
                if Some(*r) != exclude {
                    return Some(*r);
                }
            }
        }
        None
    }

    /// Bit mask of the DESC columns.
    pub fn desc_mask(&self) -> u64 {
        let mut m = 0;
        for (i, c) in self.cols.iter().enumerate().take(64) {
            if c.desc {
                m |= 1 << i;
            }
        }
        m
    }

    /// Plain column indices, if the index has no expression columns.
    pub fn plain_cols(&self) -> Option<Vec<usize>> {
        self.cols
            .iter()
            .map(|c| match c.kind {
                IdxColKind::Col(i) => Some(i),
                _ => None,
            })
            .collect()
    }
}

/// A CHECK constraint; `col` names the column it was declared on.
#[derive(Clone, Debug)]
pub struct Check {
    pub expr: Expr,
    pub col: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Table {
    pub name: String,
    pub columns: Vec<Column>,
    /// Rows keyed by rowid; each row has one value per column.
    pub rows: BTreeMap<i64, Vec<Value>>,
    /// Column that aliases the rowid (INTEGER PRIMARY KEY).
    pub rowid_alias: Option<usize>,
    /// Conflict clause of the INTEGER PRIMARY KEY.
    pub rowid_conflict: Option<Conflict>,
    pub autoincrement: bool,
    /// Largest rowid ever used (AUTOINCREMENT tables).
    pub seq: i64,
    /// Automatic indexes in declaration order, then created indexes.
    pub indexes: Vec<Index>,
    pub checks: Vec<Check>,
    pub sql: String,
    pub schema_seq: u64,
    /// Bumped on every row change (invalidates cached automatic indexes).
    pub version: u64,
}

impl Table {
    pub fn column_index(&self, name: &str) -> Option<usize> {
        self.columns.iter().position(|c| c.name.eq_ignore_ascii_case(name))
    }

    /// Rowid for a new row, or None if none is available.
    pub fn next_rowid(&self) -> Option<i64> {
        let max = self.rows.keys().next_back().copied().unwrap_or(0);
        if self.autoincrement {
            let m = max.max(self.seq);
            return m.checked_add(1);
        }
        match max.checked_add(1) {
            Some(r) => Some(r),
            None => {
                // Find an unused rowid.
                let mut r: i64 = 1;
                while self.rows.contains_key(&r) {
                    r = r.checked_add(1)?;
                }
                Some(r)
            }
        }
    }

    pub fn insert_row(&mut self, rowid: i64, row: Vec<Value>) {
        self.version += 1;
        for ix in &mut self.indexes {
            ix.insert(&row, rowid);
        }
        self.rows.insert(rowid, row);
    }

    pub fn remove_row(&mut self, rowid: i64) -> Option<Vec<Value>> {
        let row = self.rows.remove(&rowid)?;
        self.version += 1;
        for ix in &mut self.indexes {
            ix.remove(&row, rowid);
        }
        Some(row)
    }

    /// Recompute the entries of index `i` from the rows.
    pub fn fill_index(&mut self, i: usize) {
        let Table { rows, indexes, .. } = self;
        let ix = &mut indexes[i];
        ix.entries.clear();
        for (rowid, row) in rows.iter() {
            ix.insert(row, *rowid);
        }
    }
}

pub fn is_rowid_name(name: &str) -> bool {
    name.eq_ignore_ascii_case("rowid") || name.eq_ignore_ascii_case("oid") || name.eq_ignore_ascii_case("_rowid_")
}

#[derive(Clone, Debug)]
pub struct View {
    pub name: String,
    pub cols: Option<Vec<String>>,
    pub select: Select,
    pub sql: String,
    pub schema_seq: u64,
}

#[derive(Clone, Debug, Default)]
pub struct Database {
    /// Keyed by ASCII-lowercased name. Shared so that snapshots are cheap.
    pub tables: BTreeMap<String, Rc<Table>>,
    pub views: BTreeMap<String, Rc<View>>,
    pub next_seq: u64,
    /// Schema position of sqlite_sequence, once an AUTOINCREMENT table
    /// has been created.
    pub sequence_seq: Option<u64>,
}

pub fn key(name: &str) -> String {
    name.to_ascii_lowercase()
}

pub fn is_sequence_table(name: &str) -> bool {
    name.eq_ignore_ascii_case("sqlite_sequence")
}

pub fn is_schema_table(name: &str) -> bool {
    ["sqlite_schema", "sqlite_master", "sqlite_temp_schema", "sqlite_temp_master"]
        .iter()
        .any(|n| n.eq_ignore_ascii_case(name))
}

impl Database {
    pub fn table(&self, name: &str) -> Option<&Table> {
        self.tables.get(&key(name)).map(|t| t.as_ref())
    }

    /// Mutable access to a table by key (copy-on-write).
    pub fn table_mut(&mut self, tkey: &str) -> Option<&mut Table> {
        self.tables.get_mut(tkey).map(Rc::make_mut)
    }

    pub fn view(&self, name: &str) -> Option<&View> {
        self.views.get(&key(name)).map(|v| v.as_ref())
    }

    /// (table key, index position) of the index called `name`.
    pub fn find_index(&self, name: &str) -> Option<(String, usize)> {
        for (k, t) in &self.tables {
            if let Some(i) = t.indexes.iter().position(|ix| ix.name.eq_ignore_ascii_case(name)) {
                return Some((k.clone(), i));
            }
        }
        None
    }

    pub fn alloc_seq(&mut self) -> u64 {
        self.next_seq += 1;
        self.next_seq
    }

    /// Rows of sqlite_schema: type, name, tbl_name, rootpage, sql.
    pub fn schema_rows(&self) -> Vec<Vec<Value>> {
        let mut rows: Vec<(u64, Vec<Value>)> = Vec::new();
        let text = |s: &str| Value::Text(s.to_string());
        for t in self.tables.values() {
            rows.push((t.schema_seq, vec![text("table"), text(&t.name), text(&t.name), Value::Int(0), text(&t.sql)]));
            for ix in &t.indexes {
                let sql = if ix.auto { Value::Null } else { Value::Text(ix.sql.clone().unwrap_or_else(|| index_sql(t, ix))) };
                rows.push((ix.seq, vec![text("index"), text(&ix.name), text(&t.name), Value::Int(0), sql]));
            }
        }
        if let Some(seq) = self.sequence_seq {
            let sql = "CREATE TABLE sqlite_sequence(name,seq)";
            rows.push((seq, vec![text("table"), text("sqlite_sequence"), text("sqlite_sequence"), Value::Int(0), text(sql)]));
        }
        for v in self.views.values() {
            rows.push((v.schema_seq, vec![text("view"), text(&v.name), text(&v.name), Value::Int(0), text(&v.sql)]));
        }
        rows.sort_by_key(|(s, _)| *s);
        for (i, (_, r)) in rows.iter_mut().enumerate() {
            if !matches!(&r[0], Value::Text(t) if t == "view") {
                r[3] = Value::Int(i as i64 + 2);
            }
        }
        rows.into_iter().map(|(_, r)| r).collect()
    }
}

impl Database {
    /// Rows of sqlite_sequence: name, seq.
    pub fn sequence_rows(&self) -> Vec<Vec<Value>> {
        let mut ts: Vec<&Rc<Table>> = self.tables.values().filter(|t| t.autoincrement && t.seq > 0).collect();
        ts.sort_by_key(|t| t.schema_seq);
        ts.iter().map(|t| vec![Value::Text(t.name.clone()), Value::Int(t.seq)]).collect()
    }
}

fn quote_ident(s: &str) -> String {
    if !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') && !s.as_bytes()[0].is_ascii_digit() {
        s.to_string()
    } else {
        format!("\"{}\"", s.replace('"', "\"\""))
    }
}

/// Approximate CREATE INDEX text for sqlite_schema.sql.
fn index_sql(t: &Table, ix: &Index) -> String {
    let cols: Vec<String> = ix
        .cols
        .iter()
        .map(|c| {
            let mut s = match &c.kind {
                IdxColKind::Col(i) => quote_ident(&t.columns[*i].name),
                IdxColKind::Expr { .. } => "<expr>".to_string(),
            };
            if let Some(n) = &c.coll_name {
                s.push_str(" COLLATE ");
                s.push_str(n);
            }
            if c.desc {
                s.push_str(" DESC");
            }
            s
        })
        .collect();
    format!(
        "CREATE {}INDEX {} ON {}({})",
        if ix.unique { "UNIQUE " } else { "" },
        quote_ident(&ix.name),
        quote_ident(&t.name),
        cols.join(", ")
    )
}
