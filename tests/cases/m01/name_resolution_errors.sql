-- Errors for unknown tables and columns. A statement that fails to resolve
-- a name prints one Error line and no rows, even if the table has rows or
-- no row would ever be produced.

CREATE TABLE t(a INTEGER, b TEXT);
INSERT INTO t VALUES (1, 'x'), (2, 'y');
SELECT * FROM nosuch;
SELECT a, b FROM t ORDER BY a;
SELECT a, nosuch FROM t;
SELECT a FROM t WHERE nosuch > 0;
SELECT a FROM t ORDER BY a;
SELECT t.nosuch FROM t;
SELECT other.a FROM t;
SELECT t.a FROM t ORDER BY t.a DESC;
-- With an alias, only the alias qualifies columns.
SELECT x.a FROM t AS y;
SELECT y.b FROM t AS y ORDER BY y.a;
-- Names are checked even when no rows would be produced.
SELECT nosuch FROM t WHERE 0;
CREATE TABLE empty(v INTEGER);
SELECT v FROM empty;
SELECT v, 'no rows' FROM empty WHERE v > 0;
-- Duplicate column names in CREATE TABLE are an error (case-insensitive),
-- so the table is not created.
CREATE TABLE dup(a INTEGER, A TEXT);
CREATE TABLE dup(a INTEGER, b TEXT);
INSERT INTO dup VALUES (1, 'one');
SELECT a, b FROM dup;
-- Errors do not disturb later statements.
SELECT b FROM t WHERE a = 2;
SELECT a + 1, b || '!' FROM t ORDER BY a;
SELECT 'done';
-- Resolution is case-insensitive, so these all succeed.
SELECT A, B FROM T ORDER BY A;
SELECT T.A FROM t ORDER BY t.a;
SELECT Y.B FROM t y WHERE Y.A = 1;
SELECT typeof(a) FROM t WHERE a = 1;
SELECT a FROM dup;
SELECT b FROM t WHERE b > 'x';
