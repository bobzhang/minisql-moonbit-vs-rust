-- INSERT column lists: any order, subsets, rowid columns, and errors.
CREATE TABLE t(a INTEGER, b TEXT, c REAL DEFAULT 0.5);

INSERT INTO t(b, a) VALUES ('one', 1);
INSERT INTO t(c, b, a) VALUES (2.5, 'two', 2);
INSERT INTO t(a) VALUES (3);
INSERT INTO t VALUES (4, 'four', 4.5);
SELECT a, b, c FROM t ORDER BY a;

-- Multi-row VALUES with a column list.
INSERT INTO t(b, a) VALUES ('five', 5), ('six', 6), ('seven', 7);
SELECT a, b, c FROM t WHERE a >= 5 ORDER BY a;

-- Identifiers are case-insensitive and may be quoted.
INSERT INTO t("A", [B], `c`) VALUES (8, 'eight', 8.5);
INSERT INTO t(A, B) VALUES (9, 'nine');
SELECT a, b, c FROM t WHERE a >= 8 ORDER BY a;

-- The rowid can be set explicitly through the column list.
CREATE TABLE r(x TEXT);
INSERT INTO r(rowid, x) VALUES (100, 'hundred');
INSERT INTO r(x, oid) VALUES ('fifty', 50);
INSERT INTO r(_rowid_, x) VALUES (7, 'seven');
INSERT INTO r(x) VALUES ('next');
SELECT rowid, x FROM r ORDER BY rowid;
-- A NULL rowid means "choose one".
INSERT INTO r(rowid, x) VALUES (NULL, 'auto');
SELECT rowid, x FROM r ORDER BY rowid;

-- Errors: unknown column, too many or too few values.
INSERT INTO t(a, nosuch) VALUES (1, 2);
INSERT INTO t(a, b) VALUES (1);
INSERT INTO t(a) VALUES (1, 2);
INSERT INTO t(a, b) VALUES (10, 'ten'), (11);
INSERT INTO t VALUES (1, 2);
SELECT a, b, c FROM t ORDER BY a;
