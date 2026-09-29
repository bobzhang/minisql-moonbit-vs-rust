-- Subqueries inside INSERT, UPDATE and DELETE, including subqueries over the
-- table being modified (evaluated against the table's state as defined by
-- SQLite: the WHERE/SET values are computed before rows change).
CREATE TABLE stock(item TEXT PRIMARY KEY, qty INTEGER);
CREATE TABLE incoming(item TEXT, qty INTEGER);
INSERT INTO stock VALUES ('bolt', 10), ('nut', 0), ('gear', 5);
INSERT INTO incoming VALUES ('bolt', 3), ('gear', 2), ('gear', 4), ('cog', 7);

-- UPDATE with a correlated SET value.
UPDATE stock SET qty = qty + (SELECT coalesce(sum(qty), 0) FROM incoming i WHERE i.item = stock.item);
SELECT * FROM stock ORDER BY item;
-- UPDATE restricted by IN (subquery).
UPDATE stock SET qty = qty * 10 WHERE item IN (SELECT item FROM incoming WHERE qty > 3);
SELECT * FROM stock ORDER BY item;
-- INSERT ... SELECT with NOT EXISTS: add unseen items.
INSERT INTO stock SELECT item, sum(qty) FROM incoming i WHERE NOT EXISTS (SELECT 1 FROM stock s WHERE s.item = i.item) GROUP BY item;
SELECT * FROM stock ORDER BY item;
-- DELETE with a scalar subquery over the same table (evaluated against the
-- table as it was before the DELETE started).
DELETE FROM stock WHERE qty < (SELECT avg(qty) FROM stock) / 10;
SELECT * FROM stock ORDER BY item;
-- INSERT with a subquery in VALUES reading the same table.
INSERT INTO stock VALUES ('spring', (SELECT max(qty) FROM stock) + 1);
SELECT * FROM stock ORDER BY item;
-- DELETE with EXISTS over another table.
DELETE FROM stock WHERE EXISTS (SELECT 1 FROM incoming WHERE incoming.item = stock.item AND incoming.qty = 7);
SELECT * FROM stock ORDER BY item;
-- RETURNING with a correlated subquery.
UPDATE stock SET qty = 1 WHERE item = 'bolt' RETURNING item, qty, (SELECT count(*) FROM incoming WHERE incoming.item = stock.item);
-- An uncorrelated subquery over the table being updated sees the table as it
-- was before the UPDATE: every row gets the same original total.
UPDATE stock SET qty = (SELECT sum(qty) FROM stock);
SELECT * FROM stock ORDER BY item;
-- INSERT ... SELECT from a join.
CREATE TABLE report(item TEXT, total INTEGER);
INSERT INTO report SELECT s.item, s.qty + sum(i.qty) FROM stock s JOIN incoming i ON i.item = s.item GROUP BY s.item;
SELECT * FROM report ORDER BY item;
-- Error: the subquery returns two columns.
UPDATE stock SET qty = (SELECT item, qty FROM incoming);
SELECT count(*) FROM stock;
