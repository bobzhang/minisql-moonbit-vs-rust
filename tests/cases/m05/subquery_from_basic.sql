-- Subqueries in FROM (derived tables): their result columns are named by the
-- subquery's aliases (or column names) and can be referenced through the
-- subquery's alias.
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, score INTEGER);
INSERT INTO t VALUES (1, 'ann', 70), (2, 'bob', 85), (3, 'cy', 92), (4, 'dee', NULL);

SELECT * FROM (SELECT id, name FROM t) ORDER BY id;
SELECT * FROM (SELECT id, name FROM t) AS s ORDER BY s.id DESC;
SELECT s.name FROM (SELECT id, name FROM t WHERE id > 1) s ORDER BY s.id;
-- Aliased expressions become column names.
SELECT n, doubled FROM (SELECT name AS n, score * 2 AS doubled FROM t) ORDER BY n;
SELECT sub.n FROM (SELECT name AS n FROM t) AS sub WHERE sub.n LIKE '%e%' ORDER BY sub.n;
-- Plain columns keep their names.
SELECT name, score FROM (SELECT * FROM t) WHERE score > 80 ORDER BY name;
-- The outer query can filter, compute and sort on derived columns.
SELECT n, pct FROM (SELECT name AS n, score / 100.0 AS pct FROM t WHERE score IS NOT NULL) WHERE pct >= 0.85 ORDER BY pct DESC;
-- ORDER BY + LIMIT inside the subquery picks the rows; the outer query re-sorts them.
SELECT name FROM (SELECT name, score FROM t ORDER BY score DESC LIMIT 2) ORDER BY name;
-- DISTINCT inside.
CREATE TABLE tags(tag TEXT);
INSERT INTO tags VALUES ('x'), ('y'), ('x'), ('z'), ('y');
SELECT count(*) FROM (SELECT DISTINCT tag FROM tags);
SELECT tag FROM (SELECT DISTINCT tag FROM tags) ORDER BY tag DESC;
-- Nested derived tables.
SELECT v FROM (SELECT v FROM (SELECT score + 1 AS v FROM t) WHERE v > 80) ORDER BY v;
-- Derived table without FROM.
SELECT a + b FROM (SELECT 1 AS a, 2 AS b);
-- An empty derived table.
SELECT count(*) FROM (SELECT * FROM t WHERE 0);
SELECT * FROM (SELECT * FROM t WHERE 0);
-- Types pass through unchanged.
SELECT typeof(score), typeof(name) FROM (SELECT score, name FROM t) ORDER BY 1, 2;
-- rowid is not available from a derived table unless selected; selected under an alias it works.
SELECT r, name FROM (SELECT rowid AS r, name FROM t) ORDER BY r;
-- Errors: referencing a column the subquery does not expose; using the inner table's name outside.
SELECT score FROM (SELECT name FROM t);
SELECT t.name FROM (SELECT name FROM t) AS s;
