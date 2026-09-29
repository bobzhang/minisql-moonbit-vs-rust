-- Interaction of window functions with SELECT DISTINCT, LIMIT/OFFSET and
-- compound queries: windows are computed before DISTINCT and LIMIT.
CREATE TABLE dl(id INTEGER PRIMARY KEY, g TEXT, v INTEGER);
INSERT INTO dl VALUES (1, 'a', 1), (2, 'a', 2), (3, 'b', 3), (4, 'b', 4), (5, 'b', 5), (6, 'c', 6);

-- DISTINCT after the window: one row per partition total.
SELECT DISTINCT g, sum(v) OVER (PARTITION BY g) FROM dl ORDER BY g;
-- DISTINCT does not reduce the rows the window sees.
SELECT DISTINCT count(*) OVER () FROM dl;
SELECT DISTINCT g, count(*) OVER (PARTITION BY g), count(*) OVER () FROM dl ORDER BY g;

-- LIMIT after the window: numbering is over all rows, not the limited ones.
SELECT id, row_number() OVER (ORDER BY v DESC), sum(v) OVER () FROM dl ORDER BY id LIMIT 3;
SELECT id, rank() OVER (ORDER BY id) FROM dl ORDER BY id LIMIT 2 OFFSET 3;
SELECT id, lag(v) OVER (ORDER BY id), lead(v) OVER (ORDER BY id) FROM dl ORDER BY id LIMIT 2, 2;

-- LIMIT inside a subquery happens before an outer window.
SELECT id, sum(v) OVER (ORDER BY id) FROM (SELECT id, v FROM dl ORDER BY id LIMIT 3) ORDER BY id;

-- Window functions in compound queries: each arm has its own windows.
SELECT id, row_number() OVER (ORDER BY id) FROM dl WHERE g = 'a'
UNION ALL
SELECT id, row_number() OVER (ORDER BY id DESC) FROM dl WHERE g = 'b'
ORDER BY 1;
-- UNION dedup on window results.
SELECT count(*) OVER () FROM dl WHERE g = 'a' UNION SELECT count(*) OVER () FROM dl WHERE g = 'c' ORDER BY 1;
-- A window over a compound (via subquery).
SELECT x, sum(x) OVER (ORDER BY x) FROM (SELECT v AS x FROM dl WHERE g = 'a' UNION ALL SELECT v * 10 FROM dl WHERE g = 'c') ORDER BY x;

-- DISTINCT with ORDER BY on a window value.
SELECT DISTINCT g, max(v) OVER (PARTITION BY g) AS m FROM dl ORDER BY m DESC;

-- LIMIT 0 returns nothing, even with windows.
SELECT id, row_number() OVER () FROM dl LIMIT 0;
-- Scalar subquery with a window and LIMIT 1.
SELECT (SELECT g FROM dl ORDER BY sum(v) OVER (PARTITION BY g) DESC, id LIMIT 1);
