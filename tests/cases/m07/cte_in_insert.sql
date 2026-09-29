-- WITH ... INSERT: a CTE providing rows (or helper data) for an INSERT.
CREATE TABLE src(id INTEGER PRIMARY KEY, v INTEGER, tag TEXT);
INSERT INTO src VALUES (1, 10, 'a'), (2, 20, 'b'), (3, 30, 'a'), (4, NULL, 'c');
CREATE TABLE dst(id INTEGER PRIMARY KEY, total INTEGER, tag TEXT);

-- The CTE feeds INSERT ... SELECT.
WITH agg AS (SELECT tag, sum(v) AS s FROM src GROUP BY tag)
INSERT INTO dst(total, tag) SELECT s, tag FROM agg ORDER BY tag;
SELECT id, total, tag FROM dst ORDER BY id;

-- A recursive CTE generating rows to insert.
CREATE TABLE nums(n INTEGER PRIMARY KEY, sq INTEGER);
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 8)
INSERT INTO nums SELECT x, x * x FROM c;
SELECT count(*), sum(sq), max(n) FROM nums;

-- The CTE is used only in a WHERE subquery of the INSERT's SELECT.
WITH wanted(t) AS (VALUES ('a'))
INSERT INTO dst(total, tag) SELECT v, 'copy-' || tag FROM src WHERE tag IN (SELECT t FROM wanted) ORDER BY id;
SELECT id, total, tag FROM dst ORDER BY id;

-- WITH ... INSERT with RETURNING (a single row, since RETURNING order is unspecified).
WITH c(x) AS (VALUES (100), (200))
INSERT INTO dst(total, tag) SELECT sum(x), 'ret' FROM c RETURNING total, tag;

-- INSERT OR IGNORE with a CTE providing conflicting keys.
WITH c(k, t) AS (VALUES (1, 'dup'), (50, 'new'))
INSERT OR IGNORE INTO dst(id, tag) SELECT k, t FROM c;
SELECT id, total, tag FROM dst WHERE id IN (1, 50) ORDER BY id;

-- Upsert fed by a CTE (the WHERE true avoids the parsing ambiguity of ON).
WITH c(k, t) AS (VALUES (1, 'upd'), (51, 'ins'))
INSERT INTO dst(id, tag) SELECT k, t FROM c WHERE true ON CONFLICT(id) DO UPDATE SET tag = excluded.tag;
SELECT id, tag FROM dst WHERE id IN (1, 51) ORDER BY id;

-- The CTE may read the target table itself: rows are computed before insert.
WITH m AS (SELECT max(n) AS mx FROM nums)
INSERT INTO nums SELECT mx + 1, (mx + 1) * (mx + 1) FROM m;
SELECT n, sq FROM nums ORDER BY n DESC LIMIT 2;

-- INSERT from a CTE that returns nothing inserts nothing.
WITH e AS (SELECT * FROM src WHERE v > 1000) INSERT INTO dst(total, tag) SELECT v, tag FROM e;
SELECT count(*) FROM dst;

-- Error: column count mismatch between the CTE's select and the target.
WITH c(x, y) AS (VALUES (1, 2)) INSERT INTO nums(n) SELECT x, y FROM c;
-- Error: constraint violation is still reported (PRIMARY KEY duplicate).
WITH c(x) AS (VALUES (1)) INSERT INTO nums SELECT x, 0 FROM c;
SELECT count(*) FROM nums;
