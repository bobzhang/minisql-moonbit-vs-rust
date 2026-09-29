///|
/// An ordered map stored as a list of sorted chunks. Lookups are binary
/// searches over arrays, and scans run in either direction with early exit.
pub struct SortedChunks[K, V] {
  priv chunks : Array[Array[(K, V)]]
  priv mut size : Int
}

///|
let chunk_limit : Int = 1024

///|
pub fn[K, V] SortedChunks::new() -> SortedChunks[K, V] {
  { chunks: [], size: 0, }
}

///|
pub fn[K, V] SortedChunks::length(self : SortedChunks[K, V]) -> Int {
  self.size
}

///|
pub fn[K, V] SortedChunks::is_empty(self : SortedChunks[K, V]) -> Bool {
  self.size == 0
}

///|
/// Index of the first chunk whose last key is >= k (the chunk count if
/// there is none).
fn[K : Compare, V] SortedChunks::chunk_for(
  self : SortedChunks[K, V],
  k : K,
) -> Int {
  let mut lo = 0
  let mut hi = self.chunks.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    let c = self.chunks[mid]
    if c[c.length() - 1].0.compare(k) < 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  lo
}

///|
/// Position of the first entry with key >= k.
fn[K : Compare, V] lower_bound(c : Array[(K, V)], k : K) -> Int {
  let mut lo = 0
  let mut hi = c.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if c[mid].0.compare(k) < 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  lo
}

///|
/// Position of the first entry with key > k.
fn[K : Compare, V] upper_bound(c : Array[(K, V)], k : K) -> Int {
  let mut lo = 0
  let mut hi = c.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if c[mid].0.compare(k) <= 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  lo
}

///|
pub fn[K : Compare, V] SortedChunks::get(
  self : SortedChunks[K, V],
  k : K,
) -> V? {
  let i = self.chunk_for(k)
  if i == self.chunks.length() {
    return None
  }
  let c = self.chunks[i]
  let p = lower_bound(c, k)
  if p < c.length() && c[p].0.compare(k) == 0 {
    Some(c[p].1)
  } else {
    None
  }
}

///|
pub fn[K : Compare, V] SortedChunks::contains(
  self : SortedChunks[K, V],
  k : K,
) -> Bool {
  self.get(k) is Some(_)
}

///|
/// Inserts or replaces the entry for `k`.
pub fn[K : Compare, V] SortedChunks::set(
  self : SortedChunks[K, V],
  k : K,
  v : V,
) -> Unit {
  if self.chunks.length() == 0 {
    self.chunks.push([(k, v)])
    self.size = 1
    return
  }
  let mut i = self.chunk_for(k)
  if i == self.chunks.length() {
    i -= 1
  }
  let c = self.chunks[i]
  let p = lower_bound(c, k)
  if p < c.length() && c[p].0.compare(k) == 0 {
    c[p] = (k, v)
    return
  }
  if p == c.length() {
    c.push((k, v))
  } else {
    c.insert(p, (k, v))
  }
  self.size += 1
  if c.length() > chunk_limit {
    let half = c.length() / 2
    let right = c[half:].to_owned()
    c.truncate(half)
    self.chunks.insert(i + 1, right)
  }
}

///|
pub fn[K : Compare, V] SortedChunks::remove(
  self : SortedChunks[K, V],
  k : K,
) -> Unit {
  let i = self.chunk_for(k)
  if i == self.chunks.length() {
    return
  }
  let c = self.chunks[i]
  let p = lower_bound(c, k)
  if p < c.length() && c[p].0.compare(k) == 0 {
    c.remove(p) |> ignore
    self.size -= 1
    if c.length() == 0 {
      self.chunks.remove(i) |> ignore
    }
  }
}

///|
/// The largest key.
pub fn[K, V] SortedChunks::max_key(self : SortedChunks[K, V]) -> K? {
  match self.chunks.last() {
    Some(c) => Some(c[c.length() - 1].0)
    None => None
  }
}

///|
/// All entries in ascending key order.
pub fn[K, V] SortedChunks::iter2(self : SortedChunks[K, V]) -> Iter2[K, V] {
  let mut ci = 0
  let mut pi = 0
  Iter2::new(() => {
    while ci < self.chunks.length() {
      let c = self.chunks[ci]
      if pi < c.length() {
        let e = c[pi]
        pi += 1
        return Some(e)
      }
      ci += 1
      pi = 0
    }
    None
  })
}

///|
/// Calls `f` on the entries with lo <= key <= hi (missing bounds are open),
/// in ascending order or descending if `rev`, until `f` returns false.
pub fn[K : Compare, V] SortedChunks::scan(
  self : SortedChunks[K, V],
  lo : K?,
  hi : K?,
  rev : Bool,
  f : (K, V) -> Bool raise?,
) -> Unit raise? {
  let n = self.chunks.length()
  if n == 0 {
    return
  }
  if !rev {
    let (ci0, pi0) = match lo {
      Some(k) => {
        let i = self.chunk_for(k)
        if i == n {
          return
        }
        (i, lower_bound(self.chunks[i], k))
      }
      None => (0, 0)
    }
    let mut ci = ci0
    let mut pi = pi0
    while ci < n {
      let c = self.chunks[ci]
      while pi < c.length() {
        let e = c[pi]
        if hi is Some(h) && e.0.compare(h) > 0 {
          return
        }
        if !f(e.0, e.1) {
          return
        }
        pi += 1
      }
      ci += 1
      pi = 0
    }
  } else {
    // Start at the last entry <= hi.
    let (ci0, pi0) = match hi {
      Some(k) => {
        let i = self.chunk_for(k)
        if i == n {
          (n - 1, self.chunks[n - 1].length() - 1)
        } else {
          (i, upper_bound(self.chunks[i], k) - 1)
        }
      }
      None => (n - 1, self.chunks[n - 1].length() - 1)
    }
    let mut ci = ci0
    let mut pi = pi0
    while ci >= 0 {
      let c = self.chunks[ci]
      while pi >= 0 {
        let e = c[pi]
        if lo is Some(l) && e.0.compare(l) < 0 {
          return
        }
        if !f(e.0, e.1) {
          return
        }
        pi -= 1
      }
      ci -= 1
      if ci >= 0 {
        pi = self.chunks[ci].length() - 1
      }
    }
  }
}
