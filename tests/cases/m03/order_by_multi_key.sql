-- Multi-key ORDER BY with mixed directions and expressions, and sorting by
-- columns that are not in the result.
CREATE TABLE emp(id INTEGER, dept TEXT, salary INTEGER, name TEXT);
INSERT INTO emp VALUES
  (1, 'eng', 120, 'ann'), (2, 'ops', 90, 'bob'), (3, 'eng', 100, 'cat'),
  (4, 'ops', 90, 'dan'), (5, 'hr', 70, 'eve'), (6, 'eng', 120, 'fay'),
  (7, 'hr', NULL, 'gus'), (8, 'ops', 110, 'hal');

SELECT dept, salary, name FROM emp ORDER BY dept, salary DESC, name;
SELECT dept, salary, name FROM emp ORDER BY dept DESC, salary, name DESC;
SELECT name FROM emp ORDER BY salary DESC, dept, id;
SELECT name FROM emp ORDER BY dept ASC, id DESC;

-- Expressions as keys.
SELECT name, salary FROM emp ORDER BY salary % 20, name;
SELECT name FROM emp ORDER BY length(name) DESC, substr(name, 2) DESC;
SELECT name, dept FROM emp ORDER BY CASE dept WHEN 'hr' THEN 0 WHEN 'eng' THEN 1 ELSE 2 END, name;
SELECT name FROM emp ORDER BY salary IS NULL, salary, name;

-- Same key repeated; the first occurrence decides.
SELECT name, salary FROM emp ORDER BY salary DESC, salary ASC, name;

-- ORDER BY on a constant expression changes nothing; the next key decides.
SELECT name FROM emp ORDER BY 1 + 1, id DESC;

-- ORDER BY a boolean expression.
SELECT name, dept FROM emp ORDER BY dept = 'eng' DESC, name;

-- WHERE plus ORDER BY on several keys.
SELECT id, name FROM emp WHERE salary >= 90 ORDER BY dept DESC, salary, id;

-- Sorting an empty result.
SELECT name FROM emp WHERE id > 100 ORDER BY dept, name;
