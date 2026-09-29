#!/bin/bash
# Count uses of std/core facilities in the final sources (Rust vs MoonBit).
R=~/minisql-bench-runs
echo "RUST"
while IFS= read -r p; do
  printf "%-75s" "$p"
  for t in rust-t1 rust-t2 rust-t3; do printf "%6s" $(grep -rEo "$p" $R/$t/work/src --include='*.rs' | grep -v 'src/io.rs' | wc -l); done; echo
done <<'P'
checked_(add|sub|mul|div|neg|rem|abs)
overflowing_|wrapping_|saturating_
\{:\.[0-9*]*e\}|\{:e\}|:\.\*e|\{:\.\*\}|\{:\.[0-9]+\}|\{:\.[0-9]+e\}
\{:0?[0-9]+\}|\{:>|\{:<|\{:0>|\{:0\$|\{:>\$|\{:<\$
from_be_bytes|to_be_bytes
\.sort_by|sort_by_key|\.sort\(\)
sort_unstable
to_bits|from_bits|total_cmp
is_ascii_(digit|alphabetic|alphanumeric|whitespace|hexdigit)
to_ascii_lowercase|to_ascii_uppercase|eq_ignore_ascii_case
from_utf8|char_indices|len_utf8
BTreeMap|BTreeSet
impl (std::hash::)?Hash
parse::<
format!|write!
P
echo "MOONBIT"
while IFS= read -r p; do
  printf "%-75s" "$p"
  for t in moonbit-t1 moonbit-t2 moonbit-t3; do printf "%6s" $(grep -rEo "$p" $R/$t/work --include='*.mbt' | grep -v -e '/io/' -e '_build' | wc -l); done; echo
done <<'P'
@sorted_map|@immut
stable_sort|sort_by|\.sort\(\)
reinterpret_as
lexical_compare
@utf8\.
@buffer\.
@string\.parse_(int|int64|double)
StringBuilder
pad_start|pad_end
to_lower|to_upper
\.to_int\(\)
\.to_int64\(\)
\.to_double\(\)
P
