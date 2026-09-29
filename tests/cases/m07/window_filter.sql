-- FILTER (WHERE ...) on aggregate window functions: only rows passing the
-- filter contribute, but every row still gets a result.
CREATE TABLE fl(id INTEGER PRIMARY KEY, kind TEXT, amt INTEGER);
INSERT INTO fl VALUES (1, 'in', 50), (2, 'out', 20), (3, 'in', 10), (4, 'out', 70), (5, 'in', NULL), (6, 'out', 5);

-- Running totals of incoming and outgoing amounts on every row.
SELECT id, sum(amt) FILTER (WHERE kind = 'in') OVER (ORDER BY id), sum(amt) FILTER (WHERE kind = 'out') OVER (ORDER BY id)
FROM fl ORDER BY id;

-- count(*) with FILTER counts matching rows; count(x) additionally skips NULLs.
SELECT id, count(*) FILTER (WHERE kind = 'in') OVER (ORDER BY id), count(amt) FILTER (WHERE kind = 'in') OVER (ORDER BY id)
FROM fl ORDER BY id;

-- FILTER with a partition and a frame.
SELECT id, kind, max(amt) FILTER (WHERE amt < 60) OVER (PARTITION BY kind ORDER BY id ROWS 1 PRECEDING) FROM fl ORDER BY id;

-- A filter that matches nothing: NULL (sum) / 0 (count) / 0.0 (total).
SELECT id, sum(amt) FILTER (WHERE amt > 1000) OVER (), count(*) FILTER (WHERE amt > 1000) OVER (), total(amt) FILTER (WHERE amt > 1000) OVER ()
FROM fl WHERE id <= 2 ORDER BY id;

-- The filter can reference columns other than the argument.
SELECT id, group_concat(id, ',') FILTER (WHERE kind = 'out') OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
FROM fl WHERE id IN (1, 6) ORDER BY id;

-- avg/min with FILTER on a sliding frame.
SELECT id, avg(amt) FILTER (WHERE id % 2 = 0) OVER (ORDER BY id ROWS BETWEEN 2 PRECEDING AND CURRENT ROW),
  min(amt) FILTER (WHERE kind = 'out') OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM fl ORDER BY id;

-- A NULL filter result is treated as false.
SELECT id, count(*) FILTER (WHERE amt > 15) OVER (ORDER BY id) FROM fl ORDER BY id;

-- FILTER with a named window.
SELECT id, sum(amt) FILTER (WHERE kind = 'in') OVER w, sum(amt) OVER w FROM fl WINDOW w AS (ORDER BY id) ORDER BY id;

-- FILTER combined with EXCLUDE.
SELECT id, sum(amt) FILTER (WHERE kind = 'out') OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE CURRENT ROW)
FROM fl ORDER BY id;

-- string_agg with a filter.
SELECT id, string_agg(kind, '/') FILTER (WHERE amt >= 10) OVER (ORDER BY id) FROM fl ORDER BY id;

-- Errors: FILTER on non-aggregate window functions.
SELECT row_number() FILTER (WHERE kind = 'in') OVER (ORDER BY id) FROM fl;
SELECT lag(amt) FILTER (WHERE amt > 0) OVER (ORDER BY id) FROM fl;
