-- @db file
-- The very first statement in a new file creates an AUTOINCREMENT table,
-- so sqlite_sequence must be created alongside it; a bulk insert then
-- leaves the right high-water mark, and a failed insert does not change it.
-- @phase engine
CREATE TABLE log(id INTEGER PRIMARY KEY AUTOINCREMENT, msg TEXT NOT NULL);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 2500)
INSERT INTO log(msg) SELECT 'msg' || i FROM c;
INSERT INTO log(msg) VALUES ('ok'), (NULL);
DELETE FROM log WHERE id > 2000;
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT name, seq FROM sqlite_sequence;
SELECT count(*), max(id) FROM log;
INSERT INTO log(msg) VALUES ('after');
SELECT id FROM log WHERE msg = 'after';
