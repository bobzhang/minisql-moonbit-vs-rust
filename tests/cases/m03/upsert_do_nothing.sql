-- Upsert: INSERT ... ON CONFLICT [(target)] DO NOTHING.
CREATE TABLE t(id INTEGER PRIMARY KEY, code TEXT UNIQUE, v INTEGER);
INSERT INTO t VALUES (1, 'a', 10), (2, 'b', 20);

-- Conflict on the named target: the row is skipped silently.
INSERT INTO t VALUES (3, 'a', 30) ON CONFLICT(code) DO NOTHING;
INSERT INTO t VALUES (1, 'z', 30) ON CONFLICT(id) DO NOTHING;
SELECT id, code, v FROM t ORDER BY id;

-- No target: any uniqueness conflict is ignored.
INSERT INTO t VALUES (4, 'b', 40) ON CONFLICT DO NOTHING;
INSERT INTO t VALUES (2, 'y', 40) ON CONFLICT DO NOTHING;
SELECT id, code, v FROM t ORDER BY id;

-- No conflict: the row is inserted.
INSERT INTO t VALUES (5, 'e', 50) ON CONFLICT(code) DO NOTHING;
SELECT id, code, v FROM t ORDER BY id;

-- The target must match; a conflict on a DIFFERENT constraint is an error.
INSERT INTO t VALUES (1, 'new', 60) ON CONFLICT(code) DO NOTHING;
SELECT id, code, v FROM t ORDER BY id;

-- Multi-row insert: conflicting rows are skipped, others inserted,
-- including conflicts between rows of the same statement.
INSERT INTO t VALUES (6, 'f', 60), (7, 'a', 70), (8, 'f', 80), (9, 'i', 90) ON CONFLICT(code) DO NOTHING;
SELECT id, code, v FROM t ORDER BY id;

-- DO NOTHING does not cover NOT NULL or CHECK failures.
CREATE TABLE n(k TEXT UNIQUE, x NOT NULL CHECK (x > 0));
INSERT INTO n VALUES ('a', 1);
INSERT INTO n VALUES ('a', NULL) ON CONFLICT DO NOTHING;
INSERT INTO n VALUES ('b', -1) ON CONFLICT DO NOTHING;
INSERT INTO n VALUES ('a', 5) ON CONFLICT DO NOTHING;
SELECT k, x FROM n ORDER BY k;

-- Multi-column target, written in any column order.
CREATE TABLE m(a, b, v, UNIQUE(a, b));
INSERT INTO m VALUES (1, 2, 'first');
INSERT INTO m VALUES (1, 2, 'second') ON CONFLICT(a, b) DO NOTHING;
INSERT INTO m VALUES (1, 2, 'third') ON CONFLICT(b, a) DO NOTHING;
SELECT a, b, v FROM m;

-- A target naming a column that has no unique constraint is an error.
INSERT INTO m VALUES (1, 2, 'x') ON CONFLICT(a) DO NOTHING;
INSERT INTO m VALUES (1, 2, 'x') ON CONFLICT(v) DO NOTHING;
SELECT a, b, v FROM m;

-- Upsert with a column list.
INSERT INTO t(code, v) VALUES ('a', 100) ON CONFLICT(code) DO NOTHING;
INSERT INTO t(code, v) VALUES ('k', 100) ON CONFLICT(code) DO NOTHING;
SELECT id, code, v FROM t WHERE v >= 100 ORDER BY id;
