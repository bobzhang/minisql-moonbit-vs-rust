-- @db file
-- A database created by SQLite containing only an empty table (its root
-- page is an empty leaf), plus an empty indexed table. Queries return no
-- rows; aggregates over no rows still return one row.
-- @phase sqlite
CREATE TABLE t(a INTEGER, b TEXT);
-- @phase engine
SELECT * FROM t;
SELECT count(*), sum(a), total(a), max(b) FROM t;
SELECT a FROM t WHERE a = 1;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT * FROM missing_table;
SELECT (SELECT count(*) FROM t) + 1;
-- @phase sqlite
CREATE TABLE u(id INTEGER PRIMARY KEY, v TEXT UNIQUE);
CREATE INDEX t_a ON t(a);
-- @phase engine
SELECT * FROM u;
SELECT count(*) FROM u WHERE v = 'x';
SELECT a, b FROM t WHERE a > 0 ORDER BY a;
SELECT group_concat(v) FROM u;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT t.a, u.v FROM t LEFT JOIN u ON t.a = u.id;
