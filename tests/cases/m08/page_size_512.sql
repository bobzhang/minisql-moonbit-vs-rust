-- @db file
-- Reading a database with page size 512.
-- Usable size U=512: table leaves keep up to X=477 payload bytes locally,
-- index pages up to 102; the minimum local amount is M=39.
-- Table t has 20000 small rows (multi-level table and index b-trees).
-- Tables big (text) and bigb (blob) hold values whose record sizes land
-- exactly on and around the overflow thresholds (table and index), plus
-- values spanning several overflow pages. Values are substrings of a
-- deterministic digit string so the engine can verify the exact contents.
-- @phase sqlite
PRAGMA page_size = 512;
CREATE TABLE t(id INTEGER PRIMARY KEY, k INTEGER, name TEXT, r REAL);
CREATE INDEX t_k ON t(k);
CREATE INDEX t_name ON t(name);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 20000)
INSERT INTO t SELECT i, (i * 7919) % 1000, 'name' || printf('%06d', i), i * 0.25 FROM c;
CREATE TABLE big(id INTEGER PRIMARY KEY, n INTEGER, off INTEGER, v TEXT);
CREATE INDEX big_v ON big(v);
INSERT INTO big(id, n, off) VALUES
  (1, 0, 2),
  (2, 1, 39),
  (3, 96, 76),
  (4, 97, 13),
  (5, 98, 50),
  (6, 467, 87),
  (7, 468, 24),
  (8, 469, 61),
  (9, 470, 98),
  (10, 503, 35),
  (11, 573, 72),
  (12, 974, 9),
  (13, 976, 46),
  (14, 978, 83),
  (15, 979, 20),
  (16, 1627, 57),
  (17, 2558, 94);
CREATE TABLE bigb(id INTEGER PRIMARY KEY, n INTEGER, off INTEGER, b BLOB);
INSERT INTO bigb SELECT id, n, off, NULL FROM big;
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 1424),
m(s) AS (SELECT group_concat(printf('%05d', i), '' ORDER BY i) FROM c)
UPDATE big SET v = substr((SELECT s FROM m), off, n);
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 1424),
m(s) AS (SELECT group_concat(printf('%05d', i), '' ORDER BY i) FROM c)
UPDATE bigb SET b = unhex(substr((SELECT s FROM m), off, 2 * n));
-- @phase engine
-- Small rows: whole-table aggregates walk every leaf of the table b-tree.
SELECT count(*), sum(k), min(id), max(id), sum(r) FROM t;
SELECT min(name), max(name) FROM t;
SELECT id, k, name, r FROM t WHERE id IN (1, 2, 10000, 19999, 20000) ORDER BY id;
-- Lookups that can use the indexes.
SELECT count(*), min(id), max(id) FROM t WHERE k = 123;
SELECT id, k FROM t WHERE name = 'name006666';
SELECT name FROM t WHERE name > 'name019997' ORDER BY name;
SELECT count(*) FROM t WHERE k BETWEEN 100 AND 199;
SELECT id FROM t ORDER BY name DESC LIMIT 3;
-- Overflow values: lengths, both ends, and exact contents.
SELECT big.id, big.n, length(v), typeof(v), length(b), typeof(b)
FROM big JOIN bigb USING (id) ORDER BY big.id;
SELECT id, substr(v, 1, 10), substr(v, -10) FROM big WHERE n > 0 ORDER BY id;
SELECT id, hex(substr(b, 1, 4)), hex(substr(b, -4)) FROM bigb WHERE n > 0 ORDER BY id;
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 1424),
m(s) AS (SELECT group_concat(printf('%05d', i), '' ORDER BY i) FROM c)
SELECT count(*), sum(big.v = substr(m.s, big.off, big.n)) FROM big, m;
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 1424),
m(s) AS (SELECT group_concat(printf('%05d', i), '' ORDER BY i) FROM c)
SELECT count(*), sum(bigb.b = unhex(substr(m.s, bigb.off, 2 * bigb.n))) FROM bigb, m;
-- Long index keys (they overflow index pages too).
SELECT id FROM big ORDER BY v, id;
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 1424),
m(s) AS (SELECT group_concat(printf('%05d', i), '' ORDER BY i) FROM c)
SELECT big.id FROM big, m WHERE big.v = substr(m.s, 98, 470) ORDER BY big.id;
SELECT count(*) FROM big WHERE v > '0';
