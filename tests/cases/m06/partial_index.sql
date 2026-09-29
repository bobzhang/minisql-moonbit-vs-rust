-- Partial indexes (CREATE INDEX ... WHERE expr) cover only rows satisfying the
-- predicate. Queries must return the same results whether or not a partial
-- index could be used, including for rows outside the predicate.
CREATE TABLE orders(id INTEGER PRIMARY KEY, status TEXT, amount INTEGER, note TEXT);
INSERT INTO orders VALUES
  (1, 'open', 10, 'a'), (2, 'closed', 20, 'b'), (3, 'open', 30, NULL),
  (4, 'void', 40, 'd'), (5, 'closed', 50, NULL), (6, 'open', 60, 'f');
CREATE INDEX orders_open_amount ON orders(amount) WHERE status = 'open';
CREATE INDEX orders_note ON orders(note) WHERE note IS NOT NULL;

-- Queries matching the predicate.
SELECT id FROM orders WHERE status = 'open' AND amount > 15 ORDER BY id;
SELECT id FROM orders WHERE status = 'open' ORDER BY amount DESC;
-- Queries on the same column that include rows outside the predicate.
SELECT id FROM orders WHERE amount > 15 ORDER BY id;
SELECT id FROM orders WHERE amount = 20;
SELECT id FROM orders WHERE note IS NULL ORDER BY id;
SELECT id FROM orders WHERE note = 'd';
SELECT id FROM orders WHERE note > 'b' ORDER BY note;
-- Rows move in and out of the predicate through UPDATE.
UPDATE orders SET status = 'open' WHERE id = 2;
UPDATE orders SET status = 'closed' WHERE id = 1;
SELECT id FROM orders WHERE status = 'open' AND amount < 35 ORDER BY id;
UPDATE orders SET note = 'c' WHERE id = 3;
UPDATE orders SET note = NULL WHERE id = 6;
SELECT id, note FROM orders WHERE note IS NOT NULL ORDER BY note;
-- Inserts and deletes on both sides of the predicate.
INSERT INTO orders VALUES (7, 'open', 5, 'g'), (8, 'void', 5, NULL);
DELETE FROM orders WHERE id = 4;
SELECT id FROM orders WHERE amount = 5 ORDER BY id;
SELECT id FROM orders WHERE status = 'open' AND amount = 5;
SELECT count(*) FROM orders WHERE note IS NOT NULL;
-- Predicates may use AND/OR, IN, IS NULL and functions of columns.
CREATE INDEX orders_big ON orders(status) WHERE amount >= 30 AND (note IS NULL OR length(note) = 1);
SELECT id FROM orders WHERE amount >= 30 ORDER BY id;
SELECT status, count(*) FROM orders GROUP BY status ORDER BY status;
-- Partial index predicate errors: unknown column, subquery.
CREATE INDEX bad1 ON orders(amount) WHERE nosuch > 0;
CREATE INDEX bad2 ON orders(amount) WHERE amount IN (SELECT 1);
SELECT name FROM sqlite_schema WHERE type = 'index' ORDER BY name;
