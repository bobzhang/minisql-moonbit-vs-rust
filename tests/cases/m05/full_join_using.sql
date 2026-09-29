-- USING/NATURAL with RIGHT and FULL joins: the unqualified shared column is
-- the non-NULL one of the two sides (like coalesce(left.col, right.col)),
-- while qualified references still see each side's own value.
CREATE TABLE a(x INTEGER, av TEXT);
CREATE TABLE b(x INTEGER, bv TEXT);
INSERT INTO a VALUES (1, 'a1'), (2, 'a2'), (NULL, 'an');
INSERT INTO b VALUES (2, 'b2'), (3, 'b3'), (NULL, 'bn');

SELECT x, av, bv FROM a FULL JOIN b USING (x) ORDER BY x, av, bv;
SELECT x, a.x, b.x FROM a FULL JOIN b USING (x) ORDER BY 1, 2, 3;
-- * shows the shared column once, first, holding the coalesced value.
SELECT * FROM a FULL JOIN b USING (x) ORDER BY x, av, bv;
SELECT * FROM a NATURAL FULL JOIN b ORDER BY x, av, bv;
-- RIGHT JOIN USING: x is taken from b for unmatched right rows.
SELECT x, av, bv FROM a RIGHT JOIN b USING (x) ORDER BY x, bv;
SELECT * FROM a NATURAL RIGHT JOIN b ORDER BY x, bv;
-- LEFT JOIN USING: x is a's value.
SELECT x, av, bv FROM a LEFT JOIN b USING (x) ORDER BY x, av;
-- Filtering and grouping on the coalesced column.
SELECT x FROM a FULL JOIN b USING (x) WHERE x > 1 ORDER BY x;
SELECT count(*) FROM a FULL JOIN b USING (x) WHERE x IS NULL;
SELECT x IS NULL, count(*) FROM a FULL JOIN b USING (x) GROUP BY 1 ORDER BY 1;
-- A chain of FULL JOINs with USING: the second USING compares against the
-- coalesced x of the first join.
CREATE TABLE c(x INTEGER, cv TEXT);
INSERT INTO c VALUES (3, 'c3'), (4, 'c4');
SELECT x, av, bv, cv FROM a FULL JOIN b USING (x) FULL JOIN c USING (x) ORDER BY x, av, bv, cv;
SELECT count(*) FROM a FULL JOIN b USING (x) FULL JOIN c USING (x);
-- Multi-column USING with FULL JOIN.
CREATE TABLE p(k1, k2, pv);
CREATE TABLE q(k1, k2, qv);
INSERT INTO p VALUES (1, 1, 'p11'), (1, 2, 'p12');
INSERT INTO q VALUES (1, 2, 'q12'), (2, 2, 'q22');
SELECT * FROM p FULL JOIN q USING (k1, k2) ORDER BY k1, k2;
