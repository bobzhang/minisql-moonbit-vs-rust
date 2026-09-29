-- A PRIMARY KEY that is not "INTEGER PRIMARY KEY" is an ordinary unique
-- constraint: the table still has its own separate rowid. For historical
-- reasons SQLite allows NULL in such a PRIMARY KEY column (documented).
CREATE TABLE t(code TEXT PRIMARY KEY, v INTEGER);
INSERT INTO t VALUES ('b', 1), ('a', 2);
INSERT INTO t VALUES ('a', 3);
SELECT rowid, code, v FROM t ORDER BY code;

-- NULL is allowed (and several of them).
INSERT INTO t VALUES (NULL, 4);
INSERT INTO t VALUES (NULL, 5);
SELECT rowid, code, v FROM t ORDER BY rowid;

-- INT PRIMARY KEY (not spelled INTEGER) is not a rowid alias.
CREATE TABLE i(id INT PRIMARY KEY, v TEXT);
INSERT INTO i VALUES (10, 'ten'), (20, 'twenty');
INSERT INTO i(v) VALUES ('none');
SELECT rowid, id, v FROM i ORDER BY rowid;
INSERT INTO i VALUES (10, 'dup');
-- Affinity still applies: '20' becomes 20 and collides.
INSERT INTO i VALUES ('20', 'dup2');
SELECT rowid, id, v FROM i ORDER BY rowid;
-- Non-integer values are allowed in a non-alias primary key.
INSERT INTO i VALUES ('abc', 'text key');
INSERT INTO i VALUES (1.5, 'real key');
SELECT id, typeof(id), v FROM i ORDER BY rowid;

-- A REAL primary key.
CREATE TABLE r(k REAL PRIMARY KEY);
INSERT INTO r VALUES (1), (2.5);
INSERT INTO r VALUES (1.0);
SELECT k FROM r ORDER BY k;

-- Column PRIMARY KEY with COLLATE NOCASE.
CREATE TABLE c(name TEXT PRIMARY KEY COLLATE NOCASE);
INSERT INTO c VALUES ('Zed');
INSERT INTO c VALUES ('zed');
SELECT name FROM c;
SELECT name FROM c WHERE name = 'ZED';

-- Only one PRIMARY KEY per table.
CREATE TABLE bad(a PRIMARY KEY, b PRIMARY KEY);
