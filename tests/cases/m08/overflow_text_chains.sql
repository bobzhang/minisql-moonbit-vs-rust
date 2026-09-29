-- @db file
-- Text values from 0 bytes up to about 12 overflow pages (page_size=1024),
-- in steps that hit many different overflow remainders. Afterwards SQLite
-- rewrites some values (shorter, longer, NULL), which frees and reallocates
-- overflow pages. Every value is compared with its expected contents.
-- @phase sqlite
PRAGMA page_size = 1024;
CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER, off INTEGER, v TEXT);
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 130)
INSERT INTO t SELECT i + 1, i * 97, 1 + (i * 13) % 50, NULL FROM c;
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 3000),
m(s) AS (SELECT group_concat(printf('%05d', i), '' ORDER BY i) FROM c)
UPDATE t SET v = substr((SELECT s FROM m), off, n);
-- Resize some values after the fact.
UPDATE t SET n = n / 3 WHERE id % 5 = 0;
UPDATE t SET n = n + 5000 WHERE id % 7 = 0 AND n < 5000;
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 3000),
m(s) AS (SELECT group_concat(printf('%05d', i), '' ORDER BY i) FROM c)
UPDATE t SET v = substr((SELECT s FROM m), off, n) WHERE id % 5 = 0 OR id % 7 = 0;
UPDATE t SET v = NULL, n = NULL WHERE id % 11 = 0;
-- @phase engine
SELECT count(*), count(v), sum(length(v)), max(length(v)) FROM t;
SELECT sum(length(v) = n), sum(n IS NULL) FROM t;
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 3000),
m(s) AS (SELECT group_concat(printf('%05d', i), '' ORDER BY i) FROM c)
SELECT count(*), sum(t.v = substr(m.s, t.off, t.n)) FROM t, m WHERE t.v IS NOT NULL;
-- Pieces taken from the start, the middle and the end of long values.
SELECT id, length(v), substr(v, 1, 12), substr(v, 1000, 12), substr(v, -12) FROM t WHERE id IN (10, 11, 50, 70, 100, 131) ORDER BY id;
SELECT id, instr(v, '00500'), instr(v, '02000') FROM t WHERE id IN (60, 90, 120) ORDER BY id;
SELECT id FROM t WHERE v LIKE '%02000%' ORDER BY id LIMIT 5;
SELECT id FROM t WHERE length(v) BETWEEN 1000 AND 1100 ORDER BY id;
SELECT id, length(v) FROM t ORDER BY v DESC, id LIMIT 3;
SELECT min(length(v)), count(*) FILTER (WHERE v = '') FROM t;
