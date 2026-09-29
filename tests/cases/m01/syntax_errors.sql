-- Syntax errors print one Error line and do not stop the script; the
-- statements around them run normally.

SELECT 1 +;
SELECT 'still running';
SELECT 1 + 1, 2 * 3;
SELECT FROM t;
SELECT (1;
SELECT (1), ((2));
SELECT 1 +* 2;
SELECT 1 + -2;
seelct 1;
SELECT 'typo above did not stop us';
CREATE TABLE t(a INTEGER, b TEXT);
INSERT INTO t VALUES (1, 'x');
SELECT a, FROM t;
SELECT a, b FROM t;
SELECT a FROM t WHERE;
SELECT a FROM t WHERE a = 1;
SELECT a FROM t ORDER BY a ASC DESC;
SELECT a FROM t ORDER BY a DESC;
-- A malformed INSERT inserts nothing.
INSERT INTO t VALUES (2, 'y') (3, 'z');
SELECT a, b FROM t ORDER BY a;
INSERT INTO t VALUES (2, 'y'), (3, 'z');
SELECT a, b FROM t ORDER BY a;
SELECT a * 10 FROM t ORDER BY a;
SELECT 'x' || 'y';
SELECT typeof(a), typeof(b) FROM t WHERE a = 1;
SELECT a FROM t WHERE b = 'z';
SELECT 'end';
-- More valid statements to confirm the session is healthy.
CREATE TABLE u(v TEXT);
INSERT INTO u VALUES ('p'), ('q');
SELECT v FROM u ORDER BY v DESC;
SELECT a - 1 FROM t WHERE a > 1 ORDER BY a;
SELECT b FROM t ORDER BY b DESC;
SELECT NULL IS NULL;
