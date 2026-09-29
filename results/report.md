# minisql token-efficiency results

Model `claude-opus-5-5`, effort `high`, 2.1.281 (Claude Code). Trials: rust×3, moonbit×3.

## Totals per trial (mean ± sd across trials)

| Metric | rust | moonbit | ratio moonbit/rust |
|---|---|---|---|
| Output tokens | 867,780 ± 190,227 | 762,261 ± 45,118 | 0.88 |
| Total input tokens (incl. cache) | 68,874,413 ± 38,301,903 | 67,791,832 ± 15,038,699 | 0.98 |
|   cache reads | 67,244,176 ± 38,070,899 | 66,221,716 ± 15,019,549 | 0.98 |
|   cache writes | 1,629,440 ± 231,313 | 1,569,275 ± 19,082 | 0.96 |
|   of which primer re-reads | 1,145,842 ± 182,016 | 4,914,958 ± 415,115 | 4.29 |
| Total input tokens excl. primer | 67,728,571 ± 38,120,144 | 62,876,875 ± 14,628,767 | 0.93 |
| Input tokens until first all-green | 21,718,894 ± 1,721,823 | 23,589,987 ± 1,287,050 | 1.09 |
| API calls until first all-green | 222 ± 14 | 236 ± 6 | 1.06 |
| API calls (total) | 398 ± 63 | 420 ± 36 | 1.06 |
| Est. cost (USD, API prices) | 43.86 ± 13.25 | 41.09 ± 3.97 | 0.94 |
| Turns | 423 ± 65 | 443 ± 35 | 1.05 |
| Wall time (h) | 2.40 ± 0.41 | 2.21 ± 0.12 | 0.92 |
| Build attempts | 91 ± 14 | 125 ± 18 | 1.37 |
| Build failure rate | 0.058 ± 0.008 | 0.130 ± 0.030 | 2.25 |
| Nudges | 0 ± 0.0 | 0 ± 0.0 | – |
| Hidden tests passed (final) | 0.963 ± 0.011 | 0.956 ± 0.002 | 0.99 |
| Visible tests passed (final) | 1.000 ± 0.000 | 1.000 ± 0.000 | 1.00 |
| Source tokens (final, non-test) | 193,931 ± 19,649 | 171,530 ± 5,190 | 0.88 |
| Source code lines (final) | 13,298 ± 1,217 | 13,842 ± 383 | 1.04 |
| Output tokens / hidden pass | 3,731 ± 863 | 3,295 ± 202 | 0.88 |
| Cost / hidden pass (USD) | 0.189 ± 0.059 | 0.178 ± 0.018 | 0.94 |
| Output tokens / final source token | 4.44 ± 0.50 | 4.44 ± 0.14 | 1.00 |

## Per milestone (mean across trials)

Output tokens, build failures, and pass rate on that milestone's hidden tests.

| M | rust out | rust build fail | rust hidden | moonbit out | moonbit build fail | moonbit hidden | out ratio |
|---|---|---|---|---|---|---|---|
| 1 | 77,363 | 0.3 | 1.00 | 71,137 | 1.7 | 1.00 | 0.92 |
| 2 | 96,333 | 0.7 | 0.97 | 89,371 | 2 | 0.97 | 0.93 |
| 3 | 69,422 | 0.7 | 0.92 | 66,517 | 1.7 | 0.90 | 0.96 |
| 4 | 77,154 | 0.7 | 0.99 | 67,935 | 1.3 | 1.00 | 0.88 |
| 5 | 119,299 | 0.7 | 0.95 | 90,704 | 2 | 0.90 | 0.76 |
| 6 | 253,788 | 0.7 | 0.91 | 215,947 | 5 | 0.94 | 0.85 |
| 7 | 108,668 | 1.3 | 0.96 | 96,291 | 1.7 | 0.96 | 0.89 |
| 8 | 15,778 | 0 | 0.98 | 14,194 | 0 | 1.00 | 0.90 |
| 9 | 49,975 | 0.3 | 0.95 | 50,166 | 0.7 | 0.95 | 1.00 |
