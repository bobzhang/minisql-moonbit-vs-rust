"""Inventory of top-level functions (name, file, lines, chars) in each final workspace.
MoonBit: items delimited by `///|`. Rust: `fn` items found by brace matching.
Writes analysis/fn_inventory.json."""
import json, os, re

RUNS = os.path.expanduser("~/minisql-bench-runs")
TRIALS = ["rust-t1", "rust-t2", "rust-t3", "moonbit-t1", "moonbit-t2", "moonbit-t3"]


def src_files(root, ext):
    for d, dirs, fs in os.walk(root):
        dirs[:] = [x for x in dirs if x not in ("_build", "target", "tests", "tools", ".git", "io", ".mooncakes")]
        for f in fs:
            if f.endswith(ext) and f != "io.rs" and not f.endswith(("_test.mbt", "_wbtest.mbt")):
                yield os.path.join(d, f)


def mbt_items(text):
    parts = re.split(r"^///\|\s*$", text, flags=re.M)
    for p in parts[1:]:
        m = re.search(r"^(?:pub(?:\([a-z]+\))?\s+)?(?:async\s+)?fn(?:\[[^\]]*\])?\s+([\w:]+)", p, re.M)
        kind = "fn" if m else "other"
        name = m.group(1) if m else (re.search(r"^\S.*$", p.strip(), re.M).group(0)[:60] if p.strip() else "")
        body = p.strip("\n")
        yield kind, name, body


def rs_items(text):
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        m = re.match(r"^\s*(?:pub(?:\([a-z]+\))?\s+)?(?:const\s+)?fn\s+(\w+)", lines[i])
        if m:
            depth, j, started = 0, i, False
            while j < len(lines):
                depth += lines[j].count("{") - lines[j].count("}")
                if "{" in lines[j]:
                    started = True
                if started and depth <= 0:
                    break
                if not started and lines[j].rstrip().endswith(";"):
                    break
                j += 1
            # include preceding doc comments
            k = i
            while k > 0 and lines[k - 1].strip().startswith(("///", "#[")):
                k -= 1
            yield "fn", m.group(1), "\n".join(lines[k:j + 1])
            i = j + 1
        else:
            i += 1


inv = {}
for t in TRIALS:
    root = os.path.join(RUNS, t, "work")
    rust = t.startswith("rust")
    items = []
    for f in src_files(root, ".rs" if rust else ".mbt"):
        text = open(f).read()
        for kind, name, body in (rs_items(text) if rust else mbt_items(text)):
            items.append({"file": os.path.relpath(f, root), "kind": kind, "name": name,
                          "lines": len([l for l in body.split("\n") if l.strip()]), "chars": len(body)})
    inv[t] = items
    print(t, len(items), sum(x["lines"] for x in items))
json.dump(inv, open("/Users/dii/git/bench/analysis/fn_inventory.json", "w"), indent=0)
