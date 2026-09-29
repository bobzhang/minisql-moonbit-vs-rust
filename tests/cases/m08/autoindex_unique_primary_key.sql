-- @db file
-- UNIQUE and non-integer PRIMARY KEY constraints make SQLite create
-- sqlite_autoindex_<table>_<n> index b-trees (schema rows with NULL sql).
-- The engine must load them alongside the table; lookups on those columns
-- must return correct rows whether or not the engine uses the index.
-- @phase sqlite
PRAGMA page_size = 1024;
CREATE TABLE p(code TEXT PRIMARY KEY, name TEXT UNIQUE, a INTEGER, b INTEGER, qty INTEGER, UNIQUE(a, b));
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 5000)
INSERT INTO p SELECT printf('C%05d', (i * 7) % 5003), 'name-' || i, i % 50, i / 50, i FROM c;
CREATE TABLE pair(x TEXT, y INTEGER, note TEXT, PRIMARY KEY(x, y));
INSERT INTO pair VALUES ('a', 1, 'a1'), ('a', 2, 'a2'), ('b', 1, 'b1'), ('A', 1, 'A1');
CREATE TABLE nk(k REAL PRIMARY KEY, v TEXT);
INSERT INTO nk VALUES (1.5, 'one and a half'), (2, 'two'), (-3.25, 'negative');
-- @phase engine
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT count(*), count(DISTINCT code), sum(qty) FROM p;
SELECT code, name, a, b, qty FROM p WHERE code = 'C00700';
SELECT code FROM p WHERE name = 'name-4321';
SELECT qty FROM p WHERE a = 17 AND b = 33;
SELECT count(*) FROM p WHERE code BETWEEN 'C01000' AND 'C01999';
SELECT code FROM p ORDER BY code LIMIT 3;
SELECT code FROM p ORDER BY code DESC LIMIT 3;
SELECT name FROM p WHERE name > 'name-999' ORDER BY name;
SELECT count(*) FROM p WHERE code = 'C99999';
SELECT x, y, note FROM pair ORDER BY x, y;
SELECT note FROM pair WHERE x = 'a' AND y = 2;
SELECT k, v FROM nk ORDER BY k;
SELECT v FROM nk WHERE k = 2.0;
SELECT v FROM nk WHERE k = 1.5;
