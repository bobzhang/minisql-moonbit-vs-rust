-- ALTER TABLE t DROP [COLUMN] c removes the column and its data; the
-- remaining columns keep their values and order.
CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT, b INTEGER, c REAL, d TEXT DEFAULT 'dd');
INSERT INTO t VALUES (1, 'a1', 10, 1.5, 'd1'), (2, 'a2', 20, 2.5, 'd2'), (3, NULL, NULL, NULL, NULL);

ALTER TABLE t DROP COLUMN b;
SELECT * FROM t ORDER BY id;
SELECT b FROM t;
-- COLUMN keyword is optional.
ALTER TABLE t DROP c;
SELECT * FROM t ORDER BY id;
-- Defaults of remaining columns still apply.
INSERT INTO t(id, a) VALUES (4, 'a4');
SELECT id, a, d FROM t ORDER BY id;
-- Inserting with the old number of values now fails; the new count works.
INSERT INTO t VALUES (5, 'a5', 50, 5.5, 'd5');
INSERT INTO t VALUES (5, 'a5', 'd5');
SELECT count(*) FROM t;
-- A column with its own column-level CHECK can be dropped along with the check.
CREATE TABLE ck(x INTEGER, y INTEGER CHECK (y > 0));
INSERT INTO ck VALUES (1, 1);
ALTER TABLE ck DROP COLUMN y;
INSERT INTO ck VALUES (2);
SELECT x FROM ck ORDER BY x;
-- A column that has a non-unique index cannot be dropped while indexed...
CREATE TABLE ix(p INTEGER, q TEXT, r TEXT);
CREATE INDEX ix_q ON ix(q);
INSERT INTO ix VALUES (1, 'q1', 'r1');
ALTER TABLE ix DROP COLUMN q;
-- ...but can after the index is dropped.
DROP INDEX ix_q;
ALTER TABLE ix DROP COLUMN q;
SELECT * FROM ix;
-- Dropping a column then adding one with the same name gives fresh values.
ALTER TABLE ix ADD COLUMN q TEXT DEFAULT 'new';
SELECT * FROM ix;
-- Dropping columns inside a table used by a view whose columns survive.
CREATE VIEW ixv AS SELECT p, r FROM ix;
ALTER TABLE ix DROP COLUMN q;
SELECT * FROM ixv;
-- Rowids and the INTEGER PRIMARY KEY survive a drop.
SELECT id, rowid FROM t ORDER BY id;
