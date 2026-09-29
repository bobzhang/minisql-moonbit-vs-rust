-- VALUES as a FROM source (in parentheses). Its columns are named column1,
-- column2, ...; a derived-table alias can qualify them.
SELECT * FROM (VALUES (1, 'a'), (2, 'b')) ORDER BY 1;
SELECT column2, column1 FROM (VALUES (1, 'a'), (2, 'b')) ORDER BY column1 DESC;
SELECT v.column1 * 10 FROM (VALUES (1), (2), (3)) AS v ORDER BY 1;
SELECT v.column1 FROM (VALUES (1), (2), (3)) v WHERE v.column1 >= 2 ORDER BY v.column1;
-- Aggregates over VALUES.
SELECT count(*), sum(column1), avg(column1), max(column2) FROM (VALUES (1, 'x'), (2, 'z'), (6, 'y'));
SELECT column1, count(*) FROM (VALUES ('a'), ('b'), ('a'), ('a')) GROUP BY column1 ORDER BY column1;
-- Joining VALUES sources with each other and with tables.
SELECT a.column1, b.column1 FROM (VALUES (1), (2)) a CROSS JOIN (VALUES ('x'), ('y')) b ORDER BY 1, 2;
SELECT column1 FROM (VALUES (1), (2), (3)) JOIN (VALUES (2), (3), (4)) USING (column1) ORDER BY 1;
CREATE TABLE emp(name TEXT, code INTEGER);
INSERT INTO emp VALUES ('ann', 1), ('bo', 2), ('cy', 3);
SELECT name, m.column2 FROM emp JOIN (VALUES (1, 'one'), (3, 'three')) m ON m.column1 = emp.code ORDER BY name;
SELECT name, m.column2 FROM emp LEFT JOIN (VALUES (1, 'one'), (3, 'three')) m ON m.column1 = emp.code ORDER BY name;
-- Renaming VALUES columns through an outer derived table.
SELECT id, label FROM (SELECT column1 AS id, column2 AS label FROM (VALUES (5, 'five'), (4, 'four'))) ORDER BY id;
-- Sorting, DISTINCT and LIMIT over a VALUES source.
SELECT DISTINCT column1 FROM (VALUES (3), (1), (3), (2)) ORDER BY column1 DESC;
SELECT column1 FROM (VALUES (3), (1), (4), (1), (5)) ORDER BY column1 LIMIT 2 OFFSET 1;
-- VALUES with a NULL column in every row still has that column.
SELECT column1, column2 IS NULL FROM (VALUES (1, NULL), (2, NULL)) ORDER BY column1;
-- INSERT from a VALUES source through SELECT.
CREATE TABLE t(a INTEGER, b TEXT);
INSERT INTO t SELECT column1, column2 FROM (VALUES (1, 'p'), (2, 'q')) WHERE column1 > 1;
SELECT * FROM t;
-- Error: column3 does not exist in a two-column VALUES.
SELECT column3 FROM (VALUES (1, 2));
