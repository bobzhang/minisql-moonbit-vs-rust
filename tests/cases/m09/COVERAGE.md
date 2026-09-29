# M9 coverage: writing SQLite database files

In these tests the engine writes the file. A later `sqlite` phase checks it
with `PRAGMA integrity_check` (which prints `ok`), then runs SELECTs,
usually with `INDEXED BY` so each engine-built index is actually read.
Many tests then let SQLite modify the file and run the engine again. No
expected output depends on page numbers, rootpage values, freelist layout,
page size, or the `sql` text of schema rows. The suite passes with an
engine that rewrites and re-lays-out the whole file after every phase:
this was checked by vacuuming to page sizes 512, 1024 and 65536 after each
engine phase. The only difference seen came from VACUUM renumbering rowids
in a table without INTEGER PRIMARY KEY, which a correct engine does not do.

The mapping below follows the bullets in SPEC §4 (M9) and the topics the
test plan asked for.

## SQLite can open the file; integrity_check is ok; contents are right

| Topic | Files |
|---|---|
| Engine creates a new file (file absent before the first phase) | `write_basic.sql`, `create_schema_new_file.sql`, and most other files |
| First engine process only reads a missing file; a later one writes to it | `engine_first_phase_readonly.sql` |
| Tables, indexes and views in a new file; schema `sql` parseable by SQLite | `create_schema_new_file.sql`, `views_write.sql`, `create_table_as_select_write.sql` |
| Multi-level table and index b-trees (20k to 40k rows from recursive CTEs) | `insert_many_rows_multilevel.sql`, `text_index_deep.sql`, `large_index_used_by_sqlite.sql`, `delete_many_rows.sql` |
| SQLite queries engine-built indexes (INDEXED BY with ranges and equality; REAL keys, mixed int/real keys) | `large_index_used_by_sqlite.sql`, `text_index_deep.sql`, `insert_many_rows_multilevel.sql` |
| Overflow values in tables and index keys (0 B to about 150 KB) | `overflow_values_new_file.sql`, `modify_page_size_<N>.sql`, `wide_table_write.sql` |
| Overflow chains grown, shrunk and freed | `overflow_update_grow_shrink.sql`, `overflow_values_new_file.sql` |
| UNIQUE/PRIMARY KEY autoindexes: names `sqlite_autoindex_<t>_<N>`, contents, uniqueness still enforced by SQLite | `autoindex_unique_write.sql`, `create_schema_new_file.sql`, `non_ascii_write.sql` |
| Index ordering by collation (NOCASE, RTRIM) and DESC | `index_collate_desc_write.sql` |
| Expression and partial indexes (contents recomputed by integrity_check) | `index_expression_partial_write.sql` |
| Every serial type and integer width | `serial_types_write.sql` |
| REAL affinity (compact integer storage allowed), NUMERIC/INTEGER conversions | `real_affinity_write.sql` |
| Negative and huge rowids, 9-byte varints | `rowid_extremes_write.sql` |
| Wide records (header-size varint of 2 bytes, records spanning overflow) | `wide_table_write.sql` |
| Schema b-tree beyond page 1, long CREATE text | `many_tables_write.sql` |
| Non-ASCII data and identifiers | `non_ascii_write.sql` |
| CREATE TABLE … AS SELECT | `create_table_as_select_write.sql`, `wide_table_write.sql` (done by SQLite, read by the engine) |

## Modifications

| Topic | Files |
|---|---|
| UPDATE of many rows (indexed columns, rowid alias, record sizes) | `update_many_rows.sql`, `modify_file_with_free_space.sql` |
| DELETE of many rows (pages freed; freelist valid) | `delete_many_rows.sql`, `delete_all_then_reinsert.sql`, `rowid_extremes_write.sql` |
| REPLACE / upsert / UPDATE OR REPLACE across several indexes | `replace_upsert_write.sql` |
| DROP TABLE / DROP INDEX / DROP VIEW, then new objects | `drop_table_recreate.sql`, `drop_index_and_view.sql`, `empty_database_write.sql`, `many_tables_write.sql` |
| ALTER TABLE ADD COLUMN (old rows get the DEFAULT) | `alter_add_column_write.sql`, `modify_sqlite_altered_table.sql` |
| ALTER TABLE RENAME TO (index tbl_name, autoindex renaming, view rewrite) | `alter_rename_table_write.sql` |
| ALTER TABLE RENAME COLUMN / DROP COLUMN (records rewritten) | `alter_rename_drop_column_write.sql` |
| AUTOINCREMENT and `sqlite_sequence` (created with the first such table, kept after deletes, row removed on DROP) | `autoincrement_sequence.sql`, `autoincrement_new_file_only.sql` |

## Files written by SQLite, then modified by the engine

| Topic | Files |
|---|---|
| Non-default page sizes 512, 1024, 8192, 65536 kept valid, with exact overflow thresholds | `modify_page_size_<N>.sql` |
| Existing long freelist, freeblocks and fragmentation | `modify_file_with_free_space.sql` |
| Short records from ADD COLUMN, updated and indexed by the engine | `modify_sqlite_altered_table.sql` |

## Several processes

| Topic | Files |
|---|---|
| Engine, engine, engine, then SQLite | `engine_processes_in_sequence.sql`, `transaction_open_at_exit.sql`, `engine_first_phase_readonly.sql` |
| SQLite and the engine alternate writes (each reads the other's changes) | `interleaved_sqlite_engine.sql`, `autoincrement_sequence.sql`, `create_schema_new_file.sql`, `drop_table_recreate.sql`, `many_tables_write.sql`, `views_write.sql` |
| Schema cookie increases when the engine changes the schema | `schema_cookie_changes.sql` |

## Transactions and atomicity

| Topic | Files |
|---|---|
| COMMIT / END persist (DDL and bulk data inside the transaction) | `transaction_commit_persists.sql` |
| ROLLBACK discards everything, including DDL | `transaction_rollback_discarded.sql` |
| A transaction (or savepoint) still open at exit is rolled back | `transaction_open_at_exit.sql` |
| SAVEPOINT / ROLLBACK TO / RELEASE | `savepoints_write.sql` |
| A failing statement leaves no partial changes; OR FAIL/IGNORE/REPLACE/ROLLBACK | `failed_statement_atomic.sql`, `autoincrement_new_file_only.sql` |
