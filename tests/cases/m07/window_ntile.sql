-- ntile(N): split the ordered partition into N buckets as evenly as
-- possible; when rows do not divide evenly, the first buckets get one
-- extra row. With more buckets than rows, each row is its own bucket.
CREATE TABLE n(id INTEGER PRIMARY KEY, g TEXT);
INSERT INTO n VALUES (1, 'a'), (2, 'a'), (3, 'a'), (4, 'a'), (5, 'a'), (6, 'a'), (7, 'a'),
  (8, 'b'), (9, 'b'), (10, 'b'), (11, 'c');

-- 7 rows into 3 buckets: sizes 3, 2, 2.
SELECT id, ntile(3) OVER (ORDER BY id) FROM n WHERE g = 'a' ORDER BY id;
-- 7 rows into 2 buckets: 4, 3.
SELECT id, ntile(2) OVER (ORDER BY id) FROM n WHERE g = 'a' ORDER BY id;
-- 7 rows into 4 buckets: 2, 2, 2, 1.
SELECT id, ntile(4) OVER (ORDER BY id) FROM n WHERE g = 'a' ORDER BY id;
-- Even split: 6 rows into 3 buckets.
SELECT id, ntile(3) OVER (ORDER BY id) FROM n WHERE id <= 6 ORDER BY id;
-- 11 rows into 4 buckets: 3, 3, 3, 2.
SELECT id, ntile(4) OVER (ORDER BY id) FROM n ORDER BY id;
-- More buckets than rows.
SELECT id, ntile(10) OVER (ORDER BY id) FROM n WHERE g = 'b' ORDER BY id;
-- One bucket.
SELECT id, ntile(1) OVER (ORDER BY id) FROM n WHERE g <> 'a' ORDER BY id;

-- Per partition.
SELECT id, g, ntile(2) OVER (PARTITION BY g ORDER BY id) FROM n ORDER BY id;

-- Descending order.
SELECT id, ntile(3) OVER (ORDER BY id DESC) FROM n WHERE g = 'a' ORDER BY id;

-- Bucket sizes summarized.
SELECT b, count(*) FROM (SELECT ntile(5) OVER (ORDER BY id) AS b FROM n) GROUP BY b ORDER BY b;
SELECT b, count(*) FROM (SELECT ntile(3) OVER (ORDER BY id) AS b FROM n) GROUP BY b ORDER BY b;

-- Argument given as a constant expression.
SELECT id, ntile(1 + 1) OVER (ORDER BY id) FROM n WHERE g = 'b' ORDER BY id;

-- Without ORDER BY, ntile still assigns the bucket sizes (which row gets
-- which bucket is unspecified, so only sizes are checked).
SELECT b, count(*) FROM (SELECT ntile(4) OVER () AS b FROM n WHERE g = 'a') GROUP BY b ORDER BY b;

-- ntile ignores the frame.
SELECT id, ntile(2) OVER (ORDER BY id ROWS CURRENT ROW) FROM n WHERE g = 'b' ORDER BY id;

-- Errors: the argument must be a positive integer.
SELECT ntile(0) OVER (ORDER BY id) FROM n;
SELECT ntile(-2) OVER (ORDER BY id) FROM n;
SELECT ntile() OVER (ORDER BY id) FROM n;
