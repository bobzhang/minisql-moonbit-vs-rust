# M6 coverage: schema, indexes and transactions

55 files (45 functional, 10 performance), 1606 statements. Each spec bullet
(SPEC.md §4, M6) is listed below with the files that test it.

## Indexes

| Spec item | Files |
|---|---|
| `CREATE INDEX name ON t (cols)`, multi-column, several indexes per column | index_create_basic, index_errors, index_null_range, index_after_dml |
| `CREATE UNIQUE INDEX`, uniqueness enforced on INSERT/UPDATE, statement atomicity | unique_index_enforcement, unique_index_multi_column, unique_index_existing_rows, index_if_exists |
| NULLs allowed multiple times in unique indexes (single and multi-column, column UNIQUE) | unique_index_nulls |
| Creating a unique index over existing duplicates fails | unique_index_existing_rows, index_collation, partial_unique_index |
| Conflict resolution against unique indexes (OR IGNORE/REPLACE, REPLACE, UPDATE OR ..., upsert) | unique_index_conflicts, partial_unique_index, expression_index, index_after_dml |
| Partial indexes (`WHERE expr`) | partial_index, partial_unique_index, expression_index |
| Expression indexes (incl. UNIQUE expression indexes) | expression_index, alter_rename_dependents |
| `ASC`/`DESC` columns | index_desc_order, index_create_basic |
| `COLLATE c` in index columns; column collations in unique indexes | index_collation |
| `CREATE INDEX IF NOT EXISTS`, `DROP INDEX [IF EXISTS]` | index_if_exists, index_create_basic, index_errors |
| Index errors (duplicate names across tables/views/indexes, unknown table/column, views, reserved `sqlite_` names, bad expressions/predicates) | index_errors, partial_index, expression_index, autoindex_schema |
| Index lookups respect affinity, cross-class order, NULL semantics, range bounds | index_lookup_affinity, index_null_range |
| Index maintenance through DML (update of key/rowid, delete, replace, upsert) | index_after_dml, partial_index, expression_index |
| Automatic indexes `sqlite_autoindex_<table>_<n>` | autoindex_schema, sqlite_schema_basic, sqlite_schema_changes, alter_rename_table |
| DROP TABLE drops its indexes | autoindex_schema, index_errors, sqlite_schema_changes |

## Views

| Spec item | Files |
|---|---|
| `CREATE VIEW name AS select`, querying like a table | view_basic, view_nested, view_over_join, view_over_aggregate |
| Column list `name(cols)` | view_column_list |
| Views over joins, aggregates, compounds, ORDER BY/LIMIT | view_over_join, view_over_aggregate, view_types_and_order, view_column_list |
| Views over views, views in subqueries/joins | view_nested, view_basic, view_over_join |
| Column affinity/collation seen through a view | view_types_and_order |
| `CREATE VIEW IF NOT EXISTS`, `DROP VIEW [IF EXISTS]` | view_if_exists, index_if_exists |
| Read-only: INSERT/UPDATE/DELETE/REPLACE on a view are errors; CREATE INDEX/ALTER/DROP TABLE on a view | view_read_only, alter_add_column_errors, alter_drop_column_errors |
| Dropping a table used by a view; late binding; `*` sees added columns | view_dependencies, alter_add_column_errors |
| Name clashes with tables/indexes | view_if_exists, view_read_only, index_errors |

## ALTER TABLE

| Spec item | Files |
|---|---|
| `RENAME TO` | alter_rename_table, alter_rename_dependents, autoindex_schema, sqlite_schema_changes |
| `RENAME [COLUMN] a TO b` | alter_rename_column, alter_rename_dependents, sqlite_schema_changes |
| Renames update dependent indexes, views and CHECK constraints | alter_rename_dependents, alter_rename_column |
| `ADD [COLUMN] def` (defaults, NOT NULL with default, CHECK, COLLATE, REFERENCES) | alter_add_column, alter_add_column_errors, view_dependencies |
| ADD COLUMN errors (duplicate, PRIMARY KEY, UNIQUE, NOT NULL without default, view, unknown table) | alter_add_column_errors |
| `DROP [COLUMN] c` | alter_drop_column, alter_drop_column_errors |
| DROP COLUMN errors (PK, UNIQUE, indexed, partial-index predicate, table CHECK, view, last column, unknown) | alter_drop_column_errors, alter_drop_column |
| Rename errors (name in use, case-only rename, unknown table/column, reserved names) | alter_rename_table, alter_rename_column |

## sqlite_schema

| Spec item | Files |
|---|---|
| `sqlite_schema` / `sqlite_master` with `type`, `name`, `tbl_name` | sqlite_schema_basic, sqlite_schema_changes, autoindex_schema, index_create_basic, alter_rename_table |
| Querying it with WHERE/GROUP BY/joins/subqueries; read-only | sqlite_schema_basic |
| Reflects CREATE/DROP/ALTER and rolled-back DDL | sqlite_schema_changes, transaction_rollback_ddl, savepoint_rollback_to |

## Transactions

| Spec item | Files |
|---|---|
| `BEGIN [DEFERRED|IMMEDIATE|EXCLUSIVE] [TRANSACTION]`, `COMMIT`/`END`, `ROLLBACK` | transaction_begin_forms, transaction_commit_rollback |
| Errors: nested BEGIN, COMMIT/END/ROLLBACK without a transaction | transaction_errors, savepoint_without_begin, savepoint_errors, transaction_statement_errors |
| Rollback restores schema changes (tables, indexes, views, all ALTER forms) | transaction_rollback_ddl, sqlite_schema_changes, savepoint_rollback_to |
| Statement atomicity inside a transaction; INSERT OR ROLLBACK/FAIL/ABORT | transaction_statement_errors |
| Open transaction at end of script is discarded | transaction_commit_rollback |
| `SAVEPOINT`, `RELEASE [SAVEPOINT]`, `ROLLBACK [TRANSACTION] TO [SAVEPOINT]` | savepoint_basic, savepoint_nested, savepoint_rollback_to |
| Nested savepoints, duplicate names, release/rollback of outer savepoints | savepoint_nested, savepoint_errors |
| ROLLBACK TO keeps the savepoint open (repeatable) | savepoint_rollback_to, savepoint_basic |
| SAVEPOINT outside BEGIN starts a transaction; RELEASE commits it | savepoint_without_begin, savepoint_errors |
| Savepoint errors (unknown, released, discarded) | savepoint_errors, savepoint_nested |

## Performance (`-- @timeout 5`)

All use a 100,000-row table built with the digits cross-join trick (50,000 rows in
perf_unique_insert) and 10,000-row probe tables. SQLite runs each file in
0.07–0.17 s; a plan that scans instead of using the index needs 10^9–5·10^9 row
visits.

| Workload | File |
|---|---|
| Equality lookups on an indexed column (correlated scalar subquery ×10k) | perf_index_point_lookup |
| Range lookups (BETWEEN, open ranges) ×10k | perf_index_range |
| Joins on indexed columns and on the rowid, 3-way join | perf_indexed_join |
| ORDER BY ... LIMIT/OFFSET on an indexed column, min() with a range ×10k | perf_order_by_limit |
| IN / NOT IN (subquery), correlated IN, EXISTS / NOT EXISTS with indexes | perf_in_subquery |
| Bulk INSERT/UPDATE with UNIQUE checks, INSERT OR IGNORE | perf_unique_insert |
| Correlated lookups in SELECT, WHERE, UPDATE, DELETE, join conditions | perf_correlated_lookup |
| INTEGER PRIMARY KEY lookups, joins, UPDATE/DELETE by rowid | perf_rowid_lookup |
| Two-column index: equality + range/equality on the second column | perf_multi_column_index |
| UPDATE/DELETE located through indexes, index maintenance under change | perf_delete_update_index |

The join tests keep the indexed table on the inner side of the FROM order (or index
both sides), so they need index use but not join reordering.
