-- INSERT OR IGNORE skips rows that violate UNIQUE, PRIMARY KEY, NOT NULL or
-- CHECK constraints and continues with the remaining rows.
CREATE TABLE t(id INTEGER PRIMARY KEY, code TEXT UNIQUE, n INTEGER NOT NULL, CHECK (n >= 0));
INSERT INTO t VALUES (1, 'a', 1);

INSERT OR IGNORE INTO t VALUES (1, 'b', 2);
INSERT OR IGNORE INTO t VALUES (2, 'a', 2);
INSERT OR IGNORE INTO t VALUES (3, 'c', NULL);
INSERT OR IGNORE INTO t VALUES (4, 'd', -1);
SELECT id, code, n FROM t ORDER BY id;

-- In a multi-row insert, only the bad rows are skipped.
INSERT OR IGNORE INTO t VALUES (5, 'e', 5), (6, 'a', 6), (7, 'g', NULL), (8, 'h', 8), (5, 'i', 9);
SELECT id, code, n FROM t ORDER BY id;
SELECT changes();

-- Duplicates within the statement itself: the first one wins.
INSERT OR IGNORE INTO t VALUES (20, 'dup', 1), (21, 'dup', 2);
SELECT id, code, n FROM t WHERE code = 'dup';

-- INSERT OR IGNORE ... SELECT.
CREATE TABLE src(id INTEGER, code TEXT, n INTEGER);
INSERT INTO src VALUES (30, 'a', 1), (31, 'x', 1), (32, 'y', -5), (33, 'z', 3);
INSERT OR IGNORE INTO t SELECT id, code, n FROM src;
SELECT id, code, n FROM t WHERE id >= 30 ORDER BY id;

-- Rows with no conflict at all are inserted normally.
INSERT OR IGNORE INTO t(code, n) VALUES ('auto', 0);
SELECT id, code FROM t WHERE code = 'auto';

-- OR IGNORE does not suppress other errors.
INSERT OR IGNORE INTO t VALUES (1, 2);
INSERT OR IGNORE INTO t VALUES ('text id', 'q', 1);
INSERT OR IGNORE INTO nosuch VALUES (1);
SELECT id, code, n FROM t ORDER BY id;

-- An IGNORE conflict clause on the constraint gives the same behaviour
-- without OR in the statement.
CREATE TABLE k(v UNIQUE ON CONFLICT IGNORE);
INSERT INTO k VALUES (1), (2), (1), (3), (2);
SELECT v FROM k ORDER BY v;
