-- Misuse of window functions: where they may appear, which functions accept
-- OVER, argument counts, and DISTINCT. Valid statements are interleaved.
CREATE TABLE we(id INTEGER PRIMARY KEY, g TEXT, v INTEGER);
INSERT INTO we VALUES (1, 'a', 10), (2, 'a', 20), (3, 'b', 30);

-- Valid baseline.
SELECT id, row_number() OVER (ORDER BY id) FROM we ORDER BY id;

-- Error: a pure window function without OVER.
SELECT row_number() FROM we;
-- Valid: an aggregate without OVER is a normal aggregate.
SELECT sum(v) FROM we;

-- Error: OVER on a scalar (non-aggregate) function.
SELECT upper(g) OVER () FROM we;
-- Valid: every M4 aggregate accepts OVER.
SELECT id, count(*) OVER w, count(v) OVER w, sum(v) OVER w, total(v) OVER w, avg(v) OVER w, min(v) OVER w, max(v) OVER w,
  group_concat(v) OVER w, group_concat(v, '-') OVER w, string_agg(g, '+') OVER w FROM we WINDOW w AS (ORDER BY id) ORDER BY id;
-- Valid: a scalar function applied to a window result.
SELECT id, abs(-sum(v) OVER (ORDER BY id)) FROM we ORDER BY id;

-- Error: window functions in WHERE.
SELECT id FROM we WHERE rank() OVER (ORDER BY v) = 1;
-- Valid: filter through a subquery instead.
SELECT id FROM (SELECT id, rank() OVER (ORDER BY v) AS r FROM we) WHERE r = 1;

-- Error: DISTINCT is not supported in window aggregates.
SELECT count(DISTINCT g) OVER () FROM we;
-- Valid: DISTINCT on the result set of a window query.
SELECT DISTINCT count(*) OVER (PARTITION BY g) FROM we ORDER BY 1;

-- Error: a window function inside a window function's arguments or ORDER BY.
SELECT sum(v) OVER (ORDER BY rank() OVER (ORDER BY v)) FROM we;
-- Valid: nest through a subquery.
SELECT id, sum(rn) OVER (ORDER BY rn) FROM (SELECT id, row_number() OVER (ORDER BY v DESC) AS rn FROM we) ORDER BY id;

-- Valid: window functions in the ORDER BY clause of the query.
SELECT id FROM we ORDER BY row_number() OVER (ORDER BY v DESC);
-- Valid: a window function in a correlated scalar subquery.
SELECT id, (SELECT max(r) FROM (SELECT rank() OVER (ORDER BY v) AS r FROM we w2 WHERE w2.g = we.g)) FROM we ORDER BY id;

-- Error: wrong argument counts for window functions.
SELECT ntile(1, 2) OVER (ORDER BY id) FROM we;
-- Valid: argument counts that are accepted.
SELECT id, lag(v, 1, 0) OVER (ORDER BY id), nth_value(v, 1) OVER (ORDER BY id), group_concat(v, ';') OVER (ORDER BY id) FROM we ORDER BY id;
-- Valid: a window query inside a CTE, filtered by the main query.
WITH r AS (SELECT id, g, rank() OVER (PARTITION BY g ORDER BY v DESC) AS rk FROM we) SELECT id, g FROM r WHERE rk = 1 ORDER BY id;
-- Valid: a window in a view.
CREATE VIEW wv AS SELECT id, sum(v) OVER (ORDER BY id) AS run FROM we;
SELECT id, run FROM wv ORDER BY id;
-- Valid: the result of a window query can feed an aggregate from outside.
SELECT sum(x), max(x) FROM (SELECT sum(v) OVER (ORDER BY id) AS x FROM we);
