-- CREATE TABLE errors when the table exists; IF NOT EXISTS makes it a no-op
-- that keeps the existing table (and its columns and rows) unchanged.

CREATE TABLE t(a INTEGER, b TEXT);
INSERT INTO t VALUES (1, 'x');
-- Creating it again is an error, even with different columns.
CREATE TABLE t(z);
-- Table names are case-insensitive, quoted or not.
CREATE TABLE T(q);
CREATE TABLE "t"(q);
-- The original table is unaffected.
SELECT * FROM t;
-- IF NOT EXISTS on an existing table is silently ignored.
CREATE TABLE IF NOT EXISTS t(completely, different, columns);
SELECT * FROM t;
INSERT INTO t VALUES (2, 'y');
SELECT a, b FROM t ORDER BY a;
-- The ignored definition's columns do not exist.
SELECT completely FROM t;
-- IF NOT EXISTS on a new table creates it.
CREATE TABLE IF NOT EXISTS fresh(v INTEGER);
INSERT INTO fresh VALUES (5);
SELECT v FROM fresh;
CREATE TABLE IF NOT EXISTS fresh(v INTEGER);
SELECT v FROM fresh;
-- Keywords in IF NOT EXISTS are case-insensitive.
create table if not exists Fresh(other);
SELECT v FROM FRESH;
INSERT INTO fresh VALUES (6);
SELECT v FROM fresh ORDER BY v;
