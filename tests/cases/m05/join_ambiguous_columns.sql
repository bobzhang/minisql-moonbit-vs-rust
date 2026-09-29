-- Column resolution across joins: an unqualified name that exists in more
-- than one FROM source is an error, unless it is a USING/NATURAL column.
CREATE TABLE t(id INTEGER, name TEXT, v INTEGER);
CREATE TABLE u(id INTEGER, name TEXT, w INTEGER);
INSERT INTO t VALUES (1, 'tn1', 10), (2, 'tn2', 20);
INSERT INTO u VALUES (1, 'un1', 100), (3, 'un3', 300);

-- Unique names need no qualification.
SELECT v, w FROM t JOIN u ON t.id = u.id;
-- Qualified names resolve the ambiguity.
SELECT t.name, u.name FROM t JOIN u ON t.id = u.id;
-- Ambiguous in the select list, WHERE, ON, ORDER BY, GROUP BY.
SELECT name FROM t JOIN u ON t.id = u.id;
SELECT v FROM t JOIN u ON t.id = u.id WHERE id = 1;
SELECT v FROM t JOIN u ON t.id = u.id ORDER BY name;
SELECT count(*) FROM t JOIN u ON t.id = u.id GROUP BY id;
-- The qualified forms of the same queries succeed.
SELECT v FROM t JOIN u ON t.id = u.id WHERE t.id = 1;
SELECT v FROM t JOIN u ON u.id = 1 ORDER BY t.name;
SELECT t.id, count(*) FROM t JOIN u ON 1 GROUP BY t.id ORDER BY t.id;
-- A result alias with the same name as an ambiguous column is fine in ORDER BY.
SELECT t.name AS name FROM t, u WHERE t.id = u.id ORDER BY name;
-- USING / NATURAL columns are not ambiguous.
SELECT id, t.name FROM t JOIN u USING (id);
SELECT id, name FROM t NATURAL JOIN u;
SELECT id, name, v, w FROM t NATURAL JOIN u WHERE 0;
-- ...but the other shared column is still ambiguous under USING.
SELECT name FROM t JOIN u USING (id);
-- Self-join without aliases is rejected when a column is referenced.
SELECT t.v FROM t JOIN t ON 1;
-- With aliases it works; the original table name is hidden by the alias.
SELECT x.v, y.v FROM t AS x JOIN t AS y ON x.id < y.id;
SELECT t.v FROM t AS x;
-- Two sources with the same alias make that alias's columns ambiguous.
SELECT x.id FROM t AS x JOIN u AS x ON 1;
-- Identifier matching is case-insensitive.
SELECT T.V, U.W FROM t JOIN u ON T.ID = U.ID;
-- Quoted identifiers resolve the same way.
SELECT "t"."name", [u].[name], `u`.`w` FROM t JOIN u ON t.id = u.id;
-- A third table with its own unique column names.
CREATE TABLE z(zid INTEGER, zv TEXT);
INSERT INTO z VALUES (1, 'z1'), (2, 'z2');
SELECT zv, t.name, u.name FROM t JOIN u ON t.id = u.id JOIN z ON zid = t.id;
SELECT zv, v FROM t JOIN z ON zid = id ORDER BY zv;
-- A column name shared by two tables is not ambiguous when only one of them is in FROM.
SELECT name FROM t ORDER BY id;
-- Qualifying with an alias of a derived table also disambiguates.
SELECT s.name, t.name FROM t JOIN (SELECT id, name FROM u) AS s ON s.id = t.id;
SELECT s.id, s.name FROM (SELECT t.id, t.name FROM t JOIN u ON u.id = t.id) AS s;
SELECT count(*) FROM t AS a JOIN t AS b ON a.id <= b.id;
