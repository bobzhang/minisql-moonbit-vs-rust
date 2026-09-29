-- lag(x, n) / lead(x, n): look n rows back / ahead; lag(x, n, d) returns d
-- instead of NULL when that row does not exist. An offset of 0 is the
-- current row. The default is only used for missing rows, not for NULL
-- values of x.
CREATE TABLE q(id INTEGER PRIMARY KEY, g INTEGER, v INTEGER);
INSERT INTO q VALUES (1, 1, 10), (2, 1, 20), (3, 1, NULL), (4, 1, 40), (5, 1, 50),
  (6, 2, 60), (7, 2, 70), (8, 2, 80);

-- Offsets 0, 1, 2 and a large offset.
SELECT id, lag(v, 0) OVER w, lag(v, 1) OVER w, lag(v, 2) OVER w, lag(v, 100) OVER w FROM q WINDOW w AS (ORDER BY id) ORDER BY id;
SELECT id, lead(v, 0) OVER w, lead(v, 2) OVER w, lead(v, 7) OVER w, lead(v, 8) OVER w FROM q WINDOW w AS (ORDER BY id) ORDER BY id;

-- Default values for missing rows.
SELECT id, lag(v, 1, -1) OVER (ORDER BY id), lead(v, 1, -1) OVER (ORDER BY id) FROM q ORDER BY id;
-- A NULL value in an existing row is returned as NULL, not replaced by the default.
SELECT id, lag(v, 1, 999) OVER (ORDER BY id) FROM q WHERE g = 1 ORDER BY id;

-- Defaults of other types, and a NULL default.
SELECT id, lag(v, 2, 'none') OVER (ORDER BY id), lead(v, 3, 0.5) OVER (ORDER BY id), lag(v, 1, NULL) OVER (ORDER BY id)
FROM q WHERE g = 2 ORDER BY id;

-- The default can be an expression over the current row.
SELECT id, lag(v, 1, v) OVER (ORDER BY id), lead(v, 1, id * 1000) OVER (ORDER BY id) FROM q ORDER BY id;

-- Per partition: offsets never cross partition boundaries.
SELECT id, g, lag(v, 2, 0) OVER (PARTITION BY g ORDER BY id), lead(v, 2, 0) OVER (PARTITION BY g ORDER BY id) FROM q ORDER BY id;

-- The offset may be a constant expression.
SELECT id, lag(v, 1 + 1) OVER (ORDER BY id), lead(v, 3 - 2) OVER (ORDER BY id) FROM q WHERE g = 2 ORDER BY id;

-- Moving difference over 2 rows with a default of the first value.
SELECT id, v - lag(v, 2, 10) OVER (ORDER BY id) FROM q WHERE v IS NOT NULL ORDER BY id;

-- lag and lead with a mix of offsets in one query; lead(x, n) equals
-- lag(x, n) evaluated on the reversed order.
SELECT id, lead(v, 2) OVER (ORDER BY id) IS lag(v, 2) OVER (ORDER BY id DESC) FROM q ORDER BY id;

-- Summary checks.
SELECT count(x), count(*) FROM (SELECT lag(v, 3) OVER (ORDER BY id) AS x FROM q);
SELECT sum(x) FROM (SELECT lead(v, 1, 0) OVER (PARTITION BY g ORDER BY id) AS x FROM q);
