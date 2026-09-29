-- UNIQUE constraints compare values with the column's collation.
CREATE TABLE t(name TEXT UNIQUE COLLATE NOCASE, tag TEXT);
INSERT INTO t VALUES ('Alice', 't1');
-- 'ALICE' equals 'Alice' under NOCASE.
INSERT INTO t VALUES ('ALICE', 't2');
INSERT INTO t VALUES ('alice ', 't3');
SELECT name, tag FROM t ORDER BY tag;

-- RTRIM: trailing spaces are ignored.
CREATE TABLE r(s TEXT COLLATE RTRIM UNIQUE);
INSERT INTO r VALUES ('abc');
INSERT INTO r VALUES ('abc   ');
INSERT INTO r VALUES ('  abc');
SELECT '[' || s || ']' FROM r ORDER BY s;

-- BINARY (default): case-sensitive.
CREATE TABLE b(s TEXT UNIQUE);
INSERT INTO b VALUES ('abc'), ('ABC'), ('abc ');
SELECT '[' || s || ']' FROM b ORDER BY s;

-- A multi-column UNIQUE uses each column's own collation.
CREATE TABLE m(a TEXT COLLATE NOCASE, b TEXT, UNIQUE(a, b));
INSERT INTO m VALUES ('x', 'y');
-- Same under NOCASE for a, identical b: conflict.
INSERT INTO m VALUES ('X', 'y');
-- b is BINARY: different.
INSERT INTO m VALUES ('X', 'Y');
SELECT a, b FROM m ORDER BY b, a;

-- UPDATE is checked the same way.
INSERT INTO t VALUES ('Bob', 't4');
UPDATE t SET name = 'bOB' WHERE tag = 't1';
SELECT name, tag FROM t ORDER BY tag;
-- Changing only the case of a row's own value is fine.
UPDATE t SET name = 'BOB' WHERE tag = 't4';
SELECT name, tag FROM t ORDER BY tag;

-- UNIQUE on a NOCASE column with a table-level constraint.
CREATE TABLE k(code TEXT COLLATE NOCASE, UNIQUE(code));
INSERT INTO k VALUES ('ab'), ('cd');
INSERT INTO k VALUES ('CD');
SELECT code FROM k ORDER BY code;
