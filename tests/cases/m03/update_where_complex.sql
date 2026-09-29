-- UPDATE with richer WHERE clauses and SET expressions that read several
-- columns, including updating the column used in the WHERE clause.
CREATE TABLE s(id INTEGER PRIMARY KEY, name TEXT, dept TEXT, pay INTEGER, bonus REAL);
INSERT INTO s VALUES
  (1, 'ann', 'eng', 100, NULL), (2, 'bob', 'ops', 80, 5.0), (3, 'cat', 'eng', 120, 10.0),
  (4, 'dan', 'hr', 60, NULL), (5, 'eve', 'ops', 90, 0.0), (6, 'fay', NULL, 70, 2.5);

UPDATE s SET pay = pay + 5 WHERE dept IN ('eng', 'hr');
SELECT id, pay FROM s ORDER BY id;
UPDATE s SET bonus = coalesce(bonus, 0) + pay / 10 WHERE pay BETWEEN 70 AND 100;
SELECT id, bonus FROM s ORDER BY id;
UPDATE s SET name = upper(substr(name, 1, 1)) || substr(name, 2) WHERE name LIKE '_a%';
SELECT id, name FROM s ORDER BY id;
UPDATE s SET dept = 'none' WHERE dept IS NULL;
SELECT id, dept FROM s ORDER BY id;

-- Update the column tested in WHERE: each row is tested once, before update.
UPDATE s SET pay = pay * 2 WHERE pay < 100;
SELECT id, pay FROM s ORDER BY id;

-- CASE in SET, NOT and OR in WHERE.
UPDATE s SET dept = CASE WHEN pay >= 150 THEN dept || '+' ELSE dept END WHERE NOT (dept = 'none' OR id = 1);
SELECT id, dept FROM s ORDER BY id;

-- WHERE on rowid and on an expression of several columns.
UPDATE s SET bonus = -1 WHERE rowid % 2 = 0 AND bonus > pay / 100.0;
SELECT id, bonus FROM s ORDER BY id;

-- Assigning one column from another after arithmetic with mixed types.
UPDATE s SET bonus = pay * 0.5, pay = bonus WHERE id = 3;
SELECT id, pay, typeof(pay), bonus, typeof(bonus) FROM s WHERE id = 3;

-- Using a scalar function over several columns.
UPDATE s SET name = name || '/' || max(pay, 150) WHERE id IN (1, 2);
SELECT id, name FROM s ORDER BY id;

-- A WHERE with a type mix: text '100' compared to INTEGER column (affinity).
UPDATE s SET name = 'hundred' WHERE pay = '210';
SELECT id, name, pay FROM s ORDER BY id;
