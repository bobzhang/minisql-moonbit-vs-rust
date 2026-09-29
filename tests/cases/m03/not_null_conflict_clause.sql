-- ON CONFLICT clauses attached to NOT NULL constraints.
--   IGNORE:  the offending row is silently skipped.
--   REPLACE: the NULL is replaced by the column default; if there is no
--            default, it behaves like ABORT.
--   FAIL/ABORT/ROLLBACK: an error.
CREATE TABLE t(
  a NOT NULL ON CONFLICT REPLACE DEFAULT 5,
  b NOT NULL ON CONFLICT IGNORE,
  c
);
INSERT INTO t VALUES (NULL, 1, 'r1');
SELECT a, b, c FROM t ORDER BY c;
SELECT changes();
INSERT INTO t VALUES (1, NULL, 'r2');
SELECT changes();
SELECT a, b, c FROM t ORDER BY c;

-- In a multi-row insert, IGNORE skips only the offending rows.
INSERT INTO t VALUES (2, 2, 'r3'), (3, NULL, 'r4'), (NULL, 4, 'r5');
SELECT changes();
SELECT a, b, c FROM t ORDER BY c;

-- UPDATE honours the constraint's clause as well.
UPDATE t SET a = NULL WHERE c = 'r3';
SELECT a, b, c FROM t ORDER BY c;
UPDATE t SET b = NULL WHERE c = 'r1';
SELECT a, b, c FROM t ORDER BY c;

-- REPLACE without a default acts like ABORT.
CREATE TABLE u(a NOT NULL ON CONFLICT REPLACE, b);
INSERT INTO u VALUES (NULL, 1);
SELECT a, b FROM u;

-- The statement's OR clause overrides the constraint's clause.
INSERT OR ABORT INTO t VALUES (1, NULL, 'r6');
INSERT OR IGNORE INTO u VALUES (NULL, 2);
INSERT OR IGNORE INTO t VALUES (NULL, 7, 'r7');
SELECT a, b, c FROM t ORDER BY c;
SELECT a, b FROM u;

-- ON CONFLICT FAIL / ABORT on NOT NULL: plain errors.
CREATE TABLE f(x NOT NULL ON CONFLICT FAIL, y NOT NULL ON CONFLICT ABORT);
INSERT INTO f VALUES (NULL, 1);
INSERT INTO f VALUES (1, NULL);
INSERT INTO f VALUES (1, 1);
SELECT x, y FROM f;
