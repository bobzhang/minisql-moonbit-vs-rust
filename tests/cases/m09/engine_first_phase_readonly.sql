-- @db file
-- The first engine process runs only queries against a file that does not
-- exist yet: it sees an empty database. A later engine process creates
-- the schema in that same file, and SQLite verifies it.
-- @phase engine
SELECT count(*) FROM sqlite_schema;
SELECT 1 + 1;
SELECT * FROM nothing_here;
-- @phase engine
SELECT count(*) FROM sqlite_schema;
CREATE TABLE t(a INTEGER, b TEXT);
INSERT INTO t VALUES (1, 'x'), (2, 'y');
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name FROM sqlite_schema;
SELECT * FROM t ORDER BY a;
