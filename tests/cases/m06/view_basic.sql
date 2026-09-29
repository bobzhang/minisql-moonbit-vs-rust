-- CREATE VIEW defines a named query that can be used like a read-only table:
-- selected from, filtered, sorted, aggregated, joined, used in subqueries.
CREATE TABLE products(id INTEGER PRIMARY KEY, name TEXT, price INTEGER, cat TEXT);
INSERT INTO products VALUES (1, 'pen', 3, 'office'), (2, 'desk', 150, 'furniture'), (3, 'lamp', 40, 'furniture'), (4, 'clip', 1, 'office'), (5, 'mug', 8, NULL);
CREATE VIEW cheap AS SELECT id, name, price FROM products WHERE price < 10;

SELECT * FROM cheap ORDER BY id;
SELECT name FROM cheap WHERE price > 2 ORDER BY name;
SELECT count(*), sum(price) FROM cheap;
SELECT cheap.name FROM cheap ORDER BY cheap.price DESC;
SELECT c.name FROM cheap AS c WHERE c.id > 1 ORDER BY c.id;
-- Expressions over view columns.
SELECT name || ':' || (price * 2) FROM cheap ORDER BY id;
-- A view reflects later changes to its base table.
INSERT INTO products VALUES (6, 'tape', 2, 'office');
UPDATE products SET price = 12 WHERE name = 'mug';
SELECT name FROM cheap ORDER BY id;
DELETE FROM products WHERE id = 1;
SELECT count(*) FROM cheap;
-- Views in subqueries and joins.
SELECT name FROM products WHERE id IN (SELECT id FROM cheap) ORDER BY name;
SELECT p.name, p.cat FROM products p JOIN cheap c ON c.id = p.id ORDER BY p.name;
SELECT (SELECT max(price) FROM cheap);
SELECT name FROM products WHERE NOT EXISTS (SELECT 1 FROM cheap WHERE cheap.id = products.id) ORDER BY name;
-- A view with expressions and aliases.
CREATE VIEW labels AS SELECT upper(name) AS label, price / 10 AS tens, coalesce(cat, 'none') AS cat FROM products;
SELECT label, tens, cat FROM labels ORDER BY label;
SELECT cat, count(*) FROM labels GROUP BY cat ORDER BY cat;
-- A view that selects * from a table.
CREATE VIEW allp AS SELECT * FROM products;
SELECT * FROM allp WHERE id = 3;
-- Views appear in sqlite_schema with type 'view'.
SELECT type, name, tbl_name FROM sqlite_schema WHERE type = 'view' ORDER BY name;
-- A view defined without FROM.
CREATE VIEW consts AS SELECT 1 AS one, 'two' AS two;
SELECT * FROM consts;
SELECT one + 1, two FROM consts;
