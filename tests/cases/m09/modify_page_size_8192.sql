-- @db file
-- SQLite creates a database with page size 8192 (usable size 8192; table
-- leaf local limit 8157, index local limit 2030, minimum local 1003) and a
-- little data. The engine must keep writing pages of that size: it adds
-- 20000 rows (multi-level b-trees), a new index, and text/blob values whose
-- record sizes sit exactly on and around the overflow thresholds for this
-- page size (table and index). SQLite verifies with integrity_check.
-- @phase sqlite
PRAGMA page_size = 8192;
CREATE TABLE t(id INTEGER PRIMARY KEY, k INTEGER, name TEXT);
CREATE INDEX t_k ON t(k);
INSERT INTO t VALUES (1, 10, 'from sqlite'), (2, 20, 'also sqlite');
CREATE TABLE big(id INTEGER PRIMARY KEY, n INTEGER, off INTEGER, v TEXT);
CREATE INDEX big_v ON big(v);
CREATE TABLE bigb(id INTEGER PRIMARY KEY, n INTEGER, off INTEGER, b BLOB);
-- @phase engine
WITH RECURSIVE c(i) AS (SELECT 3 UNION ALL SELECT i + 1 FROM c WHERE i < 20000)
INSERT INTO t SELECT i, (i * 7919) % 1000, 'name' || printf('%06d', i) FROM c;
CREATE INDEX t_name ON t(name);
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 10267),
m(s) AS (SELECT group_concat(printf('%05d', i), '' ORDER BY i) FROM c),
lens(id, n, off) AS (VALUES (1, 0, 2), (2, 1, 39), (3, 2024, 76), (4, 2025, 13), (5, 2026, 50), (6, 8147, 87), (7, 8148, 24), (8, 8149, 61), (9, 8183, 98), (10, 9698, 35), (11, 16333, 72), (12, 16335, 9), (13, 16337, 46), (14, 24666, 83))
INSERT INTO big SELECT lens.id, lens.n, lens.off, substr(m.s, lens.off, lens.n) FROM lens, m;
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 10267),
m(s) AS (SELECT group_concat(printf('%05d', i), '' ORDER BY i) FROM c)
INSERT INTO bigb SELECT big.id, big.n, big.off, unhex(substr(m.s, big.off, 2 * big.n)) FROM big, m;
SELECT count(*), sum(length(v)) FROM big;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), sum(k), min(name), max(name) FROM t;
SELECT id, k, name FROM t WHERE id IN (1, 2, 3, 20000) ORDER BY id;
SELECT id FROM t INDEXED BY t_name WHERE name = 'name010000';
SELECT count(*) FROM t INDEXED BY t_k WHERE k = 10;
SELECT id, n, length(v), substr(v, 1, 10), substr(v, -10) FROM big ORDER BY id;
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 10267),
m(s) AS (SELECT group_concat(printf('%05d', i), '' ORDER BY i) FROM c)
SELECT count(*), sum(big.v = substr(m.s, big.off, big.n)) FROM big, m;
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 10267),
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
