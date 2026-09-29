"""Compare the same components between rust-t1 and moonbit-t1: size and the
constructs that account for the difference. Writes analysis/code_shape.json."""
import json, os, re

R = os.path.expanduser("~/minisql-bench-runs")
PAIRS = {
    "lexer": (["rust-t1/work/src/lexer.rs"], ["moonbit-t1/work/db/lexer.mbt"]),
    "file_reader": (["rust-t1/work/src/file.rs"], ["moonbit-t1/work/db/fileread.mbt"]),
    "file_writer": (["rust-t1/work/src/write.rs"], ["moonbit-t1/work/db/filewrite.mbt"]),
    "value+ops": (["rust-t1/work/src/value.rs"], ["moonbit-t1/work/db/value.mbt", "moonbit-t1/work/db/ops.mbt"]),
    "parser": (["rust-t1/work/src/parser.rs"], ["moonbit-t1/work/db/parser.mbt"]),
    "datetime": (["rust-t1/work/src/datetime.rs"], ["moonbit-t1/work/db/datetime.mbt"]),
    "window": (["rust-t1/work/src/window.rs"], ["moonbit-t1/work/db/window.mbt"]),
    "printf": (["rust-t1/work/src/printf.rs"], ["moonbit-t1/work/db/printf.mbt"]),
}
RUST = {
    "try_?": r"\?(?=[;.)\s,])", "Ok(/Err(/Some(": r"\b(Ok|Err)\(", "Result<": r"\bResult<",
    "& borrow/ref": r"&(?!&)", "lifetime 'a": r"'[a-z]\b(?!')", ".clone()": r"\.clone\(\)",
    "to_string/to_owned/into": r"\.(to_string|to_owned|into)\(\)", "as casts": r"\bas (i64|i32|u8|u16|u32|u64|usize|f64|isize)\b",
    "Box::new": r"Box::new", "mut": r"\bmut\b", "impl blocks": r"^impl\b", "use lines": r"^use\b",
    "closing-brace-only lines": r"^\s*[}\])]+[;,]?\s*$", "vec!/Vec": r"\bvec!|\bVec<",
}
MBT = {
    "///| markers": r"^///\|", "raise": r"\braise\b", "catch/try": r"\b(catch|try)\b",
    "self : T params": r"self : ", "type conversions .to_int/.to_int64/.to_double/..": r"\.(to_int|to_int64|to_double|to_byte|to_uint|reinterpret_as_\w+)\(\)",
    ".to_owned()": r"\.to_owned\(\)", "mut": r"\bmut\b", "pub/pub(all)/priv": r"^(pub|priv)",
    "closing-brace-only lines": r"^\s*[}\])]+[;,]?\s*$", "multi-line signature lines": r"^\s+\w+ : [^=]*,\s*$",
    "labelled args ~ / ?": r"\w[~?] :|\w~[,)]",
}


def stats(paths, pats):
    text = "".join(open(os.path.join(R, p)).read() for p in paths)
    lines = text.split("\n")
    nb = [l for l in lines if l.strip()]
    com = [l for l in nb if l.strip().startswith("//") and not l.strip().startswith("///|")]
    code = "\n".join(l for l in nb if not (l.strip().startswith("//") and not l.strip().startswith("///|")))
    out = {"nonblank_lines": len(nb), "comment_lines": len(com), "code_lines": len(nb) - len(com),
           "chars_code": len(code), "approx_tokens_code": round(len(code) / 4),
           "chars_code_no_indent": len(re.sub(r"(?m)^\s+", "", code))}
    for k, p in pats.items():
        out[k] = len(re.findall(p, code, re.M))
    return out


res = {}
for comp, (rp, mp) in PAIRS.items():
    r, m = stats(rp, RUST), stats(mp, MBT)
    res[comp] = {"rust": r, "moonbit": m,
                 "ratio_code_lines": round(m["code_lines"] / r["code_lines"], 2),
                 "ratio_tokens": round(m["approx_tokens_code"] / r["approx_tokens_code"], 2)}
    print(f"{comp:12s} rust {r['code_lines']:5d} lines {r['approx_tokens_code']:6d} tok | moonbit {m['code_lines']:5d} lines {m['approx_tokens_code']:6d} tok | ratio lines {res[comp]['ratio_code_lines']} tok {res[comp]['ratio_tokens']}")
json.dump(res, open("/Users/dii/git/bench/analysis/code_shape.json", "w"), indent=1)
for comp in ("file_reader", "value+ops", "lexer"):
    print(comp, "RUST", {k: v for k, v in res[comp]["rust"].items() if k in RUST})
    print(comp, "MBT ", {k: v for k, v in res[comp]["moonbit"].items() if k in MBT})
