// Persistent (immutable) AVL tree map with a custom comparator.
// Updates return a new map and leave the old one intact, so snapshots for
// statement rollback are free.

///|
priv enum Node[K, V] {
  Nil
  N(Node[K, V], K, V, Node[K, V], Int, Int) // left, key, val, right, height, size
}

///|
priv struct PMap[K, V] {
  root : Node[K, V]
  cmp : (K, K) -> Int
}

///|
fn[K, V] PMap::empty(cmp : (K, K) -> Int) -> PMap[K, V] {
  { root: Nil, cmp, }
}

///|
fn[K, V] node_height(n : Node[K, V]) -> Int {
  match n {
    Nil => 0
    N(_, _, _, _, h, _) => h
  }
}

///|
fn[K, V] node_size(n : Node[K, V]) -> Int {
  match n {
    Nil => 0
    N(_, _, _, _, _, s) => s
  }
}

///|
fn[K, V] mk_node(l : Node[K, V], k : K, v : V, r : Node[K, V]) -> Node[K, V] {
  let hl = node_height(l)
  let hr = node_height(r)
  N(
    l,
    k,
    v,
    r,
    (if hl > hr { hl } else { hr }) + 1,
    node_size(l) + node_size(r) + 1,
  )
}

///|
fn[K, V] balance(l : Node[K, V], k : K, v : V, r : Node[K, V]) -> Node[K, V] {
  let hl = node_height(l)
  let hr = node_height(r)
  if hl > hr + 1 {
    guard l is N(ll, lk, lv, lr, _, _) else { abort("avl") }
    if node_height(ll) >= node_height(lr) {
      mk_node(ll, lk, lv, mk_node(lr, k, v, r))
    } else {
      guard lr is N(lrl, lrk, lrv, lrr, _, _) else { abort("avl") }
      mk_node(mk_node(ll, lk, lv, lrl), lrk, lrv, mk_node(lrr, k, v, r))
    }
  } else if hr > hl + 1 {
    guard r is N(rl, rk, rv, rr, _, _) else { abort("avl") }
    if node_height(rr) >= node_height(rl) {
      mk_node(mk_node(l, k, v, rl), rk, rv, rr)
    } else {
      guard rl is N(rll, rlk, rlv, rlr, _, _) else { abort("avl") }
      mk_node(mk_node(l, k, v, rll), rlk, rlv, mk_node(rlr, rk, rv, rr))
    }
  } else {
    mk_node(l, k, v, r)
  }
}

///|
fn[K, V] node_insert(
  n : Node[K, V],
  k : K,
  v : V,
  cmp : (K, K) -> Int,
) -> Node[K, V] {
  match n {
    Nil => N(Nil, k, v, Nil, 1, 1)
    N(l, nk, nv, r, h, s) => {
      let c = cmp(k, nk)
      if c < 0 {
        balance(node_insert(l, k, v, cmp), nk, nv, r)
      } else if c > 0 {
        balance(l, nk, nv, node_insert(r, k, v, cmp))
      } else {
        N(l, k, v, r, h, s)
      }
    }
  }
}

///|
fn[K, V] node_remove_min(n : Node[K, V]) -> (K, V, Node[K, V]) {
  guard n is N(l, k, v, r, _, _) else { abort("avl") }
  match l {
    Nil => (k, v, r)
    _ => {
      let (mk, mv, l2) = node_remove_min(l)
      (mk, mv, balance(l2, k, v, r))
    }
  }
}

///|
fn[K, V] node_remove(n : Node[K, V], k : K, cmp : (K, K) -> Int) -> Node[K, V] {
  match n {
    Nil => Nil
    N(l, nk, nv, r, _, _) => {
      let c = cmp(k, nk)
      if c < 0 {
        balance(node_remove(l, k, cmp), nk, nv, r)
      } else if c > 0 {
        balance(l, nk, nv, node_remove(r, k, cmp))
      } else {
        match r {
          Nil => l
          _ => {
            let (mk, mv, r2) = node_remove_min(r)
            balance(l, mk, mv, r2)
          }
        }
      }
    }
  }
}

///|
fn[K, V] PMap::add(self : PMap[K, V], k : K, v : V) -> PMap[K, V] {
  { root: node_insert(self.root, k, v, self.cmp), cmp: self.cmp, }
}

///|
fn[K, V] PMap::remove(self : PMap[K, V], k : K) -> PMap[K, V] {
  { root: node_remove(self.root, k, self.cmp), cmp: self.cmp, }
}

///|
fn[K, V] PMap::find(self : PMap[K, V], k : K) -> V? {
  let mut n = self.root
  while n is N(l, nk, nv, r, _, _) {
    let c = (self.cmp)(k, nk)
    if c < 0 {
      n = l
    } else if c > 0 {
      n = r
    } else {
      return Some(nv)
    }
  }
  None
}

///|
fn[K, V] PMap::length(self : PMap[K, V]) -> Int {
  node_size(self.root)
}

///|
fn[K, V] PMap::max_key(self : PMap[K, V]) -> K? {
  let mut n = self.root
  let mut best : K? = None
  while n is N(_, k, _, r, _, _) {
    best = Some(k)
    n = r
  }
  best
}

///|
/// Visit entries with key >= lo (all if None) in ascending order until
/// `f` returns false.
fn[K, V] PMap::each_from(
  self : PMap[K, V],
  lo : K?,
  f : (K, V) -> Bool,
) -> Unit {
  fn go(n : Node[K, V]) -> Bool {
    match n {
      Nil => true
      N(l, k, v, r, _, _) => {
        let inside = match lo {
          Some(b) => (self.cmp)(k, b) >= 0
          None => true
        }
        if inside {
          if !go(l) {
            return false
          }
          if !f(k, v) {
            return false
          }
        }
        go(r)
      }
    }
  }

  ignore(go(self.root))
}

///|
/// Visit entries with key <= hi (all if None) in descending order until
/// `f` returns false.
fn[K, V] PMap::each_rev_from(
  self : PMap[K, V],
  hi : K?,
  f : (K, V) -> Bool,
) -> Unit {
  fn go(n : Node[K, V]) -> Bool {
    match n {
      Nil => true
      N(l, k, v, r, _, _) => {
        let inside = match hi {
          Some(b) => (self.cmp)(k, b) <= 0
          None => true
        }
        if inside {
          if !go(r) {
            return false
          }
          if !f(k, v) {
            return false
          }
        }
        go(l)
      }
    }
  }

  ignore(go(self.root))
}

///|
fn[K, V] PMap::to_array(self : PMap[K, V]) -> Array[(K, V)] {
  let out : Array[(K, V)] = Array(capacity=self.length())
  self.each_from(None, (k, v) => {
    out.push((k, v))
    true
  })
  out
}

///|
test "pmap" {
  let mut m : PMap[Int, Int] = PMap::empty((a, b) => a - b)
  for i in 0..<1000 {
    m = m.add(i * 7919 % 1000, i)
  }
  let old = m
  for i in 0..<500 {
    m = m.remove(i * 2)
  }
  inspect(m.length(), content="500")
  inspect(old.length(), content="1000")
  debug_inspect(m.max_key(), content="Some(999)")
  let ks : Array[Int] = []
  m.each_from(Some(10), (k, _) => {
    ks.push(k)
    ks.length() < 3
  })
  debug_inspect(ks, content="[11, 13, 15]")
  let rs : Array[Int] = []
  m.each_rev_from(Some(10), (k, _) => {
    rs.push(k)
    rs.length() < 3
  })
  debug_inspect(rs, content="[9, 7, 5]")
}
