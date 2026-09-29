// Reading SQLite 3 database files into the in-memory database.

use crate::ast::Stmt;
use crate::db::{key, Database, View, SEQ_TABLE};
use crate::ddl::make_index;
use crate::eval::{bind, eval, Env, Scope};
use crate::exec::build_table;
use crate::parser::parse_statement;
use crate::value::{apply_affinity, Affinity, Value};

const MAGIC: &[u8; 16] = b"SQLite format 3\0";

/// A read-only view of a database file's pages.
pub struct Pages<'a> {
    data: &'a [u8],
    pub page_size: usize,
    usable: usize,
}

/// Decodes a big-endian varint; returns (value, length).
pub fn read_varint(b: &[u8]) -> (u64, usize) {
    let mut v: u64 = 0;
    for i in 0..9 {
        let Some(&c) = b.get(i) else {
            return (v, i);
        };
        if i == 8 {
            return ((v << 8) | c as u64, 9);
        }
        v = (v << 7) | (c & 0x7f) as u64;
        if c & 0x80 == 0 {
            return (v, i + 1);
        }
    }
    (v, 9)
}

fn be(b: &[u8]) -> u64 {
    b.iter().fold(0u64, |a, &c| (a << 8) | c as u64)
}

impl<'a> Pages<'a> {
    pub fn open(data: &'a [u8]) -> Result<Pages<'a>, String> {
        if data.len() < 100 || &data[..16] != MAGIC {
            return Err("file is not a database".to_string());
        }
        let ps = be(&data[16..18]) as usize;
        let page_size = if ps == 1 { 65536 } else { ps };
        if !(512..=65536).contains(&page_size) || !page_size.is_power_of_two() {
            return Err("file is not a database".to_string());
        }
        if data[56..60] != [0, 0, 0, 1] && data[56..60] != [0, 0, 0, 0] {
            return Err("unsupported text encoding".to_string());
        }
        let usable = page_size - data[20] as usize;
        Ok(Pages { data, page_size, usable })
    }

    fn page(&self, n: u64) -> Result<&'a [u8], String> {
        let start = (n as usize).checked_sub(1).map(|p| p * self.page_size);
        match start {
            Some(s) if n > 0 && s + self.page_size <= self.data.len() => Ok(&self.data[s..s + self.page_size]),
            _ => Err("database disk image is malformed".to_string()),
        }
    }

    /// Assembles a payload of `total` bytes whose first part is at
    /// `cell[..]`, spilling to overflow pages when larger than `max_local`.
    fn payload(&self, cell: &[u8], total: usize, index: bool) -> Result<Vec<u8>, String> {
        let u = self.usable;
        let x = if index { (u - 12) * 64 / 255 - 23 } else { u - 35 };
        if total <= x {
            return cell.get(..total).map(|s| s.to_vec()).ok_or_else(malformed);
        }
        let m = (u - 12) * 32 / 255 - 23;
        let k = m + (total - m) % (u - 4);
        let local = if k <= x { k } else { m };
        let mut out = Vec::with_capacity(total);
        out.extend_from_slice(cell.get(..local).ok_or_else(malformed)?);
        let mut next = be(cell.get(local..local + 4).ok_or_else(malformed)?);
        let mut guard = 0usize;
        while out.len() < total {
            if next == 0 || guard > self.data.len() / self.page_size + 1 {
                return Err(malformed());
            }
            guard += 1;
            let p = self.page(next)?;
            next = be(&p[..4]);
            let n = (total - out.len()).min(u - 4);
            out.extend_from_slice(&p[4..4 + n]);
        }
        Ok(out)
    }

    /// Every (rowid, record) of the table b-tree rooted at `root`, in rowid order.
    pub fn table_rows(&self, root: u64) -> Result<Vec<(i64, Vec<u8>)>, String> {
        let mut out = Vec::new();
        self.walk_table(root, &mut out, 0)?;
        Ok(out)
    }

    fn walk_table(&self, pgno: u64, out: &mut Vec<(i64, Vec<u8>)>, depth: usize) -> Result<(), String> {
        if depth > 64 {
            return Err(malformed());
        }
        let p = self.page(pgno)?;
        let h = if pgno == 1 { 100 } else { 0 };
        let kind = p[h];
        let ncells = be(&p[h + 3..h + 5]) as usize;
        let hdr = if kind == 0x05 { 12 } else { 8 };
        let cell_at = |i: usize| -> Result<usize, String> {
            let o = h + hdr + 2 * i;
            let off = be(p.get(o..o + 2).ok_or_else(malformed)?) as usize;
            if off >= p.len() {
                return Err(malformed());
            }
            Ok(off)
        };
        match kind {
            0x0d => {
                for i in 0..ncells {
                    let c = &p[cell_at(i)?..];
                    let (size, n1) = read_varint(c);
                    let (rowid, n2) = read_varint(&c[n1..]);
                    let body = self.payload(&c[n1 + n2..], size as usize, false)?;
                    out.push((rowid as i64, body));
                }
            }
            0x05 => {
                for i in 0..ncells {
                    let c = &p[cell_at(i)?..];
                    let child = be(c.get(..4).ok_or_else(malformed)?);
                    self.walk_table(child, out, depth + 1)?;
                }
                let right = be(&p[h + 8..h + 12]);
                self.walk_table(right, out, depth + 1)?;
            }
            _ => return Err(malformed()),
        }
        Ok(())
    }
}

fn malformed() -> String {
    "database disk image is malformed".to_string()
}

/// Decodes a record into its values.
pub fn decode_record(rec: &[u8]) -> Result<Vec<Value>, String> {
    let (hsize, n) = read_varint(rec);
    let hsize = hsize as usize;
    if hsize > rec.len() || hsize < n {
        return Err(malformed());
    }
    let mut types = Vec::new();
    let mut pos = n;
    while pos < hsize {
        let (t, n) = read_varint(&rec[pos..hsize]);
        if n == 0 {
            break;
        }
        types.push(t);
        pos += n;
    }
    let mut body = hsize;
    let mut vals = Vec::with_capacity(types.len());
    for t in types {
        let len = match t {
            0 | 8 | 9 | 10 | 11 => 0,
            1..=4 => t as usize,
            5 => 6,
            6 | 7 => 8,
            _ => ((t - 12) / 2) as usize,
        };
        let b = rec.get(body..body + len).ok_or_else(malformed)?;
        body += len;
        vals.push(match t {
            0 | 10 | 11 => Value::Null,
            1..=6 => {
                let mut v = be(b);
                let bits = len * 8;
                if bits < 64 && v & (1 << (bits - 1)) != 0 {
                    v |= !0u64 << bits;
                }
                Value::Integer(v as i64)
            }
            7 => Value::Real(f64::from_bits(be(b))),
            8 => Value::Integer(0),
            9 => Value::Integer(1),
            _ if t % 2 == 0 => Value::Blob(b.to_vec()),
            _ => Value::Text(String::from_utf8_lossy(b).into_owned()),
        });
    }
    Ok(vals)
}

fn text_of(v: Option<&Value>) -> Option<String> {
    match v {
        Some(Value::Text(s)) => Some(s.clone()),
        _ => None,
    }
}

/// Loads the database in `data` into the (empty) `db`.
pub fn load(db: &mut Database, data: &[u8]) -> Result<(), String> {
    if data.is_empty() {
        return Ok(());
    }
    let pages = Pages::open(data)?;
    let schema = pages.table_rows(1)?;
    let mut roots: Vec<(String, u64)> = Vec::new();
    for (_, rec) in &schema {
        let r = decode_record(rec)?;
        let (Some(kind), Some(name)) = (text_of(r.first()), text_of(r.get(1))) else {
            continue;
        };
        let tbl_name = text_of(r.get(2)).unwrap_or_default();
        let root = match r.get(3) {
            Some(Value::Integer(i)) => *i,
            _ => 0,
        };
        let sql = text_of(r.get(4));
        // objects that fail to parse are skipped
        let _ = load_object(db, &kind, &name, &tbl_name, root, sql);
        if kind == "table" && root > 0 && db.tables.contains_key(&key(&name)) {
            roots.push((key(&name), root as u64));
        }
    }
    for (tk, root) in roots {
        load_rows(db, &pages, &tk, root)?;
    }
    db.end_statement();
    Ok(())
}

fn load_object(
    db: &mut Database,
    kind: &str,
    name: &str,
    tbl_name: &str,
    root: i64,
    sql: Option<String>,
) -> Result<(), String> {
    match kind {
        "table" => {
            let src = if key(name) == SEQ_TABLE { "CREATE TABLE sqlite_sequence(name,seq)".to_string() } else { sql.clone().ok_or_else(malformed)? };
            let Stmt::CreateTable(ct) = parse_statement(&src)? else {
                return Err(malformed());
            };
            let mut t = build_table(db, &ct)?;
            t.name = name.to_string();
            t.sql = sql.unwrap_or(src);
            t.order = db.next_order();
            t.root = root;
            db.put_table(t);
        }
        "index" => {
            let tk = key(tbl_name);
            match sql {
                None => {
                    let order = db.next_order();
                    let t = db.tables.get_mut(&tk).ok_or_else(malformed)?;
                    let pos = t
                        .indexes
                        .iter()
                        .position(|i| i.auto && i.name.eq_ignore_ascii_case(name))
                        .or_else(|| t.indexes.iter().position(|i| i.auto && i.root == 0))
                        .ok_or_else(malformed)?;
                    let idx = &mut t.indexes[pos];
                    idx.name = name.to_string();
                    idx.order = order;
                    idx.root = root;
                }
                Some(sql) => {
                    let Stmt::CreateIndex(mut ci) = parse_statement(&sql)? else {
                        return Err(malformed());
                    };
                    ci.sql = sql;
                    let t = db.tables.get(&tk).ok_or_else(malformed)?;
                    let mut idx = make_index(db, t, &ci)?;
                    idx.order = db.next_order();
                    idx.root = root;
                    db.tables.get_mut(&tk).unwrap().indexes.push(idx);
                }
            }
        }
        "view" => {
            let sql = sql.ok_or_else(malformed)?;
            let Stmt::CreateView(cv) = parse_statement(&sql)? else {
                return Err(malformed());
            };
            let order = db.next_order();
            db.put_view(View { name: name.to_string(), columns: cv.columns, select: cv.select, sql, order, temp: false });
        }
        _ => {}
    }
    Ok(())
}

fn load_rows(db: &mut Database, pages: &Pages, tk: &str, root: u64) -> Result<(), String> {
    let rows = pages.table_rows(root)?;
    let t = &db.tables[tk];
    let ncols = t.columns.len();
    let ipk = t.ipk;
    let affs: Vec<Affinity> = t.columns.iter().map(|c| c.affinity).collect();
    // values of columns missing from older records (ALTER TABLE ADD COLUMN)
    let mut defaults = Vec::with_capacity(ncols);
    {
        let empty = Scope::empty();
        let env = Env::new(db);
        for c in &t.columns {
            let v = match &c.default {
                Some(d) => eval(&bind(d, &empty, db)?, &[], &env)?,
                None => Value::Null,
            };
            defaults.push(apply_affinity(v, c.affinity));
        }
    }
    let t = db.tables.get_mut(tk).unwrap();
    for (rowid, rec) in rows {
        let mut vals = decode_record(&rec)?;
        vals.truncate(ncols);
        for i in vals.len()..ncols {
            vals.push(defaults[i].clone());
        }
        for (v, aff) in vals.iter_mut().zip(&affs) {
            if *aff == Affinity::Real {
                if let Value::Integer(i) = v {
                    *v = Value::Real(*i as f64);
                }
            }
        }
        if let Some(p) = ipk {
            vals[p] = Value::Integer(rowid);
        }
        t.add_row(rowid, vals)?;
    }
    Ok(())
}
