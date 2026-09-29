"""Extract metrics from a `claude -p --output-format stream-json` transcript
and from a workspace snapshot."""

from __future__ import annotations

import json
import os
import re
import subprocess

BUILD_CMD = re.compile(r"^(\S+=\S+\s+)*(cargo\s+(build|check|run|test)|moon\s+(build|check|run|test)|rustc)\b")
TEST_CMD = re.compile(r"^(\S+=\S+\s+)*(python3?\s+)?\S*run_tests\.py\b")
SEGMENT_SPLIT = re.compile(r"&&|\|\||;|\||\n")


def classify_command(cmd: str) -> str | None:
    """'test' if the command runs the test runner, 'build' if it invokes a
    compiler, else None. Only real invocations count, not commands that merely
    mention these names (e.g. `sed -n 1,80p tools/run_tests.py`)."""
    kinds = set()
    for seg in SEGMENT_SPLIT.split(cmd):
        seg = seg.strip().lstrip("(").strip()
        if seg.startswith(("time ", "timeout ")):
            seg = seg.split(None, 2)[-1] if seg.startswith("timeout ") else seg[5:]
        if TEST_CMD.match(seg):
            kinds.add("test")
        elif BUILD_CMD.match(seg):
            kinds.add("build")
    return "test" if "test" in kinds else ("build" if "build" in kinds else None)
# Compiler diagnostics only (case-sensitive): rustc/cargo "error[E0308]:" / "error: could not compile",
# moon "Error: [4014]" / "Failed with 2 warnings, 1 errors". Engine output such as
# "Error: no such table" printed by the same command must not count.
BUILD_FAIL = re.compile(r"(^|\n)\s*error(\[E\d+\])?: |Error: \[\d{4}\]|\b[1-9]\d* errors?\b|could not compile|failed when (checking|building)")
RATE_LIMIT = re.compile(r"rate.?limit|usage limit|limit reached|hit your limit|resets? (at|in)|overloaded|\b429\b|\b529\b", re.I)
OUTSIDE = re.compile(r"(/Users/[^/\s]+/git/bench|tests/cases|split\.json|curl |wget |https?://)")


def _text_of(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(c.get("text", "") for c in content if isinstance(c, dict))
    return ""


def parse_transcript(path: str) -> dict:
    """Summarize one session transcript."""
    result = None
    calls: dict[str, dict] = {}  # API calls deduped by message id
    tool_uses: dict[str, dict] = {}
    tool_counts: dict[str, int] = {}
    builds = build_fails = test_runs = compactions = 0
    suspicious: list[str] = []
    session_id = None
    green = None  # snapshot when a full test run first passes everything
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            t = ev.get("type")
            if t == "system" and ev.get("subtype") == "init":
                session_id = ev.get("session_id")
            elif t == "system" and "compact" in str(ev.get("subtype", "")):
                compactions += 1
            elif t == "assistant":
                msg = ev.get("message", {})
                if msg.get("id") and msg.get("usage"):
                    calls[msg["id"]] = msg["usage"]
                for c in msg.get("content", []) or []:
                    if c.get("type") == "tool_use":
                        tool_uses[c["id"]] = c
                        tool_counts[c["name"]] = tool_counts.get(c["name"], 0) + 1
                        if c["name"] == "Bash":
                            cmd = c.get("input", {}).get("command", "")
                            if OUTSIDE.search(cmd):
                                suspicious.append(cmd[:200])
                        elif c["name"] in ("Read", "Edit", "Write"):
                            p = str(c.get("input", {}).get("file_path", ""))
                            if OUTSIDE.search(p):
                                suspicious.append(f"{c['name']} {p}")
            elif t == "user":
                for c in ev.get("message", {}).get("content", []) or []:
                    if not (isinstance(c, dict) and c.get("type") == "tool_result"):
                        continue
                    use = tool_uses.get(c.get("tool_use_id"))
                    if not use or use["name"] != "Bash":
                        continue
                    cmd = use.get("input", {}).get("command", "")
                    out = _text_of(c.get("content"))
                    kind = classify_command(cmd)
                    if kind == "test" and green is None and not re.search(r"\s(-k|-m|--milestone)\b", cmd):
                        tot = re.findall(r"TOTAL: (\d+)/(\d+) passed", out)
                        if tot and tot[-1][0] == tot[-1][1]:
                            green = {"api_calls": len(calls), "input_tokens": sum(
                                u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0)
                                + u.get("cache_creation_input_tokens", 0) for u in calls.values())}
                    if kind == "test":
                        test_runs += 1
                        builds += 1
                        if re.search(r"^BUILD FAILED", out, re.M):
                            build_fails += 1
                    elif kind == "build":
                        builds += 1
                        if BUILD_FAIL.search(out):
                            build_fails += 1
            elif t == "result":
                result = ev

    per_call = list(calls.values())
    ctx = [u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
           for u in per_call]
    summary = {
        "session_id": session_id or (result or {}).get("session_id"),
        "api_calls": len(per_call),
        "max_context_tokens": max(ctx) if ctx else 0,
        "tool_calls": tool_counts,
        "build_attempts": builds,
        "build_failures": build_fails,
        "test_runs": test_runs,
        "compactions": compactions,
        "suspicious_commands": suspicious,
        "complete": result is not None,
        # First moment every visible test passed. Per-call input usage in the stream is exact;
        # per-call output usage is not, so only input tokens and calls are recorded.
        "green_api_calls": green["api_calls"] if green else None,
        "green_input_tokens": green["input_tokens"] if green else None,
    }
    if result:
        u = result.get("usage", {})
        summary.update({
            "subtype": result.get("subtype"),
            "is_error": result.get("is_error"),
            "result_text": (result.get("result") or "")[:2000],
            "num_turns": result.get("num_turns"),
            "duration_ms": result.get("duration_ms"),
            "duration_api_ms": result.get("duration_api_ms"),
            "cost_usd": result.get("total_cost_usd"),
            "input_tokens": u.get("input_tokens", 0),
            "cache_creation_input_tokens": u.get("cache_creation_input_tokens", 0),
            "cache_read_input_tokens": u.get("cache_read_input_tokens", 0),
            "output_tokens": u.get("output_tokens", 0),
            "model_usage": result.get("modelUsage"),
        })
    else:
        # Session died without a result event: fall back to per-call sums.
        summary.update({
            "subtype": "no_result", "is_error": True, "result_text": "",
            "num_turns": None, "duration_ms": None, "duration_api_ms": None, "cost_usd": None,
            "input_tokens": sum(u.get("input_tokens", 0) for u in per_call),
            "cache_creation_input_tokens": sum(u.get("cache_creation_input_tokens", 0) for u in per_call),
            "cache_read_input_tokens": sum(u.get("cache_read_input_tokens", 0) for u in per_call),
            "output_tokens": sum(u.get("output_tokens", 0) for u in per_call),
            "model_usage": None,
        })
    summary["rate_limited"] = bool(summary["is_error"] and RATE_LIMIT.search(summary["result_text"] or ""))
    return summary


# ---------------------------------------------------------------------------
# Source snapshot statistics
# ---------------------------------------------------------------------------


def source_files(work: str, arm: dict) -> list[str]:
    files = []
    io_mod = arm["io_module"].rstrip("/")
    for dirpath, dirnames, filenames in os.walk(work):
        rel_dir = os.path.relpath(dirpath, work)
        dirnames[:] = [d for d in dirnames
                       if d not in arm["ignore_dirs"] and not d.startswith(".")
                       and os.path.normpath(os.path.join(rel_dir, d)) != io_mod]
        for fn in filenames:
            rel = os.path.normpath(os.path.join(rel_dir, fn))
            if rel == io_mod:
                continue
            if any(fn.endswith(ext) for ext in arm["source_ext"]):
                files.append(rel)
    return sorted(files)


def is_test_file(rel: str, arm: dict) -> bool:
    return any(p in rel for p in arm["test_file_patterns"])


def line_stats(text: str) -> dict:
    lines = text.split("\n")
    nonblank = [l for l in lines if l.strip()]
    comment = [l for l in nonblank if l.strip().startswith("//")]
    return {"lines": len(lines), "nonblank": len(nonblank), "comment": len(comment),
            "code": len(nonblank) - len(comment), "bytes": len(text.encode("utf-8")),
            "words": len(re.findall(r"\w+|[^\w\s]", text))}


def snapshot_stats(work: str, arm: dict, exact_tokens: bool) -> dict:
    files = source_files(work, arm)
    texts = [open(os.path.join(work, f), encoding="utf-8", errors="replace").read() for f in files]
    tokens = [None] * len(files)
    if exact_tokens and files:
        from count_tokens import count_texts
        tokens = count_texts(texts)
    per_file = []
    for f, t, n in zip(files, texts, tokens):
        s = line_stats(t)
        s.update({"file": f, "tokens": n, "test": is_test_file(f, arm)})
        per_file.append(s)

    def total(sel, key):
        vals = [p[key] for p in per_file if sel(p)]
        return None if any(v is None for v in vals) else sum(vals)

    out = {"files": per_file}
    for label, sel in (("all", lambda p: True), ("main", lambda p: not p["test"]), ("test", lambda p: p["test"])):
        out[label] = {k: total(sel, k) for k in ("lines", "nonblank", "code", "comment", "bytes", "words", "tokens")}
        out[label]["n_files"] = sum(1 for p in per_file if sel(p))
    return out


def git_churn(work: str, rev_from: str, rev_to: str = "HEAD") -> dict:
    r = subprocess.run(["git", "diff", "--numstat", rev_from, rev_to], cwd=work,
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    added = deleted = 0
    for line in r.stdout.splitlines():
        a, d, _ = line.split("\t", 2)
        if a.isdigit():
            added += int(a)
            deleted += int(d)
    return {"lines_added": added, "lines_deleted": deleted}


# ---------------------------------------------------------------------------
# Rule compliance
# ---------------------------------------------------------------------------

FORBIDDEN = {
    ".rs": [(r"std::fs\b|std::process\b|std::net\b|std::os\b", "OS access outside io module"),
            (r"extern\s+\"C\"|#\[link\b", "FFI"),
            (r"\b(println|print)!\s*\(", "stdout bypassing io module")],
    ".mbt": [(r"extern\s+\"[cC]\"", "FFI"),
             (r"(^|[^.\w])println\s*\(", "stdout bypassing io module")],
}


def compliance(work: str, arm: dict, template_dir: str) -> dict:
    issues = []
    for rel in source_files(work, arm):
        if is_test_file(rel, arm):
            continue
        text = open(os.path.join(work, rel), encoding="utf-8", errors="replace").read()
        for ext, rules in FORBIDDEN.items():
            if rel.endswith(ext):
                for rx, why in rules:
                    if re.search(rx, text, re.M):
                        issues.append(f"{rel}: {why}")
    # io module unchanged
    io_rel = arm["io_module"].rstrip("/")
    tpl, cur = os.path.join(template_dir, io_rel), os.path.join(work, io_rel)
    r = subprocess.run(["diff", "-r", "-w", "-B", tpl, cur], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    if r.returncode != 0:
        issues.append(f"io module modified: {r.stdout[:300]}")
    # dependencies
    cargo = os.path.join(work, "Cargo.toml")
    if os.path.exists(cargo):
        text = open(cargo).read()
        deps = re.search(r"\[(dev-|build-)?dependencies\]\s*\n\s*[A-Za-z]", text)
        if deps:
            issues.append("Cargo.toml declares dependencies")
        if os.path.exists(os.path.join(work, "build.rs")):
            issues.append("build.rs present")
    mod = os.path.join(work, "moon.mod")
    if os.path.exists(mod) and re.search(r"^\s*import\s*\{", open(mod).read(), re.M):
        issues.append("moon.mod imports external modules")
    for dirpath, dirnames, filenames in os.walk(work):
        dirnames[:] = [d for d in dirnames if d not in ("target", "_build", ".git", ".mooncakes")]
        for fn in filenames:
            if fn.endswith((".c", ".h", ".cc", ".cpp")):
                rel = os.path.relpath(os.path.join(dirpath, fn), work)
                if not rel.startswith(io_rel):
                    issues.append(f"C source file {rel}")
    return {"ok": not issues, "issues": issues}
