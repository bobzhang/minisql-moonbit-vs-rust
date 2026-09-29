# M7 coverage map

Maps each bullet of SPEC.md §4 M7 to the test files that exercise it
(file names without `.sql`). 57 functional files (21 CTE, 36 window) plus
4 performance files.

## Bullet 1 — `WITH [RECURSIVE] name [(cols)] AS [NOT] [MATERIALIZED] (select), ...`

| Aspect | Files |
|---|---|
| WITH before SELECT (basic use, CTE referenced several times, empty CTE, unused CTE) | cte_basic_select, cte_body_forms, cte_multiple_chained |
| Column lists `name(cols)` (renaming, quoting, count mismatch errors) | cte_column_list, recursive_errors, cte_errors |
| Several CTEs in one WITH, later ones reading earlier ones | cte_multiple_chained, cte_materialized_hints, recursive_errors, window_with_cte |
| Body forms: VALUES, UNION/UNION ALL/INTERSECT/EXCEPT, joins, DISTINCT, ORDER BY/LIMIT/OFFSET | cte_body_forms |
| Scoping: CTE shadows tables and views, nested WITH in subqueries, inner WITH shadows outer CTE, circular references | cte_scoping_shadowing, cte_in_views, cte_errors |
| `MATERIALIZED` / `NOT MATERIALIZED` (results unchanged, also on recursive CTEs and in DML) | cte_materialized_hints |
| WITH before INSERT (incl. OR IGNORE, upsert, RETURNING, recursive source) | cte_in_insert, recursive_iterate_rows, window_with_cte, perf_recursive_cte_100k |
| WITH before UPDATE | cte_in_update_delete, cte_materialized_hints, recursive_tree_walk |
| WITH before DELETE | cte_in_update_delete, cte_materialized_hints |
| CTEs inside views / views inside CTEs | cte_in_views |
| Syntax and semantic errors (missing parens, empty column list, duplicate names incl. case, mutual recursion) | cte_errors, cte_column_list, cte_multiple_chained |

## Bullet 1 (cont.) — recursive CTEs with UNION and UNION ALL, ORDER BY/LIMIT in the recursive part

| Aspect | Files |
|---|---|
| UNION ALL recursion: series, multiple anchor rows, VALUES anchor, empty anchor, RECURSIVE keyword omitted | recursive_counting, recursive_sequences |
| UNION recursion: dedup makes cyclic recursions terminate; dedup on whole rows, NULLs, 1 vs 1.0 | recursive_union_dedup, recursive_graph_walk, perf_recursive_graph_walk |
| ORDER BY in the recursive part (queue order: depth-first vs breadth-first, priority queue) | recursive_order_by_limit, recursive_tree_walk |
| LIMIT / OFFSET in the recursive part (caps total rows incl. anchors; OFFSET rows still recurse; LIMIT 0 / -1) | recursive_order_by_limit, recursive_counting, recursive_union_dedup, perf_recursive_cte_100k |
| Several anchor selects and several recursive selects | recursive_multiple_arms, recursive_order_by_limit, perf_recursive_graph_walk |
| Tree walks (descendants, ancestors, paths, depth, subtree aggregates, LCA) | recursive_tree_walk, perf_recursive_graph_walk |
| Graph walks (reachability, simple paths with cycle check, shortest paths, components, transitive closure) | recursive_graph_walk, recursive_union_dedup, perf_recursive_graph_walk |
| Text and date processing, row-by-row iteration | recursive_string_processing, recursive_date_series, recursive_iterate_rows |
| Errors: aggregate/GROUP BY in recursive part, two recursive references, reference in subquery, circular reference, column count mismatch, non-recursive arm after a recursive one | recursive_errors, recursive_multiple_arms, cte_errors |

## Bullet 2 — window functions

| Function | Main file | Also in |
|---|---|---|
| row_number | window_row_number | window_top_n_per_group, window_practical_patterns, window_peer_semantics, many others |
| rank, dense_rank | window_rank_dense_rank | window_nulls_ordering, window_with_group_by, window_peer_semantics, window_mixed_types |
| percent_rank, cume_dist | window_percent_rank_cume_dist | window_nulls_ordering, window_peer_semantics, window_empty_frames |
| ntile (uneven splits, more buckets than rows, errors) | window_ntile | window_peer_semantics, window_dml, perf_window_running_50k |
| lag, lead (offset, default, partitions, NULL values vs missing rows) | window_lag_lead, window_lag_lead_offset_default | window_practical_patterns, window_mixed_types, window_nulls_ordering |
| first_value, last_value (default-frame pitfall, peers) | window_first_last_value | window_exclude_current_row, window_peer_semantics, window_nulls_ordering |
| nth_value (N beyond frame, NULL at N, sliding and FOLLOWING frames, errors) | window_nth_value | window_exclude_current_row, window_peer_semantics, window_empty_frames |
| count(*), count(x), min, max | window_count_min_max | window_empty_frames, window_errors (all aggregates in one statement) |
| sum, avg (types, overflow error, text inputs) | window_sum_avg | window_default_frame, window_practical_patterns |
| total, group_concat (1 and 2 args), string_agg | window_group_concat_total | window_errors, window_filter, window_mixed_types |

## Bullet 3 — OVER clause, named windows, frames, EXCLUDE, FILTER

| Aspect | Files |
|---|---|
| PARTITION BY (columns, expressions, collations, NULL keys, type classes) | window_partition_by, window_nulls_ordering |
| ORDER BY in windows (NULLS FIRST/LAST, DESC, expressions, cross-class values) | window_nulls_ordering, window_mixed_types, window_in_expressions |
| Default frames (no ORDER BY = whole partition; with ORDER BY = RANGE to last peer) | window_default_frame, window_first_last_value, window_peer_semantics |
| ROWS frames, every bound kind, short and BETWEEN forms | window_rows_frames, window_empty_frames, perf_window_running_50k |
| RANGE frames (integer/real offsets, DESC, NULL keys, dates via julianday) | window_range_frames, window_range_desc_real, window_nulls_ordering |
| GROUPS frames | window_groups_frames, window_exclude_group_ties, window_nulls_ordering |
| EXCLUDE NO OTHERS / CURRENT ROW | window_exclude_current_row |
| EXCLUDE GROUP / TIES (and all four side by side) | window_exclude_group_ties |
| Empty frames (aggregate empty values, value functions NULL) | window_empty_frames |
| Frame errors (start after end, FOLLOWING short form, UNBOUNDED misuse, bad offsets, RANGE offset needs one ORDER BY term, EXCLUDE without frame) | window_frame_errors, window_range_frames, window_exclude_current_row |
| Named windows: `WINDOW w AS (...)`, `OVER w`, several windows, compound queries | window_named_windows |
| Window inheritance `OVER (w ...)`, chained definitions, override errors | window_inheritance |
| FILTER on window aggregates (and error on non-aggregates) | window_filter, window_empty_frames |
| Peers and ties (peer-aware vs order-dependent functions) | window_peer_semantics, window_rank_dense_rank, window_default_frame |

## Interactions with earlier milestones

| Aspect | Files |
|---|---|
| Windows with GROUP BY / HAVING / aggregates as window arguments | window_with_group_by, perf_window_partitions_50k |
| Windows in subqueries, CTEs, joins, IN/EXISTS (top-N per group) | window_top_n_per_group, window_with_cte |
| Windows in expressions and in the query ORDER BY | window_in_expressions |
| DISTINCT, LIMIT/OFFSET, compound queries | window_distinct_limit, window_named_windows |
| Windows in INSERT/UPDATE/DELETE and upsert | window_dml |
| Several different windows in one SELECT | window_multiple_specs |
| Misuse errors (no OVER, scalar with OVER, WHERE/HAVING/GROUP BY, nesting, DISTINCT, arg counts, RETURNING) | window_errors, window_with_group_by, window_dml |
| Analytics patterns (sessions, gaps and islands, moving averages, median) | window_practical_patterns |

## Performance (`-- @timeout 5`)

| File | What it stresses |
|---|---|
| perf_recursive_cte_100k | 100k-row recursive CTEs aggregated, multi-column, materialized via WITH ... INSERT, 50k-step PK-lookup recursion |
| perf_recursive_graph_walk | 100k-node tree walk via an indexed parent column; UNION dedup over 20k-30k distinct values; graph reachability with cycles |
| perf_window_partitions_50k | 50k rows in 200 partitions: ranking, running sums, lag, top-N, RANGE frames, window over GROUP BY |
| perf_window_running_50k | one 50k-row partition: incremental running sums, sliding ROWS sum/max, ntile, RANGE and GROUPS frames, lag |
