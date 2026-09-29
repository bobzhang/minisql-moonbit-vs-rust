-- @db file
-- Large UPDATEs by the engine: changing indexed columns (index entries must
-- move), changing the rowid alias (rows move within the table b-tree),
-- and changing record sizes. SQLite verifies table and index agree.
-- @phase engine
CREATE TABLE t(id INTEGER PRIMARY KEY, k INTEGER, s TEXT, u TEXT UNIQUE);
CREATE INDEX t_k ON t(k);
CREATE INDEX t_s ON t(s);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 10000)
INSERT INTO t SELECT i, i % 100, 's' || i, 'u' || i FROM c;
UPDATE t SET k = k + 1000 WHERE k < 50;
UPDATE t SET s = s || '-' || printf('%.*c', id % 40, 'z') WHERE id % 3 = 0;
UPDATE t SET id = id + 100000 WHERE id % 7 = 0;
UPDATE t SET u = upper(u) WHERE id > 100000;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), sum(id), sum(k), sum(length(s)) FROM t;
SELECT count(*) FROM t INDEXED BY t_k WHERE k >= 1000;
SELECT id, k, s, u FROM t WHERE id IN (3, 7, 100007, 100014, 9999) ORDER BY id;
SELECT id FROM t INDEXED BY t_s WHERE s = 's21-' || printf('%.*c', 21, 'z');
SELECT id FROM t INDEXED BY sqlite_autoindex_t_1 WHERE u = 'U70';
-- @phase engine
UPDATE t SET k = NULL, s = NULL WHERE id > 100000;
UPDATE t SET u = 'x' || u;
SELECT count(*), count(k), count(s) FROM t;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), count(k), count(s), min(u), max(u) FROM t;
SELECT count(*) FROM t INDEXED BY t_k WHERE k IS NULL;
