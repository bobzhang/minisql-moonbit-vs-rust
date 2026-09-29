-- INSERT errors: wrong number of values, unknown table or column. A failed
-- INSERT inserts nothing, not even the rows that were well-formed.

CREATE TABLE t(a INTEGER, b TEXT);
INSERT INTO t VALUES (1, 'ok');
SELECT a, b FROM t ORDER BY a;
-- Too few and too many values for the table.
INSERT INTO t VALUES (2);
INSERT INTO t VALUES (3, 'x', 'extra');
SELECT a, b FROM t ORDER BY a;
-- A column list and the value count must match.
INSERT INTO t (a) VALUES (4, 'x');
SELECT a, b FROM t ORDER BY a;
-- A column list with fewer columns is fine when the counts match.
INSERT INTO t (a) VALUES (5);
SELECT a, b FROM t ORDER BY a;
-- All rows of a multi-row VALUES must have the same width; nothing from the
-- statement is inserted.
INSERT INTO t VALUES (6, 'six'), (7);
SELECT a, b FROM t ORDER BY a;
-- Unknown table.
INSERT INTO nosuch VALUES (1);
-- Unknown column in the column list.
INSERT INTO t (a, zzz) VALUES (8, 2);
SELECT a, b FROM t ORDER BY a;
-- Unknown column referenced inside VALUES.
INSERT INTO t VALUES (a, 'x');
-- Valid inserts after the errors work.
INSERT INTO t VALUES (11, 'eleven'), (12, 'twelve');
INSERT INTO t (b, a) VALUES ('thirteen', 13);
SELECT a, b FROM t ORDER BY a;
SELECT a, b FROM t ORDER BY a DESC;
SELECT b FROM t WHERE a = 13;
SELECT a FROM t WHERE b IS NULL;
SELECT a FROM t WHERE b = 'twelve';
-- More valid statements.
INSERT INTO t VALUES (14, 'fourteen');
SELECT b FROM t WHERE a > 12 ORDER BY a;
SELECT a, b FROM t WHERE a < 6 ORDER BY a;
SELECT b || '!' FROM t WHERE a = 1;
