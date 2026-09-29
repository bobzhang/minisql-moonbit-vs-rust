# M3 coverage: query shaping, DML and constraints

Maps each bullet of SPEC.md §4 M3 to the test files that exercise it.

## Full ORDER BY, LIMIT/OFFSET, DISTINCT

| Feature | Files |
|---|---|
| Result-column aliases in ORDER BY (incl. alias shadowing a column) | order_by_alias, select_distinct_order_limit, rowid_ordering_expressions |
| Ordinals (incl. out-of-range errors, with `*`) | order_by_ordinal, select_distinct_order_limit, order_by_nulls_first_last |
| `NULLS FIRST` / `NULLS LAST` | order_by_nulls_first_last, order_by_special_reals, select_distinct_order_limit |
| `COLLATE` in ORDER BY | order_by_collate, order_by_alias, order_by_ordinal |
| Declared column collations in ORDER BY | order_by_collate, collate_column_definitions |
| Mixed storage classes, int/real ties, Inf, -0.0, big ints | order_by_mixed_types, order_by_special_reals |
| Multi-key, mixed directions, expression keys | order_by_multi_key |
| `LIMIT n [OFFSET m]`, `LIMIT m, n`, negative LIMIT/OFFSET, expressions, errors | limit_offset, select_distinct_order_limit, rowid_ordering_expressions |
| `SELECT DISTINCT` (NULLs, multi-column, classes) | select_distinct, select_distinct_order_limit, distinct_numeric_equality |
| DISTINCT with collations | distinct_collation |

## DML

| Feature | Files |
|---|---|
| `UPDATE ... SET ... [WHERE]` | update_basic, update_expressions, update_where_complex, update_rowid |
| `DELETE FROM ... [WHERE]` | delete_basic, delete_reinsert_cycle |
| `INSERT INTO t [(cols)] SELECT ...` | insert_select, insert_or_abort_fail, insert_or_ignore, rowid_allocation |
| Column lists (order, subsets, rowid columns, errors) | insert_column_list |
| `INSERT INTO t DEFAULT VALUES` | insert_default_values, replace_into, returning_insert |
| `REPLACE INTO` | replace_into, rowid_ordering_expressions, changes_conflict_resolution |
| `INSERT OR REPLACE` | insert_or_replace, conflict_clause_on_constraints, upsert_multiple_clauses |
| `INSERT OR IGNORE` | insert_or_ignore, check_or_clauses, not_null_conflict_clause |
| `INSERT OR ABORT` / `OR FAIL` | insert_or_abort_fail, check_or_clauses |
| `INSERT OR ROLLBACK` (outside a transaction) | insert_or_rollback |
| `UPDATE OR {REPLACE, IGNORE, ABORT, FAIL, ROLLBACK}` | update_or_clauses, check_or_clauses, insert_or_rollback |
| Upsert `ON CONFLICT [(cols)] DO NOTHING` | upsert_do_nothing, upsert_multiple_clauses |
| Upsert `DO UPDATE SET ... [WHERE ...]`, `excluded.col` | upsert_do_update, upsert_errors, upsert_multiple_clauses |
| Upsert with INSERT ... SELECT (`WHERE true` form) | upsert_do_update, upsert_errors |
| Upsert vs. OR clause precedence | upsert_multiple_clauses, conflict_clause_on_constraints |
| `RETURNING` on INSERT | returning_insert |
| `RETURNING` on UPDATE / DELETE | returning_update_delete |

## Constraints

| Feature | Files |
|---|---|
| `NOT NULL` | not_null_constraint, insert_default_values |
| `UNIQUE` column level | unique_column, unique_collation |
| `UNIQUE` table level, multi-column | unique_multi_column, constraint_syntax |
| `PRIMARY KEY` column level (non-integer, NULLs allowed) | primary_key_non_integer |
| `PRIMARY KEY` table level (composite, single INTEGER column = alias) | primary_key_table_level |
| `CHECK` (column/table level, named, NULL passes, affinity first) | check_constraint, check_or_clauses |
| `DEFAULT` literal, signed number, `(expr)`, affinity of defaults | default_expressions, insert_default_values, constraint_syntax |
| Conflict clauses on constraints (`ON CONFLICT ...`) | conflict_clause_on_constraints, not_null_conflict_clause, insert_or_abort_fail, insert_or_rollback, insert_or_ignore |
| `COLLATE` in column definitions | collate_column_definitions, unique_collation, order_by_collate, distinct_collation |
| All constraint syntax forms, REFERENCES/FOREIGN KEY parsed but not enforced | constraint_syntax |

## Rowids

| Feature | Files |
|---|---|
| `rowid` / `oid` / `_rowid_`, column named rowid | rowid_basic, rowid_ordering_expressions |
| `INTEGER PRIMARY KEY` as alias (and INT / BIGINT / DESC non-aliases) | integer_primary_key_alias, primary_key_table_level |
| Allocation max+1, after deletes, negative, explicit | rowid_allocation, delete_reinsert_cycle, update_rowid |
| Maximum rowid 9223372036854775807 behaviour | rowid_max_value, autoincrement_max |
| `AUTOINCREMENT` | autoincrement, autoincrement_max |

## Atomicity and change counters

| Feature | Files |
|---|---|
| Failing statement leaves no partial effects | statement_atomicity, insert_or_abort_fail, not_null_constraint, returning_insert, upsert_errors |
| `changes()`, `total_changes()`, `last_insert_rowid()` | changes_functions, changes_conflict_resolution, insert_or_ignore, statement_atomicity |
