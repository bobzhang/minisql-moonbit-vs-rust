-- @db file
-- Deleting every other row and rewriting rows with different lengths
-- leaves freeblocks and fragmented bytes inside b-tree pages, and cell
-- pointers no longer in address order. Cells must be found through the
-- cell pointer array, never by scanning page contents.
-- @phase sqlite
PRAGMA page_size = 4096;
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT, n INTEGER);
CREATE INDEX t_v ON t(v);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 4000)
INSERT INTO t SELECT i, printf('%.*c', 5 + i % 60, 'x') || i, i FROM c;
DELETE FROM t WHERE id % 2 = 0;
UPDATE t SET v = v || '-longer-value-longer-value' WHERE id % 3 = 0;
UPDATE t SET v = substr(v, 1, 3) || id WHERE id % 5 = 0;
DELETE FROM t WHERE id % 7 = 0;
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 2000)
INSERT INTO t SELECT i * 2, 'again' || i, -i FROM c WHERE i % 4 = 0;
-- @phase engine
SELECT count(*), sum(n), sum(length(v)), min(id), max(id) FROM t;
SELECT id, v, n FROM t WHERE id IN (1, 3, 5, 8, 15, 21, 999, 3999, 4000) ORDER BY id;
SELECT count(*) FROM t WHERE v LIKE 'again%';
SELECT count(*) FROM t WHERE v LIKE '%-longer-value-longer-value';
SELECT id FROM t WHERE v = 'xxx15';
SELECT id FROM t WHERE v = 'again1000';
SELECT v FROM t ORDER BY v LIMIT 3;
SELECT v FROM t ORDER BY v DESC LIMIT 3;
SELECT count(*) FROM t WHERE id % 7 = 0 AND n > 0;
