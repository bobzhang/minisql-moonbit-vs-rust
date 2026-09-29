-- WHERE filters rows by a boolean expression over the row's columns.

CREATE TABLE p(id INTEGER, name TEXT, qty INTEGER, price REAL);
INSERT INTO p VALUES
  (1, 'apple', 10, 0.5), (2, 'banana', 0, 0.25), (3, 'cherry', 100, 2.0),
  (4, 'date', 7, NULL), (5, 'elder', NULL, 3.5), (6, 'fig', 3, 1.25);
SELECT name FROM p WHERE qty > 5 ORDER BY id;
SELECT name FROM p WHERE qty = 0 ORDER BY id;
SELECT name FROM p WHERE price < 1 ORDER BY id;
SELECT name FROM p WHERE qty * price > 4 ORDER BY id;
SELECT name FROM p WHERE qty > 5 AND price >= 0.5 ORDER BY id;
SELECT name FROM p WHERE qty < 5 OR price > 3 ORDER BY id;
SELECT name FROM p WHERE NOT qty > 5 ORDER BY id;
SELECT name FROM p WHERE name = 'fig';
SELECT name FROM p WHERE name > 'c' ORDER BY id;
SELECT name FROM p WHERE name >= 'banana' AND name <= 'date' ORDER BY id;
-- A condition that is NULL filters the row.
SELECT name FROM p WHERE qty > price ORDER BY id;
-- WHERE may use columns that are not selected.
SELECT id FROM p WHERE price = 2 ORDER BY id;
-- Constant conditions.
SELECT name FROM p WHERE 1 = 1 ORDER BY id;
SELECT name FROM p WHERE 1 = 0 ORDER BY id;
-- Qualified column references in WHERE.
SELECT p.name FROM p WHERE p.id = 3;
SELECT q.name FROM p AS q WHERE q.qty IS NULL;
-- Comparing two columns of the same row.
SELECT name FROM p WHERE qty > id ORDER BY id;
SELECT name FROM p WHERE id * 2 = qty + 1 ORDER BY id;
-- An error in WHERE: unknown column.
SELECT name FROM p WHERE nosuch = 1;
