-- CROSS JOIN and plain JOIN without a constraint behave like a comma join.
CREATE TABLE a(x INTEGER);
CREATE TABLE b(y TEXT);
INSERT INTO a VALUES (1), (2), (3);
INSERT INTO b VALUES ('p'), ('q');

SELECT x, y FROM a CROSS JOIN b ORDER BY x, y;
SELECT count(*) FROM a CROSS JOIN b;
-- JOIN with no ON/USING is also a cross product.
SELECT x, y FROM a JOIN b ORDER BY y DESC, x DESC;
SELECT count(*) FROM a INNER JOIN b;
-- CROSS JOIN may still carry an ON clause, which filters like an inner join.
SELECT x, y FROM a CROSS JOIN b ON x = 2 ORDER BY y;
-- Chains of CROSS JOINs.
SELECT count(*) FROM a CROSS JOIN b CROSS JOIN a AS a2;
SELECT a.x, b.y, a2.x FROM a CROSS JOIN b CROSS JOIN a AS a2
  WHERE a.x + a2.x = 4 ORDER BY a.x, b.y;
-- Mixing comma and CROSS JOIN.
SELECT count(*) FROM a, b CROSS JOIN a AS a3 WHERE a3.x = a.x;
-- A cross join with a single-row table just widens each row.
CREATE TABLE one(k TEXT);
INSERT INTO one VALUES ('only');
SELECT x, k FROM a CROSS JOIN one ORDER BY x;
-- Empty right side gives an empty product.
DELETE FROM one;
SELECT x, k FROM a CROSS JOIN one;
SELECT count(*) FROM one CROSS JOIN a;
-- Aggregates over a cross product.
SELECT y, sum(x), count(*) FROM a CROSS JOIN b GROUP BY y ORDER BY y;
-- Error: ON clause referencing an unknown column.
SELECT * FROM a CROSS JOIN b ON a.z = 1;
