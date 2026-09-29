-- @db file
-- CREATE TABLE ... AS SELECT by the engine: the new table's schema text is
-- generated (column names and types come from the query), and the copied
-- rows must be readable by SQLite with the right affinities.
-- @phase engine
CREATE TABLE src(id INTEGER PRIMARY KEY, name TEXT, score REAL, n INT, b BLOB, x);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 1000)
INSERT INTO src SELECT i, 'n' || i, i * 0.5, i % 7, x'AB', CASE WHEN i % 2 THEN i ELSE 'text' END FROM c;
CREATE TABLE copy1 AS SELECT * FROM src;
CREATE TABLE copy2 AS SELECT name AS "the name", score * 2 AS doubled, n + 1, count(*) OVER () AS total FROM src WHERE id <= 10;
CREATE TABLE copy3 AS SELECT n, count(*) AS cnt, sum(score) AS s FROM src GROUP BY n;
CREATE TABLE empty_copy AS SELECT * FROM src WHERE 0;
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT count(*), sum(id), sum(score), sum(n) FROM copy1;
SELECT id, name, score, n, hex(b), x, typeof(x) FROM copy1 WHERE id IN (1, 2, 1000) ORDER BY id;
SELECT * FROM copy2 ORDER BY "the name";
SELECT n, cnt, s FROM copy3 ORDER BY n;
SELECT count(*) FROM empty_copy;
INSERT INTO copy1(id, score) VALUES (1001, '2.5');
SELECT typeof(score) FROM copy1 WHERE id = 1001;
