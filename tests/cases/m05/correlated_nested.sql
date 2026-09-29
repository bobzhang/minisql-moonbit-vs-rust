-- Nested subqueries: an inner subquery can see columns of every enclosing
-- query, and names resolve to the innermost query that has them.
CREATE TABLE a(id INTEGER, x INTEGER);
CREATE TABLE b(id INTEGER, a_id INTEGER, y INTEGER);
CREATE TABLE c(id INTEGER, b_id INTEGER, z INTEGER);
INSERT INTO a VALUES (1, 100), (2, 200), (3, 300);
INSERT INTO b VALUES (10, 1, 5), (11, 1, 6), (12, 2, 7), (13, 3, 8);
INSERT INTO c VALUES (20, 10, 1), (21, 10, 2), (22, 11, 3), (23, 12, 4), (24, 12, 99);

-- Two levels: per a, the number of c rows under its b rows.
SELECT id, (SELECT count(*) FROM b WHERE b.a_id = a.id AND EXISTS (SELECT 1 FROM c WHERE c.b_id = b.id)) FROM a ORDER BY id;
SELECT id, (SELECT sum((SELECT count(*) FROM c WHERE c.b_id = b.id)) FROM b WHERE b.a_id = a.id) FROM a ORDER BY id;
-- The innermost query references the outermost table directly.
SELECT id FROM a WHERE EXISTS (SELECT 1 FROM b WHERE b.a_id = a.id AND EXISTS (SELECT 1 FROM c WHERE c.b_id = b.id AND c.z * 100 > a.x)) ORDER BY id;
-- Unqualified "id" inside each subquery means that subquery's own table.
-- In the second query the innermost "id" is c.id (not b.id), so b_id = id
-- never holds and every count is 0.
SELECT id, (SELECT max(id) FROM b WHERE a_id = a.id) FROM a ORDER BY id;
SELECT id, (SELECT count(*) FROM b WHERE (SELECT count(*) FROM c WHERE b_id = id) >= 2) FROM a ORDER BY id;
-- Aliases distinguish the same table at different levels.
SELECT o.id, (SELECT count(*) FROM a i WHERE i.x < o.x AND (SELECT count(*) FROM a j WHERE j.x < i.x) >= 0) FROM a o ORDER BY o.id;
-- Three-level IN chain.
SELECT x FROM a WHERE id IN (SELECT a_id FROM b WHERE id IN (SELECT b_id FROM c WHERE z > 2)) ORDER BY x;
-- A subquery in FROM that contains a correlated subquery of its own.
SELECT s.aid, s.n FROM (SELECT a.id AS aid, (SELECT count(*) FROM b WHERE b.a_id = a.id) AS n FROM a) s ORDER BY s.aid;
-- Correlated reference to the outer query from inside a FROM-subquery's WHERE.
SELECT id, (SELECT count(*) FROM (SELECT * FROM b WHERE b.a_id = a.id) sub) FROM a ORDER BY id;
-- Outer references inside aggregate arguments of the inner query.
SELECT id, (SELECT sum(y * a.x) FROM b WHERE b.a_id = a.id) FROM a ORDER BY id;
-- Error: a column that exists at no level.
SELECT id, (SELECT nosuch FROM b) FROM a;
