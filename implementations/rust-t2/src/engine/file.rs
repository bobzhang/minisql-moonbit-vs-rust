// Reading the SQLite 3 database file format: header, table b-trees,
// records and overflow chains.

use crate::value::Value;

pub struct FileReader<'a> {
    data: &'a [u8],
    page_size: usize,
    usable: usize,
    page_count: usize,
}

/// A read varint and its length in bytes.
pub fn read_varint(b: &[u8]) -> (u64, usize) {
    let mut v: u64 = 0;
    for i in 0..9 {
        let Some(&x) = b.get(i) else {
            return (v, i.max(1));
        };
        if i == 8 {
            return ((v << 8) | x as u64, 9);
        }
        v = (v << 7) | (x & 0x7f) as u64;
        if x & 0x80 == 0 {
            return (v, i + 1);
        }
    }
    (v, 9)
}

fn be(b: &[u8]) -> u64 {
    b.iter().fold(0u64, |acc, &x| (acc << 8) | x as u64)
}

impl<'a> FileReader<'a> {
    pub fn new(data: &'a [u8]) -> Result<Self, String> {
        if data.len() < 100 || &data[..16] != b"SQLite format 3\0" {
            return Err("file is not a database".into());
        }
        let ps = u16::from_be_bytes([data[16], data[17]]) as usize;
        let page_size = if ps == 1 { 65536 } else { ps };
        if !(512..=65536).contains(&page_size) || !page_size.is_power_of_two() {
            return Err("file is not a database".into());
        }
        let reserved = data[20] as usize;
        let enc = be(&data[56..60]);
        if enc > 1 {
            return Err("unsupported text encoding".into());
        }
        let page_count = data.len() / page_size;
        Ok(FileReader {
            data,
            page_size,
            usable: page_size - reserved,
            page_count,
        })
    }

    #[allow(dead_code)]
    pub fn page_size(&self) -> usize {
        self.page_size
    }

    fn page(&self, n: u64) -> Result<&'a [u8], String> {
        if n == 0 || n as usize > self.page_count {
            return Err("database disk image is malformed".into());
        }
        let start = (n as usize - 1) * self.page_size;
        Ok(&self.data[start..start + self.page_size])
    }

    /// Payload of a cell whose declared size is `total`, starting at `off`
    /// in `page`, following overflow pages when needed.
    fn payload(
        &self,
        page: &[u8],
        off: usize,
        total: usize,
        max_local: usize,
        min_local: usize,
    ) -> Result<Vec<u8>, String> {
        let u = self.usable;
        let local = if total <= max_local {
            total
        } else {
            let k = min_local + (total - min_local) % (u - 4);
            if k <= max_local {
                k
            } else {
                min_local
            }
        };
        let bad = || "database disk image is malformed".to_string();
        let mut out = Vec::with_capacity(total);
        out.extend_from_slice(page.get(off..off + local).ok_or_else(bad)?);
        if local < total {
            let mut next = be(page.get(off + local..off + local + 4).ok_or_else(bad)?);
            let mut guard = 0;
            while out.len() < total {
                guard += 1;
                if next == 0 || guard > self.page_count {
                    return Err(bad());
                }
                let p = self.page(next)?;
                let n = (total - out.len()).min(u - 4);
                out.extend_from_slice(&p[4..4 + n]);
                next = be(&p[0..4]);
            }
        }
        Ok(out)
    }

    /// All (rowid, record payload) entries of the table b-tree rooted at
    /// `root`, in rowid order.
    pub fn table_entries(&self, root: u64) -> Result<Vec<(i64, Vec<u8>)>, String> {
        let mut out = Vec::new();
        let mut visited = 0usize;
        self.walk_table(root, &mut out, &mut visited, 0)?;
        Ok(out)
    }

    fn walk_table(
        &self,
        pgno: u64,
        out: &mut Vec<(i64, Vec<u8>)>,
        visited: &mut usize,
        depth: usize,
    ) -> Result<(), String> {
        let bad = || "database disk image is malformed".to_string();
        *visited += 1;
        if *visited > self.page_count || depth > 64 {
            return Err(bad());
        }
        let page = self.page(pgno)?;
        let h = if pgno == 1 { 100 } else { 0 };
        let kind = page[h];
        let ncells = u16::from_be_bytes([page[h + 3], page[h + 4]]) as usize;
        let hdr_len = if kind == 0x05 { 12 } else { 8 };
        let ptrs = h + hdr_len;
        let cell_at = |i: usize| -> Result<usize, String> {
            let p = page.get(ptrs + 2 * i..ptrs + 2 * i + 2).ok_or_else(bad)?;
            Ok(u16::from_be_bytes([p[0], p[1]]) as usize)
        };
        match kind {
            0x0d => {
                let max_local = self.usable - 35;
                let min_local = (self.usable - 12) * 32 / 255 - 23;
                for i in 0..ncells {
                    let mut off = cell_at(i)?;
                    let (size, n) = read_varint(page.get(off..).ok_or_else(bad)?);
                    off += n;
                    let (rowid, n) = read_varint(page.get(off..).ok_or_else(bad)?);
                    off += n;
                    let payload = self.payload(page, off, size as usize, max_local, min_local)?;
                    out.push((rowid as i64, payload));
                }
                Ok(())
            }
            0x05 => {
                for i in 0..ncells {
                    let off = cell_at(i)?;
                    let child = be(page.get(off..off + 4).ok_or_else(bad)?);
                    self.walk_table(child, out, visited, depth + 1)?;
                }
                let right = be(&page[h + 8..h + 12]);
                self.walk_table(right, out, visited, depth + 1)
            }
            _ => Err(bad()),
        }
    }
}

/// Decode a record into its values.
pub fn decode_record(rec: &[u8]) -> Result<Vec<Value>, String> {
    let bad = || "database disk image is malformed".to_string();
    let (hsize, n) = read_varint(rec);
    let hsize = hsize as usize;
    if hsize > rec.len() || hsize < n {
        return Err(bad());
    }
    let mut types = Vec::new();
    let mut p = n;
    while p < hsize {
        let (t, n) = read_varint(&rec[p..hsize]);
        types.push(t);
        p += n;
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
        let b = rec.get(body..body + len).ok_or_else(bad)?;
        body += len;
        let v = match t {
            0 | 10 | 11 => Value::Null,
            1..=6 => {
                let u = be(b);
                let shift = 64 - 8 * len as u32;
                Value::Integer(((u << shift) as i64) >> shift)
            }
            7 => {
                let f = f64::from_bits(be(b));
                if f.is_nan() {
                    Value::Null
                } else {
                    Value::Real(f)
                }
            }
            8 => Value::Integer(0),
            9 => Value::Integer(1),
            _ if t % 2 == 0 => Value::Blob(b.to_vec()),
            _ => Value::Text(String::from_utf8_lossy(b).into_owned()),
        };
        vals.push(v);
    }
    Ok(vals)
}
