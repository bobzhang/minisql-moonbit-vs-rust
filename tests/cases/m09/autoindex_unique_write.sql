-- @db file
-- UNIQUE and non-integer PRIMARY KEY constraints need index b-trees named
-- sqlite_autoindex_<table>_<N> (N counts from 1 in the order the
-- constraints appear) with NULL sql. SQLite checks that each constraint's
-- index exists, that integrity_check finds every row in it, and that
-- uniqueness is still enforced when SQLite inserts.
-- @phase engine
CREATE TABLE p(code TEXT PRIMARY KEY, name TEXT UNIQUE, a INTEGER, b INTEGER, qty INTEGER, UNIQUE(a, b));
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 5000)
INSERT INTO p SELECT printf('C%05d', (i * 7) % 5003), 'name-' || i, i % 50, i / 50, i FROM c;
CREATE TABLE pair(x TEXT, y INTEGER, note TEXT, PRIMARY KEY(x, y));
INSERT INTO pair VALUES ('a', 1, 'a1'), ('a', 2, 'a2'), ('b', 1, 'b1');
CREATE TABLE nk(k REAL PRIMARY KEY, v TEXT UNIQUE);
INSERT INTO nk VALUES (1.5, 'x'), (2, 'y'), (NULL, 'z'), (NULL, NULL);
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT count(*), sum(qty) FROM p;
SELECT qty FROM p INDEXED BY sqlite_autoindex_p_1 WHERE code = 'C00700';
SELECT qty FROM p INDEXED BY sqlite_autoindex_p_2 WHERE name = 'name-4321';
SELECT qty FROM p INDEXED BY sqlite_autoindex_p_3 WHERE a = 17 AND b = 33;
SELECT note FROM pair INDEXED BY sqlite_autoindex_pair_1 WHERE x = 'a' AND y = 2;
SELECT k, v FROM nk ORDER BY k, v;
INSERT INTO p VALUES ('C00700', 'new', 99, 99, 0);
INSERT INTO p VALUES ('NEW', 'name-1', 99, 99, 0);
INSERT INTO p VALUES ('NEW', 'new', 17, 33, 0);
INSERT INTO pair VALUES ('b', 1, 'dup');
INSERT INTO p VALUES ('NEW', 'new', 99, 99, 0);
PRAGMA integrity_check;
-- @phase engine
SELECT code, name, qty FROM p WHERE code = 'NEW';
INSERT INTO p VALUES ('NEW', 'newer', 98, 98, 0);
INSERT INTO p VALUES ('NEWER', 'newer', 98, 98, 1);
DELETE FROM p WHERE qty % 2 = 0;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), sum(qty) FROM p;
SELECT code FROM p INDEXED BY sqlite_autoindex_p_2 WHERE name = 'newer';
