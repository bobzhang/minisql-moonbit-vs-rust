-- @db file
-- AUTOINCREMENT tables make SQLite create the internal sqlite_sequence
-- table (name, seq). It is an ordinary table b-tree in the file and can be
-- queried like any table.
-- @phase sqlite
CREATE TABLE a(id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT);
CREATE TABLE b(id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT);
CREATE TABLE c(id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT);
INSERT INTO a(v) VALUES ('x'), ('y'), ('z');
DELETE FROM a WHERE id = 3;
INSERT INTO b VALUES (1000, 'big');
DELETE FROM b;
-- @phase engine
SELECT name, seq FROM sqlite_sequence ORDER BY name;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT * FROM a ORDER BY id;
SELECT count(*) FROM b;
SELECT count(*) FROM c;
SELECT seq FROM sqlite_sequence WHERE name = 'c';
SELECT a.v, s.seq FROM a JOIN sqlite_sequence s ON s.name = 'a' ORDER BY a.id;
