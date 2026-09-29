-- Correlated subqueries in WHERE and in join ON clauses.
CREATE TABLE orders(oid INTEGER PRIMARY KEY, cust TEXT, amount INTEGER, day INTEGER);
INSERT INTO orders VALUES
  (1, 'a', 10, 1), (2, 'a', 50, 2), (3, 'b', 20, 1), (4, 'b', 20, 3),
  (5, 'c', 5, 2), (6, 'a', 30, 4), (7, 'c', 45, 5), (8, 'd', NULL, 1);

-- Orders above their customer's average.
SELECT oid FROM orders o WHERE amount > (SELECT avg(amount) FROM orders i WHERE i.cust = o.cust) ORDER BY oid;
-- Each customer's largest order.
SELECT cust, oid, amount FROM orders o WHERE amount = (SELECT max(amount) FROM orders i WHERE i.cust = o.cust) ORDER BY cust, oid;
-- Each customer's first order by day.
SELECT cust, oid FROM orders o WHERE day = (SELECT min(day) FROM orders i WHERE i.cust = o.cust) ORDER BY cust;
-- Correlated IN.
SELECT oid FROM orders o WHERE day IN (SELECT day + 1 FROM orders i WHERE i.cust = o.cust) ORDER BY oid;
-- Correlated NOT IN. d's only order has a NULL amount, but its subquery is
-- empty, so NOT IN is still true for it.
SELECT oid FROM orders o WHERE amount NOT IN (SELECT amount FROM orders i WHERE i.cust = o.cust AND i.oid <> o.oid) ORDER BY oid;
-- Customers whose every order is at least 20 (correlated count comparison).
SELECT DISTINCT cust FROM orders o WHERE (SELECT count(*) FROM orders i WHERE i.cust = o.cust AND i.amount < 20) = 0 ORDER BY cust;
-- Correlated subquery comparing with the previous order of the same customer.
SELECT oid, amount - (SELECT amount FROM orders p WHERE p.cust = o.cust AND p.day < o.day ORDER BY p.day DESC LIMIT 1) AS delta
  FROM orders o WHERE delta IS NOT NULL ORDER BY oid;
-- Correlated subquery inside a join's ON clause.
CREATE TABLE custs(name TEXT, tier TEXT);
INSERT INTO custs VALUES ('a', 'gold'), ('b', 'silver'), ('c', 'gold'), ('e', 'none');
SELECT c.name, o.oid FROM custs c LEFT JOIN orders o ON o.cust = c.name
  AND o.amount = (SELECT max(amount) FROM orders x WHERE x.cust = c.name) ORDER BY c.name;
-- Two outer tables referenced from one subquery.
SELECT c.name, o.oid FROM custs c JOIN orders o ON o.cust = c.name
  WHERE (SELECT count(*) FROM orders x WHERE x.cust = c.name AND x.day > o.day) = 0 ORDER BY c.name;
-- Correlated subquery in a DELETE.
DELETE FROM orders WHERE amount < (SELECT max(amount) FROM orders i WHERE i.cust = orders.cust) / 2;
SELECT oid FROM orders ORDER BY oid;
-- Correlated subquery in an UPDATE.
UPDATE orders SET amount = (SELECT sum(amount) FROM orders i WHERE i.cust = orders.cust) WHERE day = 1;
SELECT oid, amount FROM orders ORDER BY oid;
