-- UPDATE ... RETURNING shows the new values; DELETE ... RETURNING shows the
-- deleted rows. (RETURNING rows are only checked where their order is
-- determined: single rows, or rows found through the rowid.)
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, qty INTEGER);
INSERT INTO t VALUES (1, 'apple', 5), (2, 'pear', 0), (3, 'plum', 7), (4, 'fig', NULL);

UPDATE t SET qty = qty + 1 WHERE id = 1 RETURNING id, name, qty;
UPDATE t SET name = upper(name), qty = 10 WHERE name = 'pear' RETURNING *;
-- RETURNING sees values after affinity.
UPDATE t SET qty = '42' WHERE id = 3 RETURNING qty, typeof(qty);
-- An expression mixing new values.
UPDATE t SET qty = coalesce(qty, 0) * 2 WHERE id = 4 RETURNING name || ':' || qty;
-- No matching row: no output.
UPDATE t SET qty = 0 WHERE id = 99 RETURNING *;
SELECT id, name, qty FROM t ORDER BY id;

-- Multi-row UPDATE with RETURNING.
UPDATE t SET qty = -qty WHERE id BETWEEN 2 AND 3 RETURNING id, qty;
SELECT id, name, qty FROM t ORDER BY id;

-- Changing the key: RETURNING shows the new key.
UPDATE t SET id = 40 WHERE id = 4 RETURNING id, rowid;

-- DELETE ... RETURNING.
DELETE FROM t WHERE id = 1 RETURNING *;
DELETE FROM t WHERE id = 99 RETURNING *;
DELETE FROM t WHERE id = 40 RETURNING name, qty * 2 AS doubled, rowid;
SELECT id, name, qty FROM t ORDER BY id;
DELETE FROM t WHERE id >= 2 RETURNING id;
SELECT id FROM t;

-- UPDATE OR IGNORE returns only rows that were actually updated.
CREATE TABLE u(id INTEGER PRIMARY KEY, code TEXT UNIQUE);
INSERT INTO u VALUES (1, 'a'), (2, 'b');
UPDATE OR IGNORE u SET code = 'a' WHERE id = 2 RETURNING id, code;
UPDATE OR IGNORE u SET code = 'c' WHERE id = 2 RETURNING id, code;

-- A failing UPDATE returns nothing.
UPDATE u SET code = 'a' WHERE id = 2 RETURNING id;
SELECT id, code FROM u ORDER BY id;

-- Errors in RETURNING.
UPDATE u SET code = 'z' WHERE id = 1 RETURNING nosuch;
DELETE FROM u WHERE id = 1 RETURNING max(id);
SELECT id, code FROM u ORDER BY id;
