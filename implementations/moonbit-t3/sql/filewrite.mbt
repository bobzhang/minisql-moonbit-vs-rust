///|
/// Serializes the database into a complete SQLite 3 file image. Every
/// b-tree is rebuilt bottom-up, so the image never has free pages.
priv struct FileImage {
  page_size : Int
  usable : Int
  pages : Array[FixedArray[Byte]]
}

///|
/// A divider in an interior page: a rowid (table) or an entry (index).
priv enum Sep {
  Key(Int64)
  Entry(Bytes)
}

///|
fn FileImage::alloc(self : FileImage) -> Int {
  self.pages.push(FixedArray::make(self.page_size, b'\x00'))
  self.pages.length()
}

///|
fn put_u16(page : FixedArray[Byte], pos : Int, v : Int) -> Unit {
  page[pos] = (v >> 8).to_byte()
  page[pos + 1] = v.to_byte()
}

///|
fn put_u32(page : FixedArray[Byte], pos : Int, v : Int) -> Unit {
  page[pos] = (v >> 24).to_byte()
  page[pos + 1] = (v >> 16).to_byte()
  page[pos + 2] = (v >> 8).to_byte()
  page[pos + 3] = v.to_byte()
}

///|
fn varint_len(v : Int64) -> Int {
  let u = v.reinterpret_as_uint64()
  if u > 0x00FFFFFFFFFFFFFFUL {
    return 9
  }
  let mut n = 1
  let mut x = u >> 7
  while x != 0UL {
    n += 1
    x = x >> 7
  }
  n
}

///|
fn write_varint(buf : @buffer.Buffer, v : Int64) -> Unit {
  let u = v.reinterpret_as_uint64()
  if u > 0x00FFFFFFFFFFFFFFUL {
    // 8 bytes of 7 bits each, then a full final byte.
    let hi = u >> 8
    for i = 7; i >= 0; i = i - 1 {
      buf.write_byte((((hi >> (7 * i)) & 0x7FUL) | 0x80UL).to_byte())
    }
    buf.write_byte((u & 0xFFUL).to_byte())
    return
  }
  let n = varint_len(v)
  for i = n - 1; i >= 0; i = i - 1 {
    let b = (u >> (7 * i)) & 0x7FUL
    buf.write_byte((if i > 0 { b | 0x80UL } else { b }).to_byte())
  }
}

///|
/// Encodes values in the record format.
fn encode_record(vals : Array[Value]) -> Bytes {
  let types : Array[Int64] = []
  let bodies : Array[Bytes] = []
  for v in vals {
    match v {
      Null => {
        types.push(0L)
        bodies.push(b"")
      }
      Int(i) => {
        let (t, n) = if i == 0L {
          (8L, 0)
        } else if i == 1L {
          (9L, 0)
        } else if i >= -128L && i <= 127L {
          (1L, 1)
        } else if i >= -32768L && i <= 32767L {
          (2L, 2)
        } else if i >= -8388608L && i <= 8388607L {
          (3L, 3)
        } else if i >= -2147483648L && i <= 2147483647L {
          (4L, 4)
        } else if i >= -140737488355328L && i <= 140737488355327L {
          (5L, 6)
        } else {
          (6L, 8)
        }
        types.push(t)
        let b = FixedArray::make(n, b'\x00')
        for k in 0..<n {
          b[k] = (i >> (8 * (n - 1 - k))).to_byte()
        }
        bodies.push(Bytes::from_array(b[:]))
      }
      Real(d) => {
        types.push(7L)
        let buf = @buffer.Buffer(size_hint=8)
        buf.write_double_be(d)
        bodies.push(buf.to_bytes())
      }
      Text(s) => {
        let b = @utf8.encode(s)
        types.push(13L + 2L * b.length().to_int64())
        bodies.push(b)
      }
      Blob(b) => {
        types.push(12L + 2L * b.length().to_int64())
        bodies.push(b)
      }
    }
  }
  let mut h = 0
  for t in types {
    h += varint_len(t)
  }
  let mut n = 1
  while varint_len((h + n).to_int64()) > n {
    n += 1
  }
  let buf = @buffer.Buffer()
  write_varint(buf, (h + n).to_int64())
  for t in types {
    write_varint(buf, t)
  }
  for b in bodies {
    buf.write_bytes(b)
  }
  buf.to_bytes()
}

///|
fn FileImage::max_local(self : FileImage, index : Bool) -> Int {
  if index {
    (self.usable - 12) * 64 / 255 - 23
  } else {
    self.usable - 35
  }
}

///|
/// Size of a cell made of a `prefix`-byte header and a `p`-byte payload.
fn FileImage::cell_size(
  self : FileImage,
  prefix : Int,
  p : Int,
  index : Bool,
) -> Int {
  let local = local_payload(self.usable, p, self.max_local(index))
  let s = prefix + local + (if local < p { 4 } else { 0 })
  if s < 4 {
    4
  } else {
    s
  }
}

///|
/// Builds a cell: `prefix`, the local part of `payload`, and (if needed) the
/// number of the first page of a freshly written overflow chain.
fn FileImage::make_cell(
  self : FileImage,
  prefix : Bytes,
  payload : Bytes,
  index : Bool,
) -> Bytes {
  let p = payload.length()
  let local = local_payload(self.usable, p, self.max_local(index))
  let buf = @buffer.Buffer(size_hint=prefix.length() + local + 4)
  buf.write_bytes(prefix)
  buf.write_bytes(payload[0:local])
  if local < p {
    let per = self.usable - 4
    let mut pg = self.alloc()
    buf.write_uint_be(pg.reinterpret_as_uint())
    let mut off = local
    while off < p {
      let n = if p - off < per { p - off } else { per }
      let page = self.pages[pg - 1]
      page.blit_from_bytesview(4, payload[off:off + n])
      off += n
      if off < p {
        let next = self.alloc()
        put_u32(page, 0, next)
        pg = next
      }
    }
  }
  while buf.length() < 4 {
    buf.write_byte(b'\x00')
  }
  buf.to_bytes()
}

///|
fn FileImage::write_page(
  self : FileImage,
  pgno : Int,
  kind : Int,
  cells : Array[Bytes],
  right : Int,
) -> Unit {
  let page = self.pages[pgno - 1]
  let hdr = if pgno == 1 { 100 } else { 0 }
  let leaf = kind == 0x0a || kind == 0x0d
  let ptrs = hdr + (if leaf { 8 } else { 12 })
  let mut content = self.usable
  for i, c in cells {
    content -= c.length()
    page.blit_from_bytesview(content, c[:])
    put_u16(page, ptrs + 2 * i, content)
  }
  page[hdr] = kind.to_byte()
  put_u16(page, hdr + 1, 0)
  put_u16(page, hdr + 3, cells.length())
  put_u16(page, hdr + 5, if content == 65536 { 0 } else { content })
  page[hdr + 7] = b'\x00'
  if !leaf {
    put_u32(page, hdr + 8, right)
  }
}

///|
fn FileImage::root_capacity(self : FileImage, root : Int, hdr : Int) -> Int {
  self.usable - hdr - (if root == 1 { 100 } else { 0 })
}

///|
fn fits_in(sizes : Array[Int], cap : Int) -> Bool {
  let mut used = 0
  for s in sizes {
    used += s + 2
    if used > cap {
      return false
    }
  }
  true
}

///|
/// Splits items into consecutive groups of at least one item that fit in
/// `cap` bytes. With `seps`, the item following each group except the last
/// is a divider that belongs to no group. Always at least two groups.
fn split_groups(sizes : Array[Int], cap : Int, seps : Bool) -> Array[(Int, Int)] {
  let n = sizes.length()
  let groups = []
  let mut i = 0
  while i < n {
    let start = i
    let mut used = 0
    while i < n && (i == start || used + sizes[i] + 2 <= cap) {
      used += sizes[i] + 2
      i += 1
    }
    if i >= n {
      groups.push((start, n))
      break
    }
    if !seps {
      groups.push((start, i))
      continue
    }
    if i == n - 1 && i - 1 > start {
      // The divider would leave an empty last group: use the previous item.
      groups.push((start, i - 1))
      groups.push((i, n))
      break
    }
    groups.push((start, i))
    i += 1
  }
  if groups.length() == 1 {
    let h = n / 2
    groups.clear()
    if seps {
      groups.push((0, h))
      groups.push((h + 1, n))
    } else {
      groups.push((0, h))
      groups.push((h, n))
    }
  }
  groups
}

///|
fn FileImage::sep_size(self : FileImage, s : Sep) -> Int {
  match s {
    Key(k) => 4 + varint_len(k)
    Entry(b) =>
      self.cell_size(4 + varint_len(b.length().to_int64()), b.length(), true)
  }
}

///|
fn FileImage::interior_cell(self : FileImage, child : Int, s : Sep) -> Bytes {
  let buf = @buffer.Buffer()
  buf.write_uint_be(child.reinterpret_as_uint())
  match s {
    Key(k) => {
      write_varint(buf, k)
      buf.to_bytes()
    }
    Entry(b) => {
      write_varint(buf, b.length().to_int64())
      self.make_cell(buf.to_bytes(), b, true)
    }
  }
}

///|
/// Builds the interior levels above `children` (divided by `seps`) up to
/// the root page `root`.
fn FileImage::build_interior(
  self : FileImage,
  root : Int,
  children : Array[Int],
  seps : Array[Sep],
  index : Bool,
) -> Unit {
  let kind = if index { 0x02 } else { 0x05 }
  let mut children = children
  let mut seps = seps
  while true {
    let m = seps.length()
    let sizes = seps.map(s => self.sep_size(s))
    if fits_in(sizes, self.root_capacity(root, 12)) {
      let cells = seps.mapi((t, s) => self.interior_cell(children[t], s))
      self.write_page(root, kind, cells, children[m])
      return
    }
    let groups = split_groups(sizes, self.usable - 12, true)
    let next_children = []
    let next_seps = []
    for gi, g in groups {
      let pg = self.alloc()
      let cells = []
      for t in g.0..<g.1 {
        cells.push(self.interior_cell(children[t], seps[t]))
      }
      let last = gi == groups.length() - 1
      self.write_page(pg, kind, cells, if last { children[m] } else {
        children[g.1]
      })
      next_children.push(pg)
      if !last {
        next_seps.push(seps[g.1])
      }
    }
    children = next_children
    seps = next_seps
  }
}

///|
fn FileImage::table_leaf_cell(
  self : FileImage,
  rowid : Int64,
  rec : Bytes,
) -> Bytes {
  let buf = @buffer.Buffer()
  write_varint(buf, rec.length().to_int64())
  write_varint(buf, rowid)
  self.make_cell(buf.to_bytes(), rec, false)
}

///|
/// Writes a table b-tree with root page `root` holding `rows` (in rowid
/// order).
fn FileImage::build_table(
  self : FileImage,
  root : Int,
  rows : Array[(Int64, Bytes)],
) -> Unit {
  let sizes = rows.map(r => {
    let p = r.1.length()
    self.cell_size(varint_len(p.to_int64()) + varint_len(r.0), p, false)
  })
  if fits_in(sizes, self.root_capacity(root, 8)) {
    let cells = rows.map(r => self.table_leaf_cell(r.0, r.1))
    self.write_page(root, 0x0d, cells, 0)
    return
  }
  let children = []
  let seps = []
  for g in split_groups(sizes, self.usable - 8, false) {
    let pg = self.alloc()
    let cells = []
    for t in g.0..<g.1 {
      cells.push(self.table_leaf_cell(rows[t].0, rows[t].1))
    }
    self.write_page(pg, 0x0d, cells, 0)
    children.push(pg)
    seps.push(Key(rows[g.1 - 1].0))
  }
  seps.pop() |> ignore
  self.build_interior(root, children, seps, false)
}

///|
fn FileImage::index_leaf_cell(self : FileImage, rec : Bytes) -> Bytes {
  let buf = @buffer.Buffer()
  write_varint(buf, rec.length().to_int64())
  self.make_cell(buf.to_bytes(), rec, true)
}

///|
/// Writes an index b-tree with root page `root` holding `entries` (in
/// index order).
fn FileImage::build_index(
  self : FileImage,
  root : Int,
  entries : Array[Bytes],
) -> Unit {
  let sizes = entries.map(e => {
    let p = e.length()
    self.cell_size(varint_len(p.to_int64()), p, true)
  })
  if fits_in(sizes, self.root_capacity(root, 8)) {
    let cells = entries.map(e => self.index_leaf_cell(e))
    self.write_page(root, 0x0a, cells, 0)
    return
  }
  let children = []
  let seps = []
  let groups = split_groups(sizes, self.usable - 8, true)
  for gi, g in groups {
    let pg = self.alloc()
    let cells = []
    for t in g.0..<g.1 {
      cells.push(self.index_leaf_cell(entries[t]))
    }
    self.write_page(pg, 0x0a, cells, 0)
    children.push(pg)
    if gi < groups.length() - 1 {
      seps.push(Entry(entries[g.1]))
    }
  }
  self.build_interior(root, children, seps, true)
}

///|
fn header_u32(data : Bytes?, pos : Int) -> Int {
  match data {
    Some(d) if d.length() >= 100 =>
      (d[pos].to_int() << 24) |
      (d[pos + 1].to_int() << 16) |
      (d[pos + 2].to_int() << 8) |
      d[pos + 3].to_int()
    _ => 0
  }
}

///|
/// The complete file image of the (committed) database. `old` is the file
/// it was loaded from, if any: its page size, reserved space and a few
/// header fields are kept, and its counters are incremented.
pub fn Database::file_image(self : Database, old : Bytes?) -> Bytes {
  let (page_size, reserved) = match old {
    Some(d) if d.length() >= 100 => {
      let ps = (d[16].to_int() << 8) | d[17].to_int()
      (if ps == 1 { 65536 } else { ps }, d[20].to_int())
    }
    _ => (4096, 0)
  }
  let img = { page_size, usable: page_size - reserved, pages: [] }
  img.alloc() |> ignore
  let schema = self.schema_rows()
  for row in schema {
    guard row[0] is Text(kind) && row[1] is Text(name) else { continue }
    if kind == "table" {
      let root = img.alloc()
      row[3] = Int(root.to_int64())
      if fold_name(name) == "sqlite_sequence" {
        let seq = self.sequence_table("sqlite_sequence")
        let rows = []
        for id, r in seq.rows {
          rows.push((id, encode_record(r)))
        }
        img.build_table(root, rows)
      } else if self.find_table(name) is Some(t) {
        let rows = []
        for id, r in t.rows {
          if t.ipk >= 0 {
            let r2 = r.copy()
            r2[t.ipk] = Null
            rows.push((id, encode_record(r2)))
          } else {
            rows.push((id, encode_record(r)))
          }
        }
        img.build_table(root, rows)
      } else {
        img.build_table(root, [])
      }
    } else if kind == "index" {
      let root = img.alloc()
      row[3] = Int(root.to_int64())
      let entries = []
      if self.indexes.get(fold_name(name)) is Some(idx) {
        for k, _ in idx.tree {
          entries.push(encode_record([..k.vals, Int(k.rowid)]))
        }
      }
      img.build_index(root, entries)
    }
  }
  img.build_table(
    1,
    schema.mapi((i, row) => (i.to_int64() + 1L, encode_record(row))),
  )
  // File header.
  let p1 = img.pages[0]
  p1.blit_from_bytesview(0, b"SQLite format 3\x00"[:])
  put_u16(p1, 16, if page_size == 65536 { 1 } else { page_size })
  p1[18] = b'\x01'
  p1[19] = b'\x01'
  p1[20] = reserved.to_byte()
  p1[21] = b'\x40'
  p1[22] = b'\x20'
  p1[23] = b'\x20'
  let counter = header_u32(old, 24) + 1
  put_u32(p1, 24, counter)
  put_u32(p1, 28, img.pages.length())
  put_u32(p1, 32, 0)
  put_u32(p1, 36, 0)
  put_u32(p1, 40, header_u32(old, 40) + 1)
  put_u32(p1, 44, 4)
  put_u32(p1, 48, header_u32(old, 48))
  put_u32(p1, 52, 0)
  put_u32(p1, 56, 1)
  put_u32(p1, 60, header_u32(old, 60))
  put_u32(p1, 64, 0)
  put_u32(p1, 68, header_u32(old, 68))
  put_u32(p1, 92, counter)
  put_u32(p1, 96, 3053000)
  let buf = @buffer.Buffer(size_hint=img.pages.length() * page_size)
  for p in img.pages {
    buf.write_bytes(Bytes::from_array(p[:]))
  }
  buf.to_bytes()
}

///|
/// Rolls back a transaction left open at the end of the script.
pub fn Database::rollback_open_txn(self : Database) -> Unit {
  if self.in_txn {
    self.rollback_to(0)
    self.end_txn()
  }
}

///|
/// A fingerprint of the persistent state: changes whenever data, schema or
/// AUTOINCREMENT counters may have changed.
pub fn Database::state_fingerprint(self : Database) -> String {
  let sb = StringBuilder()
  sb.write_string(data_version.val.to_string())
  for row in self.schema_rows() {
    for v in row {
      sb.write_char('\u{1}')
      sb.write_string(v.to_output())
    }
  }
  for _, t in self.tables {
    if t.autoinc {
      sb.write_string("\u{2}\{t.name}=\{t.seq}")
    }
  }
  sb.to_string()
}
