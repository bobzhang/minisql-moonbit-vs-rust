-- INTERSECT returns distinct rows present in both results; EXCEPT returns
-- distinct rows of the left result that are absent from the right.
CREATE TABLE a(v INTEGER, w TEXT);
CREATE TABLE b(v INTEGER, w TEXT);
INSERT INTO a VALUES (1, 'p'), (2, 'q'), (2, 'q'), (3, 'r'), (4, 's');
INSERT INTO b VALUES (2, 'q'), (3, 'R'), (4, 's'), (4, 's'), (5, 't');

SELECT v FROM a INTERSECT SELECT v FROM b ORDER BY v;
SELECT v, w FROM a INTERSECT SELECT v, w FROM b ORDER BY v;
SELECT v FROM a EXCEPT SELECT v FROM b ORDER BY v;
SELECT v, w FROM a EXCEPT SELECT v, w FROM b ORDER BY v;
SELECT v, w FROM b EXCEPT SELECT v, w FROM a ORDER BY v;
-- Results are distinct even when inputs have duplicates.
SELECT count(*) FROM (SELECT v, w FROM a INTERSECT SELECT v, w FROM a);
SELECT count(*) FROM (SELECT v FROM a EXCEPT SELECT v FROM b WHERE 0);
-- Empty operands.
SELECT v FROM a INTERSECT SELECT v FROM b WHERE 0;
SELECT v FROM a WHERE 0 EXCEPT SELECT v FROM b;
SELECT v FROM a EXCEPT SELECT v FROM a;
-- Constant rows.
SELECT 1 INTERSECT SELECT 1;
SELECT 1 INTERSECT SELECT 2;
SELECT 1 EXCEPT SELECT 2;
SELECT 1 EXCEPT SELECT 1;
-- Text comparison is case-sensitive (BINARY) here.
SELECT w FROM a INTERSECT SELECT w FROM b ORDER BY w;
SELECT w FROM a EXCEPT SELECT w FROM b ORDER BY w;
-- Expressions on either side.
SELECT v + 1 FROM a INTERSECT SELECT v FROM b ORDER BY 1;
SELECT lower(w) FROM b EXCEPT SELECT w FROM a ORDER BY 1;
-- EXCEPT/INTERSECT over aggregated sides.
SELECT v FROM a GROUP BY v HAVING count(*) > 1 INTERSECT SELECT v FROM b ORDER BY v;
SELECT v FROM b GROUP BY v HAVING count(*) > 1 EXCEPT SELECT v FROM a;
