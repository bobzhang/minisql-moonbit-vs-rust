-- @db file
-- Subqueries (scalar, IN, EXISTS, correlated, FROM-subqueries), compound
-- selects, DISTINCT/LIMIT/OFFSET and CASE over tables read from a file.
-- @phase sqlite
CREATE TABLE item(id INTEGER PRIMARY KEY, cat TEXT, price INTEGER, stock INTEGER);
CREATE TABLE sale(id INTEGER PRIMARY KEY, item_id INTEGER REFERENCES item(id), n INTEGER);
CREATE INDEX sale_item ON sale(item_id);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 300)
INSERT INTO item SELECT i, 'cat' || (i % 7), 10 + (i * 29) % 90, (i * 11) % 17 FROM c;
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 3000)
INSERT INTO sale SELECT i, 1 + (i * 17) % 280, 1 + i % 5 FROM c;
-- @phase engine
SELECT count(*) FROM item WHERE id NOT IN (SELECT item_id FROM sale);
SELECT id FROM item WHERE NOT EXISTS (SELECT 1 FROM sale WHERE sale.item_id = item.id) ORDER BY id LIMIT 5;
SELECT id, price, (SELECT sum(n) FROM sale WHERE item_id = item.id) FROM item WHERE id IN (1, 2, 3, 299) ORDER BY id;
SELECT cat, max(price) FROM item WHERE price > (SELECT avg(price) FROM item) GROUP BY cat ORDER BY cat;
SELECT t.cat, t.total FROM (SELECT i.cat, sum(s.n * i.price) AS total FROM sale s JOIN item i ON i.id = s.item_id GROUP BY i.cat) t
  ORDER BY t.total DESC, t.cat LIMIT 3;
SELECT id FROM item WHERE stock = 0 UNION SELECT item_id FROM sale WHERE id < 5 ORDER BY 1;
SELECT cat FROM item WHERE price > 95 INTERSECT SELECT cat FROM item WHERE stock > 15 ORDER BY 1;
SELECT id FROM item WHERE id <= 20 EXCEPT SELECT item_id FROM sale ORDER BY 1 DESC;
SELECT count(*) FROM (SELECT item_id FROM sale UNION ALL SELECT id FROM item);
SELECT DISTINCT stock FROM item ORDER BY stock DESC LIMIT 4 OFFSET 2;
SELECT id, CASE WHEN stock = 0 THEN 'out' WHEN stock < 5 THEN 'low' ELSE 'ok' END FROM item WHERE id BETWEEN 10 AND 16 ORDER BY id;
SELECT i.id, (SELECT count(*) FROM sale s WHERE s.item_id = i.id AND s.n = 5) AS fives FROM item i ORDER BY fives DESC, i.id LIMIT 3;
SELECT * FROM (VALUES (1, 'x'), (2, 'y')) v JOIN item ON item.id = v.column1 ORDER BY item.id;
