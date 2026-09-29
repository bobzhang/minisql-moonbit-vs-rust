# M5 coverage: joins, subqueries and compound queries

56 files, 1088 statements. Each spec bullet (SPEC.md §4, M5) is listed below with the
files that test it.

## Joins

| Spec item | Files |
|---|---|
| Comma joins | cross_join_comma, self_join, multi_way_join, join_ambiguous_columns, subquery_from_aggregate |
| `CROSS JOIN` (also with an ON clause) | cross_join_keyword, values_from |
| `[INNER] JOIN ... ON` | inner_join_on, inner_join_null_keys, join_order_limit, join_rowid_keys, join_affinity, join_collation |
| `LEFT [OUTER] JOIN`, NULL-extended rows | left_join_basic, left_join_antijoin, left_join_on_vs_where, mixed_outer_joins, self_join, join_aggregates |
| `RIGHT [OUTER] JOIN` | right_join_basic, right_join_on_vs_where, mixed_outer_joins, full_join_using, natural_join_star |
| `FULL [OUTER] JOIN` | full_join_basic, full_join_nulls, full_join_using, mixed_outer_joins, natural_join_star |
| ON vs WHERE for outer joins | left_join_on_vs_where, right_join_on_vs_where, full_join_basic, left_join_antijoin, correlated_where (ON with a subquery) |
| NULL join keys (`=` vs `IS`) | inner_join_null_keys, full_join_nulls, natural_join_basic, join_using_basic |
| `USING (cols)`, incl. multi-column | join_using_basic, join_using_star, full_join_using, join_affinity, join_collation, subquery_from_join |
| `NATURAL` (inner/left/right/full, no common columns = cross join) | natural_join_basic, natural_join_star, full_join_using, subquery_from_join |
| `*` / `table.*` expansion with USING/NATURAL | join_using_star, natural_join_star, full_join_using, subquery_from_join |
| Unqualified USING column in RIGHT/FULL join is the coalesced value; chained USING | full_join_using |
| Self-joins | self_join, cross_join_comma, join_ambiguous_columns, subquery_scope |
| Multi-way (3–4 tables), mixed join kinds, left-to-right evaluation | multi_way_join, mixed_outer_joins, join_using_star, natural_join_star, self_join |
| Column resolution: qualified names, aliases hiding table names, case-insensitive and quoted identifiers | join_column_resolution, join_ambiguous_columns |
| Ambiguity errors (select list, WHERE, ON, ORDER BY, GROUP BY, duplicate alias, self-join without alias) | join_ambiguous_columns, join_using_basic |
| Join errors (unknown table/column, USING column missing, NATURAL with ON/USING) | cross_join_comma, inner_join_on, join_using_basic, natural_join_basic, join_column_resolution |
| Comparison affinity and collation in join conditions | join_affinity, join_collation, join_rowid_keys |
| Joins with GROUP BY/HAVING/aggregates, ORDER BY/LIMIT/DISTINCT | join_aggregates, join_order_limit, self_join |

## Subqueries

| Spec item | Files |
|---|---|
| Scalar subquery: first row, NULL when empty, errors for >1 column | scalar_subquery_basic, scalar_subquery_expressions, compound_subqueries, values_query |
| Scalar subqueries in arithmetic, CASE, functions, BETWEEN, LIMIT/OFFSET, GROUP BY, VALUES, INSERT/UPDATE/DELETE | scalar_subquery_expressions, subquery_in_dml |
| `[NOT] IN (SELECT ...)` | in_subquery_basic, in_subquery_nulls, in_subquery_affinity, compound_subqueries, left_join_antijoin |
| IN / NOT IN with NULLs in the subquery, empty subquery, NULL on the left | in_subquery_nulls, exists_correlated, correlated_where, compound_subqueries |
| Affinity and collation in IN (SELECT) | in_subquery_affinity |
| `[NOT] EXISTS` | exists_basic, exists_correlated, left_join_antijoin, compound_subqueries |
| Correlated subqueries in SELECT list | correlated_select_list, correlated_nested, subquery_scope |
| Correlated subqueries in WHERE and ON | correlated_where, exists_correlated, in_subquery_nulls |
| Correlated subqueries in ORDER BY | correlated_order_by |
| Correlated subqueries in HAVING / GROUP BY; outer aggregates inside subqueries | correlated_having |
| Correlated subqueries in UPDATE/DELETE/INSERT/RETURNING | subquery_in_dml, correlated_where |
| Nested (multi-level) correlation, innermost-name resolution | correlated_nested, subquery_scope |
| Subqueries in FROM with aliases, derived column names | subquery_from_basic, subquery_from_aggregate, subquery_from_join, values_from |
| Derived tables in joins (USING/NATURAL/outer) | subquery_from_join, multi_way_join, join_aggregates |

## Compound queries

| Spec item | Files |
|---|---|
| `UNION` (duplicate removal) | union_basic, compound_nulls, compound_types, compound_chains |
| `UNION ALL` | union_all, compound_chains, values_compound |
| `INTERSECT`, `EXCEPT` | intersect_except, compound_nulls, compound_types, compound_chains |
| NULLs compare equal for duplicate removal | compound_nulls |
| Mixed storage classes (no affinity between sides; 1 = 1.0 but 1 ≠ '1') | compound_types, union_all |
| Collation used by compound operators | compound_collation |
| ORDER BY on the whole compound: column number, first-SELECT name/alias, DESC, NULLS, COLLATE; errors | compound_order_by, compound_limit, compound_collation |
| LIMIT/OFFSET on the whole compound; LIMIT/ORDER BY before UNION is an error | compound_limit, compound_order_by |
| Chains with equal precedence, left to right | compound_chains |
| Compounds as subqueries (IN, EXISTS, scalar, FROM, correlated, INSERT) | compound_subqueries, in_subquery_basic |
| Column-count mismatch errors | compound_chains, values_compound |

## VALUES

| Spec item | Files |
|---|---|
| `VALUES (...), (...)` as a query | values_query, values_compound |
| VALUES as a FROM source (column1, column2, ...) | values_from, values_query, subquery_from_join |
| VALUES in compounds, IN and scalar subqueries | values_compound, values_query |
| Errors: rows of different lengths, unknown column | values_query, values_compound, values_from |

Notes for implementers:
* Every multi-row result is ordered by an explicit ORDER BY. A top-level multi-row
  `VALUES` has no ORDER BY because SQLite does not accept ORDER BY after a
  trailing VALUES clause; such rows are expected in the order written.
* Scalar subqueries that return several rows always order them (or use LIMIT), so
  "first row" is well defined.
