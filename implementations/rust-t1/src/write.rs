// Writing the in-memory database as a SQLite 3 database file.
//
// The whole file is rebuilt from the committed state: every table and index
// b-tree is packed bottom-up, and the schema table is rooted at page 1.

use crate::db::{Database, IdxColKind};
use crate::value::Value;

fn put_varint(out: &mut Vec<u8>, v: u64) {
    if v >> 56 != 0 {
        let mut buf = [0u8; 9];
        buf[8] = v as u8;
        let mut x = v >> 8;
        for i in (0..8).rev() {
            buf[i] = (x as u8 & 0x7f) | 0x80;
            x >>= 7;
        }
        out.extend_from_slice(&buf);
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

fn varint_len(v: u64) -> usize {
    if v >> 56 != 0 {
        return 9;
    }
    let mut n = 1;
    let mut x = v >> 7;
    while x != 0 {
        n += 1;
        x >>= 7;
    }
    n
}

/// Serial type and body length of an integer.
fn int_type(i: i64) -> (u64, usize) {
    match i {
        0 => (8, 0),
        1 => (9, 0),
        -128..=127 => (1, 1),
        -32768..=32767 => (2, 2),
        -8388608..=8388607 => (3, 3),
        -2147483648..=2147483647 => (4, 4),
        -140737488355328..=140737488355327 => (5, 6),
        _ => (6, 8),
    }
}

/// Encode values in the record format.
pub fn encode_record(vals: &[Value]) -> Vec<u8> {
    let mut hdr = Vec::new();
    let mut body = Vec::new();
    for v in vals {
        match v {
            Value::Null => put_varint(&mut hdr, 0),
            Value::Int(i) => {
                let (t, n) = int_type(*i);
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
    let mut n = 1;
    while varint_len((hdr.len() + n) as u64) > n {
        n += 1;
    }
    let mut out = Vec::with_capacity(hdr.len() + n + body.len());
    put_varint(&mut out, (hdr.len() + n) as u64);
    out.extend_from_slice(&hdr);
    out.extend_from_slice(&body);
    out
}

const LEAF_TABLE: u8 = 0x0d;
const INTERIOR_TABLE: u8 = 0x05;
const LEAF_INDEX: u8 = 0x0a;
const INTERIOR_INDEX: u8 = 0x02;

/// Space a cell takes on a page, including its pointer.
fn cost(cell_len: usize) -> usize {
    cell_len.max(4) + 2
}

struct Builder {
    ps: usize,
    pages: Vec<Vec<u8>>,
}

impl Builder {
    fn alloc(&mut self) -> u32 {
        self.pages.push(vec![0; self.ps]);
        self.pages.len() as u32
    }

    /// Append the local part of `payload` (and the first overflow page
    /// number, allocating the overflow chain) to `out`.
    fn spill(&mut self, payload: &[u8], max_local: usize, out: &mut Vec<u8>) {
        let u = self.ps;
        let p = payload.len();
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
        out.extend_from_slice(&payload[..local]);
        if local < p {
            let chunks: Vec<&[u8]> = payload[local..].chunks(u - 4).collect();
            let pgnos: Vec<u32> = chunks.iter().map(|_| self.alloc()).collect();
            for (i, c) in chunks.iter().enumerate() {
                let next = pgnos.get(i + 1).copied().unwrap_or(0);
                let pg = &mut self.pages[pgnos[i] as usize - 1];
                pg[..4].copy_from_slice(&next.to_be_bytes());
                pg[4..4 + c.len()].copy_from_slice(c);
            }
            out.extend_from_slice(&pgnos[0].to_be_bytes());
        }
    }

    /// Usable cell space of a b-tree page.
    fn cap(&self, page1: bool, interior: bool) -> usize {
        self.ps - if page1 { 100 } else { 0 } - if interior { 12 } else { 8 }
    }

    fn write_page(&mut self, pgno: u32, kind: u8, cells: &[&[u8]], right: Option<u32>) {
        let ps = self.ps;
        let h = if pgno == 1 { 100 } else { 0 };
        let pg = &mut self.pages[pgno as usize - 1];
        let hdr = if right.is_some() { 12 } else { 8 };
        let mut content = ps;
        let mut ptr = h + hdr;
        for c in cells {
            content -= c.len().max(4);
            pg[content..content + c.len()].copy_from_slice(c);
            pg[ptr..ptr + 2].copy_from_slice(&(content as u16).to_be_bytes());
            ptr += 2;
        }
        debug_assert!(ptr <= content);
        pg[h] = kind;
        pg[h + 1] = 0;
        pg[h + 2] = 0;
        pg[h + 3..h + 5].copy_from_slice(&(cells.len() as u16).to_be_bytes());
        pg[h + 5..h + 7].copy_from_slice(&((content % 65536) as u16).to_be_bytes());
        pg[h + 7] = 0;
        if let Some(r) = right {
            pg[h + 8..h + 12].copy_from_slice(&r.to_be_bytes());
        }
    }

    fn page_for(&mut self, page1: bool) -> u32 {
        if page1 {
            1
        } else {
            self.alloc()
        }
    }

    /// Build a table b-tree from (rowid, record) pairs in rowid order;
    /// returns the root page.
    fn table_tree(&mut self, rows: Vec<(i64, Vec<u8>)>, page1: bool) -> u32 {
        let max_local = self.ps - 35;
        let mut cells: Vec<(i64, Vec<u8>)> = Vec::with_capacity(rows.len());
        for (rowid, payload) in rows {
            let mut c = Vec::with_capacity(payload.len().min(max_local) + 13);
            put_varint(&mut c, payload.len() as u64);
            put_varint(&mut c, rowid as u64);
            self.spill(&payload, max_local, &mut c);
            cells.push((rowid, c));
        }
        let total: usize = cells.iter().map(|c| cost(c.1.len())).sum();
        if total <= self.cap(page1, false) {
            let pg = self.page_for(page1);
            let refs: Vec<&[u8]> = cells.iter().map(|c| c.1.as_slice()).collect();
            self.write_page(pg, LEAF_TABLE, &refs, None);
            return pg;
        }
        let cap = if page1 && total <= self.cap(false, false) { self.cap(true, false) } else { self.cap(false, false) };
        let groups = pack(&cells.iter().map(|c| cost(c.1.len())).collect::<Vec<_>>(), cap);
        // (page, largest rowid) of each child.
        let mut level: Vec<(u32, i64)> = Vec::new();
        for g in groups {
            let pg = self.alloc();
            let refs: Vec<&[u8]> = cells[g.clone()].iter().map(|c| c.1.as_slice()).collect();
            self.write_page(pg, LEAF_TABLE, &refs, None);
            level.push((pg, cells[g.end - 1].0));
        }
        loop {
            let cell_of = |c: &(u32, i64)| {
                let mut v = c.0.to_be_bytes().to_vec();
                put_varint(&mut v, c.1 as u64);
                v
            };
            let cells: Vec<Vec<u8>> = level.iter().map(cell_of).collect();
            let n = level.len();
            let total: usize = cells[..n - 1].iter().map(|c| cost(c.len())).sum();
            if total <= self.cap(page1, true) {
                let pg = self.page_for(page1);
                let refs: Vec<&[u8]> = cells[..n - 1].iter().map(|c| c.as_slice()).collect();
                self.write_page(pg, INTERIOR_TABLE, &refs, Some(level[n - 1].0));
                return pg;
            }
            let cap = if page1 && total <= self.cap(false, true) { self.cap(true, true) } else { self.cap(false, true) };
            // Each node takes a run of children; all but the last become cells.
            let costs: Vec<usize> = cells.iter().map(|c| cost(c.len())).collect();
            let groups = pack_children(&costs, cap);
            let mut next = Vec::new();
            for g in groups {
                let pg = self.alloc();
                let refs: Vec<&[u8]> = cells[g.start..g.end - 1].iter().map(|c| c.as_slice()).collect();
                self.write_page(pg, INTERIOR_TABLE, &refs, Some(level[g.end - 1].0));
                next.push((pg, level[g.end - 1].1));
            }
            level = next;
        }
    }

    /// Build an index b-tree from records in index order; returns the root.
    fn index_tree(&mut self, keys: Vec<Vec<u8>>) -> u32 {
        let max_local = ((self.ps - 12) * 64 / 255) - 23;
        let mut bodies: Vec<Vec<u8>> = Vec::with_capacity(keys.len());
        for payload in keys {
            let mut c = Vec::with_capacity(payload.len().min(max_local) + 13);
            put_varint(&mut c, payload.len() as u64);
            self.spill(&payload, max_local, &mut c);
            bodies.push(c);
        }
        let total: usize = bodies.iter().map(|c| cost(c.len())).sum();
        if total <= self.cap(false, false) {
            let pg = self.alloc();
            let refs: Vec<&[u8]> = bodies.iter().map(|c| c.as_slice()).collect();
            self.write_page(pg, LEAF_INDEX, &refs, None);
            return pg;
        }
        // Leaves separated by divider entries.
        let cap = self.cap(false, false);
        let mut groups: Vec<Vec<Vec<u8>>> = vec![Vec::new()];
        let mut dividers: Vec<Vec<u8>> = Vec::new();
        let mut used = 0;
        for b in bodies {
            let c = cost(b.len());
            let cur = groups.last_mut().unwrap();
            if !cur.is_empty() && used + c > cap {
                dividers.push(b);
                groups.push(Vec::new());
                used = 0;
            } else {
                used += c;
                cur.push(b);
            }
        }
        if groups.last().unwrap().is_empty() {
            groups.pop();
            let d = dividers.pop().unwrap();
            let e = groups.last_mut().unwrap().pop().unwrap();
            dividers.push(e);
            groups.push(vec![d]);
        }
        let mut children: Vec<u32> = Vec::new();
        for g in &groups {
            let pg = self.alloc();
            let refs: Vec<&[u8]> = g.iter().map(|c| c.as_slice()).collect();
            self.write_page(pg, LEAF_INDEX, &refs, None);
            children.push(pg);
        }
        loop {
            let cell = |child: u32, body: &[u8]| {
                let mut v = child.to_be_bytes().to_vec();
                v.extend_from_slice(body);
                v
            };
            let total: usize = dividers.iter().map(|d| cost(d.len() + 4)).sum();
            if total <= self.cap(false, true) {
                let pg = self.alloc();
                let cells: Vec<Vec<u8>> = dividers.iter().zip(&children).map(|(d, c)| cell(*c, d)).collect();
                let refs: Vec<&[u8]> = cells.iter().map(|c| c.as_slice()).collect();
                self.write_page(pg, INTERIOR_INDEX, &refs, Some(*children.last().unwrap()));
                return pg;
            }
            let cap = self.cap(false, true);
            // Nodes: (cells as (child, divider)), right child.
            let mut nodes: Vec<(Vec<(u32, Vec<u8>)>, u32)> = Vec::new();
            let mut up: Vec<Vec<u8>> = Vec::new();
            let mut cur: Vec<(u32, Vec<u8>)> = Vec::new();
            let mut used = 0;
            let n = children.len();
            let mut divs = std::mem::take(&mut dividers).into_iter();
            for (i, &child) in children.iter().enumerate() {
                if i + 1 == n {
                    nodes.push((std::mem::take(&mut cur), child));
                    break;
                }
                let d = divs.next().unwrap();
                let c = cost(d.len() + 4);
                if !cur.is_empty() && used + c > cap {
                    nodes.push((std::mem::take(&mut cur), child));
                    up.push(d);
                    used = 0;
                } else {
                    used += c;
                    cur.push((child, d));
                }
            }
            if nodes.last().unwrap().0.is_empty() {
                let (_, last_right) = nodes.pop().unwrap();
                let (mut cells, right) = nodes.pop().unwrap();
                let d_up = up.pop().unwrap();
                let (c_a, d_a) = cells.pop().unwrap();
                nodes.push((cells, c_a));
                up.push(d_a);
                nodes.push((vec![(right, d_up)], last_right));
            }
            let mut next = Vec::new();
            for (cells, right) in nodes {
                let pg = self.alloc();
                let cs: Vec<Vec<u8>> = cells.iter().map(|(c, d)| cell(*c, d)).collect();
                let refs: Vec<&[u8]> = cs.iter().map(|c| c.as_slice()).collect();
                self.write_page(pg, INTERIOR_INDEX, &refs, Some(right));
                next.push(pg);
            }
            children = next;
            dividers = up;
        }
    }
}

/// Split items into consecutive non-empty runs whose costs fit `cap`.
fn pack(costs: &[usize], cap: usize) -> Vec<std::ops::Range<usize>> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut used = 0;
    for (i, &c) in costs.iter().enumerate() {
        if i > start && used + c > cap {
            out.push(start..i);
            start = i;
            used = 0;
        }
        used += c;
    }
    out.push(start..costs.len());
    out
}

/// Split children into runs of at least two where the costs of all but
/// the last child of each run fit `cap`.
fn pack_children(costs: &[usize], cap: usize) -> Vec<std::ops::Range<usize>> {
    let mut out: Vec<std::ops::Range<usize>> = Vec::new();
    let mut start = 0;
    let mut used = 0;
    for (i, &c) in costs.iter().enumerate() {
        // Child i joins the run; the previous child becomes a cell.
        if i > start {
            let prev = costs[i - 1];
            if used + prev > cap {
                out.push(start..i);
                start = i;
                used = 0;
                continue;
            }
            used += prev;
        }
        let _ = c;
    }
    out.push(start..costs.len());
    let k = out.len();
    if k >= 2 && out[k - 1].len() == 1 {
        out[k - 2].end -= 1;
        out[k - 1].start -= 1;
    }
    out
}

fn be32(h: &[u8], off: usize) -> u32 {
    u32::from_be_bytes([h[off], h[off + 1], h[off + 2], h[off + 3]])
}

/// Serialize `db` as a database file. `old_header` is the header of the
/// file it was loaded from, if any.
pub fn build_file(db: &Database, page_size: usize, old_header: Option<&[u8]>, schema_changed: bool) -> Vec<u8> {
    let mut b = Builder { ps: page_size, pages: vec![vec![0; page_size]] };
    let text = |s: &str| Value::Text(s.to_string());

    // Schema entries: (rowid, record values).
    let mut schema: Vec<(i64, Vec<Value>)> = Vec::new();
    let mut objs: Vec<(u64, u8, String)> = Vec::new();
    for (k, t) in &db.tables {
        objs.push((t.schema_seq, 0, k.clone()));
        for (i, ix) in t.indexes.iter().enumerate() {
            objs.push((ix.seq, 1, format!("{}\0{}", k, i)));
        }
    }
    if let Some(s) = db.sequence_seq {
        objs.push((s, 2, String::new()));
    }
    for (k, v) in &db.views {
        objs.push((v.schema_seq, 3, k.clone()));
    }
    objs.sort();
    for (seq, kind, k) in objs {
        let rec = match kind {
            0 => {
                let t = &db.tables[&k];
                let rows: Vec<(i64, Vec<u8>)> = t
                    .rows
                    .iter()
                    .map(|(rowid, row)| {
                        let rec = match t.rowid_alias {
                            Some(a) => {
                                let mut r = row.clone();
                                r[a] = Value::Null;
                                encode_record(&r)
                            }
                            None => encode_record(row),
                        };
                        (*rowid, rec)
                    })
                    .collect();
                let root = b.table_tree(rows, false);
                vec![text("table"), text(&t.name), text(&t.name), Value::Int(root as i64), text(&t.sql)]
            }
            1 => {
                let (tk, i) = k.split_once('\0').unwrap();
                let t = &db.tables[tk];
                let ix = &t.indexes[i.parse::<usize>().unwrap()];
                let mut keys = Vec::with_capacity(ix.entries.len());
                for e in &ix.entries {
                    let Some(Value::Int(rowid)) = e.0.last() else { continue };
                    let Some(row) = t.rows.get(rowid) else { continue };
                    let Some(mut vals) = ix.raw_values_of(row, *rowid) else { continue };
                    for (v, c) in vals.iter_mut().zip(&ix.cols) {
                        if let (IdxColKind::Expr { .. }, Some(a)) = (&c.kind, c.aff) {
                            *v = std::mem::replace(v, Value::Null).apply_affinity(a);
                        }
                    }
                    vals.push(Value::Int(*rowid));
                    keys.push(encode_record(&vals));
                }
                let root = b.index_tree(keys);
                let sql = match &ix.sql {
                    Some(s) if !ix.auto => text(s),
                    _ => Value::Null,
                };
                vec![text("index"), text(&ix.name), text(&t.name), Value::Int(root as i64), sql]
            }
            2 => {
                let rows: Vec<(i64, Vec<u8>)> =
                    db.sequence_rows().iter().enumerate().map(|(i, r)| (i as i64 + 1, encode_record(r))).collect();
                let root = b.table_tree(rows, false);
                vec![
                    text("table"),
                    text("sqlite_sequence"),
                    text("sqlite_sequence"),
                    Value::Int(root as i64),
                    text("CREATE TABLE sqlite_sequence(name,seq)"),
                ]
            }
            _ => {
                let v = &db.views[&k];
                vec![text("view"), text(&v.name), text(&v.name), Value::Int(0), text(&v.sql)]
            }
        };
        schema.push((seq as i64, rec));
    }
    let rows: Vec<(i64, Vec<u8>)> = schema.iter().map(|(r, v)| (*r, encode_record(v))).collect();
    b.table_tree(rows, true);

    // File header.
    let npages = b.pages.len() as u32;
    let old = |off: usize| old_header.map(|h| be32(h, off)).unwrap_or(0);
    let counter = old(24).wrapping_add(1);
    let cookie = if schema_changed { old(40).wrapping_add(1) } else { old(40) };
    let h = &mut b.pages[0][..100];
    h[..16].copy_from_slice(b"SQLite format 3\0");
    let ps = if page_size == 65536 { 1u16 } else { page_size as u16 };
    h[16..18].copy_from_slice(&ps.to_be_bytes());
    h[18] = 1;
    h[19] = 1;
    h[20] = 0;
    h[21] = 64;
    h[22] = 32;
    h[23] = 32;
    let put = |h: &mut [u8], off: usize, v: u32| h[off..off + 4].copy_from_slice(&v.to_be_bytes());
    put(h, 24, counter);
    put(h, 28, npages);
    put(h, 32, 0);
    put(h, 36, 0);
    put(h, 40, cookie);
    put(h, 44, 4);
    put(h, 48, old(48));
    put(h, 52, 0);
    put(h, 56, 1);
    put(h, 60, old(60));
    put(h, 64, 0);
    put(h, 68, old(68));
    put(h, 92, counter);
    put(h, 96, 3053000);
    b.pages.concat()
}
