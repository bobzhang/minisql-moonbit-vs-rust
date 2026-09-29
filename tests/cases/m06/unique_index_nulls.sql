-- NULLs are distinct from each other in UNIQUE indexes: any number of rows
-- may have NULL in a unique column (or NULL in any column of a multi-column
-- unique index).
CREATE TABLE t(a INTEGER, b TEXT);
CREATE UNIQUE INDEX t_a ON t(a);
INSERT INTO t VALUES (NULL, 'n1'), (NULL, 'n2'), (NULL, 'n3');
INSERT INTO t VALUES (1, 'one');
INSERT INTO t VALUES (1, 'again');
SELECT count(*), count(a) FROM t;
-- Updating non-NULLs to NULL is always fine.
UPDATE t SET a = NULL WHERE a = 1;
SELECT count(*) FROM t WHERE a IS NULL;
-- Updating several NULLs to the same value fails.
UPDATE t SET a = 5 WHERE a IS NULL;
UPDATE t SET a = 5 WHERE b = 'n1';
SELECT b FROM t WHERE a = 5;
-- Multi-column unique index: a NULL in any column makes the row distinct.
CREATE TABLE m(x INTEGER, y INTEGER, tag TEXT);
CREATE UNIQUE INDEX m_xy ON m(x, y);
INSERT INTO m VALUES (1, NULL, 'a'), (1, NULL, 'b'), (NULL, NULL, 'c'), (NULL, NULL, 'd');
INSERT INTO m VALUES (1, 2, 'e');
INSERT INTO m VALUES (1, 2, 'f');
INSERT INTO m VALUES (2, 1, 'g');
SELECT tag FROM m ORDER BY tag;
-- Creating a unique index over existing NULL duplicates succeeds.
CREATE TABLE p(v);
INSERT INTO p VALUES (NULL), (NULL), (3);
CREATE UNIQUE INDEX p_v ON p(v);
INSERT INTO p VALUES (3);
INSERT INTO p VALUES (NULL);
SELECT count(*) FROM p;
-- Column-level UNIQUE constraints behave the same way.
CREATE TABLE q(v INTEGER UNIQUE);
INSERT INTO q VALUES (NULL), (NULL), (7);
INSERT INTO q VALUES (7);
SELECT count(*), count(v) FROM q;
-- INSERT OR IGNORE only ignores real conflicts.
INSERT OR IGNORE INTO q VALUES (NULL), (7), (8);
SELECT count(*), count(v), sum(v) FROM q;
