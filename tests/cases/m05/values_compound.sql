-- VALUES combined with SELECT through compound operators. (A compound whose
-- last member is a VALUES clause cannot take ORDER BY/LIMIT, so ordering is
-- done by an enclosing query or by putting VALUES first.)
CREATE TABLE t(v INTEGER);
INSERT INTO t VALUES (2), (4);

VALUES (1), (3) UNION SELECT v FROM t ORDER BY 1;
VALUES (1), (2) UNION ALL SELECT v FROM t ORDER BY 1 DESC;
VALUES (1), (2), (3) EXCEPT SELECT v FROM t ORDER BY 1;
VALUES (1), (2), (3) INTERSECT SELECT v FROM t;
SELECT column1 FROM (SELECT v AS column1 FROM t UNION ALL VALUES (0), (9)) ORDER BY 1;
SELECT x FROM (SELECT v AS x FROM t UNION VALUES (4), (5)) ORDER BY x;
-- VALUES on both sides.
SELECT count(*) FROM (VALUES (1), (2) UNION VALUES (2), (3));
SELECT count(*) FROM (VALUES (1), (2) UNION ALL VALUES (2), (3));
SELECT * FROM (VALUES (1, 'a') UNION ALL VALUES (2, 'b')) ORDER BY 1 DESC;
-- Duplicate rows inside a single VALUES are removed by UNION.
VALUES (5), (5), (5) UNION SELECT 5;
SELECT count(*) FROM (VALUES (NULL), (NULL) UNION SELECT NULL);
-- Multi-column VALUES in compounds.
VALUES (1, 'x'), (2, 'y') EXCEPT SELECT 2, 'y';
VALUES (1, 'x'), (2, 'y') UNION SELECT v, 'z' FROM t ORDER BY 1, 2;
-- Mismatched column counts between VALUES and SELECT.
VALUES (1, 2) UNION SELECT 1;
SELECT 1 UNION VALUES (1, 2);
