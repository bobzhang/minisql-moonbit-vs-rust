-- Views are bound to their base tables by name when they are used, not when
-- they are created. Dropping a table used by a view is allowed; the view then
-- fails when queried, and works again once a table with that name exists.
CREATE TABLE t(a INTEGER, b TEXT);
INSERT INTO t VALUES (1, 'one'), (2, 'two');
CREATE VIEW v AS SELECT a, b FROM t WHERE a > 0;
CREATE VIEW vv AS SELECT count(*) AS n FROM v;
SELECT * FROM v ORDER BY a;
SELECT * FROM vv;

DROP TABLE t;
-- The views still exist in the schema...
SELECT type, name FROM sqlite_schema ORDER BY name;
-- ...but using them fails (directly or through another view).
SELECT * FROM v;
SELECT * FROM vv;
SELECT count(*) FROM (SELECT * FROM v);
-- Recreate the table with the needed columns: the views work again and see the new data.
CREATE TABLE t(a INTEGER, b TEXT, c TEXT);
INSERT INTO t VALUES (5, 'five', 'extra'), (-1, 'neg', 'x');
SELECT * FROM v ORDER BY a;
SELECT * FROM vv;
-- Dropping an inner view breaks the outer one in the same way.
DROP VIEW v;
SELECT * FROM vv;
CREATE VIEW v AS SELECT 1 AS a UNION ALL SELECT 2 UNION ALL SELECT 3;
SELECT * FROM vv;
-- A view over a missing table can even be created; it fails only when used.
CREATE VIEW later AS SELECT x FROM not_yet;
SELECT * FROM later;
CREATE TABLE not_yet(x INTEGER);
INSERT INTO not_yet VALUES (42);
SELECT * FROM later;
-- Recreating the table without a referenced column makes the view fail.
DROP TABLE not_yet;
CREATE TABLE not_yet(y INTEGER);
SELECT * FROM later;
-- A view with SELECT * picks up the columns the table has at query time.
CREATE TABLE w(p INTEGER);
INSERT INTO w VALUES (1);
CREATE VIEW wstar AS SELECT * FROM w;
ALTER TABLE w ADD COLUMN q TEXT DEFAULT 'added';
SELECT * FROM wstar;
