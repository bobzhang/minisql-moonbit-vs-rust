-- LEFT [OUTER] JOIN keeps every left row; left rows without a match get NULLs
-- for all right-hand columns.
CREATE TABLE customers(id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE orders(oid INTEGER PRIMARY KEY, cust_id INTEGER, amount INTEGER);
INSERT INTO customers VALUES (1, 'alice'), (2, 'bob'), (3, 'carol'), (4, 'dan');
INSERT INTO orders VALUES (100, 1, 50), (101, 1, 25), (102, 3, 10), (103, 9, 99), (104, NULL, 5);

SELECT name, oid, amount FROM customers LEFT JOIN orders ON orders.cust_id = customers.id ORDER BY customers.id, oid;
SELECT name, oid FROM customers LEFT OUTER JOIN orders ON orders.cust_id = customers.id ORDER BY customers.id, oid;
-- * over a left join: NULL-extended right columns print as NULL.
SELECT * FROM customers LEFT JOIN orders ON orders.cust_id = customers.id ORDER BY customers.id, oid;
-- NULL-extended values really are NULL.
SELECT name, typeof(oid), typeof(amount), amount IS NULL FROM customers
  LEFT JOIN orders ON orders.cust_id = customers.id WHERE customers.id IN (2, 4) ORDER BY name;
-- Order rows without a customer are dropped (they are on the right side).
SELECT count(*) FROM customers LEFT JOIN orders ON orders.cust_id = customers.id;
-- Swapping the sides keeps all orders instead.
SELECT oid, name FROM orders LEFT JOIN customers ON orders.cust_id = customers.id ORDER BY oid;
-- Expressions over NULL-extended columns.
SELECT name, coalesce(amount, 0), amount + 1, ifnull(oid, 'none') FROM customers
  LEFT JOIN orders ON orders.cust_id = customers.id ORDER BY customers.id, oid;
-- count(col) ignores NULL-extended rows, count(*) does not.
SELECT name, count(*), count(oid), coalesce(sum(amount), 0) FROM customers
  LEFT JOIN orders ON orders.cust_id = customers.id GROUP BY customers.id ORDER BY customers.id;
-- Left join against an empty table keeps all left rows.
CREATE TABLE nada(cust_id INTEGER, note TEXT);
SELECT name, note FROM customers LEFT JOIN nada ON nada.cust_id = customers.id ORDER BY name;
-- Empty left table: no rows.
SELECT * FROM nada LEFT JOIN customers ON nada.cust_id = customers.id;
-- A left row matching several right rows appears once per match.
SELECT name, count(*) FROM customers LEFT JOIN orders ON 1 GROUP BY name ORDER BY name;
-- ON condition that is never true: every left row NULL-extended once.
SELECT name, oid FROM customers LEFT JOIN orders ON 0 ORDER BY name;
