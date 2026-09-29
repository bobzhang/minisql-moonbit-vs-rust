-- sqlite_schema reflects every schema change: CREATE/DROP of tables,
-- indexes and views, ALTER TABLE renames, and rolled-back DDL.
CREATE TABLE a(x INTEGER, y TEXT UNIQUE);
CREATE INDEX a_x ON a(x);
CREATE VIEW av AS SELECT x FROM a;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
-- Renaming the table updates tbl_name of its indexes (and renames automatic indexes).
ALTER TABLE a RENAME TO b;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
-- Renaming a column does not change any names.
ALTER TABLE b RENAME COLUMN x TO xx;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
-- Adding a column does not add schema rows; indexing it does.
ALTER TABLE b ADD COLUMN z;
SELECT count(*) FROM sqlite_schema;
CREATE INDEX b_z ON b(z);
SELECT count(*) FROM sqlite_schema WHERE tbl_name = 'b';
-- Dropping a view and an index.
DROP VIEW av;
DROP INDEX a_x;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
-- Dropping the table removes its remaining indexes.
DROP TABLE b;
SELECT count(*) FROM sqlite_schema;
-- DDL inside a rolled-back transaction leaves no trace.
BEGIN;
CREATE TABLE tmp(q);
CREATE INDEX tmp_q ON tmp(q);
CREATE VIEW tmpv AS SELECT q FROM tmp;
SELECT count(*) FROM sqlite_schema;
ROLLBACK;
SELECT count(*) FROM sqlite_schema;
-- Committed DDL stays.
BEGIN;
CREATE TABLE keep(k TEXT PRIMARY KEY);
COMMIT;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
-- A rolled-back DROP brings the objects back.
CREATE INDEX keep_k2 ON keep(k DESC);
BEGIN;
DROP TABLE keep;
SELECT count(*) FROM sqlite_schema;
ROLLBACK;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
-- A failed CREATE adds nothing.
CREATE TABLE keep(z);
CREATE INDEX bad ON keep(nosuch);
SELECT count(*) FROM sqlite_schema;
