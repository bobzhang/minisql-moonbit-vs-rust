-- UPDATE ... SET ... [WHERE ...]: basic forms.
CREATE TABLE t(id INTEGER, name TEXT, qty INTEGER, price REAL);
INSERT INTO t VALUES (1, 'apple', 10, 0.5), (2, 'pear', 0, 0.75), (3, 'plum', 7, NULL), (4, 'fig', NULL, 2.0);

-- Update one row.
UPDATE t SET qty = 11 WHERE id = 1;
SELECT * FROM t ORDER BY id;

-- Update several columns at once.
UPDATE t SET name = 'green pear', price = 0.8 WHERE name = 'pear';
SELECT * FROM t ORDER BY id;

-- Update with no WHERE touches every row.
UPDATE t SET qty = coalesce(qty, 0) + 1;
SELECT id, qty FROM t ORDER BY id;

-- WHERE that matches nothing changes nothing.
UPDATE t SET qty = 999 WHERE id > 100;
SELECT id, qty FROM t ORDER BY id;

-- WHERE with NULL comparison is never true.
UPDATE t SET name = 'x' WHERE price = NULL;
UPDATE t SET name = upper(name) WHERE price IS NULL;
SELECT id, name FROM t ORDER BY id;

-- Set a column to NULL.
UPDATE t SET price = NULL WHERE id = 4;
SELECT id, price FROM t ORDER BY id;

-- Update on an empty table is fine.
CREATE TABLE e(a);
UPDATE e SET a = 1;
SELECT a FROM e;

-- Qualified column names in expressions (the SET target itself is unqualified).
UPDATE t SET qty = t.qty * 2 WHERE t.id <= 2;
SELECT id, qty FROM t ORDER BY id;

-- Errors: unknown column in SET or WHERE, unknown table.
UPDATE t SET nosuch = 1;
UPDATE t SET qty = 1 WHERE nosuch = 2;
UPDATE nosuch SET a = 1;
SELECT * FROM t ORDER BY id;
