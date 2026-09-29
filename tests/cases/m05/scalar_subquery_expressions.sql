-- Scalar subqueries may appear anywhere an expression is allowed: inside
-- arithmetic, function arguments, CASE, ORDER BY, GROUP BY, LIMIT, VALUES,
-- INSERT and UPDATE.
CREATE TABLE prices(item TEXT, price INTEGER);
CREATE TABLE cfg(k TEXT, v);
INSERT INTO prices VALUES ('pen', 2), ('book', 15), ('lamp', 40), ('desk', 120);
INSERT INTO cfg VALUES ('discount', 10), ('limit', 2), ('label', 'sale');

SELECT item, price - (SELECT v FROM cfg WHERE k = 'discount') FROM prices ORDER BY price;
SELECT upper((SELECT v FROM cfg WHERE k = 'label')), length((SELECT group_concat(item, '') FROM prices));
SELECT item, CASE WHEN price > (SELECT avg(price) FROM prices) THEN 'high' ELSE 'low' END FROM prices ORDER BY item;
SELECT CASE (SELECT v FROM cfg WHERE k = 'label') WHEN 'sale' THEN 'yes' ELSE 'no' END;
SELECT coalesce((SELECT v FROM cfg WHERE k = 'missing'), 'default');
SELECT max((SELECT min(price) FROM prices), 5), min((SELECT max(price) FROM prices), 100);
-- In BETWEEN and IN lists.
SELECT item FROM prices WHERE price BETWEEN (SELECT v FROM cfg WHERE k = 'limit') AND (SELECT v FROM cfg WHERE k = 'discount') * 2 ORDER BY item;
SELECT item FROM prices WHERE price IN ((SELECT min(price) FROM prices), (SELECT max(price) FROM prices)) ORDER BY item;
-- In ORDER BY: sort by distance from the average.
SELECT item FROM prices ORDER BY abs(price - (SELECT avg(price) FROM prices)), item;
-- In LIMIT and OFFSET.
SELECT item FROM prices ORDER BY price LIMIT (SELECT v FROM cfg WHERE k = 'limit');
SELECT item FROM prices ORDER BY price LIMIT 1 OFFSET (SELECT count(*) FROM cfg);
-- In GROUP BY: bucket by whether above the configured discount.
SELECT price > (SELECT v FROM cfg WHERE k = 'discount') AS big, count(*) FROM prices GROUP BY big ORDER BY big;
-- In VALUES and INSERT.
INSERT INTO prices VALUES ('bag', (SELECT max(price) FROM prices) + 1);
SELECT price FROM prices WHERE item = 'bag';
INSERT INTO prices SELECT 'mug', (SELECT v FROM cfg WHERE k = 'discount');
SELECT item, price FROM prices WHERE price = 10;
-- In UPDATE SET and WHERE.
UPDATE cfg SET v = (SELECT count(*) FROM prices) WHERE k = 'limit';
SELECT v FROM cfg WHERE k = 'limit';
UPDATE prices SET price = price * 2 WHERE price < (SELECT v FROM cfg WHERE k = 'discount');
SELECT item, price FROM prices ORDER BY item;
-- In a DELETE condition.
DELETE FROM prices WHERE price = (SELECT max(price) FROM prices);
SELECT count(*), max(price) FROM prices;
-- String concatenation with a subquery.
SELECT 'items: ' || (SELECT count(*) FROM prices) || ', top: ' || (SELECT item FROM prices ORDER BY price DESC LIMIT 1);
