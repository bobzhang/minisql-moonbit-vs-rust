-- @db file
-- Tiny tables whose whole b-tree is a single leaf root page, next to a
-- table that needs just two levels. Also a one-row table, and a table
-- whose index has a single entry.
-- @phase sqlite
CREATE TABLE one(x);
INSERT INTO one VALUES (42);
CREATE TABLE few(id INTEGER PRIMARY KEY, name TEXT, qty INTEGER);
INSERT INTO few VALUES (1, 'apple', 3), (2, 'banana', NULL), (5, 'cherry', 7), (9, 'date', 0);
CREATE INDEX few_name ON few(name);
CREATE TABLE two_level(id INTEGER PRIMARY KEY, pad TEXT);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 300)
INSERT INTO two_level SELECT i, printf('%030d', i) FROM c;
-- @phase engine
SELECT * FROM one;
SELECT x + 1, typeof(x) FROM one;
SELECT * FROM few ORDER BY id;
SELECT id FROM few WHERE name = 'cherry';
SELECT name FROM few WHERE qty IS NULL;
SELECT name FROM few ORDER BY name DESC;
SELECT count(*), sum(qty), max(id) FROM few;
SELECT rowid, id FROM few WHERE id > 1 ORDER BY id;
SELECT count(*), min(id), max(id), max(pad) FROM two_level;
SELECT id, pad FROM two_level WHERE id IN (1, 150, 300) ORDER BY id;
SELECT count(*) FROM two_level WHERE id > 299;
