-- @db file
-- The engine inserts 30000 rows (built with a recursive CTE) into a new
-- file, enough for table and index b-trees with interior pages at any page
-- size up to 64 KiB. SQLite verifies structure and contents, and the engine
-- reads them back in a later process.
-- @phase engine
CREATE TABLE t(id INTEGER PRIMARY KEY, k INTEGER, name TEXT, r REAL);
CREATE INDEX t_k ON t(k);
CREATE INDEX t_name ON t(name);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 30000)
INSERT INTO t SELECT i, (i * 7919) % 30011, 'name-' || printf('%06d', (i * 104729) % 30000), i * 0.5 FROM c;
SELECT count(*), sum(k) FROM t;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), sum(k), sum(r), min(name), max(name) FROM t;
SELECT id, k, name, r FROM t WHERE id IN (1, 15000, 30000) ORDER BY id;
SELECT count(*) FROM t INDEXED BY t_k WHERE k BETWEEN 1000 AND 1999;
SELECT id FROM t INDEXED BY t_name WHERE name = 'name-012345';
SELECT name FROM t INDEXED BY t_name ORDER BY name LIMIT 3;
-- @phase engine
SELECT count(*), sum(k), sum(r) FROM t;
SELECT id, k FROM t WHERE name = 'name-029999';
SELECT count(*) FROM t WHERE k > 30000;
