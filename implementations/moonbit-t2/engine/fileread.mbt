// Reading SQLite 3 database files: header, table b-trees, records and
// overflow chains. The schema is rebuilt by re-running each object's CREATE
// statement; indexes are rebuilt from the table rows.

///|
priv struct DbFile {
  data : Bytes
  page_size : Int
  usable : Int
}

///|
fn DbFile::page_off(self : DbFile, pgno : Int) -> Int raise SqlError {
  let off = (pgno - 1) * self.page_size
  if pgno < 1 || off + self.page_size > self.data.length() {
    raise SqlError("database disk image is malformed")
  }
  off
}

///|
fn DbFile::u8(self : DbFile, off : Int) -> Int {
  self.data[off].to_int()
}

///|
fn DbFile::u16(self : DbFile, off : Int) -> Int {
  (self.data[off].to_int() << 8) | self.data[off + 1].to_int()
}

///|
fn DbFile::u32(self : DbFile, off : Int) -> Int {
  (self.data[off].to_int() << 24) |
  (self.data[off + 1].to_int() << 16) |
  (self.data[off + 2].to_int() << 8) |
  self.data[off + 3].to_int()
}

///|
/// Big-endian varint at `off` in `b`: (value, length).
fn read_varint(b : Bytes, off : Int) -> (Int64, Int) {
  let mut v = 0L
  for i in 0..<8 {
    let c = b[off + i].to_int64()
    v = (v << 7) | (c & 0x7FL)
    if (c & 0x80L) == 0L {
      return (v, i + 1)
    }
  }
  v = (v << 8) | b[off + 8].to_int64()
  (v, 9)
}

///|
/// Reads the full payload of a cell whose payload starts at `off`.
fn DbFile::payload(
  self : DbFile,
  off : Int,
  size : Int,
  is_index : Bool,
) -> Bytes raise SqlError {
  let u = self.usable
  let x = if is_index { (u - 12) * 64 / 255 - 23 } else { u - 35 }
  if size <= x {
    return self.data[off:off + size].to_owned()
  }
  let m = (u - 12) * 32 / 255 - 23
  let k = m + (size - m) % (u - 4)
  let nlocal = if k <= x { k } else { m }
  let buf = @buffer.Buffer(size_hint=size)
  buf.write_bytes(self.data[off:off + nlocal])
  let mut remaining = size - nlocal
  let mut next = self.u32(off + nlocal)
  let mut guard_count = 0
  while remaining > 0 && next != 0 {
    let po = self.page_off(next)
    let n = if remaining < u - 4 { remaining } else { u - 4 }
    buf.write_bytes(self.data[po + 4:po + 4 + n])
    remaining -= n
    next = self.u32(po)
    guard_count += 1
    if guard_count > 10000000 {
      raise SqlError("database disk image is malformed")
    }
  }
  buf.to_bytes()
}

///|
/// Visits every (rowid, payload) of the table b-tree rooted at `root`.
fn DbFile::scan_table(
  self : DbFile,
  root : Int,
  f : (Int64, Bytes) -> Unit raise SqlError,
) -> Unit raise SqlError {
  let stack = [root]
  let mut visited = 0
  while stack.pop() is Some(pgno) {
    visited += 1
    if visited > 100000000 {
      raise SqlError("database disk image is malformed")
    }
    let base = self.page_off(pgno)
    let hdr = if pgno == 1 { base + 100 } else { base }
    let kind = self.u8(hdr)
    let ncells = self.u16(hdr + 3)
    match kind {
      0x0d => {
        let ptrs = hdr + 8
        for i in 0..<ncells {
          let cell = base + self.u16(ptrs + 2 * i)
          let (size, n1) = read_varint(self.data, cell)
          let (rowid, n2) = read_varint(self.data, cell + n1)
          f(rowid, self.payload(cell + n1 + n2, size.to_int(), false))
        }
      }
      0x05 => {
        let ptrs = hdr + 12
        // push in reverse so children are visited left to right
        stack.push(self.u32(hdr + 8))
        for i = ncells - 1; i >= 0; i = i - 1 {
          let cell = base + self.u16(ptrs + 2 * i)
          stack.push(self.u32(cell))
        }
      }
      _ => raise SqlError("database disk image is malformed")
    }
  }
}

///|
fn be_int(b : Bytes, off : Int, n : Int) -> Int64 {
  let mut v = if b[off].to_int() >= 128 { -1L } else { 0L }
  for i in 0..<n {
    v = (v << 8) | b[off + i].to_int64()
  }
  v
}

///|
/// Decodes a record into its values.
fn decode_record(b : Bytes) -> Array[Value] raise SqlError {
  if b.length() == 0 {
    return []
  }
  let (hsize, n0) = read_varint(b, 0)
  let hend = hsize.to_int()
  if hend > b.length() {
    raise SqlError("database disk image is malformed")
  }
  let mut hp = n0
  let mut bp = hend
  let out : Array[Value] = []
  while hp < hend {
    let (st64, n) = read_varint(b, hp)
    hp += n
    let st = st64.to_int()
    let v : Value = match st {
      0 => Null
      1 => Int(be_int(b, bp, 1))
      2 => Int(be_int(b, bp, 2))
      3 => Int(be_int(b, bp, 3))
      4 => Int(be_int(b, bp, 4))
      5 => Int(be_int(b, bp, 6))
      6 => Int(be_int(b, bp, 8))
      7 => Real(be_int(b, bp, 8).reinterpret_as_double())
      8 => Int(0L)
      9 => Int(1L)
      _ =>
        if st >= 12 {
          let len = (st - 12) / 2
          if bp + len > b.length() {
            raise SqlError("database disk image is malformed")
          }
          if st % 2 == 0 {
            Blob(b[bp:bp + len].to_owned())
          } else {
            Text(@utf8.decode_lossy(b[bp:bp + len]))
          }
        } else {
          raise SqlError("database disk image is malformed")
        }
    }
    bp += match st {
      1 | 2 | 3 | 4 => st
      5 => 6
      6 | 7 => 8
      _ => if st >= 12 { (st - 12) / 2 } else { 0 }
    }
    out.push(v)
  }
  out
}

///|
fn value_as_string(v : Value) -> String? {
  match v {
    Text(s) => Some(s)
    _ => None
  }
}

///|
/// Loads the database file contents into `self` (which must be empty).
pub fn Database::load_file(
  self : Database,
  data : Bytes,
) -> Unit raise SqlError {
  if data.length() == 0 {
    return
  }
  if data.length() < 100 || data[0:16] != b"SQLite format 3\x00"[:] {
    raise SqlError("file is not a database")
  }
  let ps0 = (data[16].to_int() << 8) | data[17].to_int()
  let page_size = if ps0 == 1 { 65536 } else { ps0 }
  let usable = page_size - data[20].to_int()
  let f : DbFile = { data, page_size, usable, }
  // schema entries: (type, name, tbl_name, rootpage, sql)
  let entries : Array[Array[Value]] = []
  f.scan_table(1, (_, payload) => entries.push(decode_record(payload)))
  self.file_header = Some(data[0:100].to_owned())
  self.file_schema_sig = schema_sig(
    entries.map(e => {
      let r = e.copy()
      while r.length() < 5 {
        r.push(Null)
      }
      r
    }),
  )
  let seqs : Array[(String, Int64)] = []
  for e in entries {
    while e.length() < 5 {
      e.push(Null)
    }
    guard value_as_string(e[0]) is Some(kind) else { continue }
    let name = value_as_string(e[1]).unwrap_or("")
    let root = match e[3] {
      Int(r) => r.to_int()
      _ => 0
    }
    if name.to_lower().has_prefix("sqlite_") {
      if kind == "index" && self.find_index(name) is Some((t, i)) {
        t.indexes[i].rootpage = root
      }
      if kind == "table" && name.to_lower() == "sqlite_sequence" && root > 0 {
        self.sequence_root = root
        f.scan_table(root, (_, payload) => {
          let r = decode_record(payload)
          if r.length() >= 2 && r[0] is Text(n) && r[1] is Int(s) {
            seqs.push((n, s))
          }
        })
      }
      continue
    }
    guard value_as_string(e[4]) is Some(sql) else { continue }
    let st = parse_statement(sql) catch { _ => continue }
    match st {
      CreateTableStmt(ct) => {
        self.create_table(ct) catch {
          _ => continue
        }
        guard self.find_table(ct.name) is Some(t) else { continue }
        t.rootpage = root
        if root > 0 {
          self.load_table_rows(f, t, root)
        }
      }
      CreateIndexStmt(ci) => {
        self.create_index(ci) catch {
          _ => continue
        }
        if self.find_index(ci.name) is Some((t, i)) {
          t.indexes[i].rootpage = root
        }
      }
      CreateViewStmt(cv) => self.create_view(cv) catch { _ => () }
      _ => ()
    }
  }
  for s in seqs {
    if self.find_table(s.0) is Some(t) && t.autoinc {
      t.seq = s.1
    }
  }
}

///|
fn Database::load_table_rows(
  self : Database,
  f : DbFile,
  t : Table,
  root : Int,
) -> Unit raise SqlError {
  ignore(self)
  let ncols = t.columns.length()
  // values for fields missing from older records (ALTER TABLE ADD COLUMN)
  let defaults = t.columns.map(c => {
    match c.def.default {
      Some(d) => apply_affinity(eval_const(d), c.aff) catch { _ => Null }
      None => Null
    }
  })
  f.scan_table(root, (rowid, payload) => {
    let rec = decode_record(payload)
    let vals = Array::make(ncols, Null)
    for i in 0..<ncols {
      if i == t.ipk {
        vals[i] = Int(rowid)
      } else if i < rec.length() {
        vals[i] = match rec[i] {
          Int(n) if t.columns[i].aff == AffReal => Real(n.to_double())
          v => v
        }
      } else {
        vals[i] = defaults[i]
      }
    }
    t.raw_insert(rowid, vals)
  })
}
