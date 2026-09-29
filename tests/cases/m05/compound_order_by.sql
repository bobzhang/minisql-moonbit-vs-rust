-- ORDER BY on a compound applies to the whole result. Terms may be column
-- numbers, or names/aliases of the result columns (as named by the first
-- SELECT); arbitrary expressions are not allowed.
CREATE TABLE a(id INTEGER, name TEXT);
CREATE TABLE b(id INTEGER, label TEXT);
INSERT INTO a VALUES (3, 'cat'), (1, 'ant'), (5, 'eel');
INSERT INTO b VALUES (2, 'bee'), (4, 'dog'), (6, 'fox');

-- By column number.
SELECT id, name FROM a UNION ALL SELECT id, label FROM b ORDER BY 1;
SELECT id, name FROM a UNION ALL SELECT id, label FROM b ORDER BY 2 DESC;
-- By a column name of the first SELECT.
SELECT id, name FROM a UNION ALL SELECT id, label FROM b ORDER BY name;
-- By an alias defined in the first SELECT.
SELECT id AS k, name AS n FROM a UNION SELECT id, label FROM b ORDER BY k DESC;
SELECT id * 10 AS big, name FROM a UNION SELECT id, label FROM b ORDER BY big;
-- Multiple terms with directions.
CREATE TABLE c(g TEXT, v INTEGER);
INSERT INTO c VALUES ('x', 1), ('y', 2), ('x', 3);
SELECT g, v FROM c UNION ALL SELECT 'y', 1 ORDER BY 1 DESC, 2 ASC;
SELECT g, v FROM c UNION ALL SELECT 'y', 1 ORDER BY g, v DESC;
-- NULLS FIRST / LAST and COLLATE on compound terms.
SELECT name FROM a UNION ALL SELECT NULL UNION ALL SELECT 'Zed' ORDER BY 1 NULLS LAST;
SELECT name FROM a UNION ALL SELECT 'Zed' ORDER BY 1 COLLATE NOCASE;
SELECT name FROM a UNION ALL SELECT 'Zed' ORDER BY 1;
-- ORDER BY with INTERSECT and EXCEPT.
SELECT id FROM a UNION SELECT id FROM b EXCEPT SELECT 4 ORDER BY 1 DESC;
-- Without ORDER BY on the compound, inner ORDER BY is not allowed; a
-- derived table can hold an ordered, limited query instead.
SELECT * FROM (SELECT id FROM a ORDER BY id DESC LIMIT 2) UNION ALL SELECT 0 ORDER BY 1;
-- Errors: ORDER BY term out of range, expression that is not a result column,
-- ORDER BY on a SELECT that is not last.
SELECT id FROM a UNION SELECT id FROM b ORDER BY 2;
SELECT id FROM a UNION SELECT id FROM b ORDER BY id + 1;
SELECT id FROM a ORDER BY id UNION SELECT id FROM b;
