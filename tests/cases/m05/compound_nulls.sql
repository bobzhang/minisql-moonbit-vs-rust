-- In compound queries NULLs are treated as equal to each other when
-- removing duplicates or matching rows (unlike = comparisons).
CREATE TABLE a(k, v);
CREATE TABLE b(k, v);
INSERT INTO a VALUES (NULL, 1), (NULL, 1), (1, NULL), (2, 2);
INSERT INTO b VALUES (NULL, 1), (1, NULL), (3, NULL);

SELECT NULL UNION SELECT NULL;
SELECT count(*) FROM (SELECT NULL UNION SELECT NULL);
SELECT count(*) FROM (SELECT NULL UNION ALL SELECT NULL);
SELECT NULL INTERSECT SELECT NULL;
SELECT count(*) FROM (SELECT NULL EXCEPT SELECT NULL);
-- Rows containing NULLs.
SELECT k, v FROM a UNION SELECT k, v FROM b ORDER BY k, v;
SELECT k, v FROM a INTERSECT SELECT k, v FROM b ORDER BY k, v;
SELECT k, v FROM a EXCEPT SELECT k, v FROM b ORDER BY k, v;
SELECT k, v FROM b EXCEPT SELECT k, v FROM a ORDER BY k, v;
-- The same rows compared with = in a join do not match.
SELECT count(*) FROM a JOIN b ON a.k = b.k AND a.v = b.v;
SELECT count(*) FROM a JOIN b ON a.k IS b.k AND a.v IS b.v;
-- NULL vs 0 vs '' are all different.
SELECT count(*) FROM (SELECT NULL UNION SELECT 0 UNION SELECT '' UNION SELECT 0.0 UNION SELECT x'');
SELECT v FROM (SELECT NULL AS v UNION SELECT 0 UNION SELECT '') ORDER BY v;
-- DISTINCT on a single side also collapses NULLs.
SELECT count(*) FROM (SELECT DISTINCT k FROM a);
-- NULL sorts first in a compound ORDER BY, last with NULLS LAST.
SELECT k FROM a UNION SELECT k FROM b ORDER BY k;
SELECT k FROM a UNION SELECT k FROM b ORDER BY k DESC;
SELECT k FROM a UNION SELECT k FROM b ORDER BY k NULLS LAST;
