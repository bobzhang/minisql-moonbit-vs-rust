-- INTEGER PRIMARY KEY AUTOINCREMENT: new ids are larger than any id ever
-- used in the table, so deleted ids are never reused.
CREATE TABLE a(id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT);
INSERT INTO a(v) VALUES ('x'), ('y'), ('z');
SELECT id, v FROM a ORDER BY id;

-- Deleting the top row does not allow its id to come back.
DELETE FROM a WHERE id = 3;
INSERT INTO a(v) VALUES ('w');
SELECT id, v FROM a ORDER BY id;

-- Deleting everything does not reset the counter.
DELETE FROM a;
INSERT INTO a(v) VALUES ('after clear');
SELECT id, v FROM a ORDER BY id;

-- An explicit larger id raises the counter.
INSERT INTO a VALUES (100, 'hundred');
DELETE FROM a WHERE id = 100;
INSERT INTO a(v) VALUES ('after hundred');
SELECT id, v FROM a ORDER BY id;

-- An explicit smaller (even negative) id is allowed and does not lower it.
INSERT INTO a VALUES (-3, 'negative'), (50, 'fifty');
INSERT INTO a(v) VALUES ('next');
SELECT id, v FROM a ORDER BY id;

-- NULL id means "allocate".
INSERT INTO a VALUES (NULL, 'null id');
SELECT id, v FROM a ORDER BY id DESC LIMIT 1;

-- A failed insert does not consume an id.
CREATE TABLE b(id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT NOT NULL);
INSERT INTO b(v) VALUES ('one');
INSERT INTO b(v) VALUES (NULL);
INSERT INTO b(v) VALUES ('two');
SELECT id, v FROM b ORDER BY id;

-- Dropping the table and recreating it starts from 1 again.
DROP TABLE b;
CREATE TABLE b(id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT NOT NULL);
INSERT INTO b(v) VALUES ('fresh');
SELECT id, v FROM b;

-- Contrast: without AUTOINCREMENT the top id is reused.
CREATE TABLE c(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO c(v) VALUES ('x'), ('y'), ('z');
DELETE FROM c WHERE id = 3;
INSERT INTO c(v) VALUES ('w');
SELECT id, v FROM c ORDER BY id;

-- AUTOINCREMENT is only allowed on an INTEGER PRIMARY KEY.
CREATE TABLE bad1(id INT PRIMARY KEY AUTOINCREMENT);
CREATE TABLE bad2(id TEXT PRIMARY KEY AUTOINCREMENT);
