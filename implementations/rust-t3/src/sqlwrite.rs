// Writing the in-memory database out as a SQLite 3 database file.
//
// The whole file is rebuilt: every b-tree is bulk-loaded bottom-up into
// freshly numbered pages, with no free pages left over.

use crate::db::Database;
use crate::value::Value;

const MAGIC: &[u8; 16] = b"SQLite format 3\0";
const DEFAULT_PAGE_SIZE: usize = 4096;
const SQLITE_VERSION: u32 = 3_053_000;

pub fn put_varint(out: &mut Vec<u8>, v: u64) {
    if v > 0x00ff_ffff_ffff_ffff {
        let mut b = [0u8; 9];
        b[8] = v as u8;
        let mut x = v >> 8;
        for i in (0..8).rev() {
            b[i] = (x & 0x7f) as u8 | 0x80;
            x >>= 7;
        }
        out.extend_from_slice(&b);
        return;
    }
    let mut tmp = [0u8; 9];
    let mut n = 0;
    let mut x = v;
    loop {
        tmp[n] = (x & 0x7f) as u8;
        n += 1;
        x >>= 7;
        if x == 0 {
            break;
        }
    }
    for i in (0..n).rev() {
        out.push(if i > 0 { tmp[i] | 0x80 } else { tmp[i] });
    }
}

fn int_serial(i: i64) -> (u64, usize) {
    match i {
        0 => (8, 0),
        1 => (9, 0),
        -128..=127 => (1, 1),
        -32768..=32767 => (2, 2),
        -8_388_608..=8_388_607 => (3, 3),
        -2_147_483_648..=2_147_483_647 => (4, 4),
        -140_737_488_355_328..=140_737_488_355_327 => (5, 6),
        _ => (6, 8),
    }
}

/// Encodes values as a record.
pub fn encode_record(vals: &[Value]) -> Vec<u8> {
    let mut hdr = Vec::new();
    let mut body = Vec::new();
    for v in vals {
        match v {
            Value::Null => put_varint(&mut hdr, 0),
            Value::Integer(i) => {
                let (t, n) = int_serial(*i);
                put_varint(&mut hdr, t);
                body.extend_from_slice(&i.to_be_bytes()[8 - n..]);
            }
            Value::Real(f) => {
                put_varint(&mut hdr, 7);
                body.extend_from_slice(&f.to_bits().to_be_bytes());
            }
            Value::Text(s) => {
                put_varint(&mut hdr, 13 + 2 * s.len() as u64);
                body.extend_from_slice(s.as_bytes());
            }
            Value::Blob(b) => {
                put_varint(&mut hdr, 12 + 2 * b.len() as u64);
                body.extend_from_slice(b);
            }
        }
    }
    // the header size counts itself
    let mut hlen = hdr.len() + 1;
    let mut size = Vec::new();
    loop {
        size.clear();
        put_varint(&mut size, hlen as u64);
        if size.len() + hdr.len() == hlen {
            break;
        }
        hlen = size.len() + hdr.len();
    }
    let mut out = size;
    out.extend_from_slice(&hdr);
    out.extend_from_slice(&body);
    out
}

struct Writer {
    page_size: usize,
    usable: usize,
    /// pages[i] is page i + 1; page 1 is filled in last.
    pages: Vec<Vec<u8>>,
}

impl Writer {
    fn alloc(&mut self) -> u32 {
        self.pages.push(vec![0u8; self.page_size]);
        self.pages.len() as u32
    }

    /// Local part of a payload of `p` bytes, followed by an overflow
    /// pointer if it does not fit.
    fn payload(&mut self, out: &mut Vec<u8>, data: &[u8], index: bool) {
        let u = self.usable;
        let x = if index { (u - 12) * 64 / 255 - 23 } else { u - 35 };
        let p = data.len();
        if p <= x {
            out.extend_from_slice(data);
            return;
        }
        let m = (u - 12) * 32 / 255 - 23;
        let k = m + (p - m) % (u - 4);
        let local = if k <= x { k } else { m };
        out.extend_from_slice(&data[..local]);
        let mut rest = &data[local..];
        let first = self.pages.len() as u32 + 1;
        out.extend_from_slice(&first.to_be_bytes());
        while !rest.is_empty() {
            let pg = self.alloc();
            let n = rest.len().min(u - 4);
            let next = if n < rest.len() { pg + 1 } else { 0 };
            let page = &mut self.pages[pg as usize - 1];
            page[..4].copy_from_slice(&next.to_be_bytes());
            page[4..4 + n].copy_from_slice(&rest[..n]);
            rest = &rest[n..];
        }
    }

    /// Space available for cells (and their pointers) on a page.
    fn capacity(&self, pgno: u32, interior: bool) -> usize {
        let h = if pgno == 1 { 100 } else { 0 };
        self.usable - h - if interior { 12 } else { 8 }
    }

    fn write_page(&mut self, pgno: u32, kind: u8, cells: &[Vec<u8>], right: Option<u32>) {
        let h = if pgno == 1 { 100 } else { 0 };
        let usable = self.usable;
        let page = &mut self.pages[pgno as usize - 1];
        let hdr = if right.is_some() { 12 } else { 8 };
        let mut end = usable;
        let mut ptr = h + hdr;
        for c in cells {
            end -= c.len();
            page[end..end + c.len()].copy_from_slice(c);
            page[ptr..ptr + 2].copy_from_slice(&(end as u16).to_be_bytes());
            ptr += 2;
        }
        page[h] = kind;
        page[h + 1..h + 3].copy_from_slice(&[0, 0]);
        page[h + 3..h + 5].copy_from_slice(&(cells.len() as u16).to_be_bytes());
        let start = if end == 65536 { 0 } else { end as u16 };
        page[h + 5..h + 7].copy_from_slice(&start.to_be_bytes());
        page[h + 7] = 0;
        if let Some(r) = right {
            page[h + 8..h + 12].copy_from_slice(&r.to_be_bytes());
        }
    }

    /// Builds a table b-tree from (rowid, record) pairs in rowid order;
    /// returns its root page (`root` if given).
    fn table_tree(&mut self, rows: Vec<(i64, Vec<u8>)>, root: Option<u32>) -> u32 {
        let mut cells: Vec<(i64, Vec<u8>)> = Vec::with_capacity(rows.len());
        for (rowid, rec) in rows {
            let mut c = Vec::with_capacity(rec.len() + 12);
            put_varint(&mut c, rec.len() as u64);
            put_varint(&mut c, rowid as u64);
            self.payload(&mut c, &rec, false);
            pad(&mut c);
            cells.push((rowid, c));
        }
        let root_cap = self.capacity(root.unwrap_or(0), false);
        if fits(cells.iter().map(|c| c.1.len()), root_cap) {
            let pg = root.unwrap_or_else(|| self.alloc());
            let cs: Vec<Vec<u8>> = cells.into_iter().map(|c| c.1).collect();
            self.write_page(pg, 0x0d, &cs, None);
            return pg;
        }
        // leaves: (page, max rowid)
        let cap = self.capacity(0, false);
        let mut groups: Vec<Vec<(i64, Vec<u8>)>> = Vec::new();
        let mut cur: Vec<(i64, Vec<u8>)> = Vec::new();
        let mut used = 0;
        for c in cells {
            if used + c.1.len() + 2 > cap && !cur.is_empty() {
                groups.push(std::mem::take(&mut cur));
                used = 0;
            }
            used += c.1.len() + 2;
            cur.push(c);
        }
        if groups.is_empty() {
            // only the smaller page 1 overflowed: an interior root needs two children
            let half = cur.len() / 2;
            groups.push(cur.drain(..half).collect());
        }
        groups.push(cur);
        let mut level: Vec<(u32, i64)> = Vec::new();
        for g in groups {
            let last = g[g.len() - 1].0;
            let cs: Vec<Vec<u8>> = g.into_iter().map(|c| c.1).collect();
            let pg = self.alloc();
            self.write_page(pg, 0x0d, &cs, None);
            level.push((pg, last));
        }
        // interior levels
        loop {
            let cell = |&(pg, key): &(u32, i64)| {
                let mut c = pg.to_be_bytes().to_vec();
                put_varint(&mut c, key as u64);
                c
            };
            let root_cap = self.capacity(root.unwrap_or(0), true);
            let n = level.len();
            if fits(level[..n - 1].iter().map(|x| cell(x).len()), root_cap) {
                let cs: Vec<Vec<u8>> = level[..n - 1].iter().map(cell).collect();
                let pg = root.unwrap_or_else(|| self.alloc());
                self.write_page(pg, 0x05, &cs, Some(level[n - 1].0));
                return pg;
            }
            let cap = self.capacity(0, true);
            // group children: each page takes cells for all but its last child
            let mut groups: Vec<Vec<(u32, i64)>> = Vec::new();
            let mut cur: Vec<(u32, i64)> = Vec::new();
            let mut used = 0;
            for ch in level {
                let sz = cell(&ch).len() + 2;
                if used + sz > cap && cur.len() >= 2 {
                    groups.push(std::mem::take(&mut cur));
                    used = 0;
                }
                used += sz;
                cur.push(ch);
            }
            if cur.len() < 2 {
                let prev = groups.last_mut().unwrap();
                let moved = prev.pop().unwrap();
                cur.insert(0, moved);
            }
            groups.push(cur);
            let mut next = Vec::new();
            for g in groups {
                let cs: Vec<Vec<u8>> = g[..g.len() - 1].iter().map(cell).collect();
                let pg = self.alloc();
                let (right, max) = g[g.len() - 1];
                self.write_page(pg, 0x05, &cs, Some(right));
                next.push((pg, max));
            }
            level = next;
        }
    }

    /// Builds an index b-tree from records in index order.
    fn index_tree(&mut self, recs: Vec<Vec<u8>>) -> u32 {
        // cell bodies (payload size, local payload, overflow pointer)
        let mut items: Vec<Vec<u8>> = Vec::with_capacity(recs.len());
        for rec in recs {
            let mut c = Vec::with_capacity(rec.len() + 8);
            put_varint(&mut c, rec.len() as u64);
            self.payload(&mut c, &rec, true);
            pad(&mut c);
            items.push(c);
        }
        let mut children: Option<Vec<u32>> = None;
        loop {
            let interior = children.is_some();
            let extra = if interior { 4 } else { 0 };
            let make = |i: usize, items: &[Vec<u8>], children: &Option<Vec<u32>>| -> Vec<u8> {
                match children {
                    Some(ch) => {
                        let mut c = ch[i].to_be_bytes().to_vec();
                        c.extend_from_slice(&items[i]);
                        c
                    }
                    None => items[i].clone(),
                }
            };
            let root_cap = self.capacity(0, interior);
            if fits(items.iter().map(|c| c.len() + extra), root_cap) {
                let cs: Vec<Vec<u8>> = (0..items.len()).map(|i| make(i, &items, &children)).collect();
                let right = children.as_ref().map(|ch| ch[ch.len() - 1]);
                let pg = self.alloc();
                self.write_page(pg, if interior { 0x02 } else { 0x0a }, &cs, right);
                return pg;
            }
            // split into runs of items separated by promoted dividers
            let cap = root_cap;
            let mut runs: Vec<(usize, usize)> = Vec::new();
            let mut start = 0;
            let mut used = 0;
            let mut i = 0;
            while i < items.len() {
                let sz = items[i].len() + extra + 2;
                if used + sz > cap && i > start {
                    // item i becomes a divider; keep at least one item after it
                    let mut div = i;
                    if div + 1 >= items.len() {
                        div -= 1;
                    }
                    runs.push((start, div));
                    start = div + 1;
                    used = 0;
                    i = start;
                    continue;
                }
                used += sz;
                i += 1;
            }
            runs.push((start, items.len()));
            let mut next_items = Vec::new();
            let mut next_children = Vec::new();
            for (k, &(a, b)) in runs.iter().enumerate() {
                let cs: Vec<Vec<u8>> = (a..b).map(|i| make(i, &items, &children)).collect();
                let right = children.as_ref().map(|ch| ch[b]);
                let pg = self.alloc();
                self.write_page(pg, if interior { 0x02 } else { 0x0a }, &cs, right);
                next_children.push(pg);
                if k + 1 < runs.len() {
                    next_items.push(items[b].clone());
                }
            }
            items = next_items;
            children = Some(next_children);
        }
    }
}

fn pad(c: &mut Vec<u8>) {
    while c.len() < 4 {
        c.push(0);
    }
}

fn fits(sizes: impl Iterator<Item = usize>, cap: usize) -> bool {
    let mut total = 0;
    for s in sizes {
        total += s + 2;
        if total > cap {
            return false;
        }
    }
    true
}

fn be32(b: &[u8]) -> u32 {
    u32::from_be_bytes(b[..4].try_into().unwrap())
}

/// Serializes `db` as a database file; `old` is the previous file content.
pub fn save(db: &Database, old: Option<&[u8]>, schema_changed: bool) -> Result<Vec<u8>, String> {
    let old = old.filter(|d| d.len() >= 100 && &d[..16] == MAGIC);
    let (page_size, reserved) = match old {
        Some(d) => {
            let ps = u16::from_be_bytes([d[16], d[17]]) as usize;
            (if ps == 1 { 65536 } else { ps }, d[20] as usize)
        }
        None => (DEFAULT_PAGE_SIZE, 0),
    };
    let mut w = Writer { page_size, usable: page_size - reserved, pages: Vec::new() };
    w.alloc(); // page 1

    // schema objects in creation order: (order, type, name, tbl_name, sql, root)
    enum Obj<'a> {
        Table(&'a crate::db::Table),
        Index(&'a crate::db::Table, usize),
        View(&'a crate::db::View),
    }
    let mut objs: Vec<(u64, usize, Obj)> = Vec::new();
    for t in db.tables.values().filter(|t| !t.temp) {
        objs.push((t.order, 0, Obj::Table(t)));
        for (i, idx) in t.indexes.iter().enumerate() {
            objs.push((idx.order, i + 1, Obj::Index(t, i)));
        }
    }
    for v in db.views.values().filter(|v| !v.temp) {
        objs.push((v.order, 0, Obj::View(v)));
    }
    objs.sort_by_key(|o| (o.0, o.1));

    let mut schema_rows = Vec::new();
    for (_, _, obj) in &objs {
        let row = match obj {
            Obj::Table(t) => {
                let mut rows = Vec::with_capacity(t.rows.len());
                for (rowid, r) in &t.rows {
                    let rec = match t.ipk {
                        Some(p) => {
                            let mut vals = r.clone();
                            vals[p] = Value::Null;
                            encode_record(&vals)
                        }
                        None => encode_record(r),
                    };
                    rows.push((*rowid, rec));
                }
                let root = w.table_tree(rows, None);
                vec![text("table"), text(&t.name), text(&t.name), Value::Integer(root as i64), text(&t.sql)]
            }
            Obj::Index(t, i) => {
                let idx = &t.indexes[*i];
                let mut recs = Vec::with_capacity(idx.entries.len());
                for (_, rowid) in &idx.entries {
                    let row = t.rows.get(rowid).ok_or("index out of sync")?;
                    let mut vals = idx.raw_key(row, *rowid)?;
                    vals.push(Value::Integer(*rowid));
                    recs.push(encode_record(&vals));
                }
                let root = w.index_tree(recs);
                let sql = match &idx.def {
                    Some(d) if !idx.auto => text(&d.sql),
                    _ => Value::Null,
                };
                vec![text("index"), text(&idx.name), text(&t.name), Value::Integer(root as i64), sql]
            }
            Obj::View(v) => vec![text("view"), text(&v.name), text(&v.name), Value::Integer(0), text(&v.sql)],
        };
        schema_rows.push(row);
    }
    let rows: Vec<(i64, Vec<u8>)> =
        schema_rows.iter().enumerate().map(|(i, r)| (i as i64 + 1, encode_record(r))).collect();
    w.table_tree(rows, Some(1));

    // file header
    let npages = w.pages.len() as u32;
    let (counter, cookie) = match old {
        Some(d) => (be32(&d[24..]), be32(&d[40..])),
        None => (0, 0),
    };
    let cookie = if schema_changed || old.is_none() { cookie.wrapping_add(1) } else { cookie };
    let counter = counter.wrapping_add(1);
    let h = &mut w.pages[0];
    h[..16].copy_from_slice(MAGIC);
    let ps = if page_size == 65536 { 1u16 } else { page_size as u16 };
    h[16..18].copy_from_slice(&ps.to_be_bytes());
    h[18] = 1;
    h[19] = 1;
    h[20] = reserved as u8;
    h[21] = 64;
    h[22] = 32;
    h[23] = 32;
    h[24..28].copy_from_slice(&counter.to_be_bytes());
    h[28..32].copy_from_slice(&npages.to_be_bytes());
    h[32..40].fill(0);
    h[40..44].copy_from_slice(&cookie.to_be_bytes());
    h[44..48].copy_from_slice(&4u32.to_be_bytes());
    if let Some(d) = old {
        h[48..52].copy_from_slice(&d[48..52]); // default cache size
        h[60..64].copy_from_slice(&d[60..64]); // user version
        h[68..72].copy_from_slice(&d[68..72]); // application id
    }
    h[52..56].fill(0);
    h[56..60].copy_from_slice(&1u32.to_be_bytes());
    h[64..68].fill(0);
    h[92..96].copy_from_slice(&counter.to_be_bytes());
    h[96..100].copy_from_slice(&SQLITE_VERSION.to_be_bytes());
    Ok(w.pages.concat())
}

fn text(s: &str) -> Value {
    Value::Text(s.to_string())
}
