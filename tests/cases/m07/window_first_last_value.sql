-- first_value(x) / last_value(x): x from the first / last row of the
-- window frame. The default frame with ORDER BY ends at the current row's
-- last peer, so last_value usually needs an explicit frame to see the
-- whole partition.
CREATE TABLE f(id INTEGER PRIMARY KEY, dept TEXT, name TEXT, sal INTEGER);
INSERT INTO f VALUES (1, 'eng', 'ann', 100), (2, 'eng', 'bob', 120), (3, 'eng', 'cat', 90),
  (4, 'ops', 'dan', 80), (5, 'ops', 'eve', 85), (6, 'hr', 'fay', 70), (7, 'eng', 'gil', NULL);

-- first_value with the default frame: the lowest salary so far per dept.
SELECT id, dept, first_value(name) OVER (PARTITION BY dept ORDER BY sal, id) FROM f ORDER BY id;

-- last_value with the default frame is the current row (keys are unique).
SELECT id, last_value(name) OVER (PARTITION BY dept ORDER BY sal, id) FROM f ORDER BY id;

-- last_value over the whole partition needs an explicit frame.
SELECT id, last_value(name) OVER (PARTITION BY dept ORDER BY sal, id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
FROM f ORDER BY id;

-- Highest and lowest paid per dept on every row.
SELECT name, first_value(name) OVER w, last_value(name) OVER w FROM f
WINDOW w AS (PARTITION BY dept ORDER BY sal DESC, id RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) ORDER BY name;

-- Sliding frames.
SELECT id, first_value(id) OVER (ORDER BY id ROWS 2 PRECEDING), last_value(id) OVER (ORDER BY id ROWS BETWEEN CURRENT ROW AND 2 FOLLOWING)
FROM f ORDER BY id;

-- first_value can return NULL when the first row's value is NULL.
SELECT id, first_value(sal) OVER (PARTITION BY dept ORDER BY sal NULLS FIRST, id) FROM f WHERE dept = 'eng' ORDER BY id;
SELECT id, last_value(sal) OVER (ORDER BY id) FROM f WHERE dept = 'eng' ORDER BY id;

-- Without ORDER BY, the frame is the whole partition; with a single-row
-- partition both functions give that row's value.
SELECT dept, first_value(sal) OVER (PARTITION BY dept), last_value(sal) OVER (PARTITION BY dept) FROM f WHERE dept = 'hr';

-- Aggregating the value with a unique ORDER BY; each row sees the global max.
SELECT id, sal - first_value(sal) OVER (ORDER BY sal DESC NULLS LAST, id) FROM f ORDER BY id;

-- With peers in the ORDER BY and a RANGE frame, last_value returns the
-- value from the last peer; use a value that is equal across the peers.
CREATE TABLE pe(id INTEGER PRIMARY KEY, k INTEGER);
INSERT INTO pe VALUES (1, 1), (2, 1), (3, 2), (4, 2), (5, 2), (6, 3);
SELECT id, last_value(k) OVER (ORDER BY k), first_value(k) OVER (ORDER BY k RANGE BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) FROM pe ORDER BY id;
SELECT id, first_value(k * 10) OVER (ORDER BY k GROUPS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) FROM pe ORDER BY id;

-- Types are preserved.
SELECT DISTINCT typeof(first_value(name) OVER (ORDER BY id)), typeof(last_value(sal * 1.0) OVER (ORDER BY id ROWS CURRENT ROW)) FROM f WHERE sal IS NOT NULL;

-- Errors: wrong number of arguments.
SELECT first_value() OVER (ORDER BY id) FROM f;
SELECT last_value(id, 2) OVER (ORDER BY id) FROM f;
