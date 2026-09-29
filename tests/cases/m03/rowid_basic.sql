-- Every ordinary table has a 64-bit integer rowid, readable as rowid, oid or
-- _rowid_. SELECT * does not include it.
CREATE TABLE t(x TEXT, y INTEGER);
INSERT INTO t VALUES ('a', 10), ('b', 20), ('c', 30);
SELECT rowid, oid, _rowid_, x FROM t ORDER BY rowid;
SELECT * FROM t ORDER BY rowid DESC;
SELECT ROWID, OID, _ROWID_ FROM t WHERE x = 'b';
SELECT t.rowid, t.x FROM t ORDER BY t.oid;
SELECT typeof(rowid) FROM t WHERE x = 'a';

-- Filtering and arithmetic on rowid.
SELECT x FROM t WHERE rowid = 2;
SELECT x FROM t WHERE rowid >= 2 ORDER BY rowid;
SELECT rowid * 10 + y FROM t ORDER BY 1;
-- Comparison with text uses integer affinity for the rowid.
SELECT x FROM t WHERE rowid = '3';
SELECT x FROM t WHERE rowid = 1.0;
SELECT x FROM t WHERE rowid = 1.5;

-- Explicit rowids on insert.
CREATE TABLE r(v);
INSERT INTO r(rowid, v) VALUES (10, 'ten'), (-5, 'minus five'), (0, 'zero');
SELECT rowid, v FROM r ORDER BY rowid;
-- Duplicate explicit rowid is a constraint error.
INSERT INTO r(rowid, v) VALUES (10, 'again');
-- Non-integer rowid values.
INSERT INTO r(rowid, v) VALUES ('abc', 'bad');
INSERT INTO r(rowid, v) VALUES ('20', 'text twenty');
INSERT INTO r(rowid, v) VALUES (30.0, 'real thirty');
SELECT rowid, v FROM r ORDER BY rowid;

-- A real column named rowid hides the built-in rowid under that name,
-- but oid and _rowid_ still reach it.
CREATE TABLE s(rowid TEXT, v);
INSERT INTO s VALUES ('custom', 'first'), ('other', 'second');
SELECT rowid, oid, _rowid_, v FROM s ORDER BY oid;
SELECT * FROM s ORDER BY v;

-- rowid in ORDER BY, DISTINCT, and SELECT with alias.
SELECT rowid AS r, v FROM r ORDER BY r DESC LIMIT 2;
