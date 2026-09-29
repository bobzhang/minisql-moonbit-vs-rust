-- UPDATE OR {REPLACE|IGNORE|ABORT|FAIL|ROLLBACK}. The examples are chosen so
-- the outcome does not depend on the order in which rows are visited.
CREATE TABLE t(id INTEGER PRIMARY KEY, code INTEGER UNIQUE, v TEXT);
INSERT INTO t VALUES (1, 1, 'a'), (2, 2, 'b'), (3, 3, 'c'), (4, 12, 'd');

-- OR IGNORE: the row whose new code (12) would collide is left unchanged.
UPDATE OR IGNORE t SET code = code + 10 WHERE id <= 3;
SELECT id, code, v FROM t ORDER BY id;

-- OR REPLACE: the row that owned the conflicting value is deleted.
UPDATE OR REPLACE t SET code = 11 WHERE id = 3;
SELECT id, code, v FROM t ORDER BY id;

-- Default (ABORT): a conflicting UPDATE changes nothing at all.
UPDATE t SET v = v || '!', code = 12 WHERE id >= 2;
SELECT id, code, v FROM t ORDER BY id;
UPDATE OR ABORT t SET code = 12 WHERE id = 3;
SELECT id, code, v FROM t ORDER BY id;

-- OR FAIL on a single-row update: same as abort for that row.
UPDATE OR FAIL t SET code = 12 WHERE id = 3;
SELECT id, code, v FROM t ORDER BY id;

-- OR REPLACE when the rowid itself collides.
UPDATE OR REPLACE t SET id = 2 WHERE id = 3;
SELECT id, code, v FROM t ORDER BY id;

-- OR IGNORE when the rowid collides.
UPDATE OR IGNORE t SET id = 4 WHERE id = 2;
SELECT id, code, v FROM t ORDER BY id;

-- NOT NULL with UPDATE OR IGNORE / OR REPLACE (REPLACE uses the default).
CREATE TABLE n(id INTEGER PRIMARY KEY, x NOT NULL DEFAULT 'dflt', y NOT NULL);
INSERT INTO n VALUES (1, 'p', 'q'), (2, 'r', 's');
UPDATE OR IGNORE n SET x = NULL WHERE id = 1;
SELECT id, x, y FROM n ORDER BY id;
UPDATE OR REPLACE n SET x = NULL WHERE id = 1;
SELECT id, x, y FROM n ORDER BY id;
UPDATE OR REPLACE n SET y = NULL WHERE id = 2;
SELECT id, x, y FROM n ORDER BY id;

-- OR ROLLBACK outside a transaction behaves like ABORT.
UPDATE OR ROLLBACK t SET code = 12 WHERE id = 2;
SELECT id, code, v FROM t ORDER BY id;

-- The OR clause overrides a constraint's own conflict clause.
CREATE TABLE k(id INTEGER PRIMARY KEY, u UNIQUE ON CONFLICT IGNORE);
INSERT INTO k VALUES (1, 'a'), (2, 'b');
UPDATE k SET u = 'a' WHERE id = 2;
SELECT id, u FROM k ORDER BY id;
UPDATE OR ABORT k SET u = 'a' WHERE id = 2;
SELECT id, u FROM k ORDER BY id;
