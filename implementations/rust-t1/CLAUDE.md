# minisql

You are implementing **minisql**, a SQLite-compatible SQL database engine, in
Rust. The specification is `SPEC.md`; read the parts you need. The work
is split into milestones; each session asks you to implement one.

## Rules

- Write the engine in Rust using only its standard library. No
  third-party packages, no C code or FFI, no linking or embedding SQLite,
  no spawning processes from the engine.
- All process I/O goes through the provided io module (`src/io.rs`). Do
  not modify it.
- Build: `cargo build --release`. The engine binary is `target/release/minisql`.
- Tests: `python3 tools/run_tests.py --upto N` builds the engine and runs the
  visible tests of milestones 1..N (`-k name` filters, `-v` shows full
  diffs, `--help` for more). Cases are `tests/mNN/*.sql` with expected
  output in `*.expected`. Do not modify anything in `tests/` or `tools/`.
- Do not special-case test names or contents: a hidden test suite with
  different cases checks the same features.
- The `sqlite3` command is available if you want to check how SQLite
  behaves.
- Stay inside this directory. No web access.
- Don't run git commands; the harness commits your work after each session.
- How you structure the code is up to you.

# Rust primer

# Rust primer

Verified against `cargo 1.89` / `rustc 1.89`, edition 2021, std only.

## 1. Toolchain and project layout

| Task | Command |
|---|---|
| Type-check (fast) | `cargo check` |
| Release build | `cargo build --release` → `target/release/minisql` |
| Tests | `cargo test` · `cargo test name_substring` · `-- --nocapture` |
| Format / lint | `cargo fmt` · `cargo clippy` |
| Explain an error code | `rustc --explain E0502` |

`src/io.rs` is the harness I/O module; do not modify it: `io::read_stdin() -> String`, `io::write_stdout(&str)`, `io::flush_stdout()`, `io::args() -> Vec<String>`, `io::read_file(&str) -> Option<Vec<u8>>`, `io::write_file(&str, &[u8]) -> bool`. All program I/O goes through it.

Add a module: create `src/util.rs` (or `src/util/mod.rs`) and declare `mod util;` in `main.rs`; refer to items as `util::f` or `use crate::util::f;`. Items need `pub` (or `pub(crate)`) to be visible to sibling modules. `[dependencies]` in `Cargo.toml` must stay empty. Unit tests go in `#[cfg(test)] mod tests { use super::*; #[test] fn t() { ... } }`. A panic prints to stderr and exits with status 101.

## 2. Language essentials

- Shared mutable state: prefer owning structs plus indices (`Vec<Node>` + `usize` ids) over `Rc<RefCell<T>>`; take fields out with `std::mem::take` / `std::mem::replace` to satisfy the borrow checker; split borrows by destructuring (`let Self { a, b, .. } = self;`).
- Recursive enums need indirection: `enum Tree { Leaf(i64), Node(Box<Tree>, Box<Tree>) }`.
- Errors: one crate-wide `enum Error` with `impl fmt::Display`, and `impl From<std::num::ParseIntError> for Error` (etc.) so `?` converts automatically.
- `f64` implements neither `Eq`, `Ord` nor `Hash`; use `a.total_cmp(&b)` for ordering and `to_bits()` for hashing, or a wrapper type with manual impls.
- `#[derive(Debug, Clone, PartialEq)]` on data types; `Eq, Hash, PartialOrd, Ord` only where all fields allow it (`Ord` derive orders fields/variants in declaration order).

## 3. Core library cheat sheet

- Integers: `checked_add/sub/mul/div/rem/neg` → `Option`; `wrapping_*`, `overflowing_*`, `saturating_*`. `i64::MIN / -1` and `% -1` panic even in release; use `checked_div`/`checked_rem` or `wrapping_*`. `/` truncates toward zero, `%` has the dividend's sign; `rem_euclid` for non-negative results.
- Casts with `as`: `f64 as i64` truncates toward zero and saturates (NaN → 0); `i64 as i32` keeps the low bits; `i64 as f64` rounds. Use `i32::try_from(x)` to detect loss.
- f64 text: `format!("{}", x)` gives the shortest round-trip digits but never an exponent (`1e21` → `1000000000000000000000`, `-0.0` → `-0`, `100.0` → `100`); `{:?}` gives `1e21` and `100.0`; `{:e}` gives `1e21`. `x.round()` rounds half away from zero; `%` on f64 is fmod.
- Parsing: `s.parse::<i64>()` accepts a leading `+`/`-`, rejects spaces, `_` and trailing junk, errors on overflow. `s.parse::<f64>()` also accepts `inf`, `NaN`, `.5`, `5.`, `1e5` and returns `inf` on overflow (`"1e400"`). `i64::from_str_radix(s, 16)`.
- f64 bits: `x.to_bits() -> u64`, `f64::from_bits(u64)`; bytes: `x.to_be_bytes() -> [u8; 8]`, `i64::from_be_bytes(slice.try_into().unwrap())`, `u16::from_be_bytes([a, b])`.
- Strings are UTF-8: `s.len()` is bytes; `&s[a..b]` panics if `a`/`b` is not a char boundary (`s.is_char_boundary(i)`); iterate with `s.char_indices()` (byte offset + char) or `s.as_bytes()` for ASCII scanning. `to_ascii_lowercase`, `eq_ignore_ascii_case`, `to_lowercase` (full Unicode). `str` `<` is byte-wise lexicographic.
- `String` building: `push_str`, `push`, `write!(s, ...)` with `use std::fmt::Write`.
- Collections: `HashMap`/`HashSet` iterate in random order (differs per run); `BTreeMap::range(lo..=hi)` for ordered ranges; `entry(k).or_insert(v)`; `VecDeque`; `BinaryHeap` (max-first; `Reverse` for min). `slice::sort_by` is stable, `sort_unstable_by` is not; `binary_search_by` returns `Result<usize, usize>`.

```rust
use std::collections::BTreeMap;
use std::fmt::Write;

pub fn demo() -> String {
    let mut out = String::new();
    let a: i64 = i64::MAX;
    assert_eq!(a.checked_add(1), None);
    assert_eq!(a.wrapping_add(1), i64::MIN);
    assert_eq!(i64::MIN.checked_div(-1), None);
    let nan: f64 = "NaN".parse().unwrap();
    assert_eq!(nan as i64, 0); // saturating cast, NaN -> 0
    assert_eq!(1.5f64.to_bits(), 0x3FF8_0000_0000_0000);
    let bytes = (-2i64).to_be_bytes();
    assert_eq!(i64::from_be_bytes(bytes[..].try_into().unwrap()), -2);
    let s = "héllo";
    let idx: Vec<usize> = s.char_indices().map(|(i, _)| i).collect();
    assert_eq!(idx, vec![0, 1, 3, 4, 5]);
    let mut m = BTreeMap::new();
    for k in [30, 10, 20] {
        *m.entry(k).or_insert(0) += 1;
    }
    let ks: Vec<i32> = m.range(10..=20).map(|(k, _)| *k).collect();
    assert_eq!(ks, vec![10, 20]);
    write!(out, "{} {:?} {:e}", 1e21f64, 1e21f64, 1234.5f64).unwrap();
    out // "1000000000000000000000 1e21 1.2345e3"
}
```

## 4. Pitfalls

1. **Overflow differs by profile.** `+ - *` panic on overflow in debug and test builds but wrap silently in release; use `checked_*`/`wrapping_*` wherever overflow can happen.
2. **String slicing panics** on non-char boundaries; derive byte offsets from `char_indices`/`find`, or scan `as_bytes()`.
3. **Nondeterministic iteration.** `HashMap`/`HashSet` order changes between runs; use `BTreeMap`, insertion-ordered `Vec`s, or sort before producing output.
4. **Float formatting.** `{}` never prints an exponent and `{:?}` appends `.0` to whole numbers; when a specific text form is required, build it explicitly.
5. **Borrow conflicts with `&mut self`.** Calling `self.helper()` while holding a reference into `self` fails; use indices, `mem::take`, clones of small data, or functions taking only the needed fields.
6. **`as` is silent** (truncates/saturates); use `try_from` when the range matters. **`sort_unstable*`** reorders equal elements.
7. **`println!`** bypasses the io module (tests only). Call `io::flush_stdout` before every exit path; `std::process::exit` skips it.
