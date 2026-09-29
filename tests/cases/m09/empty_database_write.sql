-- @db file
-- The engine creates objects and then drops all of them, leaving a valid
-- database with an empty schema (SQLite may see free pages, but no
-- tables). Then a new engine process adds a table to that file.
-- @phase engine
CREATE TABLE a(x INTEGER PRIMARY KEY, y TEXT UNIQUE);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 3000)
INSERT INTO a SELECT i, 'y' || i FROM c;
CREATE INDEX a_y ON a(y DESC);
CREATE VIEW va AS SELECT * FROM a;
DROP VIEW va;
DROP TABLE a;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*) FROM sqlite_schema;
-- @phase engine
SELECT count(*) FROM sqlite_schema;
CREATE TABLE b(z);
INSERT INTO b VALUES ('z');
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name FROM sqlite_schema;
SELECT * FROM b;
