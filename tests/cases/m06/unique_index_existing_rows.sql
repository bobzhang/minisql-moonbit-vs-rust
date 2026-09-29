-- CREATE UNIQUE INDEX over a table that already has duplicate values fails
-- and leaves no index behind; once duplicates are removed it succeeds.
CREATE TABLE t(a INTEGER, b TEXT);
INSERT INTO t VALUES (1, 'x'), (2, 'y'), (1, 'z'), (3, 'x');

CREATE UNIQUE INDEX t_a ON t(a);
SELECT count(*) FROM sqlite_schema WHERE name = 't_a';
-- The table is unchanged and still accepts duplicates.
INSERT INTO t VALUES (2, 'w');
SELECT count(*) FROM t;
-- Remove duplicates, then create the index.
DELETE FROM t WHERE b IN ('z', 'w');
CREATE UNIQUE INDEX t_a ON t(a);
SELECT name FROM sqlite_schema WHERE type = 'index';
INSERT INTO t VALUES (1, 'dup');
SELECT a, b FROM t ORDER BY a;
-- A non-unique index on the same duplicates is fine.
CREATE INDEX t_b ON t(b);
SELECT a FROM t WHERE b = 'x' ORDER BY a;
-- Unique over b fails while 'x' is duplicated...
CREATE UNIQUE INDEX t_b_u ON t(b);
-- ...but a multi-column unique index over (a, b) succeeds.
CREATE UNIQUE INDEX t_ab ON t(a, b);
INSERT INTO t VALUES (4, 'x');
INSERT INTO t VALUES (4, 'x');
SELECT count(*) FROM t;
-- Values equal after affinity conversion are duplicates: '5' stored in an INTEGER column is 5.
CREATE TABLE n(v INTEGER);
INSERT INTO n VALUES (5), ('5');
CREATE UNIQUE INDEX n_v ON n(v);
SELECT count(*) FROM sqlite_schema WHERE name = 'n_v';
-- Integer and real compare equal.
CREATE TABLE r(v);
INSERT INTO r VALUES (2), (2.0);
CREATE UNIQUE INDEX r_v ON r(v);
SELECT count(*) FROM sqlite_schema WHERE name = 'r_v';
