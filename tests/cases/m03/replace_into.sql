-- REPLACE INTO is shorthand for INSERT OR REPLACE INTO, and supports the
-- same forms: column lists, multiple rows, SELECT, DEFAULT VALUES.
CREATE TABLE kv(k TEXT PRIMARY KEY, v INTEGER);
REPLACE INTO kv VALUES ('a', 1);
REPLACE INTO kv VALUES ('b', 2), ('c', 3);
SELECT k, v FROM kv ORDER BY k;

REPLACE INTO kv VALUES ('a', 10);
SELECT k, v FROM kv ORDER BY k;

-- Column list.
REPLACE INTO kv(v, k) VALUES (20, 'b');
SELECT k, v FROM kv ORDER BY k;

-- Replace with rows from a SELECT.
CREATE TABLE upd(k TEXT, v INTEGER);
INSERT INTO upd VALUES ('c', 30), ('d', 40);
REPLACE INTO kv SELECT k, v FROM upd;
SELECT k, v FROM kv ORDER BY k;

-- Rowids change when a row is replaced (it is deleted and reinserted).
CREATE TABLE r(name TEXT UNIQUE, n INTEGER);
INSERT INTO r VALUES ('x', 1), ('y', 2);
SELECT rowid, name, n FROM r ORDER BY rowid;
REPLACE INTO r VALUES ('x', 100);
SELECT rowid, name, n FROM r ORDER BY rowid;

-- NOCASE unique column: 'X' replaces 'x'.
CREATE TABLE ci(name TEXT UNIQUE COLLATE NOCASE, n INTEGER);
INSERT INTO ci VALUES ('x', 1);
REPLACE INTO ci VALUES ('X', 2);
SELECT name, n FROM ci;

-- REPLACE INTO ... DEFAULT VALUES.
CREATE TABLE dv(id INTEGER PRIMARY KEY, v DEFAULT 'd');
REPLACE INTO dv DEFAULT VALUES;
REPLACE INTO dv DEFAULT VALUES;
SELECT id, v FROM dv ORDER BY id;

-- On a table without any unique constraint REPLACE is just INSERT.
CREATE TABLE plain(a);
REPLACE INTO plain VALUES (1), (1);
SELECT a FROM plain ORDER BY a;

-- Errors that REPLACE does not resolve.
REPLACE INTO kv VALUES ('e');
REPLACE INTO nosuch VALUES (1);
