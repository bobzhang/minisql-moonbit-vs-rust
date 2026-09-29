-- DROP TABLE [IF EXISTS].

CREATE TABLE t(a INTEGER);
INSERT INTO t VALUES (1), (2);
SELECT a FROM t ORDER BY a;
DROP TABLE t;
-- The table is gone.
SELECT a FROM t;
INSERT INTO t VALUES (3);
-- Dropping it again is an error.
DROP TABLE t;
-- IF EXISTS makes dropping a missing table a no-op.
DROP TABLE IF EXISTS t;
DROP TABLE IF EXISTS never_existed;
-- Recreate with a different shape: no old rows or columns remain.
CREATE TABLE t(b TEXT, c TEXT);
SELECT * FROM t;
INSERT INTO t VALUES ('x', 'y');
SELECT * FROM t;
SELECT a FROM t;
-- Drop is case-insensitive and works with quoted names.
CREATE TABLE MixedCase(v INTEGER);
INSERT INTO MixedCase VALUES (9);
DROP TABLE mixedcase;
SELECT v FROM MixedCase;
CREATE TABLE "quoted name"(v INTEGER);
INSERT INTO "quoted name" VALUES (10);
SELECT v FROM "quoted name";
DROP TABLE IF EXISTS "quoted name";
SELECT v FROM "quoted name";
-- Dropping one table leaves others intact.
CREATE TABLE keep(v INTEGER);
CREATE TABLE gone(v INTEGER);
INSERT INTO keep VALUES (1);
INSERT INTO gone VALUES (2);
DROP TABLE gone;
SELECT v FROM keep;
-- Missing table name is a syntax error.
DROP TABLE;
