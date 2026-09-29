// Writing the in-memory database back as a SQLite 3 database file. The
// whole file is rebuilt from the committed state: every b-tree is bulk
// loaded in key order and there are no free pages.

///|
/// Header fields of the file the database was loaded from.
priv struct FileHdr {
  page_size : Int
  change_counter : Int
  schema_cookie : Int
  cache_size : Int
  user_version : Int
  app_id : Int
}

///|
priv struct LoadState {
  mut hdr : FileHdr?
  mut schema_sig : String
  mut data_ver : Int
}

///|
let load_state : LoadState = { hdr: None, schema_sig: "", data_ver: 0, }

///|
fn hdr_u32(data : Bytes, off : Int) -> Int {
  (data[off].to_int() << 24) |
  (data[off + 1].to_int() << 16) |
  (data[off + 2].to_int() << 8) |
  data[off + 3].to_int()
}

///|
/// Remember the loaded file's header and the loaded state, so the writer
/// can tell what changed.
fn Database::note_loaded(
  self : Database,
  data : Bytes,
  page_size : Int,
) -> Unit {
  load_state.hdr = Some({
    page_size,
    change_counter: hdr_u32(data, 24),
    schema_cookie: hdr_u32(data, 40),
    cache_size: hdr_u32(data, 48),
    user_version: hdr_u32(data, 60),
    app_id: hdr_u32(data, 68),
  })
  load_state.schema_sig = self.schema_signature()
  load_state.data_ver = data_version.val
}

///|
priv enum SchemaObj {
  OTable(Table)
  OIndex(Table, Index)
  OSeq
  OView(View)
}

///|
/// Schema objects in sqlite_schema order.
fn Database::schema_objs(self : Database) -> Array[SchemaObj] {
  let objs : Array[(Int, SchemaObj)] = []
  for _, t in self.tables {
    objs.push((t.seq, OTable(t)))
    for ix in t.indexes {
      objs.push((ix.seq, OIndex(t, ix)))
    }
  }
  if self.seq_table is Some(sq) {
    objs.push((sq, OSeq))
  }
  for _, v in self.views {
    objs.push((v.seq, OView(v)))
  }
  objs.sort_by((a, b) => a.0 - b.0)
  objs.map(o => o.1)
}

///|
fn schema_obj_row(o : SchemaObj) -> (String, String, String, String?) {
  match o {
    OTable(t) => ("table", t.name, t.name, Some(t.sql))
    OIndex(t, ix) =>
      (
        "index",
        ix.name,
        t.name,
        match ix.def {
          Some(d) => Some(d.sql)
          None => None
        },
      )
    OSeq =>
      (
        "table",
        "sqlite_sequence",
        "sqlite_sequence",
        Some("CREATE TABLE sqlite_sequence(name,seq)"),
      )
    OView(v) => ("view", v.name, v.name, Some(v.sql))
  }
}

///|
fn Database::schema_signature(self : Database) -> String {
  let sb = StringBuilder()
  for o in self.schema_objs() {
    let (a, b, c, d) = schema_obj_row(o)
    sb.write_string("\{a}\u{1}\{b}\u{1}\{c}\u{1}\{d.unwrap_or("\u{2}")}\u{0}")
  }
  sb.to_string()
}

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

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
    // 8 bytes of 7 bits, then a full byte
    for i in 0..<8 {
      let shift = 57 - 7 * i
      buf.write_byte((((u >> shift) & 0x7FUL) | 0x80UL).to_byte())
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
fn int_serial(n : Int64) -> (Int, Int) {
  if n == 0L {
    (8, 0)
  } else if n == 1L {
    (9, 0)
  } else if n >= -128L && n <= 127L {
    (1, 1)
  } else if n >= -32768L && n <= 32767L {
    (2, 2)
  } else if n >= -8388608L && n <= 8388607L {
    (3, 3)
  } else if n >= -2147483648L && n <= 2147483647L {
    (4, 4)
  } else if n >= -140737488355328L && n <= 140737488355327L {
    (5, 6)
  } else {
    (6, 8)
  }
}

///|
fn encode_record(vals : Array[Value]) -> Bytes {
  let types : Array[Int64] = []
  let bodies : Array[Bytes?] = []
  for v in vals {
    match v {
      Null => {
        types.push(0L)
        bodies.push(None)
      }
      Int(n) => {
        let (st, _) = int_serial(n)
        types.push(st.to_int64())
        bodies.push(None)
      }
      Real(_) => {
        types.push(7L)
        bodies.push(None)
      }
      Text(s) => {
        let b = @utf8.encode(s)
        types.push(b.length().to_int64() * 2L + 13L)
        bodies.push(Some(b))
      }
      Blob(b) => {
        types.push(b.length().to_int64() * 2L + 12L)
        bodies.push(Some(b))
      }
    }
  }
  let mut tlen = 0
  for t in types {
    tlen += varint_len(t)
  }
  let mut hs = tlen + 1
  while tlen + varint_len(hs.to_int64()) != hs {
    hs = tlen + varint_len(hs.to_int64())
  }
  let buf = @buffer.Buffer()
  write_varint(buf, hs.to_int64())
  for t in types {
    write_varint(buf, t)
  }
  for i, v in vals {
    match v {
      Int(n) => {
        let (_, len) = int_serial(n)
        for k = len - 1; k >= 0; k = k - 1 {
          buf.write_byte((n >> (8 * k)).to_byte())
        }
      }
      Real(d) => buf.write_uint64_be(d.reinterpret_as_uint64())
      _ => if bodies[i] is Some(b) { buf.write_bytes(b) }
    }
  }
  buf.to_bytes()
}

// ---------------------------------------------------------------------------
// Pages and b-trees
// ---------------------------------------------------------------------------

///|
priv struct Writer {
  page_size : Int
  usable : Int
  pages : Array[FixedArray[Byte]]
}

///|
fn Writer::alloc(self : Writer) -> Int {
  self.pages.push(FixedArray::make(0, b'\x00'))
  self.pages.length()
}

///|
fn put_u16(p : FixedArray[Byte], off : Int, v : Int) -> Unit {
  p[off] = (v >> 8).to_byte()
  p[off + 1] = v.to_byte()
}

///|
fn put_u32(p : FixedArray[Byte], off : Int, v : Int) -> Unit {
  p[off] = (v >> 24).to_byte()
  p[off + 1] = (v >> 16).to_byte()
  p[off + 2] = (v >> 8).to_byte()
  p[off + 3] = v.to_byte()
}

///|
/// Payload bytes stored on the b-tree page for a payload of `p` bytes.
fn Writer::local_size(self : Writer, p : Int, is_table : Bool) -> Int {
  let u = self.usable
  let x = if is_table { u - 35 } else { (u - 12) * 64 / 255 - 23 }
  if p <= x {
    return p
  }
  let m = (u - 12) * 32 / 255 - 23
  let k = m + (p - m) % (u - 4)
  if k <= x {
    k
  } else {
    m
  }
}

///|
/// Cell body: payload size varint, [rowid varint], local payload and the
/// first overflow page number (overflow pages are written here).
fn Writer::make_cell(self : Writer, payload : Bytes, rowid : Int64?) -> Bytes {
  let p = payload.length()
  let nlocal = self.local_size(p, rowid is Some(_))
  let buf = @buffer.Buffer(size_hint=nlocal + 20)
  write_varint(buf, p.to_int64())
  if rowid is Some(r) {
    write_varint(buf, r)
  }
  buf.write_bytes(payload[0:nlocal])
  if nlocal < p {
    // chain of overflow pages
    let per = self.usable - 4
    let mut off = nlocal
    let first = self.alloc()
    let mut pg = first
    while off < p {
      let n = if p - off < per { p - off } else { per }
      let page = FixedArray::make(self.page_size, b'\x00')
      page.blit_from_bytesview(4, payload[off:off + n])
      off += n
      if off < p {
        let next = self.alloc()
        put_u32(page, 0, next)
        self.pages[pg - 1] = page
        pg = next
      } else {
        self.pages[pg - 1] = page
      }
    }
    buf.write_uint_be(first.reinterpret_as_uint())
  }
  buf.to_bytes()
}

///|
fn Writer::hdr_off(pgno : Int) -> Int {
  if pgno == 1 {
    100
  } else {
    0
  }
}

///|
/// Space available for cells and cell pointers on a b-tree page.
fn Writer::cap(self : Writer, pgno : Int, interior : Bool) -> Int {
  self.usable - Writer::hdr_off(pgno) - (if interior { 12 } else { 8 })
}

///|
fn Writer::write_page(
  self : Writer,
  pgno : Int,
  kind : Int,
  cells : ArrayView[Bytes],
  right : Int,
) -> Unit {
  let page = FixedArray::make(self.page_size, b'\x00')
  let h = Writer::hdr_off(pgno)
  let interior = kind == 0x02 || kind == 0x05
  page[h] = kind.to_byte()
  put_u16(page, h + 3, cells.length())
  let ptrs = h + (if interior { 12 } else { 8 })
  let mut content = self.usable
  for i, c in cells {
    content -= c.length()
    page.blit_from_bytesview(content, c[:])
    put_u16(page, ptrs + 2 * i, content)
  }
  put_u16(page, h + 5, if content == 65536 { 0 } else { content })
  if interior {
    put_u32(page, h + 8, right)
  }
  self.pages[pgno - 1] = page
}

///|
fn cells_size(cells : ArrayView[Bytes]) -> Int {
  let mut n = 0
  for c in cells {
    n += c.length() + 2
  }
  n
}

///|
fn child_cell(child : Int, body : Bytes) -> Bytes {
  let buf = @buffer.Buffer(size_hint=body.length() + 4)
  buf.write_uint_be(child.reinterpret_as_uint())
  buf.write_bytes(body)
  buf.to_bytes()
}

///|
/// Greedy split of a leaf level into page ranges [start, end).
fn pack_leaves(cells : Array[Bytes], cap : Int) -> Array[(Int, Int)] {
  let out : Array[(Int, Int)] = []
  let mut start = 0
  let mut size = 0
  for i, c in cells {
    let s = c.length() + 2
    if size + s > cap && i > start {
      out.push((start, i))
      start = i
      size = 0
    }
    size += s
  }
  out.push((start, cells.length()))
  out
}

///|
/// Build a table b-tree over (rowid, record) pairs in rowid order and
/// return its root page. `root` forces the root page number (page 1).
fn Writer::table_tree(
  self : Writer,
  rows : Array[(Int64, Bytes)],
  root? : Int,
) -> Int {
  let cells = rows.map(r => self.make_cell(r.1, Some(r.0)))
  let root_pg = match root {
    Some(r) => r
    None => 0
  }
  let root_cap = if root_pg == 1 {
    self.cap(1, false)
  } else {
    self.cap(2, false)
  }
  if cells_size(cells[:]) <= root_cap {
    let pg = if root_pg > 0 { root_pg } else { self.alloc() }
    self.write_page(pg, 0x0d, cells[:], 0)
    return pg
  }
  let mut groups = pack_leaves(cells, self.cap(2, false))
  if groups.length() == 1 {
    let n = cells.length()
    groups = [(0, n / 2), (n / 2, n)]
  }
  let mut children : Array[(Int, Int64)] = []
  for g in groups {
    let pg = self.alloc()
    self.write_page(pg, 0x0d, cells[g.0:g.1], 0)
    children.push((pg, rows[g.1 - 1].0))
  }
  for ;; {
    // interior cells for all children but the last
    let n = children.length()
    let icells = Array::makei(n, i => {
      let buf = @buffer.Buffer()
      buf.write_uint_be(children[i].0.reinterpret_as_uint())
      write_varint(buf, children[i].1)
      buf.to_bytes()
    })
    let rcap = if root_pg == 1 { self.cap(1, true) } else { self.cap(2, true) }
    if cells_size(icells[0:n - 1]) <= rcap {
      let pg = if root_pg > 0 { root_pg } else { self.alloc() }
      self.write_page(pg, 0x05, icells[0:n - 1], children[n - 1].0)
      return pg
    }
    let cap = self.cap(2, true)
    let next : Array[(Int, Int64)] = []
    let mut start = 0
    let mut size = 0
    let mut i = 0
    while i < n {
      // children[start..=end] form a page with children[end] as right child
      let mut end = -1
      if i == n - 1 {
        end = i
        if next.length() == 0 {
          // everything would land on one page: split in two
          end = (start + i - 1) / 2
        }
      } else if size + icells[i].length() + 2 > cap && i > start + 1 {
        end = if i == n - 2 { i - 1 } else { i }
      }
      if end < 0 {
        size += icells[i].length() + 2
        i += 1
        continue
      }
      let pg = self.alloc()
      self.write_page(pg, 0x05, icells[start:end], children[end].0)
      next.push((pg, children[end].1))
      start = end + 1
      size = 0
      i = start
    }
    children = next
  }
}

///|
/// Build an index b-tree over records in index order.
fn Writer::index_tree(self : Writer, keys : Array[Bytes]) -> Int {
  let cells = keys.map(k => self.make_cell(k, None))
  if cells_size(cells[:]) <= self.cap(2, false) {
    let pg = self.alloc()
    self.write_page(pg, 0x0a, cells[:], 0)
    return pg
  }
  // leaves separated by promoted entries
  let cap = self.cap(2, false)
  let n = cells.length()
  let mut children : Array[Int] = []
  let mut seps : Array[Int] = []
  let mut start = 0
  let mut size = 0
  let mut i = 0
  while i < n {
    let s = cells[i].length() + 2
    if size + s > cap && i > start + 1 {
      let mut sep = i
      if i == n - 1 {
        // the final leaf must not be empty
        sep = i - 1
      }
      let pg = self.alloc()
      self.write_page(pg, 0x0a, cells[start:sep], 0)
      children.push(pg)
      seps.push(sep)
      start = sep + 1
      size = 0
      i = start
      continue
    }
    size += s
    i += 1
  }
  let pg = self.alloc()
  self.write_page(pg, 0x0a, cells[start:n], 0)
  children.push(pg)
  for ;; {
    let m = seps.length()
    let icells = Array::makei(m, j => child_cell(children[j], cells[seps[j]]))
    if cells_size(icells[:]) <= self.cap(2, true) {
      let pg = self.alloc()
      self.write_page(pg, 0x02, icells[:], children[m])
      return pg
    }
    let icap = self.cap(2, true)
    let next_children : Array[Int] = []
    let next_seps : Array[Int] = []
    let mut start = 0
    let mut size = 0
    let mut j = 0
    while j < m {
      let s = icells[j].length() + 2
      if size + s > icap && j > start + 1 {
        // page gets cells start..j-1 (or ..j-2) with a right child
        let mut sep = j
        if j == m - 1 {
          sep = j - 1
        }
        let pg = self.alloc()
        self.write_page(pg, 0x02, icells[start:sep], children[sep])
        next_children.push(pg)
        next_seps.push(seps[sep])
        start = sep + 1
        size = 0
        j = start
        continue
      }
      size += s
      j += 1
    }
    let pg = self.alloc()
    self.write_page(pg, 0x02, icells[start:m], children[m])
    next_children.push(pg)
    children = next_children
    seps = next_seps
  }
}

// ---------------------------------------------------------------------------
// Whole database
// ---------------------------------------------------------------------------

///|
fn Database::table_records(self : Database, t : Table) -> Array[(Int64, Bytes)] {
  ignore(self)
  t.rows
  .to_array()
  .map(p => {
    let vals = match t.rowid_alias {
      Some(a) => {
        let v = p.1.copy()
        v[a] = Null
        v
      }
      None => p.1
    }
    (p.0, encode_record(vals))
  })
}

///|
/// Serialize the database into a file image.
fn Database::to_file_image(
  self : Database,
  page_size : Int,
  change_counter : Int,
  schema_cookie : Int,
  hdr : FileHdr?,
) -> Bytes {
  let w : Writer = { page_size, usable: page_size, pages: [], }
  ignore(w.alloc()) // page 1: schema root
  let entries : Array[(Int64, Bytes)] = []
  for i, o in self.schema_objs() {
    let (typ, name, tbl, sql) = schema_obj_row(o)
    let root = match o {
      OTable(t) => w.table_tree(self.table_records(t))
      OIndex(_, ix) =>
        w.index_tree(ix.map.to_array().map(p => encode_record(p.0)))
      OSeq => {
        let rows = self.sequence_table("sqlite_sequence").rows.to_array()
        w.table_tree(rows.map(r => (r.0, encode_record(r.1))))
      }
      OView(_) => 0
    }
    let sqlv = match sql {
      Some(s) => Text(s)
      None => Null
    }
    entries.push(
      (
        (i + 1).to_int64(),
        encode_record([
          Text(typ),
          Text(name),
          Text(tbl),
          Int(root.to_int64()),
          sqlv,
        ]),
      ),
    )
  }
  ignore(w.table_tree(entries, root=1))
  let npages = w.pages.length()
  let p1 = w.pages[0]
  let magic = b"SQLite format 3\x00"
  p1.blit_from_bytesview(0, magic[:])
  put_u16(p1, 16, if page_size == 65536 { 1 } else { page_size })
  p1[18] = b'\x01'
  p1[19] = b'\x01'
  p1[20] = b'\x00'
  p1[21] = b'\x40'
  p1[22] = b'\x20'
  p1[23] = b'\x20'
  put_u32(p1, 24, change_counter)
  put_u32(p1, 28, npages)
  put_u32(p1, 40, schema_cookie)
  put_u32(p1, 44, 4)
  put_u32(p1, 56, 1)
  if hdr is Some(h) {
    put_u32(p1, 48, h.cache_size)
    put_u32(p1, 60, h.user_version)
    put_u32(p1, 68, h.app_id)
  }
  put_u32(p1, 92, change_counter)
  put_u32(p1, 96, 3053003)
  let buf = @buffer.Buffer(size_hint=npages * page_size)
  for p in w.pages {
    buf.write_bytes(Bytes::from_array(p[:]))
  }
  buf.to_bytes()
}

///|
/// File image of the committed state, if it must be written back (anything
/// changed, or the file does not exist yet). An open transaction is rolled
/// back first.
pub fn Database::image_to_save(self : Database, existed : Bool) -> Bytes? {
  if self.txn is Some(s) {
    self.restore(s)
    self.end_txn()
  }
  let sig = self.schema_signature()
  let schema_changed = sig != load_state.schema_sig
  let data_changed = data_version.val != load_state.data_ver
  if existed && !schema_changed && !data_changed {
    return None
  }
  let (page_size, counter, cookie) = match load_state.hdr {
    Some(h) =>
      (
        h.page_size,
        h.change_counter + 1,
        if schema_changed {
          h.schema_cookie + 1
        } else {
          h.schema_cookie
        },
      )
    None => (4096, 1, if sig == "" { 0 } else { 1 })
  }
  Some(self.to_file_image(page_size, counter, cookie, load_state.hdr))
}
