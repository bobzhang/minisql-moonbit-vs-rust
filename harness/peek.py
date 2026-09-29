#!/usr/bin/env python3
"""Live view of running sessions: tokens so far, tool calls, builds, last action.

Usage: peek.py [TRIAL_DIR_NAME ...]   (default: all trials with a running milestone)
"""

import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import metrics  # noqa: E402

CONFIG = json.load(open(os.path.join(HERE, "config.json")))
RUNS = os.path.expanduser(os.environ.get("MINISQL_RUNS_DIR", CONFIG["runs_dir"]))


def last_action(path: str) -> str:
    last = ""
    with open(path, errors="replace") as f:
        for line in f:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev.get("type") == "assistant":
                for c in ev["message"].get("content", []) or []:
                    if c.get("type") == "tool_use":
                        inp = c.get("input", {})
                        detail = inp.get("command") or inp.get("file_path") or ""
                        last = f"{c['name']}: {' '.join(str(detail).split())[:90]}"
    return last


def main() -> int:
    names = sys.argv[1:] or sorted(os.listdir(RUNS))
    for name in names:
        rec = os.path.join(RUNS, name, "records")
        if not os.path.isdir(rec):
            continue
        sessions = sorted(glob.glob(os.path.join(rec, "m*", "session-*.jsonl")), key=os.path.getmtime)
        if not sessions:
            continue
        cur = sessions[-1]
        s = metrics.parse_transcript(cur)
        tin = s["input_tokens"] + s["cache_creation_input_tokens"] + s["cache_read_input_tokens"]
        status = "finished" if s["complete"] else "running"
        print(f"{name} {os.path.relpath(cur, rec)} [{status}]  calls={s['api_calls']} out={s['output_tokens']:,} "
              f"in={tin:,} ctx={s['max_context_tokens']:,} builds={s['build_attempts']} "
              f"fails={s['build_failures']} tests={s['test_runs']}")
        print(f"    last: {last_action(cur)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
