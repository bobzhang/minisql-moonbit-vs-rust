-- Views defined in terms of other views, views with subqueries, and views
-- used in several places of one query.
CREATE TABLE nums(n INTEGER);
INSERT INTO nums VALUES (1), (2), (3), (4), (5), (6), (7), (8), (9), (10);
CREATE VIEW evens AS SELECT n FROM nums WHERE n % 2 = 0;
CREATE VIEW big_evens AS SELECT n FROM evens WHERE n > 4;
CREATE VIEW squares AS SELECT n, n * n AS sq FROM big_evens;

SELECT n FROM evens ORDER BY n;
SELECT n FROM big_evens ORDER BY n;
SELECT n, sq FROM squares ORDER BY n;
SELECT sum(sq) FROM squares;
-- A view with a correlated subquery.
CREATE VIEW with_rank AS SELECT n, (SELECT count(*) FROM nums m WHERE m.n > nums.n) AS above FROM nums;
SELECT n, above FROM with_rank WHERE above < 3 ORDER BY n;
-- A view with IN and EXISTS subqueries over another view.
CREATE VIEW odds AS SELECT n FROM nums WHERE n NOT IN (SELECT n FROM evens);
SELECT n FROM odds ORDER BY n;
SELECT count(*) FROM odds WHERE EXISTS (SELECT 1 FROM evens WHERE evens.n = odds.n + 1);
-- The same view twice in one query (self-join of a view).
SELECT a.n, b.n FROM evens a JOIN evens b ON b.n = a.n + 2 ORDER BY a.n;
-- A view joined with a view built on it.
SELECT e.n, s.sq FROM evens e LEFT JOIN squares s ON s.n = e.n ORDER BY e.n;
-- A view in a FROM subquery and in a scalar subquery.
SELECT (SELECT max(n) FROM big_evens) - (SELECT min(n) FROM evens);
SELECT total FROM (SELECT sum(n) AS total FROM odds);
-- A compound of views.
SELECT n FROM big_evens UNION SELECT n FROM odds WHERE n > 7 ORDER BY n;
-- Changes to the base table propagate through every level.
DELETE FROM nums WHERE n > 8;
INSERT INTO nums VALUES (12);
SELECT n, sq FROM squares ORDER BY n;
SELECT count(*) FROM odds;
-- Aggregate over a three-level view chain with GROUP BY.
SELECT sq % 3, count(*) FROM squares GROUP BY sq % 3 ORDER BY 1;
