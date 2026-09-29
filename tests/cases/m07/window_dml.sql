-- Window functions inside data-modifying statements: INSERT ... SELECT,
-- UPDATE and DELETE with window-based subqueries, and RETURNING.
CREATE TABLE item(id INTEGER PRIMARY KEY, cat TEXT, price INTEGER, pos INTEGER);
INSERT INTO item(id, cat, price) VALUES (1, 'a', 30), (2, 'a', 10), (3, 'b', 50), (4, 'a', 20), (5, 'b', 40), (6, 'c', 5);

-- UPDATE: store each row's rank within its category.
UPDATE item SET pos = (SELECT rn FROM (SELECT id, row_number() OVER (PARTITION BY cat ORDER BY price) AS rn FROM item) r WHERE r.id = item.id);
SELECT id, cat, price, pos FROM item ORDER BY id;

-- INSERT ... SELECT with window functions.
CREATE TABLE summary(cat TEXT, id INTEGER, running INTEGER, share REAL);
INSERT INTO summary SELECT cat, id, sum(price) OVER (PARTITION BY cat ORDER BY id), price * 1.0 / sum(price) OVER (PARTITION BY cat) FROM item;
SELECT cat, id, running, round(share, 4) FROM summary ORDER BY cat, id;

-- DELETE all but the cheapest item per category.
DELETE FROM item WHERE id IN (SELECT id FROM (SELECT id, rank() OVER (PARTITION BY cat ORDER BY price) AS rk FROM item) WHERE rk > 1);
SELECT id, cat, price FROM item ORDER BY id;

-- INSERT ... SELECT copying rows (window values computed over the source).
INSERT INTO item(id, cat, price) SELECT id + 100, cat, price * 2 FROM item WHERE cat <> 'c';
-- INSERT ... SELECT ... RETURNING (one row) with a windowed value.
INSERT INTO item(id, cat, price, pos) SELECT 300, 'y', sum(price) OVER (), count(*) OVER () FROM item WHERE id = 2 RETURNING id, price, pos;
DELETE FROM item WHERE id = 300;

-- UPDATE with a window-computed value from a derived table (the updated
-- column is not one the window reads).
UPDATE item SET pos = (SELECT d FROM (SELECT id, price - lag(price, 1, price) OVER (ORDER BY id) AS d FROM item) x WHERE x.id = item.id);
SELECT id, price, pos FROM item ORDER BY id;

-- DELETE based on ntile: remove the upper half by price.
DELETE FROM item WHERE id IN (SELECT id FROM (SELECT id, ntile(2) OVER (ORDER BY price, id) AS half FROM item) WHERE half = 2);
SELECT id FROM item ORDER BY id;
-- DELETE ... RETURNING (one row) of the most expensive remaining item.
DELETE FROM item WHERE id = (SELECT id FROM (SELECT id, row_number() OVER (ORDER BY price DESC, id) AS rn FROM item) WHERE rn = 1) RETURNING id, price;
SELECT count(*) FROM item;

-- A window over rows inserted in the same statement sequence.
INSERT INTO item(id, cat, price) VALUES (200, 'z', 1), (201, 'z', 2), (202, 'z', 3);
SELECT id, sum(price) OVER (PARTITION BY cat ORDER BY id) FROM item WHERE cat = 'z' ORDER BY id;

-- Upsert whose values come from a window query.
CREATE TABLE best(cat TEXT PRIMARY KEY, price INTEGER);
INSERT INTO best VALUES ('z', 100);
INSERT INTO best SELECT cat, price FROM (SELECT cat, price, row_number() OVER (PARTITION BY cat ORDER BY price DESC, id) AS rn FROM item) WHERE rn = 1
  ON CONFLICT(cat) DO UPDATE SET price = excluded.price;
SELECT cat, price FROM best ORDER BY cat;

-- Error: RETURNING may not contain window functions.
INSERT INTO best VALUES ('q', 1) RETURNING row_number() OVER ();
SELECT count(*) FROM best;
