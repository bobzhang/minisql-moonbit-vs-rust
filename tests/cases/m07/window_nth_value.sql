-- nth_value(x, N): x from the N-th row (1-based) of the window frame, or
-- NULL if the frame has fewer than N rows. N must be a positive integer.
CREATE TABLE nv(id INTEGER PRIMARY KEY, g TEXT, v INTEGER);
INSERT INTO nv VALUES (1, 'a', 11), (2, 'a', 22), (3, 'a', 33), (4, 'a', 44),
  (5, 'b', 55), (6, 'b', NULL), (7, 'b', 77);

-- Default frame (grows with the current row): NULL until the frame reaches N rows.
SELECT id, nth_value(v, 1) OVER (ORDER BY id), nth_value(v, 2) OVER (ORDER BY id), nth_value(v, 3) OVER (ORDER BY id)
FROM nv ORDER BY id;

-- Per partition.
SELECT id, g, nth_value(v, 2) OVER (PARTITION BY g ORDER BY id) FROM nv ORDER BY id;

-- Whole-partition frame: the same value on every row.
SELECT id, nth_value(v, 3) OVER (PARTITION BY g ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM nv ORDER BY id;

-- N larger than any frame: always NULL.
SELECT id, nth_value(v, 10) OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM nv ORDER BY id;

-- Sliding frame: the 2nd row of a 3-row window centred on the current row.
SELECT id, nth_value(v, 2) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM nv ORDER BY id;

-- The N-th row may hold NULL; the result is NULL even though the row exists.
SELECT id, nth_value(v, 2) OVER (PARTITION BY g ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM nv WHERE g = 'b' ORDER BY id;

-- Descending order: second highest value per group.
SELECT DISTINCT g, nth_value(v, 2) OVER (PARTITION BY g ORDER BY v DESC ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
FROM nv WHERE v IS NOT NULL ORDER BY g;

-- nth_value(x, 1) equals first_value(x).
SELECT id, nth_value(v, 1) OVER w IS first_value(v) OVER w FROM nv WINDOW w AS (ORDER BY id ROWS 2 PRECEDING) ORDER BY id;

-- Frame starting after the current row.
SELECT id, nth_value(id, 2) OVER (ORDER BY id ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) FROM nv ORDER BY id;

-- With peers and a RANGE frame (value equal across peers).
CREATE TABLE pk(id INTEGER PRIMARY KEY, k INTEGER);
INSERT INTO pk VALUES (1, 5), (2, 5), (3, 6), (4, 7), (5, 7);
SELECT id, nth_value(k, 3) OVER (ORDER BY k), nth_value(k, 1) OVER (ORDER BY k GROUPS BETWEEN 1 FOLLOWING AND 1 FOLLOWING) FROM pk ORDER BY id;

-- Errors: N must be a positive integer.
SELECT nth_value(v, 0) OVER (ORDER BY id) FROM nv;
SELECT nth_value(v, -1) OVER (ORDER BY id) FROM nv;
SELECT nth_value(v) OVER (ORDER BY id) FROM nv;
