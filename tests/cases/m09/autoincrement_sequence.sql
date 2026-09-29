-- @db file
-- AUTOINCREMENT tables written by the engine. The first such table creates
-- the internal table sqlite_sequence(name, seq) in the schema; each insert
-- records the largest rowid ever used, which survives deletes. SQLite and
-- the engine continue the same sequences across processes.
-- @phase engine
CREATE TABLE a(id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT);
CREATE TABLE b(id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT);
CREATE TABLE plain(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO a(v) VALUES ('a1'), ('a2'), ('a3');
DELETE FROM a WHERE id = 3;
INSERT INTO b VALUES (100, 'b100');
DELETE FROM b;
INSERT INTO plain(v) VALUES ('p1'), ('p2');
DELETE FROM plain WHERE id = 2;
SELECT name, seq FROM sqlite_sequence ORDER BY name;
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT name, seq FROM sqlite_sequence ORDER BY name;
INSERT INTO a(v) VALUES ('a-sqlite');
INSERT INTO b(v) VALUES ('b-sqlite');
INSERT INTO plain(v) VALUES ('p-sqlite');
SELECT * FROM a ORDER BY id;
SELECT * FROM b ORDER BY id;
SELECT * FROM plain ORDER BY id;
-- @phase engine
INSERT INTO a(v) VALUES ('a-engine');
INSERT INTO b(id, v) VALUES (50, 'b50');
INSERT INTO b(v) VALUES ('b-engine');
SELECT * FROM a ORDER BY id;
SELECT * FROM b ORDER BY id;
SELECT name, seq FROM sqlite_sequence ORDER BY name;
CREATE TABLE c(id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT);
-- @phase sqlite
PRAGMA integrity_check;
SELECT name, seq FROM sqlite_sequence ORDER BY name;
INSERT INTO c(v) VALUES ('c1');
SELECT name, seq FROM sqlite_sequence ORDER BY name;
-- @phase engine
DROP TABLE a;
INSERT INTO c(v) VALUES ('c2');
SELECT name, seq FROM sqlite_sequence ORDER BY name;
SELECT * FROM c ORDER BY id;
-- @phase sqlite
PRAGMA integrity_check;
SELECT name, seq FROM sqlite_sequence ORDER BY name;
