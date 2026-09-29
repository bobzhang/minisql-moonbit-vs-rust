-- @db file
-- DROP TABLE removes the table, its indexes and autoindexes from the
-- schema and frees all their pages (integrity_check reports pages that are
-- neither in use nor on the freelist). Tables re-created with the same
-- name start empty.
-- @phase engine
CREATE TABLE a(id INTEGER PRIMARY KEY, v TEXT UNIQUE, big TEXT);
CREATE INDEX a_big ON a(big);
CREATE TABLE b(id INTEGER PRIMARY KEY, w INTEGER);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 3000)
INSERT INTO a SELECT i, 'v' || i, CASE WHEN i % 100 = 0 THEN printf('%.*c', 9000, 'x') END FROM c;
INSERT INTO b SELECT id, id * 2 FROM a WHERE id <= 1000;
DROP TABLE a;
CREATE TABLE a(x TEXT, y TEXT);
INSERT INTO a VALUES ('new', 'table');
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT * FROM a;
SELECT count(*), sum(w) FROM b;
-- @phase engine
DROP TABLE b;
DROP TABLE IF EXISTS b;
DROP TABLE b;
CREATE TABLE b(id INTEGER PRIMARY KEY, v TEXT UNIQUE);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 2000)
INSERT INTO b SELECT i, 'again' || i FROM c;
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT count(*), max(v) FROM b;
SELECT id FROM b INDEXED BY sqlite_autoindex_b_1 WHERE v = 'again1500';
DROP TABLE a;
-- @phase engine
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT count(*) FROM b;
SELECT * FROM a;
