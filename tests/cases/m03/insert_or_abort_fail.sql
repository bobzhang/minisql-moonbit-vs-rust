-- ABORT (the default) undoes everything the failing statement did.
-- FAIL stops at the failing row but keeps the rows the statement already
-- changed.
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT UNIQUE);
INSERT INTO t VALUES (1, 'a');

-- Default = ABORT: no row of the statement survives.
INSERT INTO t VALUES (2, 'b'), (3, 'c'), (4, 'a'), (5, 'e');
SELECT id, v FROM t ORDER BY id;
INSERT OR ABORT INTO t VALUES (2, 'b'), (3, 'c'), (4, 'a'), (5, 'e');
SELECT id, v FROM t ORDER BY id;

-- FAIL: rows before the failing one stay, rows after it are not inserted.
INSERT OR FAIL INTO t VALUES (2, 'b'), (3, 'c'), (4, 'a'), (5, 'e');
SELECT id, v FROM t ORDER BY id;
SELECT changes();

-- FAIL with INSERT ... SELECT (rows are inserted in the SELECT's order).
CREATE TABLE src(id INTEGER, v TEXT);
INSERT INTO src VALUES (10, 'j'), (11, 'k'), (12, 'b'), (13, 'm');
INSERT OR FAIL INTO t SELECT id, v FROM src ORDER BY id;
SELECT id, v FROM t ORDER BY id;
INSERT OR ABORT INTO t SELECT id + 10, v || v FROM src ORDER BY id;
SELECT id, v FROM t ORDER BY id;

-- A constraint-level ON CONFLICT FAIL behaves the same way.
CREATE TABLE f(k INTEGER UNIQUE ON CONFLICT FAIL);
INSERT INTO f VALUES (1), (2), (1), (3);
SELECT k FROM f ORDER BY k;
-- ...and the statement's OR ABORT overrides it.
INSERT OR ABORT INTO f VALUES (4), (1), (5);
SELECT k FROM f ORDER BY k;

-- FAIL on NOT NULL.
CREATE TABLE n(x NOT NULL);
INSERT OR FAIL INTO n VALUES (1), (2), (NULL), (4);
SELECT x FROM n ORDER BY x;

-- FAIL and ABORT with no conflict insert every row.
INSERT OR FAIL INTO n VALUES (5), (6);
INSERT OR ABORT INTO n VALUES (7);
SELECT x FROM n ORDER BY x;
-- The rows kept by FAIL are real rows: they can be updated and deleted.
UPDATE t SET v = upper(v) WHERE id IN (2, 3);
DELETE FROM t WHERE id = 10;
SELECT id, v FROM t ORDER BY id;
