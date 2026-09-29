-- A statement that fails leaves no partial effects (with the default ABORT
-- resolution): all rows it inserted, updated or deleted before the error are
-- undone. Later statements run normally.
CREATE TABLE t(id INTEGER PRIMARY KEY, u TEXT UNIQUE, n INTEGER NOT NULL CHECK (n < 100));
INSERT INTO t VALUES (1, 'a', 1), (2, 'b', 2);

-- Multi-row INSERT failing on the 3rd row (UNIQUE): nothing is inserted.
INSERT INTO t VALUES (3, 'c', 3), (4, 'd', 4), (5, 'a', 5), (6, 'f', 6);
SELECT id, u, n FROM t ORDER BY id;
-- ...failing on the last row (NOT NULL).
INSERT INTO t VALUES (3, 'c', 3), (4, 'd', NULL);
SELECT id, u, n FROM t ORDER BY id;
-- ...failing on a CHECK.
INSERT INTO t VALUES (3, 'c', 3), (4, 'd', 400);
SELECT id, u, n FROM t ORDER BY id;
-- ...failing on a primary key collision within the statement itself.
INSERT INTO t VALUES (7, 'g', 7), (7, 'h', 8);
SELECT id, u, n FROM t ORDER BY id;
-- ...failing on a datatype mismatch.
INSERT INTO t VALUES (8, 'i', 8), ('x', 'j', 9);
SELECT id, u, n FROM t ORDER BY id;

-- The rowid counter is not advanced by a failed statement.
INSERT INTO t(u, n) VALUES ('k', 10);
SELECT id, u, n FROM t ORDER BY id;

-- INSERT ... SELECT failing midway.
CREATE TABLE src(u TEXT, n INTEGER);
INSERT INTO src VALUES ('p', 1), ('q', 2), ('r', 200);
INSERT INTO t(u, n) SELECT u, n FROM src;
SELECT id, u, n FROM t ORDER BY id;

-- UPDATE touching several rows where one fails: none are changed.
UPDATE t SET n = n * 30;
SELECT id, u, n FROM t ORDER BY id;
UPDATE t SET u = 'same' WHERE id >= 1;
SELECT id, u, n FROM t ORDER BY id;

-- A runtime error in an expression (integer overflow in abs) also aborts.
CREATE TABLE big(v INTEGER);
INSERT INTO big VALUES (1), (2);
INSERT INTO big SELECT abs(-9223372036854775808);
SELECT v FROM big ORDER BY v;

-- A failed statement does not touch last_insert_rowid() either.
SELECT last_insert_rowid();

-- Statements that succeed after the failures behave normally.
UPDATE t SET n = n + 1 WHERE id <= 2;
SELECT id, u, n FROM t ORDER BY id;
DELETE FROM t WHERE u = 'k';
SELECT id, u, n FROM t ORDER BY id;
INSERT INTO t VALUES (3, 'c', 3), (4, 'd', 4);
SELECT id, u, n FROM t ORDER BY id;
DELETE FROM t WHERE id >= 3;

-- After all of this, a valid multi-row statement works.
INSERT INTO t(u, n) VALUES ('x', 1), ('y', 2);
SELECT id, u, n FROM t ORDER BY id;
