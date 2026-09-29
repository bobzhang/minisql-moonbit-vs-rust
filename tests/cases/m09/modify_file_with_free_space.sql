-- @db file
-- SQLite leaves a file with a long freelist (many trunk/leaf entries from
-- dropped tables and mass deletes) and b-tree pages full of freeblocks and
-- fragmented bytes. The engine then inserts, updates and deletes in it.
-- Whether it reuses free space or rewrites the file, integrity_check must
-- pass (it checks freelist length, freeblock chains and fragment counts).
-- @phase sqlite
PRAGMA page_size = 1024;
PRAGMA auto_vacuum = NONE;
CREATE TABLE junk(id INTEGER PRIMARY KEY, pad TEXT);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 6000)
INSERT INTO junk SELECT i, printf('%.*c', 200, 'j') FROM c;
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT, n INTEGER);
CREATE INDEX t_v ON t(v);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 5000)
INSERT INTO t SELECT i, printf('%.*c', 5 + i % 40, 'v') || i, i FROM c;
DROP TABLE junk;
DELETE FROM t WHERE id % 3 = 0;
UPDATE t SET v = substr(v, 1, 4) || id WHERE id % 5 = 0;
-- @phase engine
SELECT count(*), sum(n) FROM t;
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 3000)
INSERT INTO t SELECT 10000 + i, 'engine' || i, -i FROM c;
UPDATE t SET v = v || '-grown-by-the-engine' WHERE id % 7 = 0;
DELETE FROM t WHERE id % 11 = 0;
CREATE TABLE fresh(id INTEGER PRIMARY KEY, blob BLOB);
INSERT INTO fresh VALUES (1, zeroblob(50000)), (2, x'01');
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), sum(n), sum(length(v)) FROM t;
SELECT id FROM t INDEXED BY t_v WHERE v = 'engine2998';
SELECT count(*) FROM t INDEXED BY t_v WHERE v LIKE '%-grown-by-the-engine';
SELECT id, length(blob) FROM fresh ORDER BY id;
