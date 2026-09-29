-- @db file
-- REPLACE, INSERT OR REPLACE and upserts change several indexes at once:
-- a replaced row's old index entries must be removed from every index.
-- integrity_check verifies each index matches the table exactly.
-- @phase engine
CREATE TABLE kv(id INTEGER PRIMARY KEY, k TEXT UNIQUE, v INTEGER, tag TEXT);
CREATE INDEX kv_v ON kv(v);
CREATE INDEX kv_tag ON kv(tag, v);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 2000)
INSERT INTO kv SELECT i, 'k' || i, i, 't' || (i % 10) FROM c;
REPLACE INTO kv VALUES (5000, 'k1', -1, 'replaced');
INSERT OR REPLACE INTO kv VALUES (2, 'k3', -3, 'replaced two');
INSERT INTO kv(k, v, tag) VALUES ('k10', 0, 'x') ON CONFLICT(k) DO UPDATE SET v = excluded.v + 1000, tag = 'upserted';
INSERT INTO kv(k, v, tag) VALUES ('fresh', 7, 'x') ON CONFLICT(k) DO NOTHING;
INSERT INTO kv(k, v, tag) VALUES ('k11', 7, 'x') ON CONFLICT(k) DO NOTHING;
WITH RECURSIVE c(i) AS (SELECT 100 UNION ALL SELECT i + 1 FROM c WHERE i < 600)
INSERT INTO kv(k, v, tag) SELECT 'k' || i, -i, 'bulk' FROM c WHERE true
  ON CONFLICT(k) DO UPDATE SET v = excluded.v, tag = excluded.tag WHERE kv.v % 2 = 0;
UPDATE OR REPLACE kv SET k = 'k20' WHERE id = 21;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), sum(v), count(DISTINCT tag) FROM kv;
SELECT id, k, v, tag FROM kv WHERE k IN ('k1', 'k2', 'k3', 'k10', 'k11', 'fresh', 'k20', 'k21', 'k100', 'k101') ORDER BY id;
SELECT count(*) FROM kv INDEXED BY kv_tag WHERE tag = 'bulk';
SELECT count(*) FROM kv INDEXED BY kv_v WHERE v < 0;
