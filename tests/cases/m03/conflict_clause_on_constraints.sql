-- Conflict clauses written on constraints: PRIMARY KEY ... ON CONFLICT,
-- UNIQUE ... ON CONFLICT, and table-level UNIQUE(...) ON CONFLICT. They
-- apply when the statement has no OR clause.
CREATE TABLE r(id INTEGER PRIMARY KEY ON CONFLICT REPLACE, v TEXT);
INSERT INTO r VALUES (1, 'a'), (2, 'b');
INSERT INTO r VALUES (1, 'A');
SELECT id, v FROM r ORDER BY id;
-- Also applies to UPDATE.
UPDATE r SET id = 2 WHERE id = 1;
SELECT id, v FROM r ORDER BY id;

CREATE TABLE i(k TEXT PRIMARY KEY ON CONFLICT IGNORE, v TEXT);
INSERT INTO i VALUES ('x', 'first'), ('y', 'second'), ('x', 'third');
SELECT k, v FROM i ORDER BY k;

-- Table-level UNIQUE with ON CONFLICT REPLACE.
CREATE TABLE u(a, b, v, UNIQUE(a, b) ON CONFLICT REPLACE);
INSERT INTO u VALUES (1, 1, 'old'), (1, 2, 'other');
INSERT INTO u VALUES (1, 1, 'new');
SELECT a, b, v FROM u ORDER BY a, b;

-- Table-level PRIMARY KEY with ON CONFLICT IGNORE.
CREATE TABLE pk(a, b, v, PRIMARY KEY(a, b) ON CONFLICT IGNORE);
INSERT INTO pk VALUES (1, 1, 'keep'), (1, 1, 'drop'), (2, 1, 'also');
SELECT a, b, v FROM pk ORDER BY a, b;

-- Different clauses on different constraints of the same table.
CREATE TABLE mix(id INTEGER PRIMARY KEY ON CONFLICT IGNORE, email TEXT UNIQUE ON CONFLICT REPLACE, n);
INSERT INTO mix VALUES (1, 'a', 1), (2, 'b', 2);
-- Primary key conflict: ignored.
INSERT INTO mix VALUES (1, 'c', 3);
-- Email conflict: replaces row 2.
INSERT INTO mix VALUES (5, 'b', 5);
SELECT id, email, n FROM mix ORDER BY id;

-- The statement's OR clause takes precedence over the constraint clause.
INSERT OR ABORT INTO mix VALUES (1, 'z', 9);
INSERT OR IGNORE INTO mix VALUES (6, 'a', 6);
INSERT OR REPLACE INTO mix VALUES (1, 'q', 10);
SELECT id, email, n FROM mix ORDER BY id;

-- ON CONFLICT ABORT / FAIL / ROLLBACK on constraints give errors.
CREATE TABLE e(a UNIQUE ON CONFLICT ABORT, b UNIQUE ON CONFLICT FAIL, c UNIQUE ON CONFLICT ROLLBACK);
INSERT INTO e VALUES (1, 1, 1);
INSERT INTO e VALUES (1, 2, 2);
INSERT INTO e VALUES (2, 1, 2);
INSERT INTO e VALUES (2, 2, 1);
INSERT INTO e VALUES (2, 2, 2);
SELECT a, b, c FROM e ORDER BY a;

-- Upsert overrides the constraint's clause for its target.
CREATE TABLE up(k TEXT PRIMARY KEY ON CONFLICT IGNORE, n INTEGER);
INSERT INTO up VALUES ('x', 1);
INSERT INTO up VALUES ('x', 5) ON CONFLICT(k) DO UPDATE SET n = n + excluded.n;
SELECT k, n FROM up;
