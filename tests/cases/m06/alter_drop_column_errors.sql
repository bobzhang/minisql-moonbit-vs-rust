-- ALTER TABLE DROP COLUMN fails when the column is a PRIMARY KEY, is UNIQUE,
-- is used by an index, a partial-index WHERE clause, a table CHECK
-- constraint or a view, is the only column, or does not exist. After each
-- failure the table is unchanged.
CREATE TABLE t(id INTEGER PRIMARY KEY, u TEXT UNIQUE, ix INTEGER, px INTEGER, ck INTEGER, vw TEXT, free TEXT, CHECK (ck >= 0));
CREATE INDEX t_ix ON t(ix);
CREATE INDEX t_part ON t(free) WHERE px > 0;
CREATE VIEW t_view AS SELECT id, vw FROM t;
INSERT INTO t VALUES (1, 'u1', 10, 1, 0, 'v1', 'f1');

ALTER TABLE t DROP COLUMN id;
ALTER TABLE t DROP COLUMN u;
ALTER TABLE t DROP COLUMN ix;
ALTER TABLE t DROP COLUMN px;
ALTER TABLE t DROP COLUMN ck;
ALTER TABLE t DROP COLUMN vw;
ALTER TABLE t DROP COLUMN nosuch;
SELECT * FROM t;
-- Other statements on the table keep working in between.
SELECT count(*) FROM t WHERE ix = 10;
SELECT vw FROM t_view;
UPDATE t SET free = 'f2' WHERE id = 1;
SELECT free FROM t WHERE px > 0;
-- Once the dependents are gone the drops succeed.
DROP INDEX t_ix;
ALTER TABLE t DROP COLUMN ix;
DROP VIEW t_view;
ALTER TABLE t DROP COLUMN vw;
DROP INDEX t_part;
ALTER TABLE t DROP COLUMN px;
ALTER TABLE t DROP COLUMN free;
SELECT * FROM t;
-- The CHECK and UNIQUE constraints still work.
INSERT INTO t VALUES (2, 'u2', -5);
INSERT INTO t VALUES (2, 'u2', 5);
SELECT * FROM t ORDER BY id;
SELECT type, name FROM sqlite_schema ORDER BY name;
-- A table's last remaining column cannot be dropped.
CREATE TABLE one(x);
ALTER TABLE one DROP COLUMN x;
CREATE TABLE two(x, y);
ALTER TABLE two DROP COLUMN x;
INSERT INTO two VALUES ('only y');
SELECT * FROM two;
-- Views cannot be altered.
CREATE VIEW v AS SELECT 1 AS a, 2 AS b;
ALTER TABLE v DROP COLUMN a;
SELECT * FROM v;
SELECT count(*) FROM two;
SELECT a + b FROM v;
