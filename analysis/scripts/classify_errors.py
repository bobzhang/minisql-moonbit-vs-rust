"""Root-cause classification of every failed build/check attempt (manual labels,
made by reading each attempt's diagnostics and the agent's follow-up), plus an
estimate of what each failure cost: API calls and output chars from the failed
attempt until the next successful build, and the context size at that point.
Writes analysis/compile_errors.json and analysis/compile_errors.csv."""
import collections, csv, json, os

RUNS = os.path.expanduser("~/minisql-bench-runs")
A = "/Users/dii/git/bench/analysis"

# Categories. "lang" = language/toolchain-specific (would not occur the same way in the other language);
# "neutral" = would happen in any statically typed language (refactor ripple, work in progress).
CATS = {
    "reserved_word": ("lang", "Identifier is a (reserved) keyword: `using` error; renames forced by `alias` warnings"),
    "tuple_mut_pattern": ("lang", "`let (mut a, b) = ...` is not valid syntax (Rust habit)"),
    "ctor_dotdot_positional": ("lang", "`C(..)` wildcard rejected for constructors with positional args"),
    "error_effect": ("lang", "raise/effect typing: missing `raise` in signature, non-raising fn where raising fn type expected"),
    "closure_effect_syntax": ("lang", "`fn(x) raise E -> T` instead of `fn(x) -> T raise E`"),
    "loop_value_nobreak": ("lang", "`while true { return ... }` in value position needs `nobreak`"),
    "old_generic_syntax": ("lang", "`fn f[T]` instead of `fn[T] f` (removed syntax)"),
    "unknown_core_api": ("lang", "non-existent / wrong core API (map_raise, StringView vs String result)"),
    "int_width_numeric": ("lang", "Int vs Int64 mixing / wrong conversion method"),
    "ambiguous_constructor": ("lang", "same constructor name in two enums in one package"),
    "field_fn_call": ("lang", "calling a closure-typed struct field as a method (needs `(x.f)(...)`)"),
    "pkg_import": ("lang", "package used without import in moon.pkg / module file missing"),
    "unused_mut_is_error": ("lang", "warning 0015 (unused mut field) is a hard error"),
    "for_in_custom_type": ("lang", "`for x in y` on a user type without `iter()`"),
    "borrow_checker": ("lang", "Rust ownership/borrowing (E0502/E0506/E0507/E0521)"),
    "rust_type_inference": ("lang", "Rust closure/Result type annotations needed (E0282/E0283)"),
    "rust_immutable_binding": ("lang", "assign to non-mut binding (E0384)"),
    "rust_missing_trait_impl": ("lang", "operator on type without PartialEq derive (E0369)"),
    "exhaustiveness": ("neutral", "new enum variant not handled in existing matches"),
    "refactor_ripple": ("neutral", "signature/struct/constructor changed, call sites not yet updated"),
    "work_in_progress": ("neutral", "checked before the referenced code was written / typo"),
    "error_hidden_by_output_filter": ("lang", "error not visible because output was piped through tail/grep and warnings buried it (needed a re-run)"),
}

# (trial, milestone, step) -> (primary, [secondary...])
LABELS = {
    ("moonbit-t1", "m01", 14): ("unknown_core_api", []),
    ("moonbit-t1", "m01", 29): ("unknown_core_api", []),  # StringView.replace_all result is not a String
    ("moonbit-t1", "m02", 24): ("work_in_progress", []),  # Value?? typo + functions defined in next file
    ("moonbit-t1", "m02", 25): ("old_generic_syntax", []),
    ("moonbit-t1", "m03", 19): ("exhaustiveness", []),
    ("moonbit-t1", "m03", 27): ("refactor_ripple", []),
    ("moonbit-t1", "m04", 24): ("tuple_mut_pattern", []),
    ("moonbit-t1", "m05", 23): ("reserved_word", []),
    ("moonbit-t1", "m05", 24): ("reserved_word", []),
    ("moonbit-t1", "m05", 51): ("work_in_progress", []),
    ("moonbit-t1", "m06", 23): ("error_hidden_by_output_filter", ["exhaustiveness"]),
    ("moonbit-t1", "m06", 24): ("exhaustiveness", []),
    ("moonbit-t1", "m06", 28): ("refactor_ripple", ["error_effect"]),
    ("moonbit-t1", "m06", 33): ("refactor_ripple", []),
    ("moonbit-t1", "m06", 52): ("refactor_ripple", []),
    ("moonbit-t1", "m07", 29): ("exhaustiveness", []),
    ("moonbit-t1", "m07", 33): ("work_in_progress", []),
    ("moonbit-t1", "m09", 16): ("error_hidden_by_output_filter", ["pkg_import"]),
    ("moonbit-t1", "m09", 17): ("pkg_import", []),
    ("moonbit-t2", "m01", 30): ("reserved_word", []),  # rename alias->as_name (warning-driven) broke a label
    ("moonbit-t2", "m02", 27): ("int_width_numeric", []),
    ("moonbit-t2", "m03", 28): ("work_in_progress", ["reserved_word", "refactor_ripple", "for_in_custom_type"]),
    ("moonbit-t2", "m03", 29): ("reserved_word", ["work_in_progress"]),
    ("moonbit-t2", "m03", 30): ("work_in_progress", []),
    ("moonbit-t2", "m04", 23): ("refactor_ripple", []),
    ("moonbit-t2", "m05", 25): ("reserved_word", ["ctor_dotdot_positional", "field_fn_call", "loop_value_nobreak"]),
    ("moonbit-t2", "m05", 26): ("ctor_dotdot_positional", ["reserved_word"]),
    ("moonbit-t2", "m06", 33): ("error_effect", []),
    ("moonbit-t2", "m06", 35): ("closure_effect_syntax", []),
    ("moonbit-t2", "m06", 123): ("exhaustiveness", []),
    ("moonbit-t2", "m07", 23): ("exhaustiveness", []),
    ("moonbit-t2", "m07", 25): ("ctor_dotdot_positional", []),
    ("moonbit-t2", "m07", 26): ("exhaustiveness", []),
    ("moonbit-t3", "m01", 12): ("reserved_word", ["loop_value_nobreak"]),
    ("moonbit-t3", "m01", 15): ("work_in_progress", []),
    ("moonbit-t3", "m02", 24): ("error_hidden_by_output_filter", ["ambiguous_constructor"]),
    ("moonbit-t3", "m02", 25): ("ambiguous_constructor", []),
    ("moonbit-t3", "m02", 30): ("error_effect", []),  # non-raising fn not accepted as raising fn value
    ("moonbit-t3", "m04", 16): ("error_hidden_by_output_filter", ["work_in_progress"]),
    ("moonbit-t3", "m04", 22): ("tuple_mut_pattern", []),
    ("moonbit-t3", "m05", 21): ("refactor_ripple", ["reserved_word"]),
    ("moonbit-t3", "m06", 34): ("work_in_progress", []),
    ("moonbit-t3", "m06", 66): ("refactor_ripple", []),
    ("moonbit-t3", "m06", 151): ("tuple_mut_pattern", ["refactor_ripple"]),
    ("moonbit-t3", "m06", 152): ("tuple_mut_pattern", []),
    ("moonbit-t3", "m06", 154): ("refactor_ripple", []),
    ("moonbit-t3", "m06", 156): ("refactor_ripple", ["unused_mut_is_error"]),
    ("moonbit-t3", "m06", 158): ("refactor_ripple", ["unused_mut_is_error"]),
    # Rust
    ("rust-t1", "m01", 30): ("rust_immutable_binding", []),
    ("rust-t1", "m04", 18): ("refactor_ripple", []),
    ("rust-t1", "m07", 24): ("refactor_ripple", ["exhaustiveness"]),
    ("rust-t1", "m09", 25): ("borrow_checker", ["rust_missing_trait_impl"]),
    ("rust-t2", "m02", 17): ("refactor_ripple", []),
    ("rust-t2", "m03", 30): ("borrow_checker", []),
    ("rust-t2", "m04", 20): ("rust_type_inference", []),
    ("rust-t2", "m06", 26): ("work_in_progress", []),  # module file not yet created
    ("rust-t2", "m07", 34): ("borrow_checker", []),
    ("rust-t3", "m02", 35): ("work_in_progress", []),
    ("rust-t3", "m03", 17): ("borrow_checker", []),
    ("rust-t3", "m05", 30): ("refactor_ripple", []),
    ("rust-t3", "m05", 31): ("refactor_ripple", []),
    ("rust-t3", "m06", 178): ("refactor_ripple", []),
    ("rust-t3", "m07", 25): ("refactor_ripple", ["exhaustiveness"]),
    ("rust-t3", "m07", 29): ("exhaustiveness", []),
}


NEXT_ONLY = False


def fix_cost(trial, m, session, fail_step, builds_by_session):
    """API calls and assistant output chars from the failed build until the next build that did not fail."""
    later = [b for b in builds_by_session[(trial, m, session)] if b["step"] > fail_step]
    ok_step = next((b["step"] for b in later if not b["failed"]), None)
    if NEXT_ONLY:
        ok_step = later[0]["step"] if later else None
    path = f"{RUNS}/{trial}/records/{m}/{session}"
    step, calls, chars, ctx, active = 0, set(), 0, 0, False
    for line in open(path):
        ev = json.loads(line)
        if ev.get("type") != "assistant":
            continue
        msg = ev["message"]
        for c in msg.get("content", []):
            if c.get("type") == "tool_use":
                step += 1
            if active:
                chars += len(json.dumps(c.get("input", ""))) if c.get("type") == "tool_use" else len(c.get("text") or c.get("thinking") or "")
        if step > fail_step and (ok_step is None or step <= ok_step):
            if not active:
                active = True
                for c in msg.get("content", []):
                    chars += len(json.dumps(c.get("input", ""))) if c.get("type") == "tool_use" else len(c.get("text") or c.get("thinking") or "")
            calls.add(msg.get("id"))
            u = msg.get("usage", {})
            ctx = max(ctx, u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0))
        if ok_step is not None and step > ok_step:
            break
    if NEXT_ONLY:
        return {"calls_to_next_build": len(calls), "assistant_chars_to_next_build": chars, "context_tokens": ctx}
    return {"calls_to_green_build": len(calls), "assistant_chars_to_green_build": chars, "context_tokens": ctx}


builds = json.load(open(f"{A}/builds.json"))
by_sess = collections.defaultdict(list)
for b in builds:
    by_sess[(b["trial"], b["m"], b["session"])].append(b)
rows = []
for b in builds:
    if not b["failed"]:
        continue
    key = (b["trial"], b["m"], b["step"])
    prim, sec = LABELS[key]
    NEXT_ONLY = False
    cost = fix_cost(b["trial"], b["m"], b["session"], b["step"], by_sess)
    NEXT_ONLY = True
    cost.update(fix_cost(b["trial"], b["m"], b["session"], b["step"], by_sess))
    diags = [{"code": d["code"], "msg": d["msg"].split("\n")[0][:200], "file": d["file"], "line": d["line"], "src": d["src"][:160]}
             for d in b["diags"] if d["sev"] == "error"]
    rows.append({"trial": b["trial"], "lang": b["lang"], "m": b["m"], "session": b["session"], "step": b["step"],
                 "primary": prim, "secondary": sec, "kind": CATS[prim][0], "n_errors": len(diags),
                 "codes": sorted({d["code"] for d in diags}), "diagnostics": diags, **cost})
json.dump({"categories": CATS, "attempts": rows}, open(f"{A}/compile_errors.json", "w"), indent=1)
with open(f"{A}/compile_errors.csv", "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["lang", "trial", "milestone", "step", "primary", "secondary", "kind", "n_errors", "codes",
                "calls_to_next_build", "assistant_chars_to_next_build", "calls_to_green_build", "assistant_chars_to_green_build", "context_tokens", "first_error"])
    for r in rows:
        fe = r["diagnostics"][0] if r["diagnostics"] else {"code": "", "msg": ""}
        w.writerow([r["lang"], r["trial"], r["m"], r["step"], r["primary"], ";".join(r["secondary"]), r["kind"],
                    r["n_errors"], " ".join(r["codes"]), r["calls_to_next_build"], r["assistant_chars_to_next_build"], r["calls_to_green_build"], r["assistant_chars_to_green_build"], r["context_tokens"],
                    f"[{fe['code']}] {fe['msg'][:120]}"])

for lang in ("moonbit", "rust"):
    rs = [r for r in rows if r["lang"] == lang]
    print(f"\n{lang}: {len(rs)} failed attempts")
    prim = collections.Counter(r["primary"] for r in rs)
    anyc = collections.Counter(c for r in rs for c in {r["primary"], *r["secondary"]})
    for c, n in sorted(anyc.items(), key=lambda x: -prim.get(x[0], 0) * 100 - x[1]):
        sub = [r for r in rs if r["primary"] == c]
        trials = sorted({r["trial"][-2:] for r in rs if c in {r["primary"], *r["secondary"]}})
        print(f"  {c:30s} {CATS[c][0]:7s} primary={prim.get(c,0):2d} involved={n:2d} trials={','.join(trials)} "
              f"next: calls={sum(r['calls_to_next_build'] for r in sub)} chars={sum(r['assistant_chars_to_next_build'] for r in sub)} | green: calls={sum(r['calls_to_green_build'] for r in sub)} ctx_avg={round(sum(r['context_tokens'] for r in sub)/max(1,len(sub)))}")
    k = collections.Counter(r["kind"] for r in rs)
    print("  by kind:", dict(k))
    for kind in ("lang", "neutral"):
        sub = [r for r in rs if r["kind"] == kind]
        print(f"   {kind}: next-build calls={sum(r['calls_to_next_build'] for r in sub)} chars={sum(r['assistant_chars_to_next_build'] for r in sub)} avg_ctx={round(sum(r['context_tokens'] for r in sub)/max(1,len(sub)))}")
