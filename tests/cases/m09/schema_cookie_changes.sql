-- @db file
-- The schema cookie (header offset 40) must change whenever the engine
-- changes the schema, so that SQLite connections know to reload it. The
-- value is recorded by SQLite before and compared after each engine phase.
-- Only "did it increase" is checked, not the exact value.
-- @phase sqlite
CREATE TABLE cookie(v INTEGER);
INSERT INTO cookie SELECT schema_version FROM pragma_schema_version;
-- @phase engine
CREATE TABLE t(a INTEGER);
INSERT INTO t VALUES (1);
-- @phase sqlite
SELECT (SELECT schema_version FROM pragma_schema_version) > v FROM cookie;
UPDATE cookie SET v = (SELECT schema_version FROM pragma_schema_version);
-- @phase engine
CREATE INDEX t_a ON t(a);
-- @phase sqlite
SELECT (SELECT schema_version FROM pragma_schema_version) > v FROM cookie;
UPDATE cookie SET v = (SELECT schema_version FROM pragma_schema_version);
-- @phase engine
DROP INDEX t_a;
ALTER TABLE t ADD COLUMN b TEXT;
-- @phase sqlite
SELECT (SELECT schema_version FROM pragma_schema_version) > v FROM cookie;
UPDATE cookie SET v = (SELECT schema_version FROM pragma_schema_version);
PRAGMA integrity_check;
SELECT * FROM t;
