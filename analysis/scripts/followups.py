"""For each failed build, print the agent's next text/thinking and next command (to see how it diagnosed the error)."""
import json, os, sys
RUNS = os.path.expanduser("~/minisql-bench-runs")
b = json.load(open("/Users/dii/git/bench/analysis/builds.json"))
lang = sys.argv[1]
fails = [x for x in b if x["lang"] == lang and x["failed"]]
for n, x in enumerate(fails, 1):
    path = f"{RUNS}/{x['trial']}/records/{x['m']}/{x['session']}"
    step, found, texts, nxt = 0, False, [], []
    for line in open(path):
        ev = json.loads(line)
        if ev.get("type") != "assistant":
            continue
        for c in ev["message"].get("content", []):
            if c.get("type") == "tool_use":
                step += 1
                if found and len(nxt) < 2:
                    nxt.append(c.get("input", {}).get("command", str(c.get("input")))[:300].replace("\n", " ⏎ "))
                if step == x["step"]:
                    found = True
            elif found and len(nxt) < 1 and c.get("type") in ("text", "thinking"):
                t = c.get("text") or c.get("thinking") or ""
                if t.strip():
                    texts.append(t.strip()[:500].replace("\n", " "))
        if len(nxt) >= 2:
            break
    print(f"#{n} {x['trial']} {x['m']} step{x['step']}")
    for t in texts:
        print("   TEXT:", t)
    for c in nxt:
        print("   NEXT:", c)
