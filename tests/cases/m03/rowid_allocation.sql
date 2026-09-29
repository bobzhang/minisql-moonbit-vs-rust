-- Automatic rowid assignment: one more than the largest rowid currently in
-- the table (1 for an empty table). Without AUTOINCREMENT, deleted rowids at
-- the top can be reused.
CREATE TABLE t(v);
INSERT INTO t VALUES ('a'), ('b'), ('c');
SELECT rowid, v FROM t ORDER BY rowid;

-- Deleting a middle row does not affect allocation.
DELETE FROM t WHERE v = 'b';
INSERT INTO t VALUES ('d');
SELECT rowid, v FROM t ORDER BY rowid;

-- Deleting the max row lets its rowid be reused.
DELETE FROM t WHERE v = 'd';
INSERT INTO t VALUES ('e');
SELECT rowid, v FROM t ORDER BY rowid;

-- After emptying the table, numbering starts over at 1.
DELETE FROM t;
INSERT INTO t VALUES ('f');
SELECT rowid, v FROM t ORDER BY rowid;

-- An explicit large rowid moves the maximum.
INSERT INTO t(rowid, v) VALUES (1000, 'g');
INSERT INTO t VALUES ('h');
SELECT rowid, v FROM t ORDER BY rowid;
-- An explicit smaller rowid does not.
INSERT INTO t(rowid, v) VALUES (500, 'i');
INSERT INTO t VALUES ('j');
SELECT rowid, v FROM t ORDER BY rowid;

-- If all rowids are negative, the next one is still max + 1.
CREATE TABLE n(id INTEGER PRIMARY KEY, v);
INSERT INTO n VALUES (-10, 'x');
INSERT INTO n(v) VALUES ('y');
SELECT id, v FROM n ORDER BY id;
INSERT INTO n VALUES (0, 'zero');
INSERT INTO n(v) VALUES ('z');
SELECT id, v FROM n ORDER BY id;

-- Multi-row inserts allocate consecutively in VALUES order.
CREATE TABLE m(id INTEGER PRIMARY KEY, v);
INSERT INTO m(v) VALUES ('p'), ('q'), ('r');
INSERT INTO m VALUES (NULL, 's'), (10, 't'), (NULL, 'u');
SELECT id, v FROM m ORDER BY id;

-- INSERT ... SELECT allocates in the SELECT's order.
CREATE TABLE s(id INTEGER PRIMARY KEY, v);
INSERT INTO s(v) SELECT v FROM m ORDER BY v DESC;
SELECT id, v FROM s ORDER BY id;
