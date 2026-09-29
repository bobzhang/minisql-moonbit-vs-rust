-- expr [NOT] IN (SELECT ...): membership in the subquery's single column.
CREATE TABLE products(id INTEGER PRIMARY KEY, name TEXT, cat TEXT);
CREATE TABLE sold(product_id INTEGER, qty INTEGER);
INSERT INTO products VALUES (1, 'nail', 'hw'), (2, 'saw', 'hw'), (3, 'glue', 'craft'), (4, 'tape', 'craft'), (5, 'rope', 'out');
INSERT INTO sold VALUES (1, 100), (1, 20), (3, 5), (5, 1), (9, 3);

SELECT name FROM products WHERE id IN (SELECT product_id FROM sold) ORDER BY id;
SELECT name FROM products WHERE id NOT IN (SELECT product_id FROM sold) ORDER BY id;
-- Duplicates in the subquery do not duplicate the outer rows.
SELECT count(*) FROM products WHERE id IN (SELECT product_id FROM sold);
-- Subquery with its own WHERE, GROUP BY and HAVING.
SELECT name FROM products WHERE id IN (SELECT product_id FROM sold WHERE qty >= 5) ORDER BY name;
SELECT name FROM products WHERE id IN (SELECT product_id FROM sold GROUP BY product_id HAVING sum(qty) > 50);
-- Subquery ordering and LIMIT restrict the candidate set.
SELECT name FROM products WHERE id IN (SELECT product_id FROM sold ORDER BY qty LIMIT 2) ORDER BY name;
-- Empty subquery: IN is false, NOT IN is true.
SELECT count(*) FROM products WHERE id IN (SELECT product_id FROM sold WHERE qty > 1000);
SELECT count(*) FROM products WHERE id NOT IN (SELECT product_id FROM sold WHERE qty > 1000);
-- IN as a value in the select list.
SELECT name, id IN (SELECT product_id FROM sold), id NOT IN (SELECT product_id FROM sold) FROM products ORDER BY id;
-- Literals and expressions on the left.
SELECT 3 IN (SELECT product_id FROM sold), 4 IN (SELECT product_id FROM sold), 2 + 3 IN (SELECT product_id FROM sold);
-- Subquery selecting an expression.
SELECT name FROM products WHERE id * 10 IN (SELECT qty FROM sold) ORDER BY name;
-- IN against a compound subquery.
SELECT name FROM products WHERE id IN (SELECT 2 UNION SELECT 4 UNION SELECT 6) ORDER BY id;
-- Nested IN subqueries.
SELECT name FROM products WHERE cat IN (SELECT cat FROM products WHERE id IN (SELECT product_id FROM sold WHERE qty < 10)) ORDER BY id;
-- IN combined with other predicates.
SELECT name FROM products WHERE cat = 'hw' AND id NOT IN (SELECT product_id FROM sold);
-- Error: the subquery must return exactly one column.
SELECT name FROM products WHERE id IN (SELECT product_id, qty FROM sold);
