-- Searched CASE: CASE WHEN cond THEN val ... [ELSE val] END. The first WHEN
-- whose condition is true wins; without ELSE, no match gives NULL.

SELECT CASE WHEN 1 THEN 'a' ELSE 'b' END;
SELECT CASE WHEN 0 THEN 'a' ELSE 'b' END;
SELECT CASE WHEN 0 THEN 'a' END;
SELECT CASE WHEN 0 THEN 'a' WHEN 1 THEN 'b' WHEN 1 THEN 'c' END;
-- A NULL condition is not true.
SELECT CASE WHEN NULL THEN 'yes' ELSE 'no' END;
SELECT CASE WHEN NULL = NULL THEN 'yes' ELSE 'no' END;
-- Conditions use truthiness: non-zero numbers are true, text is converted.
SELECT CASE WHEN 0.5 THEN 't' ELSE 'f' END, CASE WHEN 'abc' THEN 't' ELSE 'f' END, CASE WHEN '1x' THEN 't' ELSE 'f' END;
-- Result values may have different types in different branches.
SELECT CASE WHEN 1 THEN 1 ELSE 'x' END, typeof(CASE WHEN 0 THEN 1 ELSE 'x' END);
SELECT typeof(CASE WHEN 0 THEN 1 END);
-- Branches that are not taken are not evaluated for errors like overflow.
SELECT CASE WHEN 1 THEN 'safe' ELSE abs(-9223372036854775808) END;
-- Nested CASE.
SELECT CASE WHEN 1 THEN CASE WHEN 0 THEN 'x' ELSE 'y' END ELSE 'z' END;
-- CASE in an expression.
SELECT 10 + CASE WHEN 1 > 2 THEN 1 ELSE 2 END * 3;
SELECT (CASE WHEN 1 THEN 'a' END) || (CASE WHEN 0 THEN 'b' ELSE 'c' END);
-- CASE over table rows.
CREATE TABLE s(name TEXT, score INTEGER);
INSERT INTO s VALUES ('ann', 95), ('bob', 82), ('cy', 67), ('di', NULL), ('ed', 40), ('flo', 90);
SELECT name, CASE WHEN score >= 90 THEN 'A' WHEN score >= 80 THEN 'B' WHEN score >= 60 THEN 'C' ELSE 'F' END FROM s ORDER BY name;
SELECT name, CASE WHEN score IS NULL THEN 'absent' WHEN score >= 50 THEN 'pass' END FROM s ORDER BY name;
-- CASE in WHERE and ORDER BY.
SELECT name FROM s WHERE CASE WHEN score > 80 THEN 1 ELSE 0 END ORDER BY name;
SELECT name FROM s ORDER BY CASE WHEN name = 'cy' THEN 0 ELSE 1 END, name;
-- Keywords are case-insensitive.
select case when score > 90 then 'top' else 'rest' end from s where name = 'ann';
-- Syntax errors: missing END, missing WHEN.
SELECT CASE WHEN 1 THEN 2;
SELECT CASE ELSE 1 END;
