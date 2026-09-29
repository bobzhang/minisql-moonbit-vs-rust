# MoonBit vs Rust: agent token efficiency on a 20k-line project

This experiment measures how many tokens an AI coding agent (Claude Opus 5.5,
effort `high`, driven by headless Claude Code) spends to build the **same
SQLite-compatible SQL engine** in Rust and in MoonBit, and how large the
resulting code is. The project is big enough (target ~20k lines, nine
milestones) that the one-time cost of an unfamiliar language is spread over a
lot of real work, and the per-milestone data shows whether that cost fades.

## Questions

1. **Agent cost:** tokens (output, input, cache reads/writes), turns, estimated
   cost and wall time to implement each milestone.
2. **Code size:** tokens (in the model's own tokenizer), lines and bytes of the
   finished source.
3. **Quality:** pass rate on hidden tests, so a cheaper-but-worse
   implementation doesn't look efficient.
4. **Learning curve:** build-failure counts and the MoonBit/Rust cost ratio per
   milestone. If unfamiliarity is a fixed cost, the ratio should fall over time.

## Design

| Piece | Where |
|---|---|
| Engine specification (language-neutral) | `spec/SPEC.md` |
| Conformance tests, ~450 cases in 9 milestones | `tests/cases/mNN/*.sql` + `.expected` |
| Test-writing rules and expected-output generator | `tests/AUTHORING.md`, `tests/gen_expected.py` |
| Visible/hidden split (hash of case name, 50/50) | `tests/split.json` |
| Starting projects with an identical I/O module | `harness/templates/{rust,moonbit}` |
| Language primers (same four sections each) | `harness/primers/{RUST,MOONBIT}.md` |
| Agent instructions and prompts | `harness/prompts/` |
| Orchestrator, metrics, token counter, report | `harness/experiment.py`, `metrics.py`, `count_tokens.py`, `report.py` |

**Project: minisql.** A CLI that reads SQL from stdin and prints results, with
SQLite 3.53 as the behavioral reference. Nine milestones (SPEC §4): core
pipeline → expressions and ~60 functions → DML and constraints → aggregation
and date/time → joins, subqueries and compound queries → indexes, views,
ALTER and transactions → CTEs and window functions → reading real SQLite
database files → writing them. Expected outputs come from real SQLite, so the
oracle is exact; every case is rerun with `PRAGMA reverse_unordered_selects`
to reject tests whose row order isn't fixed.

**Sessions.** Each (language, trial) gets a fresh workspace (a git repo
outside this directory). For each milestone the harness copies in that
milestone's visible tests and starts a new headless session:

```
claude -p <milestone prompt> --model claude-opus-5-5 --effort high
  --tools Bash,Read,Edit,Write --dangerously-skip-permissions
  --disable-slash-commands --strict-mcp-config --setting-sources project
  --settings '{"autoMemoryEnabled":false}' --output-format stream-json
```

A fresh session per milestone means the cost of re-reading existing code is
part of the measurement: denser code is cheaper to revisit. If the agent stops
with visible tests still failing, the same session is nudged up to twice with
the failure count. Usage-limit interruptions are detected, waited out, and
resumed in the same session; they're recorded but don't change the token
totals. After each milestone the harness commits a snapshot, scores it on
pristine copies of the visible and hidden tests of all milestones so far,
measures the source, and checks the rules.

## Fairness controls

- **Same everything except the language:** spec, tests, prompts, model,
  effort, tools, and harness. The per-language differences are only the
  language name, build command, binary path, and primer.
- **Standard library only.** No crates and no MoonBit registry packages; no FFI
  or C code; no linking SQLite; no spawning processes. Checked automatically
  after each milestone (`metrics.compliance`).
- **Identical I/O layer.** MoonBit's core library can't read stdin or files,
  so both templates ship the same five-function `io` module (read stdin, write
  stdout, args, read/write whole file). MoonBit's is a small C stub, Rust's
  wraps std. Agents can't modify it, and all I/O must go through it in both
  languages.
- **Primers.** MoonBit is new and thin in training data, so its agent gets a
  primer (≈4–6k tokens) covering toolchain, syntax, core APIs and common
  mistakes, with every snippet compiled against the installed toolchain. The
  Rust agent gets a primer with the same four sections, shorter because the
  model already knows Rust. Neither contains any SQL-engine design advice. The
  primer sits in the workspace `CLAUDE.md`, so its cost shows up in every
  session's cache reads. An optional `moonbit-noprimer` arm measures what the
  primer is worth.
- **Isolated sessions.** No user settings, memory, skills or MCP servers (this
  machine has a MoonBit skill installed globally; it's excluded so it can't
  help one side unevenly). No web tools. Both sides may run `sqlite3` to
  check behavior.
- **Paired scheduling.** Trials run in Rust/MoonBit pairs at the same time, so
  both sides see the same service conditions.
- **Hidden tests.** Half of each milestone's cases are never shown to the
  agent. Transcripts are scanned for access to this directory or the network.

## Repository layout

| Path | Contents |
|---|---|
| `implementations/<lang>-t<N>/` | Final source of each trial's engine (tests and tools removed; `CLAUDE.md` is the exact instruction file the agent saw) |
| `runs/<lang>-t<N>/history.bundle` | Full git history of the trial workspace, one commit per milestone: `git clone runs/rust-t1/history.bundle rust-t1` |
| `runs/<lang>-t<N>/state.json` | Per-milestone session metrics, evaluation results and compliance checks |
| `runs/<lang>-t<N>/mNN/` | Agent transcripts (`session-*.jsonl.gz`, Claude Code stream-json), visible/hidden test results and logs |
| `results/` | `report.md`, `trials.csv`, `milestones.csv`, and the results page `moonbit-vs-rust.html` |
| `analysis/` | Follow-up analysis of where MoonBit cost the agent extra |

## Results (3 trials per language, Claude Opus 5.5, effort high)

| Metric (mean) | Rust | MoonBit | MoonBit ÷ Rust |
|---|---|---|---|
| Estimated cost (API prices) | $43.86 ± 13.25 | $41.09 ± 3.97 | 0.94 (median 1.12) |
| Output tokens | 868k | 762k | 0.88 |
| Input tokens until visible tests first all pass | 21.7M | 23.6M | 1.09 |
| Hidden tests passed | 96.3% | 95.6% | 0.99 |
| Final source tokens | 194k | 172k | 0.88 |
| Failed-build rate | 5.8% | 13.0% | 2.25 |
| Wall time (median) | 2.19 h | 2.19 h | 1.00 |

Agent cost is a draw within run-to-run noise; the largest source of variance is how long an agent keeps hardening after its tests pass (47–82% of input tokens). MoonBit writes about 12% less code; its unfamiliarity shows up as more compile errors plus the primer's re-read cost (about $1.40 per trial). See `results/report.md`.

## Metrics

Per milestone and per trial (`results/milestones.csv`, `results/trials.csv`):

- `output_tokens` (includes thinking), `input_tokens`,
  `cache_creation_input_tokens`, `cache_read_input_tokens`, `cost_usd` (Claude
  Code's estimate at API list prices; on a subscription nothing is billed per
  token), `num_turns`, `api_calls`, `max_context_tokens`, `compactions`,
  wall time.
- `build_attempts` / `build_failures` (from compiler invocations in the
  transcript), `test_runs`, nudges, usage-limit interruptions.
- Hidden and visible pass rates, cumulative and for the milestone itself.
- Source size: tokens (exact, via the model's tokenizer; see
  `count_tokens.py`), code lines, bytes, files; lines added/deleted per
  milestone.
- Derived: output tokens per hidden test passed, cost per hidden test passed,
  output tokens per final source token (how much the agent writes, rewrites or
  thinks per token of code it keeps).

## Running

Prerequisites: `claude` (logged in; a subscription works), `cargo`, `moon`
with the native backend, Python 3 with the stdlib `sqlite3` module (3.53
here; the version that produced `.expected` files).

```bash
python3 tests/gen_expected.py --check               # expected outputs are current
python3 harness/experiment.py batch --arms rust,moonbit --trials 1 --upto 1   # smoke test: milestone 1
python3 harness/experiment.py batch --arms rust,moonbit --trials 1-3 --parallel 2
python3 harness/experiment.py status
python3 harness/report.py                           # writes results/
```

Runs are resumable: rerunning `batch` continues each trial from its last
unfinished milestone. `MINISQL_CLAUDE_BIN=harness/fake_claude.py` runs the
whole pipeline with a zero-cost fake agent.

## Threats to validity

- **n = 3 per language.** Agent runs vary a lot; report means with spread and
  treat small differences as noise.
- **One model, one harness.** Results are about Claude Opus 5.5 in Claude Code,
  not languages in the abstract.
- **Primer design.** A better or worse MoonBit primer changes the result; the
  `moonbit-noprimer` arm bounds the effect.
- **Toolchain maturity.** MoonBit's compiler messages, build speed and core
  library breadth are part of what's measured, intentionally. Wall time also
  includes compile time, which differs between toolchains.
- **Test suite as spec.** Tests generated from SQLite are exact but can't cover
  everything; hidden tests guard against overfitting to the visible half.
- **Tokenizer counts** are measured through the CLI with ±3 tokens of noise
  per file; negligible at this scale.
