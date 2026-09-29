# Where MoonBit cost the agent extra: findings from the minisql benchmark

This covers 6 trials: `rust-t{1,2,3}` and `moonbit-t{1,2,3}`. Each trial ran 9 milestones with Claude Opus 5.5 (effort high), using `moon 0.1.20260920` (native target) and cargo 1.89 on an Apple M2 Ultra.
All raw data and scripts are next to this file. Scripts are in `scripts/` and can be re-run from the repo root (see "Reproducing" at the end).

## 0. Headline

| | Rust (mean of 3) | MoonBit (mean of 3) | MoonBit/Rust |
|---|---|---|---|
| Output tokens | 867,780 | 762,261 | 0.88 |
| Est. cost | $43.86 | $41.09 | 0.94 |
| Build/check invocations | 91 | 125 | 1.37 |
| Failed builds | 5.3 | 16.0 | 3.0 |
| Failed builds, **language-specific cause** | 2.0 | 8.3 | 4.2 |
| Failed builds, language-neutral cause (refactor ripple, work in progress, new enum variant) | 3.3 | 7.7 | 2.3 |
| `moon check` / `cargo check` invocations | 1 | 66 | – |
| Primer input re-read per trial | 1.15 M tokens | 4.91 M tokens | 4.3 |
| Hand-written helpers that Rust std provides (final code) | – | 460–525 lines (~2.6–3.2 k tokens) | – |
| Runtime, same-algorithm workloads (geo. mean) | 1.00 | 1.25 (micro) / 1.55 (perf tests) | – |

Summary:
* **Compile errors were not a large cost.** Language-specific MoonBit failures cost about 44 API calls over 3 trials, against 12 for Rust. Most fixes were one `sed` line. The net extra is about 11 calls per trial, which is about 2.5% of calls and about 3% of input tokens.
* **The primer cost more than the compile errors.** The MoonBit primer is about 11.7 k tokens, versus about 2.6 k for Rust. It is re-read on every call, which adds about 3.8 M cached input tokens per trial (about 5.6% of MoonBit input). It exists because model knowledge of MoonBit is stale.
* **The largest code-level gap is the ordered map.** All three MoonBit agents hand-wrote one (AVL or sorted chunks, 252–316 lines) because `@sorted_map` has no reverse, open-ended or seek iteration and no custom comparator. Rust used `BTreeMap`.
* **About half of MoonBit's extra failures are language-neutral.** The primer says to run `moon check` "after every edit", so the agents checked half-written code often: 198 checks versus 3 `cargo check` runs. This is cheap, because a check takes about 0.2 s.

## 1. Compile-error taxonomy

Sources: `builds.json` (every build/check/test-runner call with parsed diagnostics) and `compile_errors.json` / `.csv` (a hand-assigned root cause for each failed attempt, plus the API calls and assistant chars until the next build).
Failure detection uses `metrics.BUILD_FAIL`, which gives the same totals as `state.json`: MoonBit 48/376, Rust 16/274.

**Raw diagnostic codes seen in failed attempts:**
* **MoonBit:** 4021 unbound ×36, 3002 parse ×30, 4015 no method ×24, 4080 arity ×21, 4014 type mismatch ×18, 4044 missing record fields ×16, 4020 package not found ×16 (all cascades from `using`), 0011 partial match ×13, then smaller counts.
* **Rust:** E0061 ×17, E0063 ×14, E0004 ×6, E0283 ×5, then 1–2 of each borrow-checker code.

**Root causes.** One primary cause is assigned per failed attempt. "Involved" also counts attempts where the cause was secondary. "Calls" means API calls from the failure to the next build attempt, which approximates the fix turns.

| Cause | Kind | MoonBit primary / involved | Trials | Calls to next build | Rust primary |
|---|---|---|---|---|---|
| Refactor ripple (arity, new struct field, renamed ctor) | neutral | 10 / 12 | t1 t2 t3 | 26 | 7 |
| Work in progress (checked before code existed, typo) | neutral | 7 / 9 | t1 t2 t3 | 19 | 2 |
| New enum variant not matched (0011 / E0004) | neutral | 6 / 7 | t1 t2 | 26 | 1 (involved 3) |
| **Reserved word**: `using` is a keyword (error); renames forced by `alias` warnings broke code | lang | **6 / 9** | **t1 t2 t3** | 11 | – |
| **`let (mut a, b) = …`** (Rust habit) | lang | **4 / 4** | t1 t3 | 7 | – |
| **Error hidden by output filter** (`… \| tail -N` showed only warnings) | lang/tooling | 4 / 4 | t1 t3 | 8 | – |
| Error-effect typing: missing `raise` in signature; non-raising fn not accepted as raising fn value | lang | 2 / 3 | t1 t2 t3 | 5 | – |
| `C(..)` for positional constructor | lang | 2 / 3 | t2 | 3 | – |
| Non-existent core API (`map_raise`, `StringView.replace_all` result used as String) | lang | 2 / 2 | t1 | 3 | – |
| Package not imported in `moon.pkg` (`@io`) | lang | 1 / 2 | t1 | 1 | – |
| Ambiguous constructor (`Binary` in two enums) | lang | 1 / 2 | t3 | 2 | – |
| Old generic syntax `fn f[T]` | lang | 1 / 1 | t1 | 1 | – |
| Int vs Int64 mixing | lang | 1 / 1 | t2 | 2 | – |
| Closure effect order `fn(x) raise E -> T` | lang | 1 / 1 | t2 | 1 | – |
| `while true { … return }` needs `nobreak` | lang | 0 / 2 | t2 t3 | – | – |
| `unused_mut` (0015) on a field is a hard error | lang | 0 / 2 | t3 | – | – |
| `for x in` on user type w/o `iter`; closure field call needs `(x.f)(…)` | lang | 0 / 1 each | t2 | – | – |
| Borrow checker (E0502/E0506/E0507/E0521) | lang | – | – | – | **4** (8 calls) |
| Type annotations for closure `Result` (E0282/E0283) | lang | – | – | – | 1 |
| Assign to immutable binding (E0384) | lang | – | – | – | 1 |
| **Totals** | lang / neutral | **25 / 23** | | 44 / 71 | **6 / 10** (12 / 30 calls) |

**Cost of language-specific failures:**
* MoonBit: 44 calls, about 51 k assistant chars (≈13 k output tokens), average context 171 k. That is ≈7.5 M cache-read tokens over 3 trials.
* Rust: 12 calls, about 19 k chars, average context 149 k. That is ≈1.8 M cache-read tokens over 3 trials.
* Net MoonBit extra: about 11 calls and about 1.9 M input tokens per trial, which is about 2.5% of calls and about 3% of input.

Why MoonBit also had more language-neutral failures:
* MoonBit agents ran `moon check` 198 times, against 3 `cargo check` runs. They checked intermediate states that were deliberately incomplete.
* Examples: t2 m03 steps 28–30 checked `Database::insert` before writing it, and t3 m04 step 16 did the same with `run_aggregate`.

Verbatim examples:
* **`using` (t1 m05 s23, t2 m05 s25, t3 m01 s12, t3 m05 s21):**
  * Source: `let mut using : Array[String]? = None`
  * Diagnostic: `[3002] Parse error, unexpected token \`using\`, you may expect id (lowercase start).` It is followed by the misleading cascade `[4020] Package "?PACKAGE_NAME" not found in the loaded packages.` and, on struct fields, `[4041] Partial type is not allowed in toplevel declarations.`
  * t1 needed 2 attempts because its first `sed` missed some spellings.
* **Tuple `mut` (t1 m04 s24):**
  * Source: `let (mut y, mut m, d) = if p.valid_ymd { … }`
  * Diagnostic: `[3002] Parse error, unexpected token \`mut\`, you may expect simple pattern.`, then 8 × `The value identifier y is unbound.`
  * t3 made the same mistake in m04 and again in m06 (2 attempts).
* **`C(..)` (t2 m07 s25):**
  * Source: `Lit(_) | Col(..) | Slot(..) | WinFunc(..) => None`
  * Diagnostic: `[4080] The constructor WinFunc requires 2 arguments, but is given 0 arguments.`
  * `B(..)` is accepted for constructors with labelled payloads, so the rule depends on how the constructor was declared.
* **Effects (t3 m02 s30):**
  * Source: `m["instr"] = { min_args: 2, max_args: 2, f: instr_func }`
  * Diagnostic: `has type : (Array[Value]) -> Value / wanted : (Array[Value]) -> Value raise SqlError`
  * I reproduced this in a scratch project: a non-raising function is not accepted where a raising function type is expected. The fix was eta-expansion, `f: args => instr_func(args)`.
* **Closure effect order (t2 m06 s35):**
  * Source: `let bound = fn(b : RangeB?) raise SqlError -> ((Value, Bool)?, Bool) {`
  * Diagnostic: `Parse error, unexpected token \`->\`, you may expect \`{\``, plus 10 cascading errors. The agent fixed every file with one regex.
* **Hidden error (t1 m06 s23):**
  * `moon check 2>&1 | tail -30` printed only warnings. The first of them is a 12-line `fragile_catch_all` help text. It ended with `Failed with 25 warnings, 1 errors.`, and a re-run with `grep -A8 Error` was needed.
* **Rust for comparison:**
  * `E0506 cannot assign to \`self.started\` because it is borrowed` (t2 m03 s30).
  * `E0282 type annotations needed for \`Result<AggCall, _>\`` (t2 m04 s20).
  * `E0063 missing field \`allow_agg\` in initializer of \`eval::Scope\`` ×6 (t1 m04 s18, neutral).

Build output volume:
* MoonBit build/check output totalled 251 k chars, against 191 k for Rust. Of that, 47 k vs 33 k chars were warning blocks.
* Both agents filtered almost every build output through `grep`/`tail`/`head` (368/376 and 272/274 invocations).

## 2. Warnings and deprecated APIs

These come from a fresh `moon check` in copies of the final workspaces (`scratchpad/analysis/chk`):

| Trial | Warnings | Kinds |
|---|---|---|
| moonbit-t1 | 13 | 7 fragile_catch_all, 4 reserved_keyword, 1 unused_field, 1 unused_struct_update |
| moonbit-t2 | 0 | – (t2 renamed every `alias`) |
| moonbit-t3 | 39 | 34 reserved_keyword (26 × `alias`, 8 × `local`), 4 fragile_catch_all, 1 unused_field |
| rust-t1/t2/t3 | 1/0/0 | 1 unused import |

Deprecated APIs:
* The final MoonBit code has no deprecated API use.
* During development only 2 deprecations appeared:
  * `or_else` (message: "use `unwrap_or_else` instead", t2 m02). The primer did not cover this.
  * Core packages used without an import (warning 0071, t3 m01, 3 times). The primer covered this.
* The primer's stale-syntax list (pitfall 1) worked: none of `f!(x)`, `try?`, `loop`, `derive(Show)`, `T::new()` or `view.to_string()` appeared in any diagnostic.

Across all transcripts, 145 warning blocks were seen:
* reserved_keyword: 50 occurrences at 46 sites.
* fragile_catch_all: 22. Each carries a 12-line `errdefer` sermon.
* unused_*: 44.

The `alias` warning is itself a cost:
* It pushed t1 (m01) and t2 (m01, m03) into sed renames.
* Those renames caused 3 of the failed attempts counted above.

## 3. API discovery

Source: `api_discovery.json`.

**MoonBit:**
* 26 `moon ide doc` queries: t1 5, t2 12, t3 9.
* 7 `moon ide outline` calls (own code). One of them failed with `only one path is supported currently` (t1 m08).
* 1 grep into `~/.moon/lib/core/sorted_map` (t3 m06, to read how `range` is implemented).
* 1 scratch project to probe `parse_double` and `Double` printing (t1 m01).
* 0 uses of `moon explain`.

**Rust:** 0 lookups of any kind.

Lookup quality:
* I re-ran every query. 25 of 26 return results; `Int::unsafe_to_char` returns "No results".
* The most repeated query is `@sorted_map.SortedMap::*`, run 5 times (t1 m03, t2 m01/m03, t3 m03/m06). The agents kept checking for range, reverse or seek methods that do not exist, then wrote their own map.
* Lookups happened before writing code. The API names that failed to compile (`map_raise`) were never looked up. The agent guessed and let the compiler answer.

Output style:
* `moon ide doc` output mixes `#alias(...)` / `#as_free_fn(..., deprecated)` attribute lines into the listing. For example, `SortedMap::*` prints 5 attribute lines before the first signature.
* In t3, `grep -o "fn.*"` then produced junk lines such as `fn(of, deprecated)`.

## 4. Missing-in-core evidence

Source: `missing_in_core.json` / `.csv`, built from `fn_inventory.json`. Lines are non-blank lines of the hand-written helper, and tokens are chars/4.

| Helper the MoonBit agents wrote | t1 / t2 / t3 lines | Mean tokens | Rust std used instead | Why it was written |
|---|---|---|---|---|
| Ordered map with range/rev/seek (`ptree.mbt` persistent AVL, `ordmap.mbt` AVL, `sorted.mbt` sorted chunks) | 254 / 316 / 252 | 1,567 | `BTreeMap` + `range(..)`, `.rev()`, `first/last_key_value` (28–31 uses/trial) | `@sorted_map` has only `range(lo, hi)` (both inclusive, forward only). It has no reverse iteration, lower_bound, first/last or comparator constructor. t3 started with `@sorted_map` and replaced it in m06 because ORDER BY … LIMIT and min/max via index "take tens of seconds" without bidirectional early-exit scans. |
| Exact decimal digits of a double (for printf `%f/%e/%g`, SQLite `FpDecode`) | 83 / 74 / 76 | 519 | `format!("{:.29e}", r)`: **1 line** | Core has no precision/exponent float formatting. t1 ported double-double (Dekker) arithmetic; t2 and t3 wrote base-1e9 bignum limbs. Nobody used `@bigint`. |
| Checked Int64 add/sub/mul | 22 / 30 / 22 | 130 | `checked_add/sub/mul` (12–15 call sites/trial) | Not in core; the primer supplied the snippet. |
| UTF-8/code-point order text compare, byte compare | 34 / 25 / 32 | 167 | `a.cmp(b)` on `&str`/`&[u8]` | `String` `<` is shortlex, and `lexical_compare` orders by UTF-16 code unit, which differs from UTF-8 order above U+E000. `Bytes::lexical_compare` exists but t1/t3 re-wrote it. |
| ASCII predicates on UTF-16 code units | 36 / 34 / 25 | 150 | `u8::is_ascii_digit/…` (26–32 uses), `to_ascii_lowercase` (42–102) | `s[i]` is `UInt16`, and `UInt16` only has surrogate predicates. The lexer is full of `c >= 'a'.to_int() && c <= 'z'.to_int()`: 56 conversions in t1's lexer vs 1 `as` cast in Rust's. |
| Stable sort with comparator | 44 / 0 / 0 | 74 | `sort_by` (stable) | `stable_sort` exists only for `T : Compare`. t2 and t3 added index tie-breakers instead. |
| Zero/space-padded integers | 22 / 15 / 26 | 123 | `{:02}`, `{:>w$}` (43–47 specifiers/trial) | No width specifiers. `String::pad_start` exists but was used 0 times. |
| Big-endian u16/u32 at offset | 25 / 31 / 29 | 221 | `from_be_bytes`/`to_be_bytes` (21–26 uses) | Bitstring patterns `u16be` and `@buffer.write_*_be` exist but don't cover random-access reads. |
| **Total** | **520 / 525 / 462** | **≈2,950** | | |

At the observed 4.44 output tokens per final source token (the same in both languages), ≈2.9 k helper tokens is ≈13 k output tokens per trial, or ≈1.7% of MoonBit output. The ordered map is over half of it.

Some helpers are **not** MoonBit-specific; both languages hand-wrote them: `format_real` (%.15g-style, about 55–100 lines each), SQLite printf, varints, LIKE/GLOB, date/time and collation keys.
Rust's `format_real` also relies on `{:e}` / `{:.*e}`, which saves a digit-extraction step.

## 5. Runtime performance

Release builds were made in a scratch copy. Source: `build_times.json`, `perf_times.json/.csv`, `microbench_times.json/.csv`.

**Build and binary:**

| | rust t1/t2/t3 | moonbit t1/t2/t3 |
|---|---|---|
| Clean release build (median of 3) | 3.2 / 4.0 / 3.9 s | 7.2 / 8.6 / 8.4 s |
| Incremental release build (one-line edit in value module) | 3.2 / 3.9 / 3.9 s | 7.1 / 8.5 / 8.4 s |
| Full type-check from clean (`cargo check` / `moon check`) | 1.14 / 0.76 / 0.94 s | 0.21 / 0.21 / 0.23 s |
| Incremental check | 0.17–0.19 s | 0.19–0.23 s |
| Binary (stripped) | 1.64 / 1.70 / 1.92 MB | 1.27 / 1.51 / 1.47 MB |

In both languages the whole engine is one crate or package, so an incremental release build equals a clean one.

**Perf tests** (`binary < file.sql`, median of 3 runs, 30 s cap). Excluding the two tests where algorithms differ:
* Geometric mean of MoonBit/Rust, per trial pair: t1 1.65, t2 1.36, t3 1.61; overall 1.55.
* Most perf tests spend most of their time in the shared 100 k-row setup (`INSERT … SELECT` over a cross join).

Algorithmic outliers:
* `perf_order_by_limit` times out (>30 s) in all 3 Rust engines and in moonbit-t1. moonbit-t2 and t3 run it in 0.31 and 0.39 s, because they implemented index-order LIMIT pushdown on their custom containers.
* `perf_multi_column_index`: Rust 3.3–4.0 s, moonbit-t1 6.7 s, moonbit-t2 and t3 0.50–0.63 s.
* So the best engine on the harder planner tests was a MoonBit one. The whole-suite totals reflect this: Rust 13.4–14.3 s vs MoonBit 7.8–17.3 s, dominated by these two tests' 5 s harness timeouts.

**Other suite cases and micro-benchmarks:**
* The m01–m07 suite without perf tests takes 1.38–1.42 s in all 6 engines. That is about 4 ms per case, dominated by process start-up.
* Controlled micro-benchmarks are in `microbench/`: 10 files, same workload in every engine, all 60 outputs match sqlite3, 5 runs each.
* Geometric-mean MoonBit/Rust per pair: t1 1.29, t2 1.19, t3 1.26; overall 1.25.

Marginal cost over the shared 300 k-row insert baseline (mean over trials):

| Workload | Rust | MoonBit | Ratio |
|---|---|---|---|
| CREATE INDEX ×2 (300 k rows) | 0.23 s | 0.77 s | 3.4 |
| ORDER BY text, 100 k rows | 0.025 | 0.078 | 3.1 |
| UPDATE + DELETE | 0.18 | 0.31 | 1.7 |
| Window functions | 0.22 | 0.35 | 1.6 |
| GROUP BY / DISTINCT | 0.24 | 0.35 | 1.4 |
| Scan + filter + arithmetic | 0.13 | 0.15 | 1.15 |
| REAL output (60 k rows) | 0.055 | 0.042 | 0.8 |
| printf, 30 k rows | 0.017 | 0.011 | 0.65 |
| String functions (upper/replace/substr/LIKE/GLOB) | 0.48 | 0.31 | 0.65 |
| 300 k-row insert itself (total) | 0.45 | 0.53 | 1.2 |

Profile (macOS `sample`, index-build workload, moonbit-t2 5.1 s vs rust-t2 2.4 s):
* **MoonBit:** 1,485 samples.
  * About 35% memory management: `moonbit_drop_object` 22% (reference-count release), `scan_regular_object` 9%, plus `mi_malloc`.
  * About 30% comparator closures (`coll_compare`, `index_cmp`, called through `(K, K) -> Int` in the hand-written AVL).
  * About 19% AVL rebalancing and path copying (`balance`, `OrdMap::set`).
* **Rust:** `BTreeMap::insert` + `compare_values` + `memcmp` dominate; malloc/free is about 10%.
* **Memory:** MoonBit peak RSS was **170 MB vs Rust 601 MB** on this workload.
* **Interpretation:**
  * The slowdown is mostly the data structure the agents had to write: a pointer-heavy AVL with closure comparators, instead of a B-tree.
  * Reference-count traffic on the `Array[Value]` keys adds to it.
  * Code generation is not the main cause: string-heavy code was faster in MoonBit (UTF-16 `upper`/`replace`/`substr` 0.65×).

## 6. Primer effectiveness (MOONBIT.md)

| Primer pitfall | Hit? | Evidence |
|---|---|---|
| 1 Stale syntax list | Mostly avoided | 0 hits of the listed forms. The unlisted `fn f[T]` was hit once (t1 m02). The listed `loop` removal pushed agents to `while true`, which then needed `nobreak` (2 involvements). |
| 2 `Int` is 32-bit | Once | t2 m02 (Int/Int64 mixing, `Int::to_int`). About 250–330 `.to_int()/.to_int64()/.to_double()` conversions per trial, vs 215–246 `as` casts in Rust: similar. |
| 3 Silent wrap-around | Followed | All trials implemented checked ops (the snippet was copied); no overflow bugs found. |
| 4 Shortlex `<` | Followed | All trials wrote their own code-point compare, which is correct for SQLite. |
| 5 UTF-16 | Followed, but costly | Helpers from §4: code-unit ASCII predicates, compare fix-up. |
| 6 Implicit trait promotion | Silenced via `warnings =` line | – |
| 7 Patterns bind | No evidence of hits | – |
| 8 Mutability | **Not covered for tuple patterns** | `let (mut a, b)`: 4 attempts in 2 trials. Also `unused_mut` on a field is an error (t3 m06). |
| 9 Unstable sort | Followed | t1 wrote a merge sort; t2/t3 used index tie-breakers. |
| 10–13 | No hits | – |

Mistakes the primer did not cover:
* The `using` keyword (all 3 trials, 9 involved attempts) and the `alias`/`local` reserved words (46 warning sites, forced renames).
* `C(..)` on positional constructors.
* The effect annotation order in closures (`-> T raise E`).
* Non-raising → raising function coercion.
* That core higher-order functions take raising closures (so there is no `map_raise`).
* `while true` needing `nobreak`.
* Constructor ambiguity across enums in one package.
* That `moon check | tail` can hide errors behind warnings.

The primer itself is costly:
* It is 11.7 k tokens, 4.4× the Rust primer.
* It is re-read on each of about 420 calls: ≈4.9 M input tokens per trial, against 1.15 M for Rust.
* The extra ≈3.8 M tokens per trial is **larger than the whole compile-error overhead** (≈1.9 M per trial).

## 7. Code shape: rust-t1 vs moonbit-t1

Source: `code_shape.json`. Code lines exclude comments; tokens are chars/4 of code.

| Component | Rust lines / tokens | MoonBit lines / tokens | Ratio lines / tokens |
|---|---|---|---|
| File-format reader | 317 / 2,964 | 279 / 1,808 | 0.88 / **0.61** |
| Lexer | 259 / 2,294 | 349 / 2,194 | 1.35 / 0.96 |
| Parser | 1,536 / 13,835 | 1,806 / 11,328 | 1.18 / 0.82 |
| File writer | 483 / 4,540 | 615 / 3,784 | 1.27 / 0.83 |
| Date/time | 796 / 6,426 | 951 / 5,370 | 1.19 / 0.84 |
| Window functions | 707 / 6,330 | 845 / 5,172 | 1.20 / 0.82 |
| Value + ops | 511 / 3,785 | 860 / 4,482 | 1.68 / **1.18** |
| printf | 436 / 3,243 | 622 / 3,629 | 1.43 / 1.12 |

What accounts for the differences:
* **File reader, where MoonBit is shorter.**
  * Rust needs 14 `?`, 12 `Ok(`/`Err(`, 7 `Result<`, 43 `&`, 7 `'a` lifetimes and 19 `as` casts.
  * MoonBit needs `raise SqlError` in 12 signatures and no call-site marker. Bounds checks are implicit (`data[off]`), where Rust needs `page.get(a..b)` + `let … else`.
* **Value + ops and printf, where MoonBit is longer.**
  * The UTF-16/UInt16 helpers (`is_space_cu`, compare fix-up), `fp_decode`'s hand-rolled digit generation and 41 numeric conversions.
  * One `///|` marker per item (47 in value+ops).
  * `moon fmt` puts `{`/`}` on their own lines, giving 183 closing-brace-only lines vs 127 in Rust.
* **Lexer.** Rust scans `&[u8]` with `is_ascii_*`. MoonBit scans UTF-16 code units with `'x'.to_int()` comparisons (56 conversions). The line count rises by 35% while tokens stay equal.
* **Overall.** MoonBit is more lines but fewer tokens. This matches the whole-project figures of 1.04× lines and 0.88× tokens.

## 8. What MoonBit did well

* 12% fewer output tokens and 12% less source for the same hidden-test pass rate (0.956 vs 0.963).
* No equivalent of the borrow checker class of errors (4 Rust failures, 8 calls). There was no ownership plumbing: 0 `clone()` / `&` / lifetimes.
* `raise` effects shrink error-heavy code: the file reader is 39% fewer tokens.
* `moon check` is ≈4× faster than a clean `cargo check` (0.2 s vs 0.8–1.1 s). This made the check-after-every-edit style cheap.
* `moon ide doc` answered 25 of 26 queries, with signatures and docs.
* Deprecation warnings name the replacement. No deprecated API was left in any final workspace.
* Binaries are 20–25% smaller and peak RSS is 3.5× lower on the index workload. String functions ran faster than in Rust.
* Two of the three MoonBit engines were the only engines that passed `perf_order_by_limit`.

## 9. Recommendations, prioritized

Savings are per trial, estimated from the counts above. A "call" costs ≈150–250 k cached input tokens plus ≈0.5–1.5 k output tokens.

1. **Core: a full ordered map API.**
   * Add `range` with open, exclusive or unbounded ends, reverse iteration (`rev_range` / `iter_rev`), `lower_bound`/`upper_bound`/`seek`, `first`/`last` (`min`/`max`) and `pop_first`/`pop_last`.
   * Add a constructor taking a comparator, or document a key newtype with `Compare`.
   * Consider a B-tree implementation for cache locality.
   * *Evidence:* 3/3 trials wrote 252–316-line maps; 5 repeated `SortedMap::*` lookups; t3 replaced `@sorted_map` in m06 after 10 s+ queries; the index-build profile showed ≈50% in the hand-made AVL plus RC.
   * *Savings:* ≈1.6 k source tokens ≈ 7 k output tokens, plus the design and debugging turns in t3 m06. Runtime could improve up to 3× on index-heavy workloads.
2. **Compiler: targeted diagnostics for common foreign-language forms.**
   * For `using` (and other contextual keywords) used as an identifier: say "`using` is a keyword; rename it", and suppress the `?PACKAGE_NAME` / partial-type cascade.
   * For `let (mut a, b) = …`: suggest `let (a0, b) = …; let mut a = a0`, or accept the syntax.
   * For `fn(x) raise E -> T`: say "write `-> T raise E`".
   * *Evidence:* 11 primary failures and 19 calls across the 3 trials, in every trial.
   * *Savings:* ≈6 calls ≈ 1 M input tokens per trial.
3. **Language/compiler: accept `C(..)` for positional constructors, and coerce non-raising functions to raising function types.** `B(..)` is already accepted for labelled payloads, and eta-expansion is always valid.
   * *Evidence:* 5 involved attempts.
   * *Savings:* ≈2–3 calls per trial.
4. **Core: float formatting with precision and exponent** (`Double::to_fixed(p)`, `to_exponential(p)`, or a small `format` with width and precision), plus integer width padding.
   * *Evidence:* 74–83 lines of digit generation per trial (Rust used 1 line), 15–26 lines of padding helpers, and 43–47 width specifiers per Rust trial.
   * *Savings:* ≈650 source tokens ≈ 3 k output tokens per trial, and removes a correctness risk (double-double rounding).
5. **Documentation for LLMs: an official, compact, versioned "MoonBit for agents" guide, and keeping training corpora current.**
   * It should cover the pitfalls from §6 that the primer missed, plus raise-polymorphic higher-order functions (`map` accepts raising closures).
   * *Evidence:* the 11.7 k-token primer costs ≈3.8 M extra input tokens per trial (≈5.6% of input), more than all compile errors. The stale-syntax items it lists were all avoided, so the content works.
   * *Savings:* halving the primer saves ≈2 M input tokens per trial; accurate model priors would remove most of it.
6. **Toolchain: diagnostic output built for filtering.**
   * Print errors after warnings, or add a `--errors-only` / `-q` mode.
   * Put a one-line summary of the first error on the final line.
   * Collapse long help texts such as the 12-line `fragile_catch_all` note, and suppress parse-error cascades.
   * Consider reclassifying `reserved_keyword` for `alias`/`local`. It caused 46 warning sites and renames that broke 3 builds.
   * *Evidence:* 4 failures where the error was invisible (8 calls); 47 k chars of warnings in outputs.
   * *Savings:* ≈3 calls per trial, plus ≈3 k tokens of output reading.
7. **Core: UTF-16-aware helpers.**
   * `UInt16::is_ascii_digit/_alphabetic/_whitespace/to_ascii_lowercase`.
   * A code-point-order `String` compare (for example `compare_by_code_point`, or document that `lexical_compare` is by code unit).
   * `Int64::checked_add/sub/mul` (or `overflowing_*`), and `stable_sort_by(cmp)`.
   * These are cheap additions that remove about 100–150 hand-written lines per trial: ≈500 source tokens ≈ 2 k output tokens.
   * UTF-16 strings and wrapping `Int` are reasonable design choices, and string-heavy code was fast. The cost is the missing adapters, not the design.
8. **Runtime: reduce reference-counting overhead on hot paths.** Examples: borrowed parameters or elided `drop` for comparator arguments, and cheaper `Array[Value]` key comparisons.
   * *Evidence:* 22% of samples in `moonbit_drop_object` and ≈35% in memory management on the index workload. Same-algorithm micro-benchmarks are 1.25× Rust overall and 1.4–3.4× on index/sort/window work.
   * The low RSS (170 MB vs 601 MB) is a real benefit worth keeping.

Minor items:
* Make `unused_mut` on a field a warning, not an error. It was hit twice.
* Make `while true` without `break` diverge, like Rust's `loop`, so no `nobreak` is needed. This is especially relevant because `loop` was removed.
* Let `moon ide outline` accept several paths (t1 m08).
* Make `moon ide doc` print attribute lines (`#alias(..., deprecated)`) after the signature, or offer a flag to hide them.
* Release builds take about 2× as long as cargo (7–8.6 s vs 3.2–4 s), driven by the C backend. This did not matter here because agents mostly used the 0.2 s `moon check`.

## Reproducing

```
python3 analysis/scripts/extract_builds.py        # builds.json, bash_commands.json
python3 analysis/scripts/classify_errors.py       # compile_errors.json/.csv (manual labels inside)
python3 analysis/scripts/followups.py moonbit     # agent reaction after each failure (for labelling)
python3 analysis/scripts/api_discovery.py         # api_discovery.json
python3 analysis/scripts/fn_inventory.py && python3 analysis/scripts/helpers.py   # missing_in_core.json/.csv
bash    analysis/scripts/std_usage.sh             # std/core facility counts
python3 analysis/scripts/code_shape.py            # code_shape.json
python3 analysis/scripts/build_and_time.py <ws>   # build_times.json (ws = copies of the work dirs)
python3 analysis/scripts/time_engines.py <ws>     # perf_times.json/.csv
python3 analysis/scripts/microbench.py <ws>       # microbench_times.json/.csv (inputs in analysis/microbench)
```

Caveats:
* There are 3 trials per language.
* Root-cause labels are manual; they are in `classify_errors.py` so they can be reviewed.
* "Calls to next build" includes turns the agent spent on other work before rebuilding, so it is an upper bound on the cost of a fix.
* Per-test runtimes of the perf suite are confounded by planner choices; the micro-benchmarks are the like-for-like comparison.
