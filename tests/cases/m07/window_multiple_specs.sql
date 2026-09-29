-- Many window functions with different window definitions in one SELECT:
-- each is computed independently of the others and of the final ORDER BY.
CREATE TABLE ms(id INTEGER PRIMARY KEY, g TEXT, x INTEGER, y INTEGER);
INSERT INTO ms VALUES (1, 'a', 5, 50), (2, 'b', 3, 40), (3, 'a', 9, 10), (4, 'b', 1, 30), (5, 'a', 7, 20), (6, 'c', 2, 60);

-- Different ORDER BYs in one query.
SELECT id, row_number() OVER (ORDER BY x), row_number() OVER (ORDER BY y), row_number() OVER (ORDER BY id DESC) FROM ms ORDER BY id;

-- Different partitions and orders.
SELECT id, sum(x) OVER (PARTITION BY g), sum(y) OVER (ORDER BY x), rank() OVER (PARTITION BY g ORDER BY y DESC) FROM ms ORDER BY id;

-- Different frame types over the same ordering.
SELECT id, sum(y) OVER (ORDER BY x ROWS 1 PRECEDING), sum(y) OVER (ORDER BY x RANGE 2 PRECEDING), sum(y) OVER (ORDER BY x GROUPS 1 PRECEDING)
FROM ms ORDER BY id;

-- Ranking, value and aggregate functions side by side.
SELECT id, dense_rank() OVER (ORDER BY g), lag(x) OVER (ORDER BY y), max(y) OVER (PARTITION BY g ORDER BY x), ntile(3) OVER (ORDER BY y DESC)
FROM ms ORDER BY id;

-- The same function with the same window twice.
SELECT id, sum(x) OVER (ORDER BY id), sum(x) OVER (ORDER BY id) FROM ms ORDER BY id;

-- The final ORDER BY is independent of all window orders.
SELECT g, x, y, row_number() OVER (ORDER BY y) FROM ms ORDER BY g DESC, x;

-- Window functions over the output of another window function (via subquery).
SELECT id, rn, sum(rn) OVER (ORDER BY id) FROM (SELECT id, row_number() OVER (ORDER BY x DESC) AS rn FROM ms) ORDER BY id;

-- Window over a derived table that itself has partitions.
SELECT g, s, rank() OVER (ORDER BY s DESC) FROM (SELECT DISTINCT g, sum(x) OVER (PARTITION BY g) AS s FROM ms) ORDER BY g;

-- Many functions over a named window plus inline variations.
SELECT id, count(*) OVER w, sum(x) OVER w, avg(x) OVER w, min(x) OVER w, max(x) OVER w, sum(x) OVER (w ROWS CURRENT ROW)
FROM ms WINDOW w AS (ORDER BY id) ORDER BY id;

-- Window functions over a VALUES source.
SELECT column1, sum(column2) OVER (ORDER BY column1), rank() OVER (ORDER BY column2) FROM (VALUES (1, 10), (2, 20), (3, 10)) ORDER BY column1;

-- Window with a WHERE that removes rows first.
SELECT id, row_number() OVER (ORDER BY x), sum(y) OVER () FROM ms WHERE g <> 'b' ORDER BY id;
