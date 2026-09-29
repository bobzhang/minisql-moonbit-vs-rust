-- ORDER BY with several keys and mixed directions: later keys break ties.

CREATE TABLE t(dept TEXT, name TEXT, age INTEGER, salary INTEGER);
INSERT INTO t VALUES
  ('eng', 'zoe', 30, 100), ('eng', 'amy', 25, 120), ('ops', 'bob', 40, 90),
  ('eng', 'cal', 30, 110), ('ops', 'dan', 22, 90), ('hr', 'eli', 35, 80),
  ('hr', 'fay', 35, 85), (NULL, 'gus', 50, 70), ('ops', 'hal', 40, 95);
SELECT dept, name FROM t ORDER BY dept, name;
SELECT dept, name FROM t ORDER BY dept DESC, name;
SELECT dept, name FROM t ORDER BY dept, name DESC;
SELECT dept, name FROM t ORDER BY dept DESC, name DESC;
SELECT age, name FROM t ORDER BY age, name;
SELECT age, salary, name FROM t ORDER BY age DESC, salary ASC, name;
SELECT salary, dept, name FROM t ORDER BY salary, dept, name;
-- Three keys where the first two tie.
SELECT dept, age, name FROM t ORDER BY dept, age, name;
-- A key that is an expression.
SELECT name, salary - age FROM t ORDER BY salary - age, name;
SELECT name FROM t ORDER BY age * -1, name;
-- The same column twice (second occurrence has no effect).
SELECT name FROM t ORDER BY name, name DESC;
-- Filtering plus multi-key ordering.
SELECT dept, name, salary FROM t WHERE salary >= 90 ORDER BY dept, salary DESC, name;
