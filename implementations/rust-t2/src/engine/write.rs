// Writing the SQLite 3 database file format: the whole file is rebuilt
// from the in-memory contents, packing each b-tree bottom-up.

use crate::value::Value;

pub fn write_varint(out: &mut Vec<u8>, v: u64) {
    if v > 0x00ff_ffff_ffff_ffff {
        let mut buf = [0u8; 9];
        buf[8] = v as u8;
        let mut x = v >> 8;
        for i in (0..8).rev() {
            buf[i] = ((x & 0x7f) as u8) | 0x80;
            x >>= 7;
        }
        out.extend_from_slice(&buf);
        return;
    }
    let mut buf = [0u8; 9];
    let mut n = 0;
    let mut x = v;
    loop {
        buf[n] = (x & 0x7f) as u8;
        n += 1;
        x >>= 7;
        if x == 0 {
            break;
        }
    }
    for i in (0..n).rev() {
        out.push(if i > 0 { buf[i] | 0x80 } else { buf[i] });
    }
}

fn varint_len(v: u64) -> usize {
    let mut b = Vec::with_capacity(9);
    write_varint(&mut b, v);
    b.len()
}

/// Encode values as a record.
pub fn encode_record(vals: &[Value]) -> Vec<u8> {
    let mut header = Vec::new();
    let mut body = Vec::new();
    for v in vals {
        let t: u64 = match v {
            Value::Null => 0,
            Value::Integer(0) => 8,
            Value::Integer(1) => 9,
            Value::Integer(n) => {
                let n = *n;
                let (t, len) = if (-128..128).contains(&n) {
                    (1, 1)
                } else if (-32768..32768).contains(&n) {
                    (2, 2)
                } else if (-8388608..8388608).contains(&n) {
                    (3, 3)
                } else if (-2147483648..2147483648).contains(&n) {
                    (4, 4)
                } else if (-(1i64 << 47)..(1i64 << 47)).contains(&n) {
                    (5, 6)
                } else {
                    (6, 8)
                };
                body.extend_from_slice(&n.to_be_bytes()[8 - len..]);
                t
            }
            Value::Real(f) => {
                body.extend_from_slice(&f.to_bits().to_be_bytes());
                7
            }
            Value::Text(s) => {
                body.extend_from_slice(s.as_bytes());
                13 + 2 * s.len() as u64
            }
            Value::Blob(b) => {
                body.extend_from_slice(b);
                12 + 2 * b.len() as u64
            }
        };
        write_varint(&mut header, t);
    }
    let mut hlen = header.len() + 1;
    while header.len() + varint_len(hlen as u64) != hlen {
        hlen = header.len() + varint_len(hlen as u64);
    }
    let mut out = Vec::with_capacity(hlen + body.len());
    write_varint(&mut out, hlen as u64);
    out.extend_from_slice(&header);
    out.extend_from_slice(&body);
    out
}

pub struct Builder {
    page_size: usize,
    usable: usize,
    /// Page n is pages[n - 1]; page 1 is reserved for the schema root.
    pages: Vec<Vec<u8>>,
}

const LEAF_TABLE: u8 = 0x0d;
const INTERIOR_TABLE: u8 = 0x05;
const LEAF_INDEX: u8 = 0x0a;
const INTERIOR_INDEX: u8 = 0x02;

impl Builder {
    pub fn new(page_size: usize) -> Self {
        Builder {
            page_size,
            usable: page_size,
            pages: vec![vec![0; page_size]],
        }
    }

    pub fn alloc(&mut self) -> u32 {
        self.pages.push(vec![0; self.page_size]);
        self.pages.len() as u32
    }

    fn hdr_off(pgno: u32) -> usize {
        if pgno == 1 {
            100
        } else {
            0
        }
    }

    /// Space for cells and their pointers on a page.
    fn capacity(&self, pgno_is_1: bool, interior: bool) -> usize {
        self.usable - if pgno_is_1 { 100 } else { 0 } - if interior { 12 } else { 8 }
    }

    fn write_page(&mut self, pgno: u32, kind: u8, cells: &[Vec<u8>], right: Option<u32>) {
        let usable = self.usable;
        let off = Self::hdr_off(pgno);
        let page = &mut self.pages[pgno as usize - 1];
        let hdr = if right.is_some() { 12 } else { 8 };
        page[off] = kind;
        page[off + 1] = 0;
        page[off + 2] = 0;
        page[off + 3..off + 5].copy_from_slice(&(cells.len() as u16).to_be_bytes());
        let mut content = usable;
        let mut ptr = off + hdr;
        for c in cells {
            content -= c.len();
            page[content..content + c.len()].copy_from_slice(c);
            page[ptr..ptr + 2].copy_from_slice(&(content as u16).to_be_bytes());
            ptr += 2;
        }
        let cs = if content == 65536 { 0 } else { content as u16 };
        page[off + 5..off + 7].copy_from_slice(&cs.to_be_bytes());
        page[off + 7] = 0;
        if let Some(r) = right {
            page[off + 8..off + 12].copy_from_slice(&r.to_be_bytes());
        }
    }

    /// Size of the locally stored part of a payload of `p` bytes.
    fn local_size(&self, p: usize, index: bool) -> usize {
        let u = self.usable;
        let x = if index { (u - 12) * 64 / 255 - 23 } else { u - 35 };
        if p <= x {
            return p;
        }
        let m = (u - 12) * 32 / 255 - 23;
        let k = m + (p - m) % (u - 4);
        if k <= x {
            k
        } else {
            m
        }
    }

    /// Local part of a payload followed by the overflow page number, if any.
    fn spill(&mut self, payload: &[u8], index: bool) -> Vec<u8> {
        let local = self.local_size(payload.len(), index);
        let mut out = payload[..local].to_vec();
        if local < payload.len() {
            let rest = &payload[local..];
            let chunk = self.usable - 4;
            let n = rest.len().div_ceil(chunk);
            let first = self.pages.len() as u32 + 1;
            for i in 0..n {
                let pg = self.alloc();
                let next = if i + 1 < n { pg + 1 } else { 0 };
                let data = &rest[i * chunk..((i + 1) * chunk).min(rest.len())];
                let page = &mut self.pages[pg as usize - 1];
                page[..4].copy_from_slice(&next.to_be_bytes());
                page[4..4 + data.len()].copy_from_slice(data);
            }
            out.extend_from_slice(&first.to_be_bytes());
        }
        out
    }

    /// Build a table b-tree from (rowid, record) pairs in rowid order.
    /// `root` is the page to use for the root (1 for the schema table);
    /// otherwise one is allocated. Returns the root page number.
    pub fn build_table(&mut self, rows: Vec<(i64, Vec<u8>)>, root: Option<u32>) -> u32 {
        let root = root.unwrap_or_else(|| self.alloc());
        let mut cells: Vec<(Vec<u8>, i64)> = Vec::with_capacity(rows.len());
        for (rowid, rec) in rows {
            let mut c = Vec::new();
            write_varint(&mut c, rec.len() as u64);
            write_varint(&mut c, rowid as u64);
            let body = self.spill(&rec, false);
            c.extend_from_slice(&body);
            cells.push((c, rowid));
        }
        let mut interior = false;
        loop {
            let root_cap = self.capacity(root == 1, interior);
            let total: usize = if interior {
                cells[..cells.len() - 1].iter().map(|c| c.0.len() + 2).sum()
            } else {
                cells.iter().map(|c| c.0.len() + 2).sum()
            };
            if total <= root_cap {
                if interior {
                    let right = u32::from_be_bytes(cells.last().unwrap().0[..4].try_into().unwrap());
                    let body: Vec<Vec<u8>> =
                        cells[..cells.len() - 1].iter().map(|c| c.0.clone()).collect();
                    self.write_page(root, INTERIOR_TABLE, &body, Some(right));
                } else {
                    let body: Vec<Vec<u8>> = cells.iter().map(|c| c.0.clone()).collect();
                    self.write_page(root, LEAF_TABLE, &body, None);
                }
                return root;
            }
            let cap = self.capacity(false, interior);
            // Group cells into pages. For interior levels each cell is a
            // child (4-byte page number + key); the last child of a page
            // becomes its right pointer.
            let mut groups: Vec<std::ops::Range<usize>> = Vec::new();
            let mut start = 0;
            let mut used = 0;
            for i in 0..cells.len() {
                let sz = cells[i].0.len() + 2;
                if i > start && used + sz > cap {
                    groups.push(start..i);
                    start = i;
                    used = 0;
                }
                used += sz;
            }
            groups.push(start..cells.len());
            if interior {
                // Counting all children as cells over-estimates by one per
                // page, which is harmless. Make sure no page has a single
                // child.
                let n = groups.len();
                if n >= 2 && groups[n - 1].len() < 2 {
                    let e = groups[n - 2].end - 1;
                    groups[n - 2].end = e;
                    groups[n - 1].start = e;
                }
            }
            let mut next = Vec::with_capacity(groups.len());
            for g in groups {
                let pg = self.alloc();
                let maxkey = cells[g.end - 1].1;
                if interior {
                    let right =
                        u32::from_be_bytes(cells[g.end - 1].0[..4].try_into().unwrap());
                    let body: Vec<Vec<u8>> =
                        cells[g.start..g.end - 1].iter().map(|c| c.0.clone()).collect();
                    self.write_page(pg, INTERIOR_TABLE, &body, Some(right));
                } else {
                    let body: Vec<Vec<u8>> = cells[g].iter().map(|c| c.0.clone()).collect();
                    self.write_page(pg, LEAF_TABLE, &body, None);
                }
                let mut c = pg.to_be_bytes().to_vec();
                write_varint(&mut c, maxkey as u64);
                next.push((c, maxkey));
            }
            cells = next;
            interior = true;
        }
    }

    /// Build an index b-tree from records in index order.
    pub fn build_index(&mut self, recs: Vec<Vec<u8>>) -> u32 {
        let root = self.alloc();
        let mut items: Vec<Vec<u8>> = Vec::with_capacity(recs.len());
        for rec in recs {
            let mut c = Vec::new();
            write_varint(&mut c, rec.len() as u64);
            let body = self.spill(&rec, true);
            c.extend_from_slice(&body);
            items.push(c);
        }
        // Leaf level: pack entries, promoting one entry between leaves.
        let cap = self.capacity(false, false);
        let total: usize = items.iter().map(|c| c.len() + 2).sum();
        if total <= cap {
            self.write_page(root, LEAF_INDEX, &items, None);
            return root;
        }
        let mut children: Vec<u32> = Vec::new();
        let mut seps: Vec<Vec<u8>> = Vec::new();
        let mut groups: Vec<Vec<Vec<u8>>> = Vec::new();
        let mut cur: Vec<Vec<u8>> = Vec::new();
        let mut used = 0;
        let mut it = items.into_iter().peekable();
        while let Some(c) = it.next() {
            let sz = c.len() + 2;
            if !cur.is_empty() && used + sz > cap {
                // `c` becomes a separator unless it is the last entry.
                if it.peek().is_some() {
                    groups.push(std::mem::take(&mut cur));
                    seps.push(c);
                    used = 0;
                    continue;
                }
                let sep = cur.pop().unwrap();
                groups.push(std::mem::take(&mut cur));
                seps.push(sep);
                used = 0;
            }
            used += sz;
            cur.push(c);
        }
        groups.push(cur);
        for g in groups {
            let pg = self.alloc();
            self.write_page(pg, LEAF_INDEX, &g, None);
            children.push(pg);
        }
        // Interior levels.
        loop {
            let with_child = |c: u32, s: &Vec<u8>| {
                let mut v = c.to_be_bytes().to_vec();
                v.extend_from_slice(s);
                v
            };
            let total: usize = seps.iter().map(|s| s.len() + 6).sum();
            if total <= self.capacity(false, true) {
                let cells: Vec<Vec<u8>> = seps
                    .iter()
                    .zip(&children)
                    .map(|(s, &c)| with_child(c, s))
                    .collect();
                self.write_page(root, INTERIOR_INDEX, &cells, Some(*children.last().unwrap()));
                return root;
            }
            let cap = self.capacity(false, true);
            // Pages as ranges of children; separators between pages move up.
            let mut groups: Vec<(usize, usize)> = Vec::new();
            let mut start = 0;
            let mut used = 0;
            let mut j = 0;
            while j < seps.len() {
                let sz = seps[j].len() + 6;
                if j > start && used + sz > cap {
                    // Page covers children start..=j; seps[j] moves up.
                    if j + 1 == children.len() - 1 {
                        // Only one child would remain: give it company.
                        groups.push((start, j - 1));
                        start = j;
                        used = 0;
                        continue;
                    }
                    groups.push((start, j));
                    start = j + 1;
                    used = 0;
                    j += 1;
                    continue;
                }
                used += sz;
                j += 1;
            }
            groups.push((start, children.len() - 1));
            let mut nchildren = Vec::new();
            let mut nseps = Vec::new();
            for (gi, &(a, b)) in groups.iter().enumerate() {
                let pg = self.alloc();
                let cells: Vec<Vec<u8>> = (a..b).map(|k| with_child(children[k], &seps[k])).collect();
                self.write_page(pg, INTERIOR_INDEX, &cells, Some(children[b]));
                nchildren.push(pg);
                if gi + 1 < groups.len() {
                    nseps.push(seps[b].clone());
                }
            }
            children = nchildren;
            seps = nseps;
        }
    }

    /// Assemble the file: page 1 gets the header.
    pub fn finish(mut self, header: &[u8; 100]) -> Vec<u8> {
        let n = self.pages.len() as u32;
        let mut h = *header;
        h[28..32].copy_from_slice(&n.to_be_bytes());
        self.pages[0][..100].copy_from_slice(&h);
        let mut out = Vec::with_capacity(self.pages.len() * self.page_size);
        for p in self.pages {
            out.extend_from_slice(&p);
        }
        out
    }
}

use super::{eval, fold, Cx, Database, Index, Row, Table};
use crate::value::compare_values_coll;
use std::cmp::Ordering;

/// Key values of an index entry as stored (without collation keys), or
/// None when a partial index excludes the row.
fn raw_key(idx: &Index, row: &[Value], rowid: i64) -> Result<Option<Vec<Value>>, String> {
    let mut env = Vec::with_capacity(row.len() + 1);
    env.extend(row.iter().cloned());
    env.push(Value::Integer(rowid));
    if let Some(w) = &idx.where_ {
        if eval(w, &env, Cx::default())?.truthy() != Some(true) {
            return Ok(None);
        }
    }
    let mut k = Vec::with_capacity(idx.parts.len() + 1);
    for p in &idx.parts {
        k.push(match p.col {
            Some(c) => row[c].clone(),
            None => eval(&p.expr, &env, Cx::default())?,
        });
    }
    Ok(Some(k))
}

fn index_records(t: &Table, idx: &Index) -> Result<Vec<Vec<u8>>, String> {
    let mut keys: Vec<(Vec<Value>, i64)> = Vec::new();
    for (&rid, row) in &t.rows {
        if let Some(k) = raw_key(idx, row, rid)? {
            keys.push((k, rid));
        }
    }
    keys.sort_by(|(a, ra), (b, rb)| {
        for (i, p) in idx.parts.iter().enumerate() {
            let o = compare_values_coll(&a[i], &b[i], p.coll);
            let o = if p.desc { o.reverse() } else { o };
            if o != Ordering::Equal {
                return o;
            }
        }
        ra.cmp(rb)
    });
    Ok(keys
        .into_iter()
        .map(|(mut k, rid)| {
            k.push(Value::Integer(rid));
            encode_record(&k)
        })
        .collect())
}

fn table_records(t: &Table) -> Vec<(i64, Vec<u8>)> {
    t.rows
        .iter()
        .map(|(&rid, row)| {
            let rec = match t.ipk {
                Some(i) => {
                    let mut r: Row = row.clone();
                    r[i] = Value::Null;
                    encode_record(&r)
                }
                None => encode_record(row),
            };
            (rid, rec)
        })
        .collect()
}

impl Database {
    /// Contents of the database file to write at exit, if it changed.
    pub fn save(&mut self) -> Result<Option<Vec<u8>>, String> {
        if let Some(t) = self.txn.take() {
            self.undo_entries(t.log);
        }
        if !self.dirty {
            return Ok(None);
        }
        let page_size = if self.page_size == 0 { 4096 } else { self.page_size };
        let mut b = Builder::new(page_size);
        let mut schema: Vec<(i64, Vec<u8>)> = Vec::new();
        for r in self.schema_rows() {
            let (Value::Text(kind), Value::Text(name), Value::Text(tbl)) = (&r[0], &r[1], &r[2])
            else {
                continue;
            };
            let root = match kind.as_str() {
                "table" if name == "sqlite_sequence" => {
                    let rows: Vec<(i64, Vec<u8>)> = self
                        .sequence_rows()
                        .unwrap_or_default()
                        .into_iter()
                        .enumerate()
                        .map(|(i, r)| (i as i64 + 1, encode_record(&r[..2])))
                        .collect();
                    b.build_table(rows, None)
                }
                "table" => {
                    let t = &self.tables[&fold(name)];
                    b.build_table(table_records(t), None)
                }
                "index" => {
                    let t = &self.tables[&fold(tbl)];
                    let idx = t
                        .indexes
                        .iter()
                        .find(|i| i.name == *name)
                        .ok_or("index vanished")?;
                    b.build_index(index_records(t, idx)?)
                }
                _ => 0,
            };
            let mut vals = r[..5].to_vec();
            vals[3] = Value::Integer(root as i64);
            let rowid = match r[5] {
                Value::Integer(n) => n,
                _ => schema.len() as i64 + 1,
            };
            schema.push((rowid, encode_record(&vals)));
        }
        b.build_table(schema, Some(1));

        let mut h = [0u8; 100];
        if let Some(old) = &self.file_header {
            h.copy_from_slice(old);
        }
        h[..16].copy_from_slice(b"SQLite format 3\0");
        let ps = if page_size == 65536 { 1u16 } else { page_size as u16 };
        h[16..18].copy_from_slice(&ps.to_be_bytes());
        h[18] = 1;
        h[19] = 1;
        h[20] = 0;
        h[21] = 64;
        h[22] = 32;
        h[23] = 32;
        let be32 = |h: &[u8; 100], o: usize| u32::from_be_bytes(h[o..o + 4].try_into().unwrap());
        let counter = be32(&h, 24).wrapping_add(1);
        h[24..28].copy_from_slice(&counter.to_be_bytes());
        h[32..40].fill(0);
        if self.schema_dirty || self.file_header.is_none() {
            let cookie = be32(&h, 40).wrapping_add(1);
            h[40..44].copy_from_slice(&cookie.to_be_bytes());
        }
        h[44..48].copy_from_slice(&4u32.to_be_bytes());
        h[52..56].fill(0);
        h[56..60].copy_from_slice(&1u32.to_be_bytes());
        h[64..68].fill(0);
        h[72..92].fill(0);
        h[92..96].copy_from_slice(&counter.to_be_bytes());
        h[96..100].copy_from_slice(&3053000u32.to_be_bytes());
        Ok(Some(b.finish(&h)))
    }
}
