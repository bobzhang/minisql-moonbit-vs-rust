-- @db file
-- A database whose page size is changed by VACUUM after it has been
-- populated (1024 -> 8192), then compacted again by VACUUM after deletes.
-- The engine reads the page size from the header; INTEGER PRIMARY KEY
-- values survive VACUUM.
-- @phase sqlite
PRAGMA page_size = 1024;
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT, big BLOB);
CREATE INDEX t_v ON t(v);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 3000)
INSERT INTO t SELECT i, 'v' || i, CASE WHEN i % 500 = 0 THEN zeroblob(20000) END FROM c;
-- @phase engine
SELECT count(*), count(big), sum(length(big)) FROM t;
-- @phase sqlite
PRAGMA page_size = 8192;
VACUUM;
PRAGMA page_size;
-- @phase engine
SELECT count(*), count(big), sum(length(big)) FROM t;
SELECT id FROM t WHERE v = 'v2999';
-- @phase sqlite
DELETE FROM t WHERE id % 3 = 0;
VACUUM;
-- @phase engine
SELECT count(*), sum(id), count(big) FROM t;
SELECT id, v FROM t WHERE id IN (1, 2, 3, 2999, 3000) ORDER BY id;
SELECT v FROM t ORDER BY v DESC LIMIT 2;
