-- Three-valued logic of IN / NOT IN with subqueries:
--   x IN (S) is true if x equals a member; otherwise NULL if x is NULL or S
--   contains a NULL; otherwise false. An empty S gives false for IN and true
--   for NOT IN, even when x is NULL.
CREATE TABLE s(v INTEGER);
CREATE TABLE e(v INTEGER);
CREATE TABLE xs(x INTEGER);
INSERT INTO s VALUES (1), (2), (NULL);
INSERT INTO xs VALUES (1), (3), (NULL);

SELECT x, x IN (SELECT v FROM s), x NOT IN (SELECT v FROM s) FROM xs ORDER BY x;
-- Without NULLs in the set, a non-member is plainly false.
SELECT x, x IN (SELECT v FROM s WHERE v IS NOT NULL), x NOT IN (SELECT v FROM s WHERE v IS NOT NULL) FROM xs ORDER BY x;
-- Empty set.
SELECT x, x IN (SELECT v FROM e), x NOT IN (SELECT v FROM e) FROM xs ORDER BY x;
SELECT NULL IN (SELECT v FROM e), NULL NOT IN (SELECT v FROM e);
-- A set containing only NULL.
SELECT 1 IN (SELECT NULL), 1 NOT IN (SELECT NULL), NULL IN (SELECT NULL);
-- The classic trap: NOT IN with a NULL in the subquery filters out everything.
SELECT count(*) FROM xs WHERE x NOT IN (SELECT v FROM s);
SELECT count(*) FROM xs WHERE x NOT IN (SELECT v FROM s WHERE v IS NOT NULL);
SELECT count(*) FROM xs WHERE NOT (x IN (SELECT v FROM s));
-- IN with NULLs still finds real members.
SELECT x FROM xs WHERE x IN (SELECT v FROM s) ORDER BY x;
-- Wrapping in IS / coalesce to turn NULL into a definite answer.
SELECT x, (x IN (SELECT v FROM s)) IS NULL, coalesce(x NOT IN (SELECT v FROM s), 'unknown') FROM xs ORDER BY x;
-- NOT EXISTS is not affected by NULLs the same way.
SELECT x FROM xs WHERE NOT EXISTS (SELECT 1 FROM s WHERE s.v = xs.x) ORDER BY x;
-- Values lists behave the same as subqueries.
SELECT 3 IN (1, 2, NULL), 3 NOT IN (1, 2, NULL), 3 IN (SELECT 1 UNION ALL SELECT NULL);
-- CASE on an IN result that is NULL takes the ELSE branch.
SELECT x, CASE WHEN x NOT IN (SELECT v FROM s) THEN 'out' ELSE 'in-or-unknown' END FROM xs ORDER BY x;
