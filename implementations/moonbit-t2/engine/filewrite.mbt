// Writing SQLite 3 database files. The whole file is rebuilt from the
// in-memory database: root pages are allocated first (in schema order, so
// they stay stable while the schema does not change), then every b-tree is
// bulk-loaded bottom-up. The result has no free pages.

///|
priv struct PageWriter {
  page_size : Int
  usable : Int
  pages : Array[FixedArray[Byte]]
}

///|
fn PageWriter::alloc(self : PageWriter) -> Int {
  self.pages.push(FixedArray::make(self.page_size, b'\x00'))
  self.pages.length()
}

///|
fn varint_len(v : Int64) -> Int {
  let u = v.reinterpret_as_uint64()
  if u <= 0x7FUL {
    1
  } else if u <= 0x3FFFUL {
    2
  } else if u <= 0x1FFFFFUL {
    3
  } else if u <= 0xFFFFFFFUL {
    4
  } else if u <= 0x7FFFFFFFFUL {
    5
  } else if u <= 0x3FFFFFFFFFFUL {
    6
  } else if u <= 0x1FFFFFFFFFFFFUL {
    7
  } else if u <= 0xFFFFFFFFFFFFFFUL {
    8
  } else {
    9
  }
}

///|
fn write_varint(buf : @buffer.Buffer, v : Int64) -> Unit {
  let u = v.reinterpret_as_uint64()
  let n = varint_len(v)
  if n == 9 {
    for i in 0..<8 {
      let shift = 57 - 7 * i
      buf.write_byte((((u >> shift) & 0x7FUL) | 0x80UL).to_byte())
    }
    buf.write_byte((u & 0xFFUL).to_byte())
    return
  }
  for i = n - 1; i >= 0; i = i - 1 {
    let b = (u >> (7 * i)) & 0x7FUL
    buf.write_byte((if i > 0 { b | 0x80UL } else { b }).to_byte())
  }
}

///|
fn int_serial(i : Int64) -> (Int, Int) {
  if i == 0L {
    (8, 0)
  } else if i == 1L {
    (9, 0)
  } else if i >= -128L && i <= 127L {
    (1, 1)
  } else if i >= -32768L && i <= 32767L {
    (2, 2)
  } else if i >= -8388608L && i <= 8388607L {
    (3, 3)
  } else if i >= -2147483648L && i <= 2147483647L {
    (4, 4)
  } else if i >= -140737488355328L && i <= 140737488355327L {
    (5, 6)
  } else {
    (6, 8)
  }
}

///|
/// Encodes values in the record format.
fn encode_record(vals : Array[Value]) -> Bytes {
  let types : Array[Int64] = []
  let body = @buffer.Buffer()
  for v in vals {
    match v {
      Null => types.push(0L)
      Int(i) => {
        let (st, n) = int_serial(i)
        types.push(st.to_int64())
        for k = n - 1; k >= 0; k = k - 1 {
          body.write_byte((i >> (8 * k)).to_byte())
        }
      }
      Real(d) => {
        types.push(7L)
        body.write_uint64_be(d.reinterpret_as_uint64())
      }
      Text(s) => {
        let b = @utf8.encode(s[:])
        types.push((b.length() * 2 + 13).to_int64())
        body.write_bytes(b[:])
      }
      Blob(b) => {
        types.push((b.length() * 2 + 12).to_int64())
        body.write_bytes(b[:])
      }
    }
  }
  let mut hlen = 0
  for t in types {
    hlen += varint_len(t)
  }
  let mut hsize = hlen + 1
  while varint_len(hsize.to_int64()) + hlen != hsize {
    hsize = hlen + varint_len(hsize.to_int64())
  }
  let out = @buffer.Buffer(size_hint=hsize + body.length())
  write_varint(out, hsize.to_int64())
  for t in types {
    write_varint(out, t)
  }
  out.write_bytes(body.to_bytes()[:])
  out.to_bytes()
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
/// Writes the payload `size` prefix, the local part and (if it spills)
/// the overflow chain; returns the cell body.
fn PageWriter::payload_cell(
  self : PageWriter,
  buf : @buffer.Buffer,
  payload : Bytes,
  is_index : Bool,
) -> Unit {
  let u = self.usable
  let size = payload.length()
  let x = if is_index { (u - 12) * 64 / 255 - 23 } else { u - 35 }
  if size <= x {
    buf.write_bytes(payload[:])
    return
  }
  let m = (u - 12) * 32 / 255 - 23
  let k = m + (size - m) % (u - 4)
  let nlocal = if k <= x { k } else { m }
  buf.write_bytes(payload[0:nlocal])
  // overflow chain
  let first = self.alloc()
  buf.write_uint_be(first.reinterpret_as_uint())
  let mut pos = nlocal
  let mut pg = first
  while pos < size {
    let n = if size - pos < u - 4 { size - pos } else { u - 4 }
    let page = self.pages[pg - 1]
    page.blit_from_bytesview(4, payload[pos:pos + n])
    pos += n
    if pos < size {
      let next = self.alloc()
      put_u32(page, 0, next)
      pg = next
    }
  }
}

///|
fn PageWriter::hdr_off(pgno : Int) -> Int {
  if pgno == 1 {
    100
  } else {
    0
  }
}

///|
/// Space for cells (with their pointers) on a page.
fn PageWriter::capacity(self : PageWriter, pgno : Int, interior : Bool) -> Int {
  self.usable - PageWriter::hdr_off(pgno) - (if interior { 12 } else { 8 })
}

///|
fn cell_cost(c : Bytes) -> Int {
  (if c.length() < 4 { 4 } else { c.length() }) + 2
}

///|
fn PageWriter::write_page(
  self : PageWriter,
  pgno : Int,
  kind : Int,
  cells : ArrayView[Bytes],
  right : Int,
) -> Unit {
  let p = self.pages[pgno - 1]
  let h = PageWriter::hdr_off(pgno)
  let interior = kind == 0x02 || kind == 0x05
  let hsize = if interior { 12 } else { 8 }
  let mut top = self.usable
  let ptrs = h + hsize
  for i, c in cells {
    let len = if c.length() < 4 { 4 } else { c.length() }
    top -= len
    p.blit_from_bytesview(top, c[:])
    put_u16(p, ptrs + 2 * i, top)
  }
  p[h] = kind.to_byte()
  put_u16(p, h + 1, 0)
  put_u16(p, h + 3, cells.length())
  put_u16(p, h + 5, if top == 65536 { 0 } else { top })
  p[h + 7] = b'\x00'
  if interior {
    put_u32(p, h + 8, right)
  }
}

///|
fn u32_prefix(child : Int, rest : Bytes) -> Bytes {
  let b = @buffer.Buffer(size_hint=rest.length() + 4)
  b.write_uint_be(child.reinterpret_as_uint())
  b.write_bytes(rest[:])
  b.to_bytes()
}

///|
/// Builds a table b-tree with the given (rowid, record) entries in rowid
/// order, rooted at page `root`.
fn PageWriter::build_table(
  self : PageWriter,
  root : Int,
  entries : Array[(Int64, Bytes)],
) -> Unit {
  let cells : Array[Bytes] = []
  for e in entries {
    let b = @buffer.Buffer()
    write_varint(b, e.1.length().to_int64())
    write_varint(b, e.0)
    self.payload_cell(b, e.1, false)
    cells.push(b.to_bytes())
  }
  let total = cells.fold(init=0, (acc, c) => acc + cell_cost(c))
  if total <= self.capacity(root, false) {
    self.write_page(root, 0x0d, cells[:], 0)
    return
  }
  // leaf level: greedy groups
  let cap = self.capacity(0, false)
  let mut children : Array[(Int, Int64)] = []
  let mut start = 0
  let mut used = 0
  for i, c in cells {
    let cost = cell_cost(c)
    if used + cost > cap && i > start {
      let pg = self.alloc()
      self.write_page(pg, 0x0d, cells[start:i], 0)
      children.push((pg, entries[i - 1].0))
      start = i
      used = 0
    }
    used += cost
  }
  let pg = self.alloc()
  self.write_page(pg, 0x0d, cells[start:], 0)
  children.push((pg, entries[entries.length() - 1].0))
  // interior levels
  while true {
    let icells = children.map(ch => {
      let b = @buffer.Buffer()
      b.write_uint_be(ch.0.reinterpret_as_uint())
      write_varint(b, ch.1)
      b.to_bytes()
    })
    let m = children.length() - 1
    let mut total = 0
    for i in 0..<m {
      total += cell_cost(icells[i])
    }
    if total <= self.capacity(root, true) {
      self.write_page(root, 0x05, icells[0:m], children[m].0)
      return
    }
    let icap = self.capacity(0, true)
    // groups [a, b]: cells a..<b, right child b
    let groups : Array[(Int, Int)] = []
    let mut a = 0
    while a <= m {
      let mut b = a
      let mut used = 0
      while b < m && used + cell_cost(icells[b]) <= icap {
        used += cell_cost(icells[b])
        b += 1
      }
      groups.push((a, b))
      a = b + 1
    }
    let ng = groups.length()
    if ng >= 2 && groups[ng - 1].0 == groups[ng - 1].1 {
      let (a0, b0) = groups[ng - 2]
      groups[ng - 2] = (a0, b0 - 1)
      groups[ng - 1] = (b0, groups[ng - 1].1)
    }
    let next : Array[(Int, Int64)] = []
    for g in groups {
      let pg = self.alloc()
      self.write_page(pg, 0x05, icells[g.0:g.1], children[g.1].0)
      next.push((pg, children[g.1].1))
    }
    children = next
  }
}

///|
/// Builds an index b-tree with the given records in index order, rooted
/// at page `root`.
fn PageWriter::build_index(
  self : PageWriter,
  root : Int,
  records : Array[Bytes],
) -> Unit {
  let mut items : Array[Bytes] = records.map(r => {
    let b = @buffer.Buffer()
    write_varint(b, r.length().to_int64())
    self.payload_cell(b, r, true)
    b.to_bytes()
  })
  let mut children : Array[Int]? = None
  while true {
    let interior = children is Some(_)
    let cell_at = fn(i : Int) -> Bytes {
      match children {
        Some(ch) => u32_prefix(ch[i], items[i])
        None => items[i]
      }
    }
    let m = items.length()
    let kind = if interior { 0x02 } else { 0x0a }
    let right_of = fn(b : Int) -> Int {
      match children {
        Some(ch) => ch[b]
        None => 0
      }
    }
    let cells = Array::makei(m, cell_at)
    let total = cells.fold(init=0, (acc, c) => acc + cell_cost(c))
    if total <= self.capacity(root, interior) {
      self.write_page(root, kind, cells[:], right_of(m))
      return
    }
    let cap = self.capacity(0, interior)
    // groups [a, b): items a..<b; item b (if < m) is the divider above
    let groups : Array[(Int, Int)] = []
    let mut a = 0
    while true {
      let mut b = a
      let mut used = 0
      while b < m && (used + cell_cost(cells[b]) <= cap || b == a) {
        used += cell_cost(cells[b])
        b += 1
      }
      groups.push((a, b))
      if b >= m {
        break
      }
      a = b + 1
    }
    let ng = groups.length()
    if ng >= 2 && groups[ng - 1].0 == m {
      let (a0, b0) = groups[ng - 2]
      groups[ng - 2] = (a0, b0 - 1)
      groups[ng - 1] = (b0, m)
    }
    let next_children : Array[Int] = []
    let next_items : Array[Bytes] = []
    for gi, g in groups {
      let pg = self.alloc()
      self.write_page(pg, kind, cells[g.0:g.1], right_of(g.1))
      next_children.push(pg)
      if gi < groups.length() - 1 {
        next_items.push(items[g.1])
      }
    }
    items = next_items
    children = Some(next_children)
  }
}

///|
priv enum SchemaObj {
  OTable(Table)
  OIndex(Table, Index)
  OSeq
  OView(View)
}

///|
fn schema_sig(rows : Array[Array[Value]]) -> String {
  let sb = StringBuilder()
  for r in rows {
    for v in r {
      sb.write_string(v.to_output())
      sb.write_char('\u{1}')
    }
    sb.write_char('\u{2}')
  }
  sb.to_string()
}

///|
fn get_u32(b : Bytes, off : Int) -> Int {
  (b[off].to_int() << 24) |
  (b[off + 1].to_int() << 16) |
  (b[off + 2].to_int() << 8) |
  b[off + 3].to_int()
}

///|
/// Serializes the database in the SQLite file format.
pub fn Database::to_file_bytes(self : Database) -> Bytes {
  let old = self.file_header
  let page_size = match old {
    Some(h) => {
      let ps = (h[16].to_int() << 8) | h[17].to_int()
      if ps == 1 {
        65536
      } else {
        ps
      }
    }
    None => 4096
  }
  let reserved = match old {
    Some(h) => h[20].to_int()
    None => 0
  }
  let w : PageWriter = { page_size, usable: page_size - reserved, pages: [], }
  ignore(w.alloc()) // page 1
  // schema objects in order
  let objs : Array[(Int, SchemaObj)] = []
  for _, t in self.tables {
    objs.push((t.schema_seq, OTable(t)))
    for idx in t.indexes {
      objs.push((idx.seq, OIndex(t, idx)))
    }
  }
  if self.sequence_seq > 0 {
    objs.push((self.sequence_seq, OSeq))
  }
  for _, v in self.views {
    objs.push((v.schema_seq, OView(v)))
  }
  objs.sort_by((a, b) => a.0 - b.0)
  let roots = objs.map(o => {
    match o.1 {
      OView(_) => 0
      _ => w.alloc()
    }
  })
  let schema : Array[Array[Value]] = []
  for i, o in objs {
    let root = roots[i]
    match o.1 {
      OTable(t) => {
        let entries : Array[(Int64, Bytes)] = []
        let ipk = t.ipk
        t.rows.each_while((rowid, vals) => {
          let rec = if ipk >= 0 {
            let c = vals.copy()
            c[ipk] = Null
            c
          } else {
            vals
          }
          entries.push((rowid, encode_record(rec)))
          true
        })
        w.build_table(root, entries)
        schema.push([
          Text("table"),
          Text(t.name),
          Text(t.name),
          Int(root.to_int64()),
          Text(t.sql),
        ])
      }
      OIndex(t, idx) => {
        let recs : Array[Bytes] = []
        idx.entries.each_while((k, _) => {
          recs.push(encode_record(k))
          true
        })
        w.build_index(root, recs)
        schema.push([
          Text("index"),
          Text(idx.name),
          Text(t.name),
          Int(root.to_int64()),
          match idx.sql {
            Some(s) => Text(s)
            None => Null
          },
        ])
      }
      OSeq => {
        let entries : Array[(Int64, Bytes)] = []
        for i, r in self.sequence_rows() {
          entries.push(((i + 1).to_int64(), encode_record(r)))
        }
        w.build_table(root, entries)
        schema.push([
          Text("table"),
          Text("sqlite_sequence"),
          Text("sqlite_sequence"),
          Int(root.to_int64()),
          Text("CREATE TABLE sqlite_sequence(name,seq)"),
        ])
      }
      OView(v) =>
        schema.push([
          Text("view"),
          Text(v.name),
          Text(v.name),
          Int(0L),
          Text(v.sql),
        ])
    }
  }
  let sentries : Array[(Int64, Bytes)] = []
  for i, r in schema {
    sentries.push(((i + 1).to_int64(), encode_record(r)))
  }
  w.build_table(1, sentries)
  // header
  let npages = w.pages.length()
  let p1 = w.pages[0]
  p1.blit_from_bytesview(0, b"SQLite format 3\x00"[:])
  put_u16(p1, 16, if page_size == 65536 { 1 } else { page_size })
  p1[18] = b'\x01'
  p1[19] = b'\x01'
  p1[20] = reserved.to_byte()
  p1[21] = b'\x40'
  p1[22] = b'\x20'
  p1[23] = b'\x20'
  let (counter, cookie) = match old {
    Some(h) => {
      let c = get_u32(h, 24) + 1
      let k = get_u32(h, 40)
      (c, if schema_sig(schema) != self.file_schema_sig { k + 1 } else { k })
    }
    None => (1, if schema.length() > 0 { 1 } else { 0 })
  }
  put_u32(p1, 24, counter)
  put_u32(p1, 28, npages)
  put_u32(p1, 32, 0)
  put_u32(p1, 36, 0)
  put_u32(p1, 40, cookie)
  put_u32(p1, 44, 4)
  match old {
    Some(h) => {
      put_u32(p1, 48, get_u32(h, 48))
      put_u32(p1, 60, get_u32(h, 60))
      put_u32(p1, 68, get_u32(h, 68))
    }
    None => ()
  }
  put_u32(p1, 52, 0)
  put_u32(p1, 56, 1)
  put_u32(p1, 64, 0)
  put_u32(p1, 92, counter)
  put_u32(p1, 96, 3053003)
  let out = @buffer.Buffer(size_hint=npages * page_size)
  for p in w.pages {
    out.write_bytes(Bytes::from_array(p[:])[:])
  }
  out.to_bytes()
}

///|
/// Called when the script has ended: rolls back an open transaction and
/// writes the database back to `path` if anything may have changed.
pub fn Database::finish_file(
  self : Database,
  path : String,
  existed : Bool,
) -> Unit {
  if self.in_txn {
    if self.txn_snap is Some(s) {
      self.restore(s)
    }
    self.end_txn()
  }
  if self.load_failed {
    return
  }
  if !self.dirty {
    if !existed {
      ignore(@io.write_file(path, b""))
    }
    return
  }
  let data = self.to_file_bytes()
  ignore(@io.write_file(path, data))
}
