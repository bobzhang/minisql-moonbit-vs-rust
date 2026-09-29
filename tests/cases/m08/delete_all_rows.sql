-- @db file
-- A multi-level table and its index emptied by DELETE (with a WHERE so
-- SQLite deletes row by row and the tree collapses), a table truncated by
-- DELETE without WHERE, and a table refilled after being emptied.
-- @phase sqlite
PRAGMA page_size = 512;
CREATE TABLE a(id INTEGER PRIMARY KEY, v TEXT);
CREATE INDEX a_v ON a(v);
CREATE TABLE b(id INTEGER PRIMARY KEY, v TEXT);
CREATE TABLE c(id INTEGER PRIMARY KEY, v TEXT);
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 3000)
INSERT INTO a SELECT i, 'value ' || i FROM n;
INSERT INTO b SELECT * FROM a;
INSERT INTO c SELECT * FROM a;
DELETE FROM a WHERE id > 0;
DELETE FROM b;
DELETE FROM c WHERE v <> '';
INSERT INTO c VALUES (5, 'five'), (3, 'three');
-- @phase engine
SELECT count(*) FROM a;
SELECT * FROM a WHERE v = 'value 10';
SELECT count(*), max(id) FROM b;
SELECT * FROM c ORDER BY id;
SELECT min(v), max(v) FROM a;
SELECT (SELECT count(*) FROM a) + (SELECT count(*) FROM b) + (SELECT count(*) FROM c);
