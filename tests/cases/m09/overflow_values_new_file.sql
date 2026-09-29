-- @db file
-- In a file the engine creates (page size of its choice), text and blob
-- values from 0 bytes to about 100 KB: whatever the page size, many of
-- them need overflow chains, including index keys (the text column is
-- indexed). Contents are checked byte for byte by SQLite.
-- @phase engine
CREATE TABLE big(id INTEGER PRIMARY KEY, n INTEGER, off INTEGER, v TEXT, b BLOB, tail INTEGER);
CREATE INDEX big_v ON big(v);
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 45000),
m(s) AS (SELECT group_concat(printf('%05d', i), '' ORDER BY i) FROM c),
lens(id, n, off) AS (SELECT 1, 0, 1 UNION ALL SELECT id + 1, (id * id * 97) % 100003, 1 + (id * 7) % 50 FROM lens WHERE id < 60)
INSERT INTO big SELECT lens.id, lens.n, lens.off, substr(m.s, lens.off, lens.n), unhex(substr(m.s, lens.off + 1, 2 * (lens.n / 3))), -lens.id FROM lens, m;
SELECT count(*), sum(n), max(n), sum(length(b)) FROM big;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), sum(length(v)), sum(length(b)), sum(tail) FROM big;
WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < 45000),
m(s) AS (SELECT group_concat(printf('%05d', i), '' ORDER BY i) FROM c)
SELECT count(*), sum(big.v = substr(m.s, big.off, big.n)), sum(big.b = unhex(substr(m.s, big.off + 1, 2 * (big.n / 3)))) FROM big, m;
SELECT id, n, tail FROM big INDEXED BY big_v ORDER BY v, id LIMIT 10;
SELECT id, substr(v, -8), hex(substr(b, -3)) FROM big WHERE id IN (2, 30, 59, 60) ORDER BY id;
-- SQLite rewrites some of the engine's large values and adds one.
UPDATE big SET v = v || v WHERE id IN (10, 20);
INSERT INTO big(id, n, off, v) VALUES (61, 150000, 0, printf('%0150000d', 61));
PRAGMA integrity_check;
-- @phase engine
SELECT id, length(v), substr(v, -6) FROM big WHERE id IN (10, 20, 61) ORDER BY id;
SELECT count(*), sum(length(v)) FROM big;
DELETE FROM big WHERE id % 2 = 1;
UPDATE big SET b = NULL WHERE id % 4 = 0;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), sum(length(v)), count(b), sum(length(b)) FROM big;
