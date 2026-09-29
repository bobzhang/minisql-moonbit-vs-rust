"""List API-discovery actions: `moon ide doc`, `moon ide outline/peek-def/find-references`,
`moon explain`, reading ~/.moon/lib/core, scratch experiment projects; Rust equivalents
(rustc --explain, ~/.rustup sources, scratch rustc/cargo projects). Writes api_discovery.json."""
import json, re, collections
B = json.load(open("/Users/dii/git/bench/analysis/bash_commands.json"))
out = []
DOC = re.compile(r"moon ide doc\s+(\"[^\"]*\"|'[^']*'|\S+)")
IDE = re.compile(r"moon ide (outline|peek-def|find-references|hover|goto)\b")
for x in B:
    cmd = x["cmd"]
    items = []
    for q in DOC.findall(cmd):
        items.append(("ide_doc", q.strip("\"'")))
    for k in IDE.findall(cmd):
        items.append(("ide_" + k, ""))
    if re.search(r"moon explain", cmd):
        items.append(("moon_explain", ""))
    if re.search(r"(~|/Users/\w+)/\.moon/lib/core", cmd):
        items.append(("read_core_source", re.findall(r"\.moon/lib/core/?(\S*)", cmd)[0][:80]))
    if re.search(r"rustc --explain", cmd):
        items.append(("rustc_explain", ""))
    if re.search(r"\.rustup|rust-src|/rustlib/", cmd):
        items.append(("read_rust_std_source", ""))
    if re.search(r"cat > \S*moon\.mod|moon new", cmd) and "/work" not in cmd.split("moon.mod")[0][-80:]:
        items.append(("scratch_moon_project", ""))
    if re.search(r"(rustc\s+\S+\.rs|cargo new|cargo init)", cmd):
        items.append(("scratch_rust_program", ""))
    for kind, q in items:
        o = x.get("out", "")
        found = None
        if kind == "ide_doc":
            found = not (o.strip() == "" or "Exit code 1" in o[:30] and q in ("Int::unsafe_to_char",)) and "not found" not in o[:200].lower()
        out.append({"trial": x["trial"], "m": x["m"], "step": x["step"], "kind": kind, "query": q,
                    "found": found, "cmd": cmd[:300], "out_head": o[:400]})
json.dump(out, open("/Users/dii/git/bench/analysis/api_discovery.json", "w"), indent=1)
c = collections.Counter((r["trial"], r["kind"]) for r in out)
for k, v in sorted(c.items()):
    print(k, v)
for r in out:
    if r["kind"] == "ide_doc":
        print(r["trial"], r["m"], repr(r["query"]), "->", r["out_head"][:150].replace("\n", " | "))
