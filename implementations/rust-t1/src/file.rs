// Reading SQLite 3 database files into the in-memory catalog.

use std::collections::BTreeMap;

use crate::ast::Stmt;
use crate::db::key;
use crate::error::{err, Result};
use crate::eval::{bind, eval, Cx, Scope};
use crate::exec::Engine;
use crate::parser::parse_statement;
use crate::value::{Affinity, Value};

/// Read-only view of the pages of a database file.
struct Pager<'a> {
    data: &'a [u8],
    page_size: usize,
    usable: usize,
}

impl<'a> Pager<'a> {
    fn new(data: &'a [u8]) -> Result<Pager<'a>> {
        if data.len() < 100 || &data[..16] != b"SQLite format 3\0" {
            return err!("file is not a database");
        }
        let ps = u16::from_be_bytes([data[16], data[17]]) as usize;
        let page_size = if ps == 1 { 65536 } else { ps };
        if !(512..=65536).contains(&page_size) || !page_size.is_power_of_two() {
            return err!("file is not a database");
        }
        let reserved = data[20] as usize;
        if data[56..60] != [0, 0, 0, 1] && data[56..60] != [0, 0, 0, 0] {
            return err!("unsupported text encoding");
        }
        Ok(Pager { data, page_size, usable: page_size - reserved })
    }

    fn page(&self, n: u32) -> Result<&'a [u8]> {
        let n = n as usize;
        if n == 0 {
            return err!("database disk image is malformed");
        }
        let start = (n - 1) * self.page_size;
        let end = start + self.page_size;
        if end > self.data.len() {
            return err!("database disk image is malformed");
        }
        Ok(&self.data[start..end])
    }

    /// Payload of a cell whose total payload size is `p`, starting at
    /// `off` in `page`; `max_local` is X for the b-tree kind.
    fn payload(&self, page: &[u8], off: usize, p: usize, max_local: usize) -> Result<Vec<u8>> {
        let u = self.usable;
        let m = ((u - 12) * 32 / 255) - 23;
        let local = if p <= max_local {
            p
        } else {
            let k = m + (p - m) % (u - 4);
            if k <= max_local {
                k
            } else {
                m
            }
        };
        let Some(local_bytes) = page.get(off..off + local) else {
            return err!("database disk image is malformed");
        };
        let mut out = Vec::with_capacity(p);
        out.extend_from_slice(local_bytes);
        if local < p {
            let Some(b) = page.get(off + local..off + local + 4) else {
                return err!("database disk image is malformed");
            };
            let mut next = u32::from_be_bytes([b[0], b[1], b[2], b[3]]);
            while out.len() < p {
                if next == 0 {
                    return err!("database disk image is malformed");
                }
                let pg = self.page(next)?;
                next = u32::from_be_bytes([pg[0], pg[1], pg[2], pg[3]]);
                let take = (p - out.len()).min(u - 4);
                out.extend_from_slice(&pg[4..4 + take]);
            }
        }
        Ok(out)
    }

    /// All (rowid, payload) cells of the table b-tree rooted at `root`,
    /// in rowid order.
    fn table_rows(&self, root: u32) -> Result<Vec<(i64, Vec<u8>)>> {
        let mut out = Vec::new();
        let max_local = self.usable - 35;
        let mut stack = vec![root];
        let mut visited = 0usize;
        let limit = self.data.len() / self.page_size + 1;
        while let Some(pn) = stack.pop() {
            visited += 1;
            if visited > limit {
                return err!("database disk image is malformed");
            }
            let page = self.page(pn)?;
            let h = if pn == 1 { 100 } else { 0 };
            let kind = page[h];
            let ncells = u16::from_be_bytes([page[h + 3], page[h + 4]]) as usize;
            match kind {
                0x0d => {
                    for i in 0..ncells {
                        let cp = h + 8 + 2 * i;
                        let off = u16::from_be_bytes([page[cp], page[cp + 1]]) as usize;
                        let (p, n1) = varint(page, off)?;
                        let (rowid, n2) = varint(page, off + n1)?;
                        let payload = self.payload(page, off + n1 + n2, p as usize, max_local)?;
                        out.push((rowid as i64, payload));
                    }
                }
                0x05 => {
                    let right = u32::from_be_bytes([page[h + 8], page[h + 9], page[h + 10], page[h + 11]]);
                    // Push in reverse so the leftmost child is visited first.
                    stack.push(right);
                    for i in (0..ncells).rev() {
                        let cp = h + 12 + 2 * i;
                        let off = u16::from_be_bytes([page[cp], page[cp + 1]]) as usize;
                        let Some(b) = page.get(off..off + 4) else {
                            return err!("database disk image is malformed");
                        };
                        stack.push(u32::from_be_bytes([b[0], b[1], b[2], b[3]]));
                    }
                }
                _ => return err!("database disk image is malformed"),
            }
        }
        Ok(out)
    }
}

/// Big-endian SQLite varint at `off`: (value, length).
fn varint(b: &[u8], off: usize) -> Result<(u64, usize)> {
    let mut v: u64 = 0;
    for i in 0..9 {
        let Some(&c) = b.get(off + i) else {
            return err!("database disk image is malformed");
        };
        if i == 8 {
            return Ok(((v << 8) | c as u64, 9));
        }
        v = (v << 7) | (c & 0x7f) as u64;
        if c & 0x80 == 0 {
            return Ok((v, i + 1));
        }
    }
    unreachable!()
}

/// Decode a record into its values.
fn decode_record(rec: &[u8]) -> Result<Vec<Value>> {
    let (hsize, mut hp) = varint(rec, 0)?;
    let hsize = hsize as usize;
    let mut body = hsize;
    let mut out = Vec::new();
    while hp < hsize {
        let (t, n) = varint(rec, hp)?;
        hp += n;
        let len = match t {
            0 | 8 | 9 | 10 | 11 => 0,
            1..=4 => t as usize,
            5 => 6,
            6 | 7 => 8,
            _ => ((t - 12) / 2) as usize,
        };
        let Some(b) = rec.get(body..body + len) else {
            return err!("database disk image is malformed");
        };
        body += len;
        let v = match t {
            0 | 10 | 11 => Value::Null,
            1..=6 => {
                let mut x: i64 = if b[0] & 0x80 != 0 { -1 } else { 0 };
                for &c in b {
                    x = (x << 8) | c as i64;
                }
                Value::Int(x)
            }
            7 => {
                let f = f64::from_bits(u64::from_be_bytes(b.try_into().unwrap()));
                if f.is_nan() {
                    Value::Null
                } else {
                    Value::Real(f)
                }
            }
            8 => Value::Int(0),
            9 => Value::Int(1),
            _ if t % 2 == 0 => Value::Blob(b.to_vec()),
            _ => Value::Text(String::from_utf8_lossy(b).into_owned()),
        };
        out.push(v);
    }
    Ok(out)
}

fn text_of(v: Option<&Value>) -> Option<String> {
    match v {
        Some(Value::Text(s)) => Some(s.clone()),
        _ => None,
    }
}

impl Engine {
    /// Load the schema and contents of a SQLite database file.
    pub fn load_file(&mut self, data: &[u8]) -> Result<()> {
        if data.is_empty() {
            return Ok(());
        }
        let pager = Pager::new(data)?;
        let mut max_seq = self.db.next_seq;
        // (rowid, type, name, rootpage)
        let mut entries: Vec<(i64, String, String, u32)> = Vec::new();
        let mut roots: Vec<(String, u32)> = Vec::new();
        let mut seq_root = None;
        for (rowid, payload) in pager.table_rows(1)? {
            let rec = decode_record(&payload)?;
            let ty = text_of(rec.first()).unwrap_or_default();
            let name = text_of(rec.get(1)).unwrap_or_default();
            let root = match rec.get(3) {
                Some(Value::Int(r)) => *r as u32,
                _ => 0,
            };
            let sql = text_of(rec.get(4));
            max_seq = max_seq.max(rowid as u64);
            entries.push((rowid, ty.clone(), name.clone(), root));
            if ty == "table" && name.eq_ignore_ascii_case("sqlite_sequence") {
                seq_root = Some(root);
                self.db.sequence_seq = Some(rowid as u64);
                continue;
            }
            let Some(sql) = sql else { continue };
            if name.len() >= 7 && name.as_bytes()[..7].eq_ignore_ascii_case(b"sqlite_") {
                continue;
            }
            let stmt = match parse_statement(&sql) {
                Ok(s) => s,
                Err(_) => continue,
            };
            let res = match stmt {
                Stmt::CreateTable(ct) => {
                    let r = self.create_table(ct, &sql);
                    if r.is_ok() {
                        roots.push((key(&name), root));
                    }
                    r
                }
                Stmt::CreateIndex(ci) => self.create_index(ci, &sql),
                Stmt::CreateView(cv) => self.create_view(cv, &sql),
                _ => Ok(()),
            };
            let _ = res;
        }

        // Rows.
        for (tkey, root) in roots {
            let t = self.db.table_mut(&tkey).unwrap();
            let defaults: Vec<Value> = t
                .columns
                .iter()
                .map(|c| {
                    c.default
                        .as_ref()
                        .and_then(|d| bind(d, &Scope::default()).ok())
                        .and_then(|b| eval(&b, &[], &Cx::new(&crate::db::Database::default())).ok())
                        .map(|v| v.apply_affinity(c.affinity))
                        .unwrap_or(Value::Null)
                })
                .collect();
            let reals: Vec<bool> = t.columns.iter().map(|c| c.affinity == Affinity::Real).collect();
            let alias = t.rowid_alias;
            for (rowid, payload) in pager.table_rows(root)? {
                let rec = decode_record(&payload)?;
                let mut rec = rec.into_iter();
                let mut row = Vec::with_capacity(defaults.len());
                for (i, d) in defaults.iter().enumerate() {
                    let v = match rec.next() {
                        Some(v) => v,
                        None => d.clone(),
                    };
                    let v = if Some(i) == alias {
                        Value::Int(rowid)
                    } else if reals[i] {
                        match v {
                            Value::Int(x) => Value::Real(x as f64),
                            v => v,
                        }
                    } else {
                        v
                    };
                    row.push(v);
                }
                t.rows.insert(rowid, row);
            }
            for i in 0..t.indexes.len() {
                t.fill_index(i);
            }
        }

        // AUTOINCREMENT counters.
        if let Some(root) = seq_root {
            for (_, payload) in pager.table_rows(root)? {
                let rec = decode_record(&payload)?;
                if let (Some(Value::Text(name)), Some(Value::Int(seq))) = (rec.first(), rec.get(1)) {
                    if let Some(t) = self.db.table_mut(&key(name)) {
                        t.seq = *seq;
                    }
                }
            }
        }

        // Schema order follows the schema table's rowids.
        for (rowid, ty, name, _) in &entries {
            let seq = *rowid as u64;
            match ty.as_str() {
                "table" => {
                    if let Some(t) = self.db.table_mut(&key(name)) {
                        t.schema_seq = seq;
                    }
                }
                "index" => {
                    if let Some((tk, pos)) = self.db.find_index(name) {
                        self.db.table_mut(&tk).unwrap().indexes[pos].seq = seq;
                    }
                }
                "view" => {
                    if let Some(v) = self.db.views.get_mut(&key(name)) {
                        std::rc::Rc::make_mut(v).schema_seq = seq;
                    }
                }
                _ => {}
            }
        }
        self.db.next_seq = max_seq;
        self.undo.clear();
        self.file_page_size = pager.page_size;
        self.file_header = Some(data[..100].to_vec());
        self.file_schema = self.schema_signature();
        Ok(())
    }
}
