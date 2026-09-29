-- CASE results keep the type of the chosen branch; CASE itself has no
-- affinity, so its result compares like an expression.

SELECT typeof(CASE WHEN 1 THEN 1 END), typeof(CASE WHEN 1 THEN 1.5 END), typeof(CASE WHEN 1 THEN 'x' END), typeof(CASE WHEN 1 THEN x'00' END), typeof(CASE WHEN 1 THEN NULL END);
SELECT CASE WHEN 1 THEN x'CAFE' END, CASE WHEN 0 THEN 1 ELSE 2.5 END;
-- ELSE NULL and a missing ELSE are the same.
SELECT CASE WHEN 0 THEN 1 ELSE NULL END IS NULL, CASE WHEN 0 THEN 1 END IS NULL;
-- A CASE returning text '1' compared with integer 1: no affinity, not equal.
SELECT CASE WHEN 1 THEN '1' END = 1;
-- Only the chosen branch is evaluated: division by zero in another branch
-- does not matter (it would be NULL anyway), nor would an overflow error.
SELECT CASE WHEN 1 THEN 'ok' ELSE 1 / 0 END;
SELECT CASE 1 WHEN 2 THEN abs(-9223372036854775808) ELSE 'not evaluated' END;
-- ...but an error in the chosen branch is raised.
SELECT CASE WHEN 1 THEN abs(-9223372036854775808) ELSE 0 END;
-- Many branches.
CREATE TABLE d(n INTEGER);
INSERT INTO d VALUES (0), (1), (2), (3), (4), (5), (6), (7);
SELECT n, CASE n % 7 WHEN 0 THEN 'sun' WHEN 1 THEN 'mon' WHEN 2 THEN 'tue' WHEN 3 THEN 'wed'
  WHEN 4 THEN 'thu' WHEN 5 THEN 'fri' ELSE 'sat' END FROM d ORDER BY n;
-- CASE producing mixed types in one column.
SELECT n, CASE WHEN n < 2 THEN n WHEN n < 4 THEN n * 1.5 WHEN n < 6 THEN 'n' || n ELSE NULL END,
  typeof(CASE WHEN n < 2 THEN n WHEN n < 4 THEN n * 1.5 WHEN n < 6 THEN 'n' || n ELSE NULL END) FROM d ORDER BY n;
-- Sorting by a mixed-type CASE uses cross-class order.
SELECT n FROM d ORDER BY CASE WHEN n % 2 = 0 THEN 'even' ELSE n END, n;
-- CASE in arithmetic and concatenation.
SELECT n * CASE WHEN n > 3 THEN -1 ELSE 1 END FROM d ORDER BY n;
