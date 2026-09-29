"""Extract every build/check/test-runner invocation from all transcripts, with
parsed compiler diagnostics. Writes analysis/builds.json and analysis/bash_commands.json.

Usage: python3 analysis/scripts/extract_builds.py
"""
import glob, json, os, re, sys

sys.path.insert(0, "/Users/dii/git/bench/harness")
from metrics import classify_command, BUILD_FAIL, _text_of  # noqa: E402

RUNS = os.path.expanduser("~/minisql-bench-runs")
OUT = "/Users/dii/git/bench/analysis"

MB_HDR = re.compile(r"^\s*(Error|Warning): \[(\d{4})\]\s*$")
MB_LOC = re.compile(r"╭─\[\s*(.*?):(\d+):(\d+)\s*\]")
MB_SRC = re.compile(r"^\s*(\d+)\s*│ ?(.*)$")
MB_MSG = re.compile(r"╰─+\s?(.*)$")
RS_HDR = re.compile(r"^(error|warning)(\[(E\d{4})\])?: (.*)$")
RS_LOC = re.compile(r"^\s*--> (.*?):(\d+):(\d+)")
RS_SRC = re.compile(r"^\s*(\d+)\s*\|\s?(.*)$")


def parse_moon(out):
    diags, cur, in_msg = [], None, False
    for line in out.split("\n"):
        m = MB_HDR.match(line)
        if m or line.startswith("Failed with") or line.startswith("Error: failed when"):
            if cur:
                diags.append(cur)
            cur, in_msg = None, False
            if m:
                cur = {"sev": m.group(1).lower(), "code": m.group(2), "msg": "", "file": None, "line": None, "src": ""}
            continue
        if cur is None:
            continue
        if (lm := MB_LOC.search(line)) and cur["file"] is None:
            cur["file"] = os.path.basename(lm.group(1)); cur["line"] = int(lm.group(2)); continue
        if in_msg:
            if re.match(r"^\s*─*╯\s*$", line) or re.match(r"^─+╯", line.strip()):
                in_msg = False
            else:
                cur["msg"] += "\n" + line.strip()
            continue
        if (mm := MB_MSG.search(line)):
            cur["msg"] = mm.group(1).strip(); in_msg = True; continue
        if (sm := MB_SRC.match(line)) and not cur["src"]:
            cur["src"] = sm.group(2).strip()
    if cur:
        diags.append(cur)
    for d in diags:
        d["msg"] = d["msg"].strip()[:600]
    return diags


def parse_rust(out):
    diags, cur = [], None
    for line in out.split("\n"):
        m = RS_HDR.match(line)
        if m:
            if cur:
                diags.append(cur)
            cur = {"sev": m.group(1), "code": m.group(3) or "", "msg": m.group(4).strip(), "file": None, "line": None, "src": "", "labels": []}
            if cur["sev"] == "warning" and ("generated" in cur["msg"] or cur["msg"].startswith("unused")) and False:
                pass
            continue
        if cur is None:
            continue
        if (lm := RS_LOC.match(line)) and cur["file"] is None:
            cur["file"] = os.path.basename(lm.group(1)); cur["line"] = int(lm.group(2)); continue
        if (sm := RS_SRC.match(line)):
            if not cur["src"] and sm.group(2).strip():
                cur["src"] = sm.group(2).strip()
            continue
        lab = re.match(r"^\s*\|\s*[\^\-]+\s*(.*)$", line)
        if lab and lab.group(1):
            cur["labels"].append(lab.group(1).strip())
        elif re.match(r"^\s*= (help|note): ", line):
            cur["labels"].append(line.strip())
    if cur:
        diags.append(cur)
    # drop summary lines like "error: could not compile" / "warning: `x` generated 3 warnings"
    out_d = []
    for d in diags:
        if re.match(r"could not compile|aborting due to|`.*` \(bin .*\) generated|.*generated \d+ warnings?", d["msg"]):
            continue
        d["labels"] = d["labels"][:6]
        out_d.append(d)
    return out_d


def iter_sessions():
    for trial in sorted(os.listdir(RUNS)):
        rec = os.path.join(RUNS, trial, "records")
        if not os.path.isdir(rec):
            continue
        for mdir in sorted(glob.glob(os.path.join(rec, "m??"))):
            for sess in sorted(glob.glob(os.path.join(mdir, "session-*.jsonl"))):
                yield trial, os.path.basename(mdir), os.path.basename(sess), sess


def main():
    builds, bash = [], []
    for trial, m, sname, path in iter_sessions():
        lang = "moonbit" if trial.startswith("moonbit") else "rust"
        uses, step = {}, 0
        for line in open(path, encoding="utf-8", errors="replace"):
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev.get("type") == "assistant":
                for c in ev.get("message", {}).get("content", []) or []:
                    if c.get("type") == "tool_use":
                        step += 1
                        c["_step"] = step
                        uses[c["id"]] = c
            elif ev.get("type") == "user":
                cont = ev.get("message", {}).get("content")
                if not isinstance(cont, list):
                    continue
                for c in cont:
                    if not (isinstance(c, dict) and c.get("type") == "tool_result"):
                        continue
                    u = uses.get(c.get("tool_use_id"))
                    if not u:
                        continue
                    out = _text_of(c.get("content"))
                    if u["name"] != "Bash":
                        bash.append({"trial": trial, "lang": lang, "m": m, "session": sname, "step": u["_step"],
                                     "tool": u["name"], "cmd": json.dumps(u.get("input"))[:4000], "out": out[:3000],
                                     "is_error": c.get("is_error", False)})
                        continue
                    cmd = u.get("input", {}).get("command", "")
                    bash.append({"trial": trial, "lang": lang, "m": m, "session": sname, "step": u["_step"],
                                 "tool": "Bash", "cmd": cmd if len(cmd) <= 6000 else cmd[:4000] + "\n[...]\n" + cmd[-2000:], "cmd_chars": len(cmd), "out": out[:6000], "out_chars": len(out),
                                 "is_error": c.get("is_error", False)})
                    kind = classify_command(cmd)
                    if not kind:
                        continue
                    failed = bool(re.search(r"^BUILD FAILED", out, re.M)) if kind == "test" else bool(BUILD_FAIL.search(out))
                    diags = parse_moon(out) if lang == "moonbit" else parse_rust(out)
                    builds.append({"trial": trial, "lang": lang, "m": m, "session": sname, "step": u["_step"],
                                   "kind": kind, "failed": failed, "cmd": cmd if len(cmd) <= 3000 else cmd[:1500] + "\n[...]\n" + cmd[-1500:], "out_chars": len(out),
                                   "n_err": sum(1 for d in diags if d["sev"] == "error"),
                                   "n_warn": sum(1 for d in diags if d["sev"] == "warning"),
                                   "diags": diags, "out": out if failed else out[:1500]})
    json.dump(builds, open(os.path.join(OUT, "builds.json"), "w"), indent=1, ensure_ascii=False)
    json.dump(bash, open(os.path.join(OUT, "bash_commands.json"), "w"), indent=0, ensure_ascii=False)
    for lang in ("rust", "moonbit"):
        b = [x for x in builds if x["lang"] == lang]
        f = [x for x in b if x["failed"]]
        print(lang, "builds", len(b), "failed", len(f), "failed-with-parsed-errors", sum(1 for x in f if x["n_err"]))


if __name__ == "__main__":
    main()
