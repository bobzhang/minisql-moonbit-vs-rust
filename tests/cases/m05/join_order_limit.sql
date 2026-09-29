-- ORDER BY, LIMIT/OFFSET and DISTINCT applied to joined results.
CREATE TABLE p(id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE s(pid INTEGER, score INTEGER, round INTEGER);
INSERT INTO p VALUES (1, 'kim'), (2, 'lee'), (3, 'max'), (4, 'ned');
INSERT INTO s VALUES (1, 50, 1), (1, 70, 2), (2, 70, 1), (2, 40, 2), (3, 90, 1), (3, 10, 2), (4, NULL, 1);

SELECT name, score FROM p JOIN s ON s.pid = p.id ORDER BY score DESC, name LIMIT 3;
SELECT name, score FROM p JOIN s ON s.pid = p.id ORDER BY score DESC, name LIMIT 3 OFFSET 2;
SELECT name, score FROM p JOIN s ON s.pid = p.id ORDER BY score DESC, name LIMIT 2, 2;
-- NULLs sort first ascending; NULLS LAST moves them.
SELECT name, score FROM p JOIN s ON s.pid = p.id ORDER BY score, name LIMIT 2;
SELECT name, score FROM p JOIN s ON s.pid = p.id ORDER BY score NULLS LAST, name LIMIT 2;
-- ORDER BY a column that is not selected, from either side.
SELECT name FROM p JOIN s ON s.pid = p.id WHERE round = 2 ORDER BY score;
SELECT score FROM p JOIN s ON s.pid = p.id WHERE round = 1 ORDER BY name DESC;
-- ORDER BY ordinal and alias.
SELECT name AS who, score * 2 AS dbl FROM p JOIN s ON s.pid = p.id WHERE score IS NOT NULL ORDER BY 2 DESC, who LIMIT 4;
-- DISTINCT over joined columns.
SELECT DISTINCT name FROM p JOIN s ON s.pid = p.id WHERE score >= 50 ORDER BY name;
SELECT DISTINCT score FROM p JOIN s ON s.pid = p.id ORDER BY score DESC;
-- LIMIT 0 and a LIMIT larger than the result.
SELECT name FROM p JOIN s ON s.pid = p.id ORDER BY name LIMIT 0;
SELECT count(*) FROM (SELECT name FROM p JOIN s ON s.pid = p.id LIMIT 100);
-- LIMIT applies after the join, not to each input.
SELECT name, round FROM p LEFT JOIN s ON s.pid = p.id ORDER BY p.id DESC, round DESC LIMIT 3;
-- Negative LIMIT means no limit.
SELECT count(*) FROM (SELECT * FROM p JOIN s ON s.pid = p.id LIMIT -1);
