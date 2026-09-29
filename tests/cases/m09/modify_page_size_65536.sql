-- @db file
-- SQLite creates a database with page size 65536 (usable size 65536; table
-- leaf local limit 65501, index local limit 16422, minimum local 8199) and a
-- little data. The engine must keep writing pages of that size: it adds
-- 30000 rows (multi-level b-trees), a new index, and text/blob values whose
-- record sizes sit exactly on and around the overflow thresholds for this
-- page size (table and index). SQLite verifies with integrity_check.
-- @phase sqlite
PRAGMA page_size = 65536;
CREATE TABLE t(id INTEGER PRIMARY KEY, k INTEGER, name TEXT);
CREATE INDEX t_k ON t(k);
INSERT INTO t VALUES (1, 10, 'from sqlite'), (2, 20, 'also sqlite');
CREATE TABLE big(id INTEGER PRIMARY KEY, n INTEGER, off INTEGER, v TEXT);
CREATE INDEX big_v ON big(v);
CREATE TABLE bigb(id INTEGER PRIMARY KEY, n INTEGER, off INTEGER, b BLOB);
-- @phase engine
WITH RECURSIVE c(i) AS (SELECT 3 UNION ALL SELECT i + 1 FROM c WHERE i < 30000)
INSERT INTO t SELECT i, (i * 7919) % 1000, 'name' || printf('%06d', i) FROM c;
CREATE INDEX t_name ON t(name);
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 79079),
m(s) AS (SELECT group_concat(printf('%05d', i), '' ORDER BY i) FROM c),
lens(id, n, off) AS (VALUES (1, 0, 2), (2, 1, 39), (3, 16415, 76), (4, 16416, 13), (5, 16417, 50), (6, 65489, 87), (7, 65490, 24), (8, 65491, 61), (9, 65525, 98), (10, 77836, 35), (11, 131020, 72), (12, 131022, 9), (13, 131024, 46), (14, 196697, 83))
INSERT INTO big SELECT lens.id, lens.n, lens.off, substr(m.s, lens.off, lens.n) FROM lens, m;
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 79079),
m(s) AS (SELECT group_concat(printf('%05d', i), '' ORDER BY i) FROM c)
INSERT INTO bigb SELECT big.id, big.n, big.off, unhex(substr(m.s, big.off, 2 * big.n)) FROM big, m;
SELECT count(*), sum(length(v)) FROM big;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), sum(k), min(name), max(name) FROM t;
SELECT id, k, name FROM t WHERE id IN (1, 2, 3, 30000) ORDER BY id;
SELECT id FROM t INDEXED BY t_name WHERE name = 'name015000';
SELECT count(*) FROM t INDEXED BY t_k WHERE k = 10;
SELECT id, n, length(v), substr(v, 1, 10), substr(v, -10) FROM big ORDER BY id;
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 79079),
m(s) AS (SELECT group_concat(printf('%05d', i), '' ORDER BY i) FROM c)
SELECT count(*), sum(big.v = substr(m.s, big.off, big.n)) FROM big, m;
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 79079),
m(s) AS (SELECT group_concat(printf('%05d', i), '' ORDER BY i) FROM c)
SELECT count(*), sum(bigb.b = unhex(substr(m.s, bigb.off, 2 * bigb.n))) FROM bigb, m;
SELECT id FROM big INDEXED BY big_v ORDER BY v, id;
-- SQLite changes the engine's overflow chains.
UPDATE big SET v = substr(v, 1, n / 2) WHERE id % 2 = 0;
DELETE FROM bigb WHERE id % 3 = 0;
PRAGMA integrity_check;
-- @phase engine
SELECT id, length(v) FROM big ORDER BY id;
SELECT count(*), sum(length(b)) FROM bigb;
SELECT count(*), sum(k) FROM t;
