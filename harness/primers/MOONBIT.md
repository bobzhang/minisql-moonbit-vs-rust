# MoonBit primer

Verified against `moon 0.1.20260920` (native). Much remembered MoonBit syntax is stale; when this primer and memory disagree, trust the primer and `moon ide doc`.

## 1. Toolchain and project layout

Run `moon` from the module root (the directory with `moon.mod`). `preferred_target = "native"` is set, so no `--target` flag is needed.

| Task | Command |
|---|---|
| Type-check (fast; after every edit) | `moon check` (`--diagnostic-limit 10` to cut noise) |
| Release build | `moon build --release` → `_build/native/release/build/cmd/main/main.exe` |
| Run with stack traces on panic | `moon run cmd/main < input.txt` (debug build) |
| Test | `moon test` · `moon test -p bench/minisql/util` · `-F 'name*'` filter · `-u` fill/refresh snapshots |
| Format | `moon fmt` |
| API lookup (types, methods, packages; `*` globs) | `moon ide doc "String::*find*"` · `moon ide doc "@sorted_map"` |
| Navigate your code | `moon ide outline util` · `moon ide peek-def Foo::bar` · `moon ide find-references Foo` |

A panicking release binary exits with status 134 and prints nothing; rerun via `moon run` for a backtrace.

**Packages.** A package is a directory with a `moon.pkg` file; all its `.mbt` files share one namespace (file names and declaration order do not matter). Import path = `<module>/<dir>`, e.g. `bench/minisql/util`. Template contents:
- `io/`: harness I/O; do not modify. `@io.read_stdin() -> String`, `@io.write_stdout(String)`, `@io.flush_stdout()`, `@io.args() -> Array[String]`, `@io.read_file(String) -> Bytes?`, `@io.write_file(String, Bytes) -> Bool`. All program I/O goes through it (`println` only in tests).
- `cmd/main/`: the executable (`pkgtype(kind: "executable")`, `fn main { ... }` without parentheses).

To add a package: create `util/moon.pkg` plus `.mbt` files and list `"bench/minisql/util"` in the importer's `moon.pkg`. No import cycles. Core packages outside the prelude must be imported too (else warning 0071), e.g.:

```
import {
  "bench/minisql/util",
  "moonbitlang/core/math",
  "moonbitlang/core/string",
}

warnings = "-implicit_impl_as_method"
```

The optional `warnings` line silences warning 0079, which this toolchain emits for every `derive(...)` on a non-`priv` type. Import names: `string`, `math`, `int`, `int64`, `double`, `buffer`, `encoding/utf8`, `hashmap`, `hashset`, `sorted_map`, `sorted_set`, `deque`, `priority_queue`; `Map`, `Set`, `Array`, `FixedArray`, `Bytes`, `StringBuilder`, `Ref` need none.

Refer to another package's items as `@util.f(x)`, `@util.Type`, `@util.Type::func()`; methods (`v.m()`) and enum constructors with a known expected type need no prefix. Only `pub` items are exported.

**Tests.** `test "name" { ... }` may appear in any `.mbt` file. `*_test.mbt` files are black-box (use `@util.` and `pub` items only); `*_wbtest.mbt` and ordinary files see private items. Snapshots: `inspect(v, content="")`, then `moon test -u` fills it in (not inside loops: `-u` can then loop forever). `inspect` needs `Show` (numbers, String, Bool); use `debug_inspect` for `Option`, `Array`, tuples and `derive(Debug)` types. Also `assert_eq(a, b)`, `assert_true(c)`, `fail("msg")`.

**Errors.** `Error: [4014]` + `file:line:col` + `has type : X / wanted : Y`; `moon explain --diagnostic 4014` describes a code. Parse errors (`[3002]`) often point just past the real mistake. Warnings do not fail the build; `Warning (deprecated)` names the replacement API.

## 2. Language essentials

Every top-level item starts with a `///|` line. Blocks are expressions whose last expression is the value (`return` exits early). No `;`. `let` is immutable; `let mut` allows rebinding a local. Arrays, maps and `mut` fields mutate through a plain `let`. Parameters cannot be `mut`. No `++`/`--`; use `+=`.

```moonbit
///|
pub(all) struct Point {
  x : Int
  mut y : Int // only `mut` fields can be assigned
} derive(Eq, Hash, Debug)

///|
/// A function named `T::T` is callable as `Point(1, 2)`.
fn Point::Point(x : Int, y : Int) -> Point {
  { x, y } // struct literal; `Point::{ x, y }` when the type is not known
}

///|
/// Methods take an explicit `self`; call as `p.moved(1)`.
fn Point::moved(self : Point, dx : Int) -> Point {
  { ..self, x: self.x + dx } // functional update
}

///|
pub(all) enum Shape {
  Circle(Double)
  Rect(w~ : Double, h~ : Double) // labelled payload
  Empty
} derive(Eq, Debug)

///|
fn Shape::area(self : Shape) -> Double {
  match self {
    Circle(r) => 3.0 * r * r
    Rect(w~, h~) => w * h // `w~` binds field w to variable w
    Empty => 0.0
  }
}

///|
test "structs and enums" {
  let p = Point(1, 2)
  p.y = 5
  let q = p.moved(3)
  assert_true(p != q)
  debug_inspect(q, content="{ x: 4, y: 5 }")
  inspect(Rect(w=2.0, h=3.0).area(), content="6")
  let (n, s) = (1, "one") // tuples: t.0, t.1, or destructure
  inspect("\{n}:\{s}", content="1:one")
}
```

**Visibility**: package-private by default; `priv` = fully hidden; `pub struct/enum` = readable and matchable outside, not constructible; `pub(all)` = also constructible; `pub trait` = usable outside; `pub(open) trait` = implementable outside.

```moonbit
///|
/// `width~` required labelled; `fill?` has a default; `note?` (no default) is `String?` inside.
fn pad_left(s : String, width~ : Int, fill? : Char = ' ', note? : String) -> String {
  let body = if s.length() >= width { s } else { String::make(width - s.length(), fill) + s }
  match note {
    Some(t) => body + t
    None => body
  }
}

///|
fn[T : Compare] largest(xs : Array[T]) -> T? { // generic with trait bound
  let mut best : T? = None
  for x in xs {
    match best {
      Some(b) if b >= x => ()
      _ => best = Some(x)
    }
  }
  best
}

///|
test "functions" {
  let width = 4
  inspect(pad_left("7", width~), content="   7") // `width~` = `width=width`
  inspect(pad_left("7", width=3, fill='0', note="!"), content="007!")
  let double = (x : Int) => x * 2 // closure; `fn(x : Int) { x * 2 }` also works
  let mut total = 0
  [1, 2, 3].each(x => total += double(x)) // closures may mutate captured `let mut`
  inspect(total, content="12")
  debug_inspect([3, 9, 2] |> largest, content="Some(9)") // x |> f == f(x)
  let r = [1, 2, 3].map(x => x * 10).filter(x => x > 10)
  debug_inspect(r, content="[20, 30]")
}
```

**Pattern matching.** `match` must be exhaustive (else compile error 0011). String literals are patterns too (`"a" | "b" => ...`). Lowercase names in patterns always bind; they never compare with an existing variable.

```moonbit
///|
fn classify(c : Char) -> String {
  match c {
    'a'..='z' | 'A'..='Z' | '_' => "word"
    '0'..='9' => "digit"
    ' ' | '\t' | '\n' => "space"
    _ => "other"
  }
}

///|
fn head_word(s : StringView) -> (String, StringView) {
  match s {
    [.. "let ", .. rest] => ("let", rest) // literal prefix on a StringView
    [c, .. rest] if c.is_ascii_digit() => ("digit", rest) // c : Char, with guard
    [] => ("", s)
    _ => ("?", s)
  }
}

///|
test "patterns" {
  inspect(classify('x'), content="word")
  let (w, rest) = head_word("let x")
  inspect("\{w}/\{rest}", content="let/x")
  match [1, 2, 3, 4] {
    [first, .. middle, last] => inspect(first + middle.length() + last, content="7")
    _ => ()
  }
  let opt : Int? = Some(4)
  if opt is Some(v) && v > 3 { // `is` tests a pattern; bindings flow into && and the body
    inspect(v, content="4")
  }
  guard opt is Some(n) else { fail("none") } // early exit; `n` is bound afterwards
  inspect(n, content="4")
}
```

**Errors.** Signatures declare `raise E` (or bare `raise` = any error). Inside a raising function, a plain call propagates; there is no `?`, `!` or `try` marker.

```moonbit
///|
suberror AppError {
  BadInput(String)
  OutOfRange(pos~ : Int)
} derive(Debug)

///|
fn check_pos(x : Int) -> Int raise AppError {
  if x < 0 {
    raise OutOfRange(pos=x)
  }
  if x > 100 {
    raise BadInput("too big: \{x}")
  }
  x
}

///|
fn doubled(x : Int) -> Int raise { // bare `raise`: any Error
  if x == 0 {
    fail("zero") // raises Failure; its message gets a source-location prefix
  }
  check_pos(x) * 2 // propagates automatically
}

///|
test "errors" {
  let a = check_pos(-1) catch { // `expr catch { pattern => value }`
    OutOfRange(pos~) => pos
    BadInput(_) => 0
  }
  inspect(a, content="-1")
  let msg = try doubled(200) catch {
    BadInput(m) => m
    err => "other: \{Repr(err)}" // Repr(x) renders any Debug value
  } noraise {
    v => "ok \{v}" // only when nothing was raised
  }
  inspect(msg, content="too big: 200")
  let r : Result[Int, Error] = try doubled(3) |> Ok catch { e => Err(e) }
  debug_inspect(r, content="Ok(6)")
  inspect(try! check_pos(5), content="5") // try! aborts the program on error
}
```

**Loops** are expressions: `break value`, `nobreak { value }`. Labelled loops: `outer~: for x in xs { ... break outer~ ... }` (also `continue outer~`).

```moonbit
///|
test "loops" {
  let out : Array[Int] = []
  for i in 0..<3 { out.push(i) } // 0 1 2    (0..=3 is inclusive)
  for i in 3>..0 { out.push(i) } // 2 1 0    (descending)
  for i in 3>=..1 { out.push(i) } // 3 2 1
  for i = 0; i < 6; i = i + 2 { out.push(i) } // C style; `for ;; { }` loops forever
  debug_inspect(out, content="[0, 1, 2, 2, 1, 0, 3, 2, 1, 0, 2, 4]")
  for i, x in ["a", "b"] { ignore((i, x)) } // index + element; `for k, v in map`
  let sum = for i = 0, acc = 0 { // functional for: `continue` rebinds, `break` returns
    if i > 4 {
      break acc
    }
    continue i + 1, acc + i
  }
  inspect(sum, content="10")
  let mut j = 0
  let found = while j < out.length() {
    if out[j] == 3 {
      break Some(j)
    }
    j += 1
  } nobreak {
    None
  }
  debug_inspect(found, content="Some(6)")
}
```

**Traits, `Show`, globals.** Type alias: `type Ids = Array[Int]`. Newtype: `struct Meters(Double)`, unwrap with `m.0`.

```moonbit
///|
priv trait Named {
  name(Self) -> String
  greet(Self) -> String = _ // `= _`: a default implementation exists
}

///|
impl Named with greet(self) { // the default
  "hi " + self.name()
}

///|
impl Named for Point with name(self) {
  "P(\{self.x})"
}

///|
impl Show for Shape with output(self, logger) { // enables "\{shape}"
  logger.write_string(
    match self {
      Circle(_) => "circle"
      Rect(..) => "rect"
      Empty => "empty"
    },
  )
}

///|
let next_id : Ref[Int] = { val: 0 } // globals are immutable; mutate through Ref/struct/Array/Map

///|
fn fresh_id() -> Int {
  next_id.val += 1
  next_id.val
}

///|
test "traits and state" {
  let p = Point(7, 0)
  inspect(Named::greet(p), content="hi P(7)") // call trait methods as Trait::m(x)
  let items : Array[&Named] = [p] // trait object
  inspect(items[0].greet(), content="hi P(7)")
  inspect("\{Rect(w=1.0, h=1.0)}", content="rect")
  inspect(fresh_id() + fresh_id(), content="3")
}
```

Manual ordering: `impl Compare for T with compare(self, other) { ... }` (return <0, 0, >0; also implement or derive `Eq`). Derivable: `Eq`, `Compare` (declaration order), `Hash` (Map/Set keys, with Eq), `Debug` (`debug_inspect`, `Repr(x)`), `Default` (`let c : T = Default::default()`). `derive(Show)` is deprecated; implement `Show` by hand for display text.

## 3. Core library cheat sheet

All names checked with `moon ide doc`.

### String (immutable, UTF-16)

`s.length()` counts UTF-16 **code units**; `s[i]` is a `UInt16` code unit (O(1)); `s.get_char(i) -> Char?`; `s.char_length()` counts code points. `for c in s` yields `Char`; in `for i, c in s`, `i` is the char index, not a code-unit offset.

- Views: `s[a:b]`, `s[a:]`, `s[:]` → `StringView` (zero-copy, code-unit offsets, clamped, never splits a surrogate pair). `view.to_owned() -> String` (`to_string()` on views is deprecated). A `StringView` parameter accepts a `String` or literal; `view == "lit"` works. Most methods exist on both types.
- Search: `find(StringView) -> Int?`, `rev_find`, `find_by((Char) -> Bool) -> Int?`, `contains`, `contains_char(Char)`, `has_prefix`, `has_suffix`, `strip_prefix(StringView) -> StringView?`, `strip_suffix`.
- Split/trim (return views): `split(StringView) -> Iter[StringView]`, `split_once(StringView) -> (StringView, StringView)?`, `trim(chars?)`, `trim_start`, `trim_end`.
- Build: `a + b`, `"\{x}"` (needs `Show`), `repeat(n)`, `String::make(n, Char)`, `String::from_array(ArrayView[Char])`, `to_array() -> Array[Char]`, `pad_start(n, Char)`, `pad_end`, `replace(old~, new~)`, `replace_all(old~, new~)`.
- Case: `to_lower()`, `to_upper()` (ASCII only), `equal_ignore_ascii_case`, `compare_ignore_ascii_case`.
- Order: `<`/`compare` are **shortlex** (length first: `"b" < "aa"`). Dictionary order: `a.lexical_compare(b) -> Int` (by code unit).
- `StringBuilder()`: `write_string`, `write_char`, `write_view(StringView)`, `to_string()`, `reset()`, `is_empty()`. Prefer it over `+` in loops.
- `@utf8.encode(StringView) -> Bytes`, `@utf8.decode(BytesView) -> String raise`, `@utf8.decode_lossy(BytesView) -> String` (import `encoding/utf8`).

```moonbit
///|
test "strings" {
  let s = "héllo😀!"
  inspect(s.length(), content="8") // 😀 is two code units
  inspect(s.char_length(), content="7")
  inspect(s[0] == 'h', content="true") // UInt16 vs char literal is fine
  debug_inspect(s.get_char(1), content="Some('é')")
  inspect(s[1:3].to_owned().to_upper(), content="éL")
  let parts = "a,b,,c".split(",").map(v => v.to_owned()).to_array()
  debug_inspect(parts, content="[\"a\", \"b\", \"\", \"c\"]")
  inspect("  x y ".trim(), content="x y")
  inspect("b" < "aa", content="true") // shortlex!
  inspect("b".lexical_compare("aa") > 0, content="true")
  let sb = StringBuilder()
  for c in "abc" {
    sb.write_char(c.to_ascii_uppercase())
  }
  sb.write_view("xyz"[1:])
  inspect(sb.to_string(), content="ABCyz")
}
```

### Char

`c.to_int()`, `(97).to_char() -> Char?`, `u16.to_char() -> Char?`, `is_ascii_digit`, `is_ascii_alphabetic`, `is_ascii_whitespace`, `to_ascii_lowercase`, `to_ascii_uppercase`, `to_string`. A `Char` variable cannot be compared with `s[i]` (`UInt16`); use a literal, `s.get_char(i)`, or `c.to_int() == s[i].to_int()`.

### Numbers

- `Int` is **32-bit**. `Int64` (`1L`), `UInt`, `UInt64` (`1UL`), `Byte` (`b'a'`), `Double`. Literals adapt to the expected type (`let x : Int64 = 5`); there is no implicit conversion otherwise.
- Convert: `to_int64()`, `to_double()`, `to_byte()` / `to_int()` (truncate bits), `d.to_int64()` (toward zero, saturating, NaN → 0). Bit casts: `reinterpret_as_uint64()`, `reinterpret_as_int64()`, `reinterpret_as_double()` (Int64/UInt64 ↔ Double, same bits).
- Integer ops wrap on overflow (no checked ops; see snippet). `/` truncates, `%` has the dividend's sign. Division by zero **panics**; `MIN / -1` wraps.
- Bits: `& | ^ << >>` (`>>` arithmetic on signed, logical on unsigned), `lnot()`, `clz()`, `ctz()`, `popcnt()`. Parenthesise mixed `& | ^`.
- Constants: `@int.MAX_VALUE`, `@int64.MIN_VALUE`, `@int64.MAX_VALUE`, `@double.infinity`, `@double.neg_infinity`, `@double.not_a_number`, `@math.PI`.
- Double: `+ - * / %` (fmod), `abs`, `floor`, `ceil`, `trunc`, `round` (half **up**: `(-2.5).round()` is `-2`), `sqrt`, `is_nan`, `is_inf`, `min`, `max`, `signum`. `@math`: `pow`, `exp`, `ln`, `log2`, `log10`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `cbrt`, `hypot`. NaN: `==` is false, `compare` returns 0.
- To text: `"\{d}"` gives shortest round-trip digits, JavaScript style: `100`, `0.1`, `1e+21`, `1e-7`, `NaN`, `Infinity`; `-0.0` prints `0`. `(255).to_string(radix=16)`. No printf.
- From text (import `string`): `@string.parse_int(s, base?) -> Int raise`, `parse_int64`, `parse_uint64`, `parse_double(s) -> Double raise`. They accept a sign, `_` separators, `0x`/`0o`/`0b` prefixes (ints) and `inf`/`nan` (doubles); reject spaces or trailing junk; raise on overflow (even `parse_double("1e400")`). Validate stricter syntax yourself.

```moonbit
///|
/// Overflow-checked Int64 arithmetic (None on overflow).
fn add_checked(a : Int64, b : Int64) -> Int64? {
  let r = a + b
  if ((a ^ r) & (b ^ r)) < 0L { None } else { Some(r) }
}

///|
fn sub_checked(a : Int64, b : Int64) -> Int64? {
  let r = a - b
  if ((a ^ b) & (a ^ r)) < 0L { None } else { Some(r) }
}

///|
fn mul_checked(a : Int64, b : Int64) -> Int64? {
  if a == 0L || b == 0L {
    return Some(0L)
  }
  if (a == -1L && b == @int64.MIN_VALUE) || (b == -1L && a == @int64.MIN_VALUE) {
    return None
  }
  let r = a * b
  if r / b != a { None } else { Some(r) }
}

///|
test "numbers" {
  debug_inspect(add_checked(@int64.MAX_VALUE, 1L), content="None")
  debug_inspect(sub_checked(@int64.MIN_VALUE, 1L), content="None")
  debug_inspect(mul_checked(3037000500L, 3037000500L), content="None")
  inspect(@int64.MAX_VALUE + 1L, content="-9223372036854775808") // wraps
  inspect((5).to_double() / 2.0, content="2.5")
  inspect(@math.pow(2.0, 10.0), content="1024")
  inspect(@string.parse_double("2.5e3"), content="2500")
  let n = @string.parse_int64("12x") catch { _ => -1L }
  inspect(n, content="-1")
  inspect(1.5.reinterpret_as_uint64().reinterpret_as_double(), content="1.5")
  inspect((-8L) >> 1, content="-4")
}
```

### Bytes, FixedArray[Byte], Buffer

- `Bytes` (immutable): `b[i] -> Byte`, `length()`, `b[a:c] -> BytesView`, `Bytes::new(n)` (zeros), `Bytes::make(n, byte)`, `Bytes::from_array(ArrayView[Byte])`, `to_fixedarray()`, `to_array()`, `view.to_owned()`, literals `b"ab\x00"`. `==` compares contents; `<` is shortlex (`lexical_compare` for byte order).
- `FixedArray[Byte]` (mutable, fixed size): `FixedArray::make(n, b'\x00')`, `fa[i] = v`, `fa.blit_from_bytesview(dst_off, view)`, `fa.blit_to(dst, len~, src_offset?, dst_offset?)`, `fa[:]` → `ArrayView[Byte]`.
- `@buffer.Buffer()` (growable): `write_byte`, `write_bytes(BytesView)`, `write_uint16_be`, `write_int_be`, `write_uint_be`, `write_int64_be`, `write_uint64_be`, `write_double_be` (`_le` too), `write_string_utf8`, `length()`, `to_bytes()`.
- Decode with bit patterns on a `BytesView`: `u8be(x)`/`u16be`/`u32be` bind `UInt`, `u64be` binds `UInt64`, `i32be` binds `Int`, `i64be` binds `Int64` (`le` forms too).

```moonbit
///|
test "bytes" {
  let w = @buffer.Buffer()
  w.write_byte(0x01)
  w.write_uint16_be(515)
  w.write_int64_be(-2L)
  w.write_double_be(1.5)
  let data : Bytes = w.to_bytes()
  match data[:] {
    [u8be(tag), u16be(n16), i64be(n64), u64be(bits), .. rest] => {
      let d = bits.reinterpret_as_double()
      inspect("\{tag} \{n16} \{n64} \{d} \{rest.length()}", content="1 515 -2 1.5 0")
    }
    _ => fail("too short")
  }
  let mut acc = 0L // manual big-endian decode
  for i in 3..<11 {
    acc = (acc << 8) | data[i].to_int64()
  }
  inspect(acc, content="-2")
  let fixed = FixedArray::make(4, b'\x00')
  fixed[0] = (0x1FF).to_byte() // keeps low 8 bits
  fixed.blit_from_bytesview(1, data[1:3])
  let frozen = Bytes::from_array(fixed[:])
  debug_inspect(frozen, content="<Bytes: [0xff, 0x02, 0x03, 0x00]>")
  inspect(frozen[0].to_int(), content="255")
}
```

### Array, ArrayView, Iter

Create: `[]`, `[1, 2]`, `Array(capacity=n)`, `Array::make(n, v)`, `Array::makei(n, i => ...)`. Methods: `length`, `a[i]` (panics out of range), `get(i) -> T?`, `push`, `pop() -> T?`, `insert(i, v)`, `remove(i) -> T`, `drain(start, end)`, `truncate(n)`, `clear`, `append(ArrayView)`, `last() -> T?`, `contains`, `search(v) -> Int?`, `rev`, `copy`, `swap(i, j)`, `map`, `mapi`, `filter`, `filter_map`, `fold(init~, f)`, `each`, `any`, `all`, `join(sep)`, `iter()`, `retain(pred)`, `sort()`, `sort_by((a, b) -> Int)`, `sort_by_key(f)`, `binary_search(v) -> Result[Int, Int]` (`Ok(index)` or `Err(insertion point)`), `binary_search_by(x => x.compare(t))`. `a[i:j]` → `ArrayView` (`.to_owned()` copies).

**`sort`, `sort_by`, `sort_by_key` are unstable.** Add an index tiebreaker, or use `a.mut_view().stable_sort()` (needs `Compare`). Array `<` is shortlex.

`Iter[T]` (from `iter()`, `split`, `keys()`): `map`, `filter`, `take`, `drop`, `fold`, `count`, `find_first`, `join(sep)`, `to_array()`. Ranges are not values: `(0..<n).map(...)` does not compile.

### Map, Set, and friends

- `Map[K, V]` (**insertion-ordered** hash map; `K : Hash + Eq`): `Map([])` (a bare `{}` warns), `{ "a": 1 }`, `m[k] = v`, `get(k) -> V?`, `m[k]` (panics if absent), `contains`, `remove`, `length`, `get_or_init(k, () => v)`, `update(k, old => new?)`, `keys()`, `values()`, `for k, v in m`.
- `Set[K]` (insertion-ordered): `Set([])`, `add`, `add_and_check(k) -> Bool` (true if new), `contains`, `remove`, `length`, `union`, `intersection`, `difference`.
- `@hashmap.HashMap([])`, `@hashset.HashSet([])`: same APIs, unordered.
- `@sorted_map.SortedMap[K, V]` (`K : Compare`): `@sorted_map.SortedMap([])`, `set`, `get`, `remove`, `contains`, `length`, `for k, v in m` (key order), `keys()`, `range(lo, hi) -> Iter2[K, V]` (both ends inclusive).
- `@deque.Deque([])`: `push_back`, `push_front`, `pop_front() -> T?`, `pop_back`, `front`, `back`, `d[i]`. `@priority_queue.PriorityQueue([])` (largest first): `push`, `pop`, `peek`.
- Option: `unwrap_or`, `unwrap_or_else`, `map`, `bind`, `filter`, `is_some`, `is_none`, `unwrap` (panics). Result: `map`, `map_err`, `unwrap_or`, `is_ok`, `to_option`.

```moonbit
///|
test "collections" {
  let m : Map[String, Int] = Map([])
  m["b"] = 2
  m["a"] = 1
  m.update("b", old => old.map(x => x + 10))
  debug_inspect(m.keys().to_array(), content="[\"b\", \"a\"]") // insertion order
  inspect(m.get("b").unwrap_or(0), content="12")
  let sm : @sorted_map.SortedMap[Int, String] = @sorted_map.SortedMap([])
  sm.set(30, "c")
  sm.set(10, "a")
  sm.set(20, "b")
  let ks : Array[Int] = []
  for k, _ in sm.range(10, 20) {
    ks.push(k)
  }
  debug_inspect(ks, content="[10, 20]")
  let seen : Set[Int] = Set([])
  inspect(seen.add_and_check(5) && !seen.add_and_check(5), content="true")
  let pairs = [(2, "x"), (1, "y"), (2, "a")]
  pairs.sort_by((l, r) => l.0.compare(r.0))
  inspect(pairs[0].1, content="y")
  debug_inspect([1, 3, 5].binary_search(4), content="Err(2)")
}
```

## 4. Pitfalls

1. **Stale syntax.** Deprecated/removed: `f!(x)`, `f(x)?` (call `f(x)`), `try?` (use `catch`), `loop` (use functional `for`), `fn main()`, `derive(Show)`, top-level `let mut` (use `Ref`), `T::new()` on core collections, `view.to_string()` (`to_owned()`), `to_uint`/`to_uint64` (`reinterpret_as_*`), `x.shl(n)` (`<<`).
2. **`Int` is 32-bit.** Use `Int64` and `L` literals for 64-bit values; mixing `Int` and `Int64` does not compile.
3. **Silent wrap-around.** `+ - *` never trap; check overflow yourself. Integer `/` or `%` by zero aborts the process.
4. **Shortlex `<`.** `String`, `Bytes` and `Array` compare length first; use `lexical_compare` for dictionary order.
5. **UTF-16.** `length()`, `s[i]`, `s[a:b]` use code units; non-BMP chars take two. `s[i]` is `UInt16`: compare with char literals or convert.
6. **Trait methods via a concrete type warn** ("implicitly promoted"): `x.trait_m()`, `T::trait_fn()`, also for derived traits (`p.compare(q)`, `T::default()`). Use `Trait::m(x)`, `Default::default()`, `"\{x}"`, or `extend T with Trait::{m}`. Operators, generic `T : Trait` code and `&Trait` objects are fine.
7. **Patterns bind.** `match x { expected => ... }` matches anything; use a guard `v if v == expected`.
8. **Mutability.** `let mut` only rebinds; fields need `mut` in the struct declaration; parameters are immutable.
9. **Unstable sort.** Add a tiebreaker when equal elements must keep their order.
10. **Literal receivers.** `255.to_string()` does not call the Int method; write `(255).to_string()`, `(-2.5).round()`.
11. **Printing.** `inspect` on `Option`/`Array` is deprecated; use `debug_inspect`. Interpolating a `Byte` prints `b'\x41'`; use `.to_int()`.
12. **Views.** `trim`, `split`, `split_once`, `s[a:b]` return `StringView`; `.to_owned()` before storing as `String`. Compare a view with a `String` variable via `view == s[:]`.
13. **Doubles.** `parse_double` raises on overflow; `round` is half-up; `-0.0` prints `0`; `NaN.compare(x) == 0`.
