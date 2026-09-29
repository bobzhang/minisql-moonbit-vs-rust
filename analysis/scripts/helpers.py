"""Hand-written MoonBit helpers that have a Rust std equivalent: lines/chars per trial.
Uses fn_inventory.json (run fn_inventory.py first). Writes analysis/missing_in_core.json/.csv."""
import csv, json, os

A = "/Users/dii/git/bench/analysis"
R = os.path.expanduser("~/minisql-bench-runs")
inv = json.load(open(f"{A}/fn_inventory.json"))

CATS = {
  "ordered_map": {
    "rust_std": "std::collections::BTreeMap: range(lo..hi) with Bound, .rev(), first/last_key_value, custom Ord on key type",
    "why": "@sorted_map has no reverse or open-ended range iteration, no lower_bound/seek, no first/last, no custom comparator; t1 also wanted cheap persistent snapshots",
    "files": {"moonbit-t1": ["db/ptree.mbt"], "moonbit-t2": ["engine/ordmap.mbt"], "moonbit-t3": ["sql/sorted.mbt"]}},
  "exact_float_digits": {
    "rust_std": "format!(\"{:.29e}\", x) / format!(\"{:.40e}\", x) (1 line) inside fp_decode",
    "why": "no precision/exponent float formatting in core (Double::to_string is shortest round-trip only)",
    "fns": {"moonbit-t1": ["hi_part", "dekker_mul2"], "moonbit-t2": ["exact_decimal"], "moonbit-t3": ["limbs_to_digits", "limbs_mul_small", "exact_decimal"]},
    "extra_lines": {"moonbit-t1": 58}},  # t1's fp_decode is 113 lines vs 54-79 in Rust: ~58 lines of inline double-double digit generation
  "checked_int64": {
    "rust_std": "i64::checked_add/checked_sub/checked_mul (12-15 call sites per trial)",
    "why": "no checked/overflowing integer ops in core (primer supplied the snippet)",
    "fns": {"moonbit-t1": ["mul_checked"], "moonbit-t2": ["add_checked", "sub_checked", "mul_checked"], "moonbit-t3": ["mul_checked"]},
    "extra_lines": {"moonbit-t1": 8, "moonbit-t3": 8}},  # inline `((a ^ r) & (b ^ r)) < 0L` sites
  "utf8_order_compare": {
    "rust_std": "a.cmp(b) on &str / &[u8] (byte-wise = code point order)",
    "why": "String compare is shortlex; lexical_compare is by UTF-16 code unit, which differs from UTF-8/code-point order for U+E000..U+FFFF vs surrogates; Bytes::lexical_compare exists but was not used",
    "fns": {"moonbit-t1": ["compare_text", "fix_cu", "compare_bytes"], "moonbit-t2": ["text_compare", "utf16_fix"], "moonbit-t3": ["compare_text", "map_code_unit", "compare_bytes"]}},
  "code_unit_ascii_classes": {
    "rust_std": "u8::is_ascii_digit / is_ascii_whitespace / is_ascii_alphanumeric / to_ascii_lowercase",
    "why": "s[i] is UInt16; the ASCII predicates exist on Char only, so agents wrote UInt16/Int versions",
    "fns": {"moonbit-t1": ["is_space_cu", "is_digit_cu", "ascii_lower_cu", "lower_ascii", "is_digit_i", "is_space_i"],
            "moonbit-t2": ["is_space_cu", "is_digit_cu", "is_space_at", "is_digit_at", "is_hex_cu", "fold_ascii", "lower_ascii_char"],
            "moonbit-t3": ["is_space_code", "is_digit", "fold_ascii", "like_fold"]}},
  "stable_sort_by": {
    "rust_std": "slice::sort_by (stable)",
    "why": "Array::sort_by is unstable; stable_sort exists only for T : Compare (no comparator variant)",
    "fns": {"moonbit-t1": ["stable_sort"], "moonbit-t2": [], "moonbit-t3": []}},
  "zero_padded_ints": {
    "rust_std": "format!(\"{:02}\") / {:04} / {:>w$} (43-47 width specifiers per trial)",
    "why": "no width/precision format specifiers; String::pad_start exists but was never used",
    "fns": {"moonbit-t1": ["pad_int", "space_pad"], "moonbit-t2": ["pad_int"], "moonbit-t3": ["zpad", "zpad_signed", "spad"]}},
  "big_endian_ints": {
    "rust_std": "u16/u32::from_be_bytes, to_be_bytes (21-26 uses per trial)",
    "why": "helpers exist (@buffer write_*_be, bitstring patterns u16be/u32be) but random-access reads at an offset have no direct API",
    "fns": {"moonbit-t1": ["Pager::u16", "Pager::u32", "hdr_u32", "put_u16", "put_u32"],
            "moonbit-t2": ["DbFile::u16", "DbFile::u32", "put_u16", "put_u32", "u32_prefix", "get_u32"],
            "moonbit-t3": ["Pager::u16", "Pager::u32", "put_u16", "put_u32", "header_u32"]}},
}

rows, out = [], {}
for cat, spec in CATS.items():
    out[cat] = {"rust_std": spec["rust_std"], "why": spec["why"], "per_trial": {}}
    for t in ("moonbit-t1", "moonbit-t2", "moonbit-t3"):
        lines = chars = 0
        names = []
        if "files" in spec:
            for f in spec["files"][t]:
                txt = open(os.path.join(R, t, "work", f)).read()
                lines += len([l for l in txt.split("\n") if l.strip()])
                chars += len(txt)
                names.append(f)
        for n in spec.get("fns", {}).get(t, []):
            hits = [x for x in inv[t] if x["name"] == n]
            if not hits:
                print("missing", t, n)
            for h in hits[:1]:
                lines += h["lines"]; chars += h["chars"]; names.append(n)
        extra = spec.get("extra_lines", {}).get(t, 0)
        lines += extra; chars += extra * 30
        out[cat]["per_trial"][t] = {"lines": lines, "chars": chars, "approx_tokens": round(chars / 4), "items": names}
        rows.append([cat, t, lines, chars, round(chars / 4), " ".join(names)])
    pt = out[cat]["per_trial"]
    out[cat]["mean_lines"] = round(sum(v["lines"] for v in pt.values()) / 3, 1)
    out[cat]["mean_tokens"] = round(sum(v["approx_tokens"] for v in pt.values()) / 3)
    print(f"{cat:25s} lines/trial " + " ".join(str(pt[t]['lines']) for t in pt) + f"  mean_tokens={out[cat]['mean_tokens']}")
tot = {t: sum(out[c]["per_trial"][t]["approx_tokens"] for c in out) for t in ("moonbit-t1", "moonbit-t2", "moonbit-t3")}
totl = {t: sum(out[c]["per_trial"][t]["lines"] for c in out) for t in ("moonbit-t1", "moonbit-t2", "moonbit-t3")}
print("TOTAL lines", totl, "approx code tokens", tot)
out["_total"] = {"lines": totl, "approx_tokens": tot}
json.dump(out, open(f"{A}/missing_in_core.json", "w"), indent=1)
with open(f"{A}/missing_in_core.csv", "w", newline="") as fh:
    w = csv.writer(fh); w.writerow(["category", "trial", "lines", "chars", "approx_tokens", "items"]); w.writerows(rows)
