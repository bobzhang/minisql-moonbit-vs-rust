-- @db file
-- @phase engine
CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT UNIQUE);
INSERT INTO t VALUES (1, 'x'), (2, 'y');
-- @phase sqlite
PRAGMA integrity_check;
SELECT * FROM t ORDER BY a;
INSERT INTO t VALUES (3, 'z');
-- @phase engine
SELECT * FROM t ORDER BY a;
