///|
/// Read-only access to the pages of an SQLite 3 database file.
priv struct Pager {
  data : Bytes
  page_size : Int
  usable : Int
}

///|
fn Pager::new(data : Bytes) -> Pager raise SqlError {
  if data.length() < 100 || data[0:16] != b"SQLite format 3\x00"[:] {
    raise err("file is not a database")
  }
  let ps = (data[16].to_int() << 8) | data[17].to_int()
  let page_size = if ps == 1 { 65536 } else { ps }
  if page_size < 512 || (page_size & (page_size - 1)) != 0 {
    raise err("file is not a database")
  }
  { data, page_size, usable: page_size - data[20].to_int() }
}

///|
/// Byte offset of page `pgno` (1-based) in the file.
fn Pager::offset(self : Pager, pgno : Int) -> Int raise SqlError {
  let off = (pgno - 1) * self.page_size
  if pgno < 1 || off + self.page_size > self.data.length() {
    raise err("database disk image is malformed")
  }
  off
}

///|
fn Pager::u8(self : Pager, pos : Int) -> Int {
  self.data[pos].to_int()
}

///|
fn Pager::u16(self : Pager, pos : Int) -> Int {
  (self.data[pos].to_int() << 8) | self.data[pos + 1].to_int()
}

///|
fn Pager::u32(self : Pager, pos : Int) -> Int {
  (self.data[pos].to_int() << 24) |
  (self.data[pos + 1].to_int() << 16) |
  (self.data[pos + 2].to_int() << 8) |
  self.data[pos + 3].to_int()
}

///|
/// Decodes a varint at `pos`; returns (value, bytes used).
fn read_varint(data : BytesView, pos : Int) -> (Int64, Int) {
  let mut v = 0L
  for i in 0..<8 {
    let b = data[pos + i].to_int64()
    v = (v << 7) | (b & 0x7FL)
    if b < 0x80L {
      return (v, i + 1)
    }
  }
  v = (v << 8) | data[pos + 8].to_int64()
  (v, 9)
}

///|
/// Assembles a cell payload of `total` bytes whose first `nlocal` bytes are
/// at `pos`, followed by an overflow page chain.
fn Pager::payload(
  self : Pager,
  pos : Int,
  total : Int,
  nlocal : Int,
) -> Bytes raise SqlError {
  if nlocal >= total {
    return self.data[pos:pos + total].to_owned()
  }
  let buf = @buffer.Buffer(size_hint=total)
  buf.write_bytes(self.data[pos:pos + nlocal])
  let mut next = self.u32(pos + nlocal)
  let mut remaining = total - nlocal
  let per_page = self.usable - 4
  while remaining > 0 {
    if next == 0 {
      raise err("database disk image is malformed")
    }
    let off = self.offset(next)
    let n = if remaining < per_page { remaining } else { per_page }
    buf.write_bytes(self.data[off + 4:off + 4 + n])
    remaining -= n
    next = self.u32(off)
  }
  buf.to_bytes()
}

///|
/// Number of payload bytes stored on the b-tree page itself.
fn local_payload(usable : Int, total : Int, max_local : Int) -> Int {
  if total <= max_local {
    return total
  }
  let m = (usable - 12) * 32 / 255 - 23
  let k = m + (total - m) % (usable - 4)
  if k <= max_local {
    k
  } else {
    m
  }
}

///|
/// Visits every (rowid, record) of the table b-tree rooted at `root`, in
/// rowid order.
fn Pager::scan_table(
  self : Pager,
  root : Int,
  f : (Int64, Bytes) -> Unit raise SqlError,
) -> Unit raise SqlError {
  let stack = [root]
  let visited : Set[Int] = Set([])
  // Depth-first, left to right: children are pushed in reverse order.
  while stack.pop() is Some(pgno) {
    if !visited.add_and_check(pgno) {
      raise err("database disk image is malformed")
    }
    let base = self.offset(pgno)
    let hdr = if pgno == 1 { base + 100 } else { base }
    let kind = self.u8(hdr)
    let ncells = self.u16(hdr + 3)
    match kind {
      0x0d => {
        let ptrs = hdr + 8
        for i in 0..<ncells {
          let cell = base + self.u16(ptrs + 2 * i)
          let (size, n1) = read_varint(self.data[:], cell)
          let (rowid, n2) = read_varint(self.data[:], cell + n1)
          let total = size.to_int()
          let nlocal = local_payload(self.usable, total, self.usable - 35)
          f(rowid, self.payload(cell + n1 + n2, total, nlocal))
        }
      }
      0x05 => {
        let ptrs = hdr + 12
        stack.push(self.u32(hdr + 8))
        for i = ncells - 1; i >= 0; i = i - 1 {
          let cell = base + self.u16(ptrs + 2 * i)
          stack.push(self.u32(cell))
        }
      }
      _ => raise err("database disk image is malformed")
    }
  }
}

///|
/// Decodes a record into its values.
fn decode_record(rec : Bytes) -> Array[Value] raise SqlError {
  let view = rec[:]
  if view.length() == 0 {
    return []
  }
  let (hsize, n) = read_varint(view, 0)
  let hend = hsize.to_int()
  if hend > view.length() {
    raise err("database disk image is malformed")
  }
  let types = []
  let mut p = n
  while p < hend {
    let (t, k) = read_varint(view, p)
    types.push(t)
    p += k
  }
  let out = []
  let mut body = hend
  for t in types {
    let len = match t {
      0L | 8L | 9L => 0
      1L => 1
      2L => 2
      3L => 3
      4L => 4
      5L => 6
      6L | 7L => 8
      _ =>
        if t >= 12L {
          ((t - 12L) / 2L).to_int()
        } else {
          0
        }
    }
    if body + len > view.length() {
      raise err("database disk image is malformed")
    }
    let v = match t {
      0L => Null
      8L => Int(0L)
      9L => Int(1L)
      1L | 2L | 3L | 4L | 5L | 6L => {
        let mut x = if view[body].to_int() >= 0x80 { -1L } else { 0L }
        for i in 0..<len {
          x = (x << 8) | view[body + i].to_int64()
        }
        Int(x)
      }
      7L => {
        let mut x = 0L
        for i in 0..<8 {
          x = (x << 8) | view[body + i].to_int64()
        }
        let d = x.reinterpret_as_double()
        if d.is_nan() {
          Null
        } else {
          Real(d)
        }
      }
      _ =>
        if t >= 12L && t % 2L == 0L {
          Blob(view[body:body + len].to_owned())
        } else if t >= 13L {
          Text(@utf8.decode_lossy(view[body:body + len]))
        } else {
          Null
        }
    }
    out.push(v)
    body += len
  }
  out
}

///|
/// Loads the SQLite database image `data` into this (empty) database.
pub fn Database::load_file(self : Database, data : Bytes) -> Unit raise SqlError {
  if data.length() == 0 {
    return
  }
  let pager = Pager::new(data)
  if data[56:60] != b"\x00\x00\x00\x00"[:] &&
    data[56:60] != b"\x00\x00\x00\x01"[:] {
    raise err("unsupported text encoding")
  }
  let entries = []
  pager.scan_table(1, (_, rec) => entries.push(decode_record(rec)))
  let loads : Array[(Table, Int)] = []
  let mut seq_root = 0
  for e in entries {
    let field = (i : Int) => if i < e.length() { e[i] } else { Null }
    let kind = match field(0) {
      Text(s) => s
      _ => ""
    }
    let name = match field(1) {
      Text(s) => s
      _ => ""
    }
    let root = match field(3) {
      Int(r) => r.to_int()
      _ => 0
    }
    guard field(4) is Text(sql) else { continue }
    if kind == "table" && fold_name(name) == "sqlite_sequence" {
      if self.sequence_seq == 0 {
        self.sequence_seq = self.next_seq()
      }
      seq_root = root
      continue
    }
    if kind != "table" && kind != "index" && kind != "view" {
      continue
    }
    ignore(self.execute(sql)) catch {
      _ => continue
    }
    if kind == "table" && self.find_table(name) is Some(t) && root > 0 {
      loads.push((t, root))
    }
  }
  for load in loads {
    let (t, root) = load
    let ncols = t.columns.length()
    let missing : Array[Value?] = Array::make(ncols, None)
    pager.scan_table(root, (rowid, rec) => {
      let vals = decode_record(rec)
      let row = Array::make(ncols, Null)
      for i in 0..<ncols {
        if i < vals.length() {
          row[i] = match (vals[i], t.columns[i].affinity) {
            (Int(x), AffReal) => Real(x.to_double())
            (v, _) => v
          }
        } else {
          row[i] = match missing[i] {
            Some(v) => v
            None => {
              let v = match t.defaults[i] {
                Some(d) => eval(d, []).apply_affinity(t.columns[i].affinity)
                None => Null
              }
              missing[i] = Some(v)
              v
            }
          }
        }
      }
      if t.ipk >= 0 {
        row[t.ipk] = Int(rowid)
      }
      t.raw_put(rowid, row)
    })
  }
  if seq_root > 0 {
    pager.scan_table(seq_root, (_, rec) => {
      let vals = decode_record(rec)
      if vals.length() >= 2 &&
        vals[0] is Text(n) &&
        vals[1] is Int(s) &&
        self.find_table(n) is Some(t) {
        t.seq = s
      }
    })
  }
}
