#!/usr/bin/env python3
"""Run the Rust-vs-MoonBit token-efficiency experiment.

  experiment.py setup   ARM TRIAL            create a fresh workspace
  experiment.py run     ARM TRIAL [--upto N] run milestone sessions (resumable)
  experiment.py eval    ARM TRIAL --milestone N [--exact-tokens]
  experiment.py batch   --arms rust,moonbit --trials 1-3 [--parallel 2] [--upto N]
  experiment.py status

A trial lives in <runs_dir>/<ARM>-t<TRIAL>/ with
  work/      the agent's workspace (a git repo, committed after every milestone)
  records/   transcripts, per-milestone metrics, evaluation results, state.json
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import metrics  # noqa: E402

CONFIG = json.load(open(os.path.join(HERE, "config.json")))
RUNS = os.path.expanduser(os.environ.get("MINISQL_RUNS_DIR", CONFIG["runs_dir"]))
CASES = os.path.join(ROOT, "tests", "cases")
SPLIT = json.load(open(os.path.join(ROOT, "tests", "split.json"))) if os.path.exists(
    os.path.join(ROOT, "tests", "split.json")) else {}
TITLES = {n: t for n, t in CONFIG["milestones"]}


def log(trial: str, msg: str) -> None:
    ts = datetime.now().strftime("%H:%M:%S")
    line = f"[{ts}] {trial}: {msg}"
    print(line, flush=True)
    with open(os.path.join(RUNS, "experiment.log"), "a") as f:
        f.write(line + "\n")


def paths(arm: str, trial: int) -> tuple[str, str, str]:
    base = os.path.join(RUNS, f"{arm}-t{trial}")
    return base, os.path.join(base, "work"), os.path.join(base, "records")


def load_state(records: str) -> dict:
    p = os.path.join(records, "state.json")
    return json.load(open(p)) if os.path.exists(p) else {"milestones": {}}


def save_state(records: str, state: dict) -> None:
    p = os.path.join(records, "state.json")
    with open(p + ".tmp", "w") as f:
        json.dump(state, f, indent=1)
    os.replace(p + ".tmp", p)


def git(work: str, *args: str) -> str:
    r = subprocess.run(["git", *args], cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0 and args[0] != "commit":
        raise RuntimeError(f"git {' '.join(args)}: {r.stdout}")
    return r.stdout.strip()


def commit(work: str, msg: str) -> str:
    git(work, "add", "-A")
    git(work, "-c", "user.name=harness", "-c", "user.email=harness@localhost",
        "commit", "-q", "--allow-empty", "-m", msg)
    return git(work, "rev-parse", "HEAD")


# ---------------------------------------------------------------------------
# Workspace setup
# ---------------------------------------------------------------------------


def render_claude_md(arm_cfg: dict) -> str:
    tmpl = open(os.path.join(HERE, "prompts", "CLAUDE.md.tmpl")).read()
    primer = ""
    if arm_cfg.get("primer") and not (os.environ.get("MINISQL_HARNESS_TEST")
                                      and not os.path.exists(os.path.join(HERE, "primers", arm_cfg["primer"]))):
        body = open(os.path.join(HERE, "primers", arm_cfg["primer"])).read().strip()
        primer = f"\n# {arm_cfg['language']} primer\n\n{body}\n"
    return tmpl.format(language=arm_cfg["language"], io_module=arm_cfg["io_module"],
                       build=arm_cfg["build"], binary=arm_cfg["binary"], primer_section=primer)


def copy_visible_tests(work: str, n: int) -> None:
    m = f"m{n:02d}"
    dst = os.path.join(work, "tests", m)
    os.makedirs(dst, exist_ok=True)
    for name in SPLIT[m]["visible"]:
        for ext in (".sql", ".expected"):
            shutil.copy(os.path.join(CASES, m, name + ext), dst)


def setup(arm: str, trial: int) -> None:
    arm_cfg = CONFIG["arms"][arm]
    base, work, records = paths(arm, trial)
    if os.path.exists(base):
        raise SystemExit(f"{base} already exists")
    shutil.copytree(os.path.join(HERE, "templates", arm_cfg["template"]), work)
    os.makedirs(records)
    shutil.copy(os.path.join(ROOT, "spec", "SPEC.md"), work)
    os.makedirs(os.path.join(work, "tools"))
    for f in ("run_tests.py", "sqlref.py"):
        shutil.copy(os.path.join(HERE, f), os.path.join(work, "tools"))
    lang = {"build": arm_cfg["build"], "binary": arm_cfg["binary"]}
    json.dump(lang, open(os.path.join(work, "tools", "lang.json"), "w"), indent=1)
    json.dump(lang, open(os.path.join(records, "lang.json"), "w"), indent=1)
    with open(os.path.join(work, "CLAUDE.md"), "w") as f:
        f.write(render_claude_md(arm_cfg))
    with open(os.path.join(work, ".gitignore"), "a") as f:
        f.write("__pycache__/\n")
    git(work, "init", "-q")
    rev = commit(work, "template")
    primer_tokens = 0
    if arm_cfg.get("primer") and not os.environ.get("MINISQL_HARNESS_TEST"):
        from count_tokens import count_texts
        primer_tokens = count_texts([open(os.path.join(HERE, "primers", arm_cfg["primer"])).read()])[0]
    state = {"primer_tokens": primer_tokens,"arm": arm, "trial": trial, "model": CONFIG["model"], "effort": CONFIG["effort"],
             "created": datetime.now(timezone.utc).isoformat(), "template_rev": rev,
             "claude_version": subprocess.run(["claude", "--version"], stdout=subprocess.PIPE, text=True).stdout.strip(),
             "milestones": {}}
    save_state(records, state)
    log(f"{arm}-t{trial}", f"workspace ready at {work}")


# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------


def claude_cmd(prompt: str, resume: str | None) -> list[str]:
    s = CONFIG["session"]
    cmd = [os.environ.get("MINISQL_CLAUDE_BIN", "claude"), "-p", prompt, "--model", CONFIG["model"], "--effort", CONFIG["effort"],
           "--output-format", "stream-json", "--verbose",
           "--tools", s["tools"], "--dangerously-skip-permissions",
           "--disable-slash-commands", "--strict-mcp-config", "--setting-sources", "project",
           "--settings", '{"autoMemoryEnabled":false}']
    if resume:
        cmd += ["--resume", resume]
    return cmd


def run_session(tag: str, work: str, transcript: str, prompt: str, resume: str | None) -> dict:
    env = {**os.environ, "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"}
    timeout = CONFIG["session"]["session_timeout_hours"] * 3600
    t0 = time.time()
    with open(transcript, "w") as out:
        p = subprocess.Popen(claude_cmd(prompt, resume), cwd=work, stdin=subprocess.DEVNULL,
                             stdout=out, stderr=subprocess.STDOUT, env=env)
        try:
            p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
            log(tag, f"session killed after {timeout}s")
    summary = metrics.parse_transcript(transcript)
    summary["wall_seconds"] = round(time.time() - t0, 1)
    summary["exit_code"] = p.returncode
    summary["resumed_from"] = resume
    if not summary["complete"] and not summary["rate_limited"]:
        tail = open(transcript, errors="replace").read()[-3000:]
        summary["rate_limited"] = bool(metrics.RATE_LIMIT.search(tail))
    return summary


def evaluate(arm: str, trial: int, n: int, exact_tokens: bool = True) -> dict:
    """Build from the workspace and score visible and hidden tests of milestones 1..n
    using pristine copies of the tests and the harness runner."""
    arm_cfg = CONFIG["arms"][arm]
    _, work, records = paths(arm, trial)
    out_dir = os.path.join(records, f"m{n:02d}")
    os.makedirs(out_dir, exist_ok=True)
    res = {}
    for kind in ("visible", "hidden"):
        stage = os.path.join(records, "_eval_tests")
        shutil.rmtree(stage, ignore_errors=True)
        for k in range(1, n + 1):
            m = f"m{k:02d}"
            os.makedirs(os.path.join(stage, m))
            for name in SPLIT[m][kind]:
                for ext in (".sql", ".expected"):
                    shutil.copy(os.path.join(CASES, m, name + ext), os.path.join(stage, m))
        jpath = os.path.join(out_dir, f"{kind}.json")
        args = [sys.executable, os.path.join(HERE, "run_tests.py"), "--root", work,
                "--tests-dir", stage, "--lang-json", os.path.join(records, "lang.json"),
                "--json", jpath, "--show", "0", "-j", "4"]
        if kind == "hidden":
            args.append("--no-build")
        r = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        with open(os.path.join(out_dir, f"{kind}.log"), "w") as f:
            f.write(r.stdout)
        data = json.load(open(jpath)) if os.path.exists(jpath) else {"build_ok": False, "results": []}
        rs = data["results"]
        per_m = {}
        for x in rs:
            m = x["case"].split("/")[0]
            per_m.setdefault(m, [0, 0])
            per_m[m][0] += x["passed"]
            per_m[m][1] += 1
        res[kind] = {"build_ok": data["build_ok"], "passed": sum(x["passed"] for x in rs), "total": len(rs),
                     "per_milestone": per_m,
                     "similarity": round(sum(x["similarity"] for x in rs) / len(rs), 4) if rs else 0}
        shutil.rmtree(stage, ignore_errors=True)
    res["code"] = metrics.snapshot_stats(work, arm_cfg, exact_tokens)
    res["compliance"] = metrics.compliance(work, arm_cfg, os.path.join(HERE, "templates", arm_cfg["template"]))
    json.dump(res, open(os.path.join(out_dir, "eval.json"), "w"), indent=1)
    return res


def run_milestone(arm: str, trial: int, n: int) -> None:
    tag = f"{arm}-t{trial} m{n:02d}"
    _, work, records = paths(arm, trial)
    state = load_state(records)
    ms = state["milestones"].setdefault(str(n), {"sessions": [], "nudges": 0, "done": False})
    if ms["done"]:
        return
    out_dir = os.path.join(records, f"m{n:02d}")
    os.makedirs(out_dir, exist_ok=True)

    if "start_rev" not in ms:
        copy_visible_tests(work, n)
        ms["start_rev"] = commit(work, f"tests for milestone {n}")
        save_state(records, state)

    fmt = {"n": n, "nn": f"{n:02d}", "title": TITLES[n]}
    prompt_first = open(os.path.join(HERE, "prompts", "milestone.txt")).read().format(**fmt).strip()
    wait = CONFIG["session"]["rate_limit_initial_wait_s"]

    while True:
        sessions = ms["sessions"]
        last = sessions[-1] if sessions else None
        if last is None:
            prompt, resume, kind = prompt_first, None, "initial"
        elif last["rate_limited"] or not last["complete"]:
            prompt, resume, kind = open(os.path.join(HERE, "prompts", "resume.txt")).read().strip(), last["session_id"], "resume"
            if last["rate_limited"]:
                log(tag, f"rate limited; sleeping {wait}s")
                time.sleep(wait)
                wait = min(wait * 2, CONFIG["session"]["rate_limit_max_wait_s"])
            if not last["session_id"]:
                prompt, resume, kind = prompt_first, None, "restart"
        else:
            # Session finished normally: check visible tests, maybe nudge.
            ev = evaluate(arm, trial, n, exact_tokens=False)
            vis = ev["visible"]
            failing = vis["total"] - vis["passed"]
            if failing == 0 or ms["nudges"] >= CONFIG["session"]["max_nudges"]:
                break
            ms["nudges"] += 1
            prompt = open(os.path.join(HERE, "prompts", "nudge.txt")).read().format(
                failing=failing, total=vis["total"], n=n).strip()
            resume, kind = last["session_id"], "nudge"
            log(tag, f"nudge {ms['nudges']}: {failing}/{vis['total']} visible failing")

        i = len(sessions) + 1
        transcript = os.path.join(out_dir, f"session-{i}.jsonl")
        log(tag, f"session {i} ({kind}) starting")
        s = run_session(tag, work, transcript, prompt, resume)
        s["kind"] = kind
        s["index"] = i
        sessions.append(s)
        save_state(records, state)
        log(tag, f"session {i} done: turns={s['num_turns']} out={s['output_tokens']} "
                 f"cache_read={s['cache_read_input_tokens']} cost={s['cost_usd']} rl={s['rate_limited']}")
        if not s["rate_limited"]:
            wait = CONFIG["session"]["rate_limit_initial_wait_s"]

    ms["end_rev"] = commit(work, f"milestone {n} (harness snapshot)")
    ms["churn"] = metrics.git_churn(work, ms["start_rev"], ms["end_rev"])
    ev = evaluate(arm, trial, n, exact_tokens=True)
    ms["eval"] = {k: ev[k] for k in ("visible", "hidden", "compliance")}
    ms["code_totals"] = {k: ev["code"][k] for k in ("all", "main", "test")}
    ms["done"] = True
    ms["finished"] = datetime.now(timezone.utc).isoformat()
    save_state(records, state)
    log(tag, f"done: visible {ev['visible']['passed']}/{ev['visible']['total']}, "
             f"hidden {ev['hidden']['passed']}/{ev['hidden']['total']}, "
             f"main tokens {ev['code']['main']['tokens']}, compliance {'ok' if ev['compliance']['ok'] else ev['compliance']['issues']}")


def run_trial(arm: str, trial: int, upto: int) -> None:
    base, _, _ = paths(arm, trial)
    if not os.path.exists(base):
        setup(arm, trial)
    for n, _ in CONFIG["milestones"]:
        if n > upto:
            break
        run_milestone(arm, trial, n)


def parse_range(s: str) -> list[int]:
    out = []
    for part in s.split(","):
        if "-" in part:
            a, b = part.split("-")
            out += list(range(int(a), int(b) + 1))
        else:
            out.append(int(part))
    return out


def remetric() -> None:
    """Recompute session metrics from saved transcripts (keeps harness fields)."""
    for d in sorted(os.listdir(RUNS)):
        rec = os.path.join(RUNS, d, "records")
        if not os.path.exists(os.path.join(rec, "state.json")):
            continue
        state = load_state(rec)
        for n, ms in state["milestones"].items():
            for s in ms["sessions"]:
                path = os.path.join(rec, f"m{int(n):02d}", f"session-{s['index']}.jsonl")
                if os.path.exists(path):
                    keep = {k: s[k] for k in ("wall_seconds", "exit_code", "resumed_from", "kind", "index", "rate_limited") if k in s}
                    s.clear()
                    s.update(metrics.parse_transcript(path))
                    s.update(keep)
        save_state(rec, state)
        print(f"{d}: updated")


def status() -> None:
    if not os.path.isdir(RUNS):
        print("no runs yet")
        return
    for d in sorted(os.listdir(RUNS)):
        sp = os.path.join(RUNS, d, "records", "state.json")
        if not os.path.exists(sp):
            continue
        st = json.load(open(sp))
        parts = []
        for n, ms in sorted(st["milestones"].items(), key=lambda kv: int(kv[0])):
            h = ms.get("eval", {}).get("hidden", {})
            mark = f"{h.get('passed', '?')}/{h.get('total', '?')}" if ms["done"] else "running"
            parts.append(f"m{int(n):02d}:{mark}")
        print(f"{d:24} " + " ".join(parts))


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("setup", "run", "eval"):
        p = sub.add_parser(name)
        p.add_argument("arm", choices=list(CONFIG["arms"]))
        p.add_argument("trial", type=int)
        if name == "run":
            p.add_argument("--upto", type=int, default=9)
        if name == "eval":
            p.add_argument("--milestone", type=int, required=True)
            p.add_argument("--exact-tokens", action="store_true")
    b = sub.add_parser("batch")
    b.add_argument("--arms", default="rust,moonbit")
    b.add_argument("--trials", default="1-3")
    b.add_argument("--parallel", type=int, default=2)
    b.add_argument("--upto", type=int, default=9)
    sub.add_parser("status")
    sub.add_parser("remetric", help="re-parse every transcript with the current metrics code")
    a = ap.parse_args()

    os.makedirs(RUNS, exist_ok=True)
    if not SPLIT and a.cmd != "status":
        raise SystemExit("tests/split.json missing: run tests/gen_expected.py first")
    if a.cmd == "setup":
        setup(a.arm, a.trial)
    elif a.cmd == "run":
        run_trial(a.arm, a.trial, a.upto)
    elif a.cmd == "eval":
        print(json.dumps(evaluate(a.arm, a.trial, a.milestone, a.exact_tokens), indent=1)[:5000])
    elif a.cmd == "batch":
        arms = a.arms.split(",")
        # Interleave arms within each trial so paired runs share service conditions.
        jobs = [(arm, t) for t in parse_range(a.trials) for arm in arms]
        with cf.ThreadPoolExecutor(max_workers=a.parallel) as ex:
            futs = {ex.submit(run_trial, arm, t, a.upto): (arm, t) for arm, t in jobs}
            for f in cf.as_completed(futs):
                arm, t = futs[f]
                try:
                    f.result()
                    log(f"{arm}-t{t}", "trial finished")
                except Exception as e:  # keep other trials going
                    log(f"{arm}-t{t}", f"trial FAILED: {e!r}")
    elif a.cmd == "status":
        status()
    elif a.cmd == "remetric":
        remetric()
    return 0


if __name__ == "__main__":
    sys.exit(main())
