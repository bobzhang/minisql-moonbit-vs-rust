-- IF [NOT] EXISTS forms for indexes (and the related table/view forms):
-- they turn "already exists" / "does not exist" errors into no-ops.
CREATE TABLE t(a INTEGER, b TEXT);
INSERT INTO t VALUES (1, 'one'), (2, 'two');

CREATE INDEX IF NOT EXISTS t_a ON t(a);
-- Second time: no error, and the existing definition is kept (not replaced).
CREATE INDEX IF NOT EXISTS t_a ON t(b);
CREATE UNIQUE INDEX IF NOT EXISTS t_a ON t(b);
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
-- Without IF NOT EXISTS it is an error.
CREATE INDEX t_a ON t(a);
-- IF NOT EXISTS does not help when the name belongs to a table.
CREATE INDEX IF NOT EXISTS t ON t(a);
-- DROP INDEX IF EXISTS on a missing index is silent.
DROP INDEX IF EXISTS nosuch;
DROP INDEX IF EXISTS t_a;
DROP INDEX IF EXISTS t_a;
SELECT count(*) FROM sqlite_schema WHERE type = 'index';
DROP INDEX t_a;
-- CREATE UNIQUE INDEX IF NOT EXISTS creates when absent and enforces.
CREATE UNIQUE INDEX IF NOT EXISTS t_b ON t(b);
INSERT INTO t VALUES (3, 'one');
SELECT count(*) FROM t;
-- Table and view forms.
CREATE TABLE IF NOT EXISTS t(z);
SELECT a, b FROM t ORDER BY a;
DROP TABLE IF EXISTS nosuch_table;
CREATE VIEW IF NOT EXISTS vw AS SELECT a FROM t;
CREATE VIEW IF NOT EXISTS vw AS SELECT b FROM t;
SELECT * FROM vw ORDER BY 1;
DROP VIEW IF EXISTS vw;
DROP VIEW IF EXISTS vw;
SELECT type, name FROM sqlite_schema ORDER BY name;
-- IF EXISTS on DROP TABLE removes the table's indexes too.
DROP TABLE IF EXISTS t;
SELECT count(*) FROM sqlite_schema;
