-- @db file
-- The engine deletes most rows of a multi-level table with indexes, so
-- pages become empty and must be freed (put on the freelist or dropped
-- from the file). integrity_check verifies no page is lost or double
-- counted and that the freelist is consistent. SQLite then inserts rows,
-- reusing free pages.
-- @phase engine
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT, w INTEGER);
CREATE INDEX t_v ON t(v);
CREATE INDEX t_w ON t(w);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 20000)
INSERT INTO t SELECT i, 'value-' || i || '-padding-padding', i % 97 FROM c;
DELETE FROM t WHERE id % 10 <> 0;
DELETE FROM t WHERE id BETWEEN 5000 AND 15000;
SELECT count(*) FROM t;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), sum(id), sum(w) FROM t;
SELECT id FROM t INDEXED BY t_v WHERE v = 'value-4990-padding-padding';
SELECT count(*) FROM t INDEXED BY t_w WHERE w = 0;
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 3000)
INSERT INTO t SELECT 30000 + i, 'sqlite-' || i, i % 5 FROM c;
PRAGMA integrity_check;
-- @phase engine
SELECT count(*), sum(w) FROM t;
DELETE FROM t WHERE w < 3;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), sum(w), min(id), max(id) FROM t;
