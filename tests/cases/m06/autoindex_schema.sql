-- UNIQUE and non-INTEGER PRIMARY KEY constraints create automatic indexes
-- that appear in sqlite_schema as sqlite_autoindex_<table>_<n>, numbered in
-- the order the constraints appear. An INTEGER PRIMARY KEY is the rowid and
-- creates no index.
CREATE TABLE a(id INTEGER PRIMARY KEY, x TEXT);
CREATE TABLE b(code TEXT PRIMARY KEY, name TEXT UNIQUE);
CREATE TABLE c(p INTEGER, q INTEGER, r TEXT UNIQUE, PRIMARY KEY (p, q), UNIQUE (q, r));
CREATE TABLE d(v INT PRIMARY KEY);
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
-- Explicit indexes are listed alongside the automatic ones.
CREATE INDEX b_name ON b(name);
CREATE UNIQUE INDEX a_x ON a(x);
SELECT type, name, tbl_name FROM sqlite_schema WHERE type = 'index' ORDER BY name;
-- Automatic indexes cannot be dropped directly.
DROP INDEX sqlite_autoindex_b_1;
-- They enforce their constraints.
INSERT INTO b VALUES ('k1', 'n1');
INSERT INTO b VALUES ('k1', 'n2');
INSERT INTO b VALUES ('k2', 'n1');
INSERT INTO c VALUES (1, 1, 'r1');
INSERT INTO c VALUES (1, 1, 'r2');
INSERT INTO c VALUES (1, 2, 'r1');
INSERT INTO c VALUES (2, 1, 'r3');
SELECT p, q, r FROM c ORDER BY p, q;
-- Renaming the table renames the automatic indexes' tbl_name and names.
ALTER TABLE b RENAME TO bee;
SELECT type, name, tbl_name FROM sqlite_schema WHERE tbl_name = 'bee' ORDER BY name;
-- Dropping the table drops its automatic and explicit indexes.
DROP TABLE c;
SELECT count(*) FROM sqlite_schema WHERE tbl_name = 'c';
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
-- Names beginning with sqlite_ are reserved for user objects.
CREATE TABLE sqlite_mytable(z);
CREATE INDEX sqlite_autoindex_a_9 ON a(x);
-- The renamed table and its constraints keep working.
SELECT code, name FROM bee ORDER BY code;
INSERT INTO bee VALUES ('k3', 'n3');
SELECT count(*) FROM bee WHERE name = 'n3';
INSERT INTO d VALUES (1), ('2');
SELECT v, typeof(v) FROM d ORDER BY v;
SELECT count(*) FROM sqlite_schema WHERE type = 'index' AND name LIKE 'sqlite_autoindex%';
