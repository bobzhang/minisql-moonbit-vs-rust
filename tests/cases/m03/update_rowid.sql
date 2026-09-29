-- Updating the rowid and INTEGER PRIMARY KEY columns.
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO t VALUES (1, 'a'), (2, 'b'), (5, 'c');

-- Move a row to a new key.
UPDATE t SET id = 10 WHERE id = 1;
SELECT rowid, id, v FROM t ORDER BY id;
-- Update through the rowid alias names.
UPDATE t SET rowid = 20 WHERE v = 'b';
SELECT rowid, id, v FROM t ORDER BY id;
UPDATE t SET oid = oid + 1 WHERE v = 'c';
SELECT _rowid_, v FROM t ORDER BY 1;

-- Text that looks like an integer is converted.
UPDATE t SET id = '30' WHERE v = 'a';
SELECT id, typeof(id), v FROM t ORDER BY id;
-- A real with an integral value is converted.
UPDATE t SET id = 40.0 WHERE v = 'a';
SELECT id, typeof(id), v FROM t ORDER BY id;

-- Errors: collision with an existing key, non-integer values, NULL.
UPDATE t SET id = 20 WHERE v = 'a';
UPDATE t SET id = 'abc' WHERE v = 'a';
UPDATE t SET id = 1.5 WHERE v = 'a';
UPDATE t SET id = NULL WHERE v = 'a';
SELECT id, v FROM t ORDER BY id;

-- Rowid of a table without an INTEGER PRIMARY KEY can be updated too.
CREATE TABLE r(x);
INSERT INTO r VALUES ('p'), ('q');
UPDATE r SET rowid = rowid * 100;
SELECT rowid, x FROM r ORDER BY rowid;
UPDATE r SET rowid = -7 WHERE x = 'q';
SELECT rowid, x FROM r ORDER BY rowid;
UPDATE r SET rowid = 100 WHERE x = 'q';
SELECT rowid, x FROM r ORDER BY rowid;

-- Next automatic rowid is based on the new maximum.
INSERT INTO t(v) VALUES ('new');
SELECT id, v FROM t ORDER BY id;
INSERT INTO r VALUES ('s');
SELECT rowid, x FROM r ORDER BY rowid;
