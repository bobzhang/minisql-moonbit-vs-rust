-- Table-level PRIMARY KEY (a, b): a composite key.
CREATE TABLE t(a INTEGER, b TEXT, v, PRIMARY KEY (a, b));
INSERT INTO t VALUES (1, 'x', 'r1'), (1, 'y', 'r2'), (2, 'x', 'r3');
INSERT INTO t VALUES (1, 'x', 'dup');
SELECT a, b, v FROM t ORDER BY a, b;

-- Rows still have ordinary rowids.
SELECT rowid, v FROM t ORDER BY rowid;

-- Update into a used key fails, into a free key works.
UPDATE t SET b = 'y' WHERE v = 'r1';
UPDATE t SET b = 'z' WHERE v = 'r1';
SELECT a, b, v FROM t ORDER BY a, b;

-- NULL components never collide.
INSERT INTO t VALUES (NULL, 'x', 'n1'), (NULL, 'x', 'n2');
SELECT a, b, v FROM t WHERE a IS NULL ORDER BY v;

-- A single-column table-level PRIMARY KEY on an INTEGER column IS a rowid alias.
CREATE TABLE s(id INTEGER, name TEXT, PRIMARY KEY(id));
INSERT INTO s(name) VALUES ('auto1'), ('auto2');
INSERT INTO s VALUES (10, 'ten');
INSERT INTO s(name) VALUES ('auto3');
SELECT rowid, id, name FROM s ORDER BY id;
INSERT INTO s VALUES (10, 'dup');
INSERT INTO s VALUES ('x', 'bad');
SELECT id, name FROM s ORDER BY id;

-- PRIMARY KEY with column order different from the table.
CREATE TABLE r(a, b, c, PRIMARY KEY (c, a));
INSERT INTO r VALUES (1, 1, 1), (1, 2, 2), (2, 1, 1);
INSERT INTO r VALUES (1, 9, 1);
SELECT a, b, c FROM r ORDER BY a, c;

-- Declared ASC/DESC in the key list parse fine.
CREATE TABLE d(a, b, PRIMARY KEY (a DESC, b ASC));
INSERT INTO d VALUES (1, 2), (1, 3);
INSERT INTO d VALUES (1, 2);
SELECT a, b FROM d ORDER BY a, b;

-- Deleting frees the key.
DELETE FROM d WHERE b = 2;
INSERT INTO d VALUES (1, 2);
SELECT a, b FROM d ORDER BY a, b;

-- Unknown column in the key is an error.
CREATE TABLE bad(a, PRIMARY KEY (nosuch));
