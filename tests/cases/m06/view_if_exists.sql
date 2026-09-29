-- CREATE VIEW IF NOT EXISTS and DROP VIEW [IF EXISTS].
CREATE TABLE t(a INTEGER);
INSERT INTO t VALUES (1), (2), (3);

CREATE VIEW IF NOT EXISTS big AS SELECT a FROM t WHERE a > 1;
SELECT a FROM big ORDER BY a;
-- The existing definition is kept; the new one is ignored.
CREATE VIEW IF NOT EXISTS big AS SELECT a FROM t WHERE a > 100;
SELECT a FROM big ORDER BY a;
-- Without IF NOT EXISTS: error.
CREATE VIEW big AS SELECT 1;
-- IF NOT EXISTS where the name is a table: silently does nothing.
CREATE VIEW IF NOT EXISTS t AS SELECT 1;
SELECT count(*) FROM t;
-- DROP VIEW, then the name is free.
DROP VIEW big;
SELECT count(*) FROM sqlite_schema WHERE type = 'view';
SELECT * FROM big;
DROP VIEW big;
DROP VIEW IF EXISTS big;
-- Re-create with a different definition.
CREATE VIEW big AS SELECT a * 10 AS a FROM t;
SELECT a FROM big ORDER BY a;
-- Names are case-insensitive.
DROP VIEW IF EXISTS BIG;
SELECT count(*) FROM sqlite_schema WHERE type = 'view';
-- A dropped view's name can be used for a table and vice versa.
CREATE TABLE big(x);
INSERT INTO big VALUES ('table now');
SELECT x FROM big;
DROP TABLE big;
CREATE VIEW big AS SELECT 'view again';
SELECT * FROM big;
-- DROP VIEW does not affect the base table.
DROP VIEW big;
SELECT a FROM t ORDER BY a;
SELECT type, name FROM sqlite_schema ORDER BY name;
