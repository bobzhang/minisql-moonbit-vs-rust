-- Errors from CREATE INDEX / DROP INDEX, interleaved with statements that
-- succeed. Index, table and view names share one namespace
-- (case-insensitively).
CREATE TABLE t(a INTEGER, b TEXT);
CREATE TABLE u(x INTEGER);
CREATE VIEW v AS SELECT a FROM t;
INSERT INTO t VALUES (1, 'p'), (2, 'q');
CREATE INDEX t_a ON t(a);

-- Index name already used by an index, in any letter case.
CREATE INDEX t_a ON t(b);
CREATE INDEX T_A ON u(x);
-- Index name already used by a table or view.
CREATE INDEX u ON t(a);
CREATE INDEX v ON t(a);
-- A table cannot take an index's name.
CREATE TABLE t_a(z);
-- Unknown table or column.
CREATE INDEX i1 ON nosuch(a);
CREATE INDEX i2 ON t(a, nosuch);
-- Views cannot be indexed.
CREATE INDEX i4 ON v(a);
-- Dropping something that is not an index.
DROP INDEX nosuch;
-- None of the failed statements created anything.
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT a, b FROM t ORDER BY a;
-- Successful statements between the errors still work.
CREATE INDEX i5 ON t(b);
CREATE INDEX i6 ON t(b, a);
CREATE INDEX i7 ON u(x);
SELECT a FROM t WHERE b = 'q';
SELECT a FROM t WHERE b = 'p' AND a = 1;
INSERT INTO u VALUES (7), (8);
SELECT x FROM u WHERE x = 7;
SELECT count(*) FROM sqlite_schema WHERE type = 'index';
DROP INDEX i5;
DROP INDEX i6;
DROP INDEX t_a;
SELECT name, tbl_name FROM sqlite_schema WHERE type = 'index';
-- The same name can be reused after dropping, even on another table.
CREATE INDEX t_a ON u(x);
SELECT name, tbl_name FROM sqlite_schema WHERE type = 'index' ORDER BY name;
SELECT x FROM u WHERE x > 7;
-- Dropping the table drops its indexes; the names become free again.
DROP TABLE u;
SELECT count(*) FROM sqlite_schema WHERE type = 'index';
CREATE INDEX i7 ON t(a);
CREATE INDEX t_a ON t(b);
SELECT name, tbl_name FROM sqlite_schema WHERE type = 'index' ORDER BY name;
