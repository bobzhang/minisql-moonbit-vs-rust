-- @db file
-- A column declared exactly "INTEGER PRIMARY KEY" is an alias for the
-- rowid: SQLite stores NULL in its record slot and the value is the cell's
-- rowid key. Other spellings (INT PRIMARY KEY, BIGINT PRIMARY KEY, and the
-- SQLite quirk INTEGER PRIMARY KEY DESC) are ordinary columns stored in the
-- record, with a separate rowid and an sqlite_autoindex.
-- @phase sqlite
CREATE TABLE a(id INTEGER PRIMARY KEY, v TEXT);
CREATE TABLE b("Id" integer primary key autoincrement, v TEXT);
CREATE TABLE c(v TEXT, id INTEGER, PRIMARY KEY(id));
CREATE TABLE d(id INTEGER NOT NULL PRIMARY KEY ASC, v TEXT);
CREATE TABLE e(id INT PRIMARY KEY, v TEXT);
CREATE TABLE f(id BIGINT PRIMARY KEY, v TEXT);
CREATE TABLE g(id INTEGER PRIMARY KEY DESC, v TEXT);
INSERT INTO a VALUES (10, 'a10'), (20, 'a20'), (5, 'a5');
INSERT INTO a(v) VALUES ('a-next');
INSERT INTO b(v) VALUES ('b1'), ('b2');
INSERT INTO b VALUES (100, 'b100');
INSERT INTO c VALUES ('c7', 7), ('c3', 3);
INSERT INTO d VALUES (-5, 'd-5'), (0, 'd0');
INSERT INTO e VALUES (10, 'e10'), (20, 'e20'), (5, 'e5');
INSERT INTO f VALUES (10, 'f10'), (5, 'f5');
INSERT INTO g VALUES (10, 'g10'), (5, 'g5');
-- @phase engine
SELECT rowid, id, v FROM a ORDER BY id;
SELECT rowid, Id, v FROM b ORDER BY rowid;
SELECT rowid, id, v FROM c ORDER BY id;
SELECT _rowid_, oid, id, v FROM d ORDER BY id;
-- Not aliases: the rowid is independent of id.
SELECT rowid, id, v FROM e ORDER BY rowid;
SELECT rowid, id, v FROM f ORDER BY rowid;
SELECT rowid, id, v FROM g ORDER BY rowid;
SELECT typeof(id) FROM a WHERE id = 10;
SELECT v FROM a WHERE rowid = 20;
SELECT v FROM e WHERE id = 20;
SELECT v FROM e WHERE rowid = 2;
SELECT id FROM g WHERE id > 6;
SELECT count(*) FROM a WHERE id BETWEEN 6 AND 20;
SELECT max(id), max(rowid) FROM a;
SELECT a.v, e.v FROM a JOIN e ON a.id = e.id ORDER BY a.id;
