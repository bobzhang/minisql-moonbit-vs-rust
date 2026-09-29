-- A column declared exactly "INTEGER PRIMARY KEY" is an alias for the rowid.
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO t VALUES (5, 'five');
INSERT INTO t(name) VALUES ('auto');
INSERT INTO t VALUES (NULL, 'null means auto');
SELECT id, rowid, oid, _rowid_, name FROM t ORDER BY id;
-- SELECT * shows the alias column.
SELECT * FROM t ORDER BY id;

-- The alias always holds an integer: convertible values are converted.
INSERT INTO t VALUES ('20', 'text');
INSERT INTO t VALUES (30.0, 'real');
INSERT INTO t VALUES (' 40 ', 'padded');
SELECT id, typeof(id), name FROM t ORDER BY id;
-- Non-convertible values are a datatype mismatch.
INSERT INTO t VALUES ('abc', 'bad');
INSERT INTO t VALUES (1.5, 'bad');
INSERT INTO t VALUES (x'01', 'bad');
-- Duplicate key.
INSERT INTO t VALUES (5, 'dup');
SELECT id, name FROM t ORDER BY id;

-- Setting rowid and the alias refer to the same value.
INSERT INTO t(rowid, name) VALUES (100, 'via rowid');
SELECT id, name FROM t WHERE id = 100;

-- Case variations in the type name still make it an alias.
CREATE TABLE c(k integer primary key, v);
INSERT INTO c(v) VALUES ('x'), ('y');
SELECT k, rowid, v FROM c ORDER BY k;

-- INT PRIMARY KEY, BIGINT PRIMARY KEY and "INTEGER PRIMARY KEY DESC" are NOT
-- aliases: they get NULL when omitted and the rowid is separate.
CREATE TABLE n1(k INT PRIMARY KEY, v);
CREATE TABLE n2(k BIGINT PRIMARY KEY, v);
CREATE TABLE n3(k INTEGER PRIMARY KEY DESC, v);
INSERT INTO n1(v) VALUES ('a');
INSERT INTO n2(v) VALUES ('b');
INSERT INTO n3(v) VALUES ('c');
SELECT rowid, k, v FROM n1;
SELECT rowid, k, v FROM n2;
SELECT rowid, k, v FROM n3;
-- ...and they accept non-integer values.
INSERT INTO n1 VALUES ('text', 'd');
SELECT k, typeof(k), v FROM n1 ORDER BY v;

-- The alias column is usable in WHERE with text/real comparisons.
SELECT name FROM t WHERE id = '20';
SELECT name FROM t WHERE id = 30.0;
