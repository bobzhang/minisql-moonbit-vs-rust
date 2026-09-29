-- Numeric sequences carried in several columns of a recursive CTE:
-- Fibonacci, factorial (with overflow to REAL), powers, GCD, digit sums.
-- Fibonacci numbers: row n carries F(n-1), F(n).
WITH RECURSIVE f(n, a, b) AS (SELECT 1, 0, 1 UNION ALL SELECT n + 1, b, a + b FROM f WHERE n < 15)
SELECT n, b FROM f ORDER BY n;

-- The largest Fibonacci number that fits in a 64-bit integer (F(92)).
WITH RECURSIVE f(n, a, b) AS (SELECT 1, 0, 1 UNION ALL SELECT n + 1, b, a + b FROM f WHERE n < 92)
SELECT n, b, typeof(b) FROM f WHERE n = 92;

-- Factorials: 20! fits in an integer, 21! overflows to REAL.
WITH RECURSIVE f(n, v) AS (SELECT 1, 1 UNION ALL SELECT n + 1, v * (n + 1) FROM f WHERE n < 22)
SELECT n, v, typeof(v) FROM f WHERE n >= 19 ORDER BY n;

-- Powers of two via left shift, printed in hex with printf.
WITH RECURSIVE p(k, v) AS (SELECT 0, 1 UNION ALL SELECT k + 1, v << 1 FROM p WHERE k < 8)
SELECT k, v, printf('%x', v) FROM p ORDER BY k;

-- Euclid's algorithm: iterate (a, b) -> (b, a % b) until b = 0.
WITH RECURSIVE g(a, b) AS (SELECT 1071, 462 UNION ALL SELECT b, a % b FROM g WHERE b <> 0)
SELECT a FROM g WHERE b = 0;
WITH RECURSIVE g(step, a, b) AS (SELECT 0, 1071, 462 UNION ALL SELECT step + 1, b, a % b FROM g WHERE b <> 0)
SELECT step, a, b FROM g ORDER BY step;

-- Digit sum of a number by repeated division.
WITH RECURSIVE d(rest, total) AS (SELECT 987654321, 0 UNION ALL SELECT rest / 10, total + rest % 10 FROM d WHERE rest > 0)
SELECT total FROM d WHERE rest = 0;

-- Triangular numbers and a running product in one CTE.
WITH RECURSIVE t(n, tri, prod) AS (SELECT 1, 1, 1 UNION ALL SELECT n + 1, tri + n + 1, prod * 2 FROM t WHERE n < 10)
SELECT n, tri, prod FROM t ORDER BY n;

-- Newton's iteration for sqrt(2) with REAL values; final value printed.
WITH RECURSIVE s(i, x) AS (SELECT 0, 1.0 UNION ALL SELECT i + 1, (x + 2.0 / x) / 2 FROM s WHERE i < 6)
SELECT i, x FROM s ORDER BY i;

-- Integer division that walks down to zero, including negative numbers.
WITH RECURSIVE h(v) AS (SELECT -100 UNION ALL SELECT v / 3 FROM h WHERE v <> 0)
SELECT group_concat(v, ' ' ORDER BY v) FROM h;

-- A sequence built from a table of starting points (anchor from a table).
CREATE TABLE seeds(s INTEGER PRIMARY KEY);
INSERT INTO seeds VALUES (3), (5), (8);
WITH RECURSIVE c(seed, k, v) AS (SELECT s, 0, s FROM seeds UNION ALL SELECT seed, k + 1, v * seed FROM c WHERE k < 3)
SELECT seed, group_concat(v, ',' ORDER BY k) FROM c GROUP BY seed ORDER BY seed;

-- Sum of 1..1000 computed by recursion equals n(n+1)/2.
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 1000)
SELECT sum(n), 1000 * 1001 / 2, sum(n) = 1000 * 1001 / 2 FROM c;
