-- @db file
-- M5 join features against tables read from a file: inner, LEFT, RIGHT,
-- FULL, NATURAL, USING, self joins and multi-way joins, where some join
-- columns are indexed in the file and some are not.
-- @phase sqlite
PRAGMA page_size = 2048;
CREATE TABLE customer(id INTEGER PRIMARY KEY, name TEXT NOT NULL, region TEXT, referrer INTEGER);
CREATE TABLE orders(id INTEGER PRIMARY KEY, customer_id INTEGER, amount INTEGER, day TEXT);
CREATE INDEX orders_customer ON orders(customer_id);
CREATE TABLE region(region TEXT PRIMARY KEY, manager TEXT);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 500)
INSERT INTO customer SELECT i, 'cust' || printf('%03d', i), CASE i % 4 WHEN 0 THEN 'north' WHEN 1 THEN 'south' WHEN 2 THEN 'east' ELSE NULL END,
  CASE WHEN i > 10 THEN i / 10 END FROM c;
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 4000)
INSERT INTO orders SELECT i, CASE WHEN i % 50 = 0 THEN NULL ELSE (i * 7) % 520 END, (i * 13) % 1000, date('2024-01-01', '+' || (i % 366) || ' days') FROM c;
INSERT INTO region VALUES ('north', 'Nia'), ('south', 'Sam'), ('west', 'Wes');
-- @phase engine
SELECT count(*), sum(o.amount) FROM orders o JOIN customer c ON c.id = o.customer_id;
SELECT c.name, count(o.id), sum(o.amount) FROM customer c LEFT JOIN orders o ON o.customer_id = c.id
  WHERE c.id BETWEEN 1 AND 5 GROUP BY c.id ORDER BY c.id;
SELECT count(*) FROM customer c LEFT JOIN orders o ON o.customer_id = c.id WHERE o.id IS NULL;
SELECT count(*) FROM orders o LEFT JOIN customer c ON c.id = o.customer_id WHERE c.id IS NULL;
SELECT region, count(*), manager FROM customer JOIN region USING (region) GROUP BY region ORDER BY region;
SELECT r.region, r.manager, count(c.id) FROM customer c RIGHT JOIN region r ON r.region = c.region GROUP BY r.region ORDER BY r.region;
SELECT coalesce(c.region, r.region), count(c.id), count(r.manager) FROM customer c FULL JOIN region r ON r.region = c.region
  GROUP BY 1 ORDER BY 1;
SELECT count(*) FROM customer NATURAL JOIN region;
SELECT a.name, b.name FROM customer a JOIN customer b ON b.id = a.referrer WHERE a.id IN (11, 99, 250, 500) ORDER BY a.id;
SELECT c.name, o.day, o.amount, r.manager FROM orders o JOIN customer c ON c.id = o.customer_id JOIN region r ON r.region = c.region
  WHERE o.id IN (7, 777, 3999) ORDER BY o.id;
SELECT c.region, sum(o.amount) FROM customer c, orders o WHERE o.customer_id = c.id AND o.day >= '2024-12-01' GROUP BY c.region ORDER BY c.region;
SELECT count(*) FROM customer a CROSS JOIN region b;
SELECT o.id, c.name FROM orders o LEFT JOIN customer c ON c.id = o.customer_id AND c.region = 'north' WHERE o.id <= 6 ORDER BY o.id;
