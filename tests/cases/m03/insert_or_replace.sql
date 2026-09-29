-- INSERT OR REPLACE / REPLACE INTO: rows that would violate a UNIQUE or
-- PRIMARY KEY constraint are deleted first, then the new row is inserted.
CREATE TABLE t(id INTEGER PRIMARY KEY, code TEXT UNIQUE, v TEXT);
INSERT INTO t VALUES (1, 'a', 'one'), (2, 'b', 'two'), (3, 'c', 'three');

-- Conflict on the primary key.
INSERT OR REPLACE INTO t VALUES (1, 'a2', 'uno');
SELECT id, code, v FROM t ORDER BY id;
-- Conflict on the UNIQUE column: the old row (id 2) disappears and the new
-- row gets its own id.
INSERT OR REPLACE INTO t VALUES (10, 'b', 'dos');
SELECT id, code, v FROM t ORDER BY id;
-- A new row that conflicts with two different rows replaces both.
INSERT OR REPLACE INTO t VALUES (3, 'a2', 'both');
SELECT id, code, v FROM t ORDER BY id;
-- No conflict: plain insert.
INSERT OR REPLACE INTO t VALUES (4, 'd', 'four');
SELECT id, code, v FROM t ORDER BY id;

-- With no explicit id, the replacement gets a fresh rowid.
INSERT OR REPLACE INTO t(code, v) VALUES ('d', 'new four');
SELECT id, code, v FROM t ORDER BY id;

-- Omitted columns get defaults, not the old row's values.
CREATE TABLE d(k TEXT PRIMARY KEY, a DEFAULT 'dflt', b);
INSERT INTO d VALUES ('x', 'A', 'B');
INSERT OR REPLACE INTO d(k, b) VALUES ('x', 'B2');
SELECT k, a, b FROM d;

-- Multi-row: later rows can replace earlier rows of the same statement.
CREATE TABLE m(k INTEGER PRIMARY KEY, v TEXT);
INSERT OR REPLACE INTO m VALUES (1, 'first'), (2, 'second'), (1, 'third');
SELECT k, v FROM m ORDER BY k;

-- REPLACE does not help with NOT NULL (no default) or CHECK failures.
CREATE TABLE c(k INTEGER PRIMARY KEY, v INTEGER NOT NULL CHECK (v > 0));
INSERT INTO c VALUES (1, 5);
INSERT OR REPLACE INTO c VALUES (1, NULL);
INSERT OR REPLACE INTO c VALUES (1, -1);
SELECT k, v FROM c;
INSERT OR REPLACE INTO c VALUES (1, 6);
SELECT k, v FROM c;

-- Multi-column UNIQUE.
CREATE TABLE p(a, b, v, UNIQUE(a, b));
INSERT INTO p VALUES (1, 1, 'x'), (1, 2, 'y');
INSERT OR REPLACE INTO p VALUES (1, 2, 'z');
SELECT a, b, v FROM p ORDER BY a, b;
INSERT OR REPLACE INTO p VALUES (1, NULL, 'n1'), (1, NULL, 'n2');
SELECT a, b, v FROM p ORDER BY a, b, v;
