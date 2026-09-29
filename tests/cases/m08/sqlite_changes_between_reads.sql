-- @db file
-- SQLite and the engine take turns: after each SQLite phase the engine (a
-- new process) must see the current data and schema, including objects
-- created, altered and dropped in between, and rows inserted, updated and
-- deleted.
-- @phase sqlite
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO t VALUES (1, 'a'), (2, 'b'), (3, 'c');
-- @phase engine
SELECT * FROM t ORDER BY id;
SELECT type, name FROM sqlite_schema ORDER BY name;
-- @phase sqlite
INSERT INTO t VALUES (4, 'd');
UPDATE t SET v = 'B' WHERE id = 2;
DELETE FROM t WHERE id = 1;
CREATE INDEX t_v ON t(v);
CREATE TABLE u(x INTEGER, y TEXT);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 3000)
INSERT INTO u SELECT i, 'y' || i FROM c;
-- @phase engine
SELECT * FROM t ORDER BY id;
SELECT id FROM t WHERE v = 'B';
SELECT count(*), sum(x) FROM u;
SELECT type, name FROM sqlite_schema ORDER BY name;
-- @phase sqlite
DROP INDEX t_v;
DROP TABLE u;
ALTER TABLE t ADD COLUMN w INTEGER DEFAULT 5;
ALTER TABLE t RENAME TO t2;
CREATE VIEW vt AS SELECT id, v || w AS vw FROM t2;
INSERT INTO t2 VALUES (5, 'e', 6);
-- @phase engine
SELECT * FROM t2 ORDER BY id;
SELECT * FROM vt ORDER BY id;
SELECT type, name FROM sqlite_schema ORDER BY name;
SELECT * FROM u;
SELECT * FROM t;
-- @phase sqlite
DELETE FROM t2;
-- @phase engine
SELECT count(*) FROM t2;
SELECT count(*) FROM vt;
