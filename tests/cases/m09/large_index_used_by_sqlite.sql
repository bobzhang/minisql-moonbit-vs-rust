-- @db file
-- The engine builds a 40000-row table and several indexes (one created
-- before the data is loaded, one after). SQLite then answers range queries
-- through each index with INDEXED BY, so every index b-tree must be
-- complete and correctly ordered, including an index on a REAL column and
-- one mixing integers and reals.
-- @phase engine
CREATE TABLE m(id INTEGER PRIMARY KEY, a INTEGER, r REAL, s TEXT, mix);
CREATE INDEX m_a ON m(a);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 40000)
INSERT INTO m SELECT i, (i * 7919) % 40009, ((i * 104729) % 40000) / 8.0, printf('%05d', (i * 31) % 40000),
  CASE WHEN i % 2 THEN i ELSE i + 0.5 END FROM c;
CREATE INDEX m_r ON m(r);
CREATE INDEX m_s_a ON m(s, a);
CREATE INDEX m_mix ON m(mix);
SELECT count(*) FROM m;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), min(id), max(id) FROM m INDEXED BY m_a WHERE a BETWEEN 10000 AND 19999;
SELECT count(*), sum(id) FROM m INDEXED BY m_r WHERE r BETWEEN 100.0 AND 200.0;
SELECT count(*) FROM m INDEXED BY m_s_a WHERE s BETWEEN '01000' AND '01999';
SELECT id, a FROM m INDEXED BY m_s_a WHERE s = '12345';
SELECT count(*), sum(mix) FROM m INDEXED BY m_mix WHERE mix > 100 AND mix <= 200;
SELECT id FROM m INDEXED BY m_mix WHERE mix = 39998.5;
SELECT r FROM m INDEXED BY m_r ORDER BY r DESC LIMIT 3;
-- @phase engine
SELECT count(*) FROM m WHERE a BETWEEN 10000 AND 19999;
SELECT count(*), sum(id) FROM m WHERE r BETWEEN 100.0 AND 200.0;
SELECT id, a FROM m WHERE s = '12345';
