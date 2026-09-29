-- Simple CASE: CASE base WHEN v1 THEN r1 ... [ELSE r] END compares base = vN
-- using ordinary '=' semantics, so NULL never matches (not even NULL).

SELECT CASE 1 WHEN 1 THEN 'one' WHEN 2 THEN 'two' ELSE 'other' END;
SELECT CASE 2 WHEN 1 THEN 'one' WHEN 2 THEN 'two' ELSE 'other' END;
SELECT CASE 3 WHEN 1 THEN 'one' WHEN 2 THEN 'two' ELSE 'other' END;
SELECT CASE 3 WHEN 1 THEN 'one' END;
-- The first matching WHEN wins.
SELECT CASE 1 WHEN 1 THEN 'first' WHEN 1 THEN 'second' END;
-- NULL base or NULL WHEN value never matches.
SELECT CASE NULL WHEN NULL THEN 'match' ELSE 'no match' END;
SELECT CASE 1 WHEN NULL THEN 'match' ELSE 'no match' END;
-- Integer and real compare numerically.
SELECT CASE 1 WHEN 1.0 THEN 'eq' ELSE 'ne' END;
-- Without affinity, text and numbers never compare equal.
SELECT CASE 1 WHEN '1' THEN 'eq' ELSE 'ne' END;
SELECT CASE '1' WHEN 1 THEN 'eq' ELSE 'ne' END;
-- Text comparison is case-sensitive (BINARY).
SELECT CASE 'a' WHEN 'A' THEN 'eq' ELSE 'ne' END;
-- The base expression can be any expression and is evaluated once.
SELECT CASE 2 + 3 WHEN 5 THEN 'five' ELSE 'not five' END;
SELECT CASE 'a' || 'b' WHEN 'ab' THEN 1 ELSE 0 END;
-- WHEN values may be expressions too.
SELECT CASE 6 WHEN 2 * 3 THEN 'six' ELSE '?' END;
-- CASE over table rows.
CREATE TABLE t(id INTEGER, code TEXT, n INTEGER);
INSERT INTO t VALUES (1, 'r', 1), (2, 'g', 2), (3, 'b', 3), (4, 'x', NULL), (5, NULL, 5);
SELECT id, CASE code WHEN 'r' THEN 'red' WHEN 'g' THEN 'green' WHEN 'b' THEN 'blue' ELSE 'unknown' END FROM t ORDER BY id;
SELECT id, CASE n WHEN 1 THEN 'one' WHEN 2 THEN 'two' END FROM t ORDER BY id;
-- Column affinity applies to the comparison: INTEGER column n vs '2'.
SELECT id FROM t WHERE CASE n WHEN '2' THEN 1 ELSE 0 END;
SELECT id FROM t WHERE CASE '3' WHEN n THEN 1 ELSE 0 END;
-- CASE used as a sort key.
SELECT id FROM t ORDER BY CASE code WHEN 'b' THEN 1 WHEN 'g' THEN 2 ELSE 3 END, id;
