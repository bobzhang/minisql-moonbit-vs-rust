// Reading SQLite 3 database files into the in-memory database.

///|
priv struct Pager {
  data : Bytes
  page_size : Int
  usable : Int
}

///|
fn Pager::page_off(self : Pager, pgno : Int) -> Int raise SqlError {
  let off = (pgno - 1) * self.page_size
  if pgno < 1 || off + self.page_size > self.data.length() {
    raise sql_err("database disk image is malformed")
  }
  off
}

///|
fn Pager::u8(self : Pager, off : Int) -> Int {
  self.data[off].to_int()
}

///|
fn Pager::u16(self : Pager, off : Int) -> Int {
  (self.data[off].to_int() << 8) | self.data[off + 1].to_int()
}

///|
fn Pager::u32(self : Pager, off : Int) -> Int {
  (self.data[off].to_int() << 24) |
  (self.data[off + 1].to_int() << 16) |
  (self.data[off + 2].to_int() << 8) |
  self.data[off + 3].to_int()
}

///|
/// Big-endian varint at `off`: (value, length).
fn read_varint(data : Bytes, off : Int) -> (Int64, Int) {
  let mut v = 0L
  for i in 0..<8 {
    let b = data[off + i].to_int64()
    v = (v << 7) | (b & 0x7FL)
    if b < 0x80L {
      return (v, i + 1)
    }
  }
  v = (v << 8) | data[off + 8].to_int64()
  (v, 9)
}

///|
/// Full payload of a cell whose payload (of `total` bytes) starts at `off`.
fn Pager::payload(
  self : Pager,
  off : Int,
  total : Int,
  is_table : Bool,
) -> Bytes raise SqlError {
  let u = self.usable
  let x = if is_table { u - 35 } else { (u - 12) * 64 / 255 - 23 }
  if total <= x {
    return self.data[off:off + total].to_owned()
  }
  let m = (u - 12) * 32 / 255 - 23
  let k = m + (total - m) % (u - 4)
  let local = if k <= x { k } else { m }
  let buf = @buffer.Buffer(size_hint=total)
  buf.write_bytes(self.data[off:off + local])
  let mut next = self.u32(off + local)
  let mut remaining = total - local
  while remaining > 0 && next != 0 {
    let po = self.page_off(next)
    let n = if remaining < u - 4 { remaining } else { u - 4 }
    buf.write_bytes(self.data[po + 4:po + 4 + n])
    remaining -= n
    next = self.u32(po)
  }
  buf.to_bytes()
}

///|
/// Visit every (rowid, payload) of the table b-tree rooted at `root`.
fn Pager::scan_table(
  self : Pager,
  root : Int,
  f : (Int64, Bytes) -> Unit raise SqlError,
) -> Unit raise SqlError {
  let stack = [root]
  let mut guard_count = 0
  while stack.pop() is Some(pgno) {
    guard_count += 1
    if guard_count > self.data.length() / 512 + 10 {
      raise sql_err("database disk image is malformed")
    }
    let base = self.page_off(pgno)
    let hdr = if pgno == 1 { base + 100 } else { base }
    let kind = self.u8(hdr)
    let ncells = self.u16(hdr + 3)
    match kind {
      0x0d => {
        let ptrs = hdr + 8
        for i in 0..<ncells {
          let c = base + self.u16(ptrs + 2 * i)
          let (plen, n1) = read_varint(self.data, c)
          let (rowid, n2) = read_varint(self.data, c + n1)
          f(rowid, self.payload(c + n1 + n2, plen.to_int(), true))
        }
      }
      0x05 => {
        let ptrs = hdr + 12
        // push in reverse so pages are visited in key order
        stack.push(self.u32(hdr + 8))
        for i = ncells - 1; i >= 0; i = i - 1 {
          let c = base + self.u16(ptrs + 2 * i)
          stack.push(self.u32(c))
        }
      }
      _ => raise sql_err("database disk image is malformed")
    }
  }
}

///|
fn be_int(data : Bytes, off : Int, n : Int) -> Int64 {
  let mut v = if data[off].to_int() >= 0x80 { -1L } else { 0L }
  for i in 0..<n {
    v = (v << 8) | data[off + i].to_int64()
  }
  v
}

///|
/// Decode a record into its values.
fn decode_record(data : Bytes) -> Array[Value] raise SqlError {
  let out : Array[Value] = []
  if data.length() == 0 {
    return out
  }
  let (hsize, n0) = read_varint(data, 0)
  let hend = hsize.to_int()
  let mut h = n0
  let mut b = hend
  while h < hend {
    let (st64, n) = read_varint(data, h)
    h += n
    let st = st64.to_int()
    let len = match st {
      0 | 8 | 9 => 0
      1 => 1
      2 => 2
      3 => 3
      4 => 4
      5 => 6
      6 | 7 => 8
      _ => if st >= 12 { (st - 12) / 2 } else { 0 }
    }
    if b + len > data.length() {
      raise sql_err("database disk image is malformed")
    }
    let v = match st {
      0 => Null
      1 | 2 | 3 | 4 | 5 | 6 => Int(be_int(data, b, len))
      7 => {
        let bits = be_int(data, b, 8)
        let d = bits.reinterpret_as_double()
        if d.is_nan() {
          Null
        } else {
          Real(d)
        }
      }
      8 => Int(0L)
      9 => Int(1L)
      _ =>
        if st >= 12 && st % 2 == 0 {
          Blob(data[b:b + len].to_owned())
        } else if st >= 13 {
          Text(@utf8.decode_lossy(data[b:b + len]))
        } else {
          Null
        }
    }
    out.push(v)
    b += len
  }
  out
}

///|
/// Load a database file image. An empty image is an empty database.
pub fn Database::load_file(
  self : Database,
  data : Bytes,
) -> Unit raise SqlError {
  if data.length() == 0 {
    return
  }
  if data.length() < 100 || data[0:16].to_owned() != b"SQLite format 3\x00" {
    raise sql_err("file is not a database")
  }
  let ps = (data[16].to_int() << 8) | data[17].to_int()
  let page_size = if ps == 1 { 65536 } else { ps }
  let pager = { data, page_size, usable: page_size - data[20].to_int(), }
  let entries : Array[Array[Value]] = []
  pager.scan_table(1, (_, p) => entries.push(decode_record(p)))
  let seqs : Array[(String, Int64)] = []
  for e in entries {
    guard e.length() >= 5 else { continue }
    let typ = match e[0] {
      Text(s) => s
      _ => continue
    }
    let name = match e[1] {
      Text(s) => s
      _ => ""
    }
    let root = match e[3] {
      Int(r) => r.to_int()
      _ => 0
    }
    guard e[4] is Text(sql) else {
      if root > 0 {
        self.roots[key_of(name)] = root
      }
      continue
    }
    if root > 0 {
      self.roots[key_of(name)] = root
    }
    if typ == "table" && name.to_lower() == "sqlite_sequence" {
      self.seq_table = Some(self.take_seq(1))
      pager.scan_table(root, (_, p) => {
        let r = decode_record(p)
        if r.length() >= 2 && r[0] is Text(n) && r[1] is Int(v) {
          seqs.push((n, v))
        }
      })
      continue
    }
    let st = parse_statement(sql) catch { _ => continue }
    match st {
      CreateTable(name~, cols~, constraints~, sql~, ..) => {
        let seq = self.next_seq
        let t = build_table(name, cols, constraints, sql, seq) catch {
          _ => continue
        }
        ignore(self.take_seq(t.indexes.length() + 1))
        self.tables[key_of(name)] = t
        self.load_rows(pager, t, root)
      }
      CreateIndex(..) | CreateView(..) => self.run_ddl(st) catch { _ => () }
      _ => ()
    }
  }
  for s in seqs {
    if self.tables.get(key_of(s.0)) is Some(t) {
      t.seq_val = s.1
    }
  }
  self.note_loaded(data, page_size)
}

///|
fn Database::load_rows(
  self : Database,
  pager : Pager,
  t : Table,
  root : Int,
) -> Unit raise SqlError {
  ignore(self)
  let ncols = t.cols.length()
  let defaults : Array[Value?] = Array::make(ncols, None)
  pager.scan_table(root, (rowid, p) => {
    let rec = decode_record(p)
    let vals : Array[Value] = Array::make(ncols, Null)
    for i in 0..<ncols {
      if t.rowid_alias == Some(i) {
        vals[i] = Int(rowid)
      } else if i < rec.length() {
        vals[i] = match rec[i] {
          Int(n) if t.cols[i].affinity == AffReal => Real(n.to_double())
          v => v
        }
      } else {
        match defaults[i] {
          Some(d) => vals[i] = d
          None => {
            let d = eval_default(t.cols[i])
            defaults[i] = Some(d)
            vals[i] = d
          }
        }
      }
    }
    t.insert_row(rowid, vals)
  })
}
