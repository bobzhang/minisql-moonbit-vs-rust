-- UNION combines two queries and removes duplicate rows (across both sides
-- and within each side).
CREATE TABLE a(v INTEGER, w TEXT);
CREATE TABLE b(v INTEGER, w TEXT);
INSERT INTO a VALUES (1, 'x'), (2, 'y'), (2, 'y'), (3, 'z');
INSERT INTO b VALUES (3, 'z'), (4, 'w'), (4, 'w'), (1, 'X');

SELECT v FROM a UNION SELECT v FROM b ORDER BY v;
SELECT v, w FROM a UNION SELECT v, w FROM b ORDER BY v, w;
SELECT count(*) FROM (SELECT v, w FROM a UNION SELECT v, w FROM b);
-- Duplicates inside a single side are removed too.
SELECT v FROM a UNION SELECT v FROM a ORDER BY v;
SELECT count(*) FROM (SELECT v, w FROM a UNION SELECT v, w FROM a WHERE 0);
-- Each side may have its own WHERE, expressions and FROM.
SELECT v * 10 FROM a WHERE v > 1 UNION SELECT v FROM b WHERE w <> 'w' ORDER BY 1;
SELECT w FROM a UNION SELECT upper(w) FROM b ORDER BY 1;
-- Sides without FROM.
SELECT 1 UNION SELECT 2 UNION SELECT 1 ORDER BY 1;
SELECT 'only';
SELECT 'same' UNION SELECT 'same';
-- One side empty.
SELECT v FROM a WHERE 0 UNION SELECT v FROM b ORDER BY v;
SELECT v FROM a UNION SELECT v FROM b WHERE 0 ORDER BY v;
SELECT v FROM a WHERE 0 UNION SELECT v FROM b WHERE 0;
-- Sides with aggregates and GROUP BY.
SELECT 'a', count(*) FROM a UNION SELECT 'b', count(*) FROM b ORDER BY 1;
SELECT v, count(*) FROM a GROUP BY v UNION SELECT v, count(*) FROM b GROUP BY v ORDER BY 1, 2;
-- Sides over joins.
SELECT a.v, b.w FROM a JOIN b ON a.v = b.v UNION SELECT 0, 'none' ORDER BY 1, 2;
-- Distinct counting via UNION vs UNION ALL.
SELECT count(*) FROM (SELECT v FROM a UNION ALL SELECT v FROM b);
SELECT count(*) FROM (SELECT v FROM a UNION SELECT v FROM b);
