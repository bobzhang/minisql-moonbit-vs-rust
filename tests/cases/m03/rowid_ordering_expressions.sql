-- The rowid in ORDER BY, LIMIT, DISTINCT and expressions, including tables
-- whose INTEGER PRIMARY KEY aliases it.
CREATE TABLE t(v TEXT);
INSERT INTO t VALUES ('c'), ('a'), ('b'), ('a');
SELECT rowid, v FROM t ORDER BY rowid DESC;
SELECT v FROM t ORDER BY v, rowid DESC;
SELECT rowid FROM t ORDER BY rowid LIMIT 2 OFFSET 1;
SELECT DISTINCT v FROM t ORDER BY v;
SELECT rowid * 2 AS dbl, v FROM t WHERE rowid IN (1, 3) ORDER BY dbl;
SELECT max(rowid, 3), min(oid, 2) FROM t ORDER BY rowid;

-- Explicit rowids out of insertion order.
CREATE TABLE s(v TEXT);
INSERT INTO s(rowid, v) VALUES (30, 'x'), (10, 'y'), (20, 'z');
SELECT rowid, v FROM s ORDER BY rowid;
SELECT rowid, v FROM s ORDER BY v DESC;
SELECT rowid FROM s WHERE rowid BETWEEN 15 AND 30 ORDER BY rowid DESC;

-- INTEGER PRIMARY KEY: ordering by either name is the same.
CREATE TABLE k(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO k VALUES (3, 'three'), (1, 'one'), (2, 'two');
SELECT id, v FROM k ORDER BY rowid;
SELECT id, v FROM k ORDER BY oid DESC;
SELECT _rowid_ + id, v FROM k ORDER BY 1;

-- Rowid of an UPDATEd row is unchanged; the rowid of a REPLACEd row changes.
CREATE TABLE r(name TEXT UNIQUE, n INTEGER);
INSERT INTO r VALUES ('a', 1), ('b', 2), ('c', 3);
UPDATE r SET n = n + 10 WHERE name = 'a';
REPLACE INTO r VALUES ('b', 20);
SELECT rowid, name, n FROM r ORDER BY rowid;

-- typeof(rowid) is always integer.
SELECT DISTINCT typeof(rowid) FROM r;
