// An ordered map (AVL tree) with a caller-supplied key comparison.

///|
priv enum Node[K, V] {
  Leaf
  Branch(Node[K, V], K, V, Node[K, V], Int)
}

///|
pub struct OrdMap[K, V] {
  priv cmp : (K, K) -> Int
  priv mut root : Node[K, V]
  priv mut size : Int
}

///|
pub fn[K, V] OrdMap::new(cmp : (K, K) -> Int) -> OrdMap[K, V] {
  { cmp, root: Leaf, size: 0, }
}

///|
pub fn[K, V] OrdMap::length(self : OrdMap[K, V]) -> Int {
  self.size
}

///|
fn[K, V] height(n : Node[K, V]) -> Int {
  match n {
    Leaf => 0
    Branch(_, _, _, _, h) => h
  }
}

///|
fn[K, V] mk(l : Node[K, V], k : K, v : V, r : Node[K, V]) -> Node[K, V] {
  let hl = height(l)
  let hr = height(r)
  Branch(l, k, v, r, if hl > hr { hl + 1 } else { hr + 1 })
}

///|
fn[K, V] balance(l : Node[K, V], k : K, v : V, r : Node[K, V]) -> Node[K, V] {
  let hl = height(l)
  let hr = height(r)
  if hl > hr + 1 {
    match l {
      Branch(ll, lk, lv, lr, _) =>
        if height(ll) >= height(lr) {
          mk(ll, lk, lv, mk(lr, k, v, r))
        } else {
          match lr {
            Branch(lrl, lrk, lrv, lrr, _) =>
              mk(mk(ll, lk, lv, lrl), lrk, lrv, mk(lrr, k, v, r))
            Leaf => mk(l, k, v, r)
          }
        }
      Leaf => mk(l, k, v, r)
    }
  } else if hr > hl + 1 {
    match r {
      Branch(rl, rk, rv, rr, _) =>
        if height(rr) >= height(rl) {
          mk(mk(l, k, v, rl), rk, rv, rr)
        } else {
          match rl {
            Branch(rll, rlk, rlv, rlr, _) =>
              mk(mk(l, k, v, rll), rlk, rlv, mk(rlr, rk, rv, rr))
            Leaf => mk(l, k, v, r)
          }
        }
      Leaf => mk(l, k, v, r)
    }
  } else {
    mk(l, k, v, r)
  }
}

///|
pub fn[K, V] OrdMap::get(self : OrdMap[K, V], key : K) -> V? {
  let mut n = self.root
  while n is Branch(l, k, v, r, _) {
    let c = (self.cmp)(key, k)
    if c == 0 {
      return Some(v)
    }
    n = if c < 0 { l } else { r }
  }
  None
}

///|
pub fn[K, V] OrdMap::contains(self : OrdMap[K, V], key : K) -> Bool {
  self.get(key) is Some(_)
}

///|
pub fn[K, V] OrdMap::set(self : OrdMap[K, V], key : K, val : V) -> Unit {
  let cmp = self.cmp
  let mut added = false
  fn ins(n : Node[K, V]) -> Node[K, V] {
    match n {
      Leaf => {
        added = true
        Branch(Leaf, key, val, Leaf, 1)
      }
      Branch(l, k, v, r, h) => {
        let c = cmp(key, k)
        if c == 0 {
          Branch(l, key, val, r, h)
        } else if c < 0 {
          balance(ins(l), k, v, r)
        } else {
          balance(l, k, v, ins(r))
        }
      }
    }
  }

  self.root = ins(self.root)
  if added {
    self.size += 1
  }
}

///|
fn[K, V] remove_min(n : Node[K, V]) -> (Node[K, V], K, V)? {
  match n {
    Leaf => None
    Branch(Leaf, k, v, r, _) => Some((r, k, v))
    Branch(l, k, v, r, _) =>
      match remove_min(l) {
        Some((l2, mk_, mv)) => Some((balance(l2, k, v, r), mk_, mv))
        None => None
      }
  }
}

///|
pub fn[K, V] OrdMap::remove(self : OrdMap[K, V], key : K) -> Unit {
  let cmp = self.cmp
  let mut removed = false
  fn del(n : Node[K, V]) -> Node[K, V] {
    match n {
      Leaf => Leaf
      Branch(l, k, v, r, _) => {
        let c = cmp(key, k)
        if c == 0 {
          removed = true
          match remove_min(r) {
            None => l
            Some((r2, sk, sv)) => balance(l, sk, sv, r2)
          }
        } else if c < 0 {
          balance(del(l), k, v, r)
        } else {
          balance(l, k, v, del(r))
        }
      }
    }
  }

  self.root = del(self.root)
  if removed {
    self.size -= 1
  }
}

///|
pub fn[K, V] OrdMap::clear(self : OrdMap[K, V]) -> Unit {
  self.root = Leaf
  self.size = 0
}

///|
pub fn[K, V] OrdMap::min(self : OrdMap[K, V]) -> (K, V)? {
  let mut n = self.root
  let mut best = None
  while n is Branch(l, k, v, _, _) {
    best = Some((k, v))
    n = l
  }
  best
}

///|
pub fn[K, V] OrdMap::max(self : OrdMap[K, V]) -> (K, V)? {
  let mut n = self.root
  let mut best = None
  while n is Branch(_, k, v, r, _) {
    best = Some((k, v))
    n = r
  }
  best
}

///|
/// Visits entries in key order until `f` returns false.
pub fn[K, V] OrdMap::each_while(
  self : OrdMap[K, V],
  f : (K, V) -> Bool raise?,
) -> Unit raise? {
  fn go(n : Node[K, V]) -> Bool raise? {
    match n {
      Leaf => true
      Branch(l, k, v, r, _) => go(l) && f(k, v) && go(r)
    }
  }

  ignore(go(self.root))
}

///|
/// Visits entries with key >= `lo` in key order until `f` returns false.
pub fn[K, V] OrdMap::each_from(
  self : OrdMap[K, V],
  lo : K,
  f : (K, V) -> Bool raise?,
) -> Unit raise? {
  let cmp = self.cmp
  // `check`: the subtree may hold keys below `lo`
  fn go(n : Node[K, V], check : Bool) -> Bool raise? {
    match n {
      Leaf => true
      Branch(l, k, v, r, _) =>
        if check && cmp(k, lo) < 0 {
          go(r, true)
        } else {
          go(l, check) && f(k, v) && go(r, false)
        }
    }
  }

  ignore(go(self.root, true))
}

///|
/// Visits entries in descending key order until `f` returns false.
pub fn[K, V] OrdMap::each_rev_while(
  self : OrdMap[K, V],
  f : (K, V) -> Bool raise?,
) -> Unit raise? {
  fn go(n : Node[K, V]) -> Bool raise? {
    match n {
      Leaf => true
      Branch(l, k, v, r, _) => go(r) && f(k, v) && go(l)
    }
  }

  ignore(go(self.root))
}

///|
pub fn[K, V] OrdMap::to_array(self : OrdMap[K, V]) -> Array[(K, V)] {
  let out = []
  self.each_while((k, v) => {
    out.push((k, v))
    true
  })
  out
}

///|
pub fn[K, V] OrdMap::values(self : OrdMap[K, V]) -> Array[V] {
  let out = []
  self.each_while((_, v) => {
    out.push(v)
    true
  })
  out
}

///|
/// An independent copy sharing the (immutable) tree nodes: O(1).
pub fn[K, V] OrdMap::copy(self : OrdMap[K, V]) -> OrdMap[K, V] {
  { cmp: self.cmp, root: self.root, size: self.size, }
}

///|
/// Visits, in key order, the entries whose key `k` satisfies
/// `probe(k) <= 0` (i.e. the probe does not sort after `k`), until `f`
/// returns false. `probe` must be monotonic in the key order.
pub fn[K, V] OrdMap::each_ge(
  self : OrdMap[K, V],
  probe : (K) -> Int,
  f : (K, V) -> Bool raise?,
) -> Unit raise? {
  fn go(n : Node[K, V], check : Bool) -> Bool raise? {
    match n {
      Leaf => true
      Branch(l, k, v, r, _) =>
        if check && probe(k) > 0 {
          go(r, true)
        } else {
          go(l, check) && f(k, v) && go(r, false)
        }
    }
  }

  ignore(go(self.root, true))
}

///|
/// Visits entries with key <= `hi` in descending key order until `f`
/// returns false.
pub fn[K, V] OrdMap::each_le_rev(
  self : OrdMap[K, V],
  hi : K,
  f : (K, V) -> Bool raise?,
) -> Unit raise? {
  let cmp = self.cmp
  fn go(n : Node[K, V], check : Bool) -> Bool raise? {
    match n {
      Leaf => true
      Branch(l, k, v, r, _) =>
        if check && cmp(k, hi) > 0 {
          go(l, true)
        } else {
          go(r, check) && f(k, v) && go(l, false)
        }
    }
  }

  ignore(go(self.root, true))
}

///|
/// Visits, in descending key order, the entries whose key `k` satisfies
/// `probe(k) >= 0` (the probe does not sort before `k`), until `f` returns
/// false.
pub fn[K, V] OrdMap::each_le_by(
  self : OrdMap[K, V],
  probe : (K) -> Int,
  f : (K, V) -> Bool raise?,
) -> Unit raise? {
  fn go(n : Node[K, V], check : Bool) -> Bool raise? {
    match n {
      Leaf => true
      Branch(l, k, v, r, _) =>
        if check && probe(k) < 0 {
          go(l, true)
        } else {
          go(r, check) && f(k, v) && go(l, false)
        }
    }
  }

  ignore(go(self.root, true))
}
