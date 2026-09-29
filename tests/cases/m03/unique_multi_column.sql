-- Table-level UNIQUE over several columns: only the combination must be
-- unique; a NULL in any column makes the row distinct from all others.
CREATE TABLE t(a INTEGER, b TEXT, c, UNIQUE(a, b));
INSERT INTO t VALUES (1, 'x', 'r1');
INSERT INTO t VALUES (1, 'y', 'r2');
INSERT INTO t VALUES (2, 'x', 'r3');
-- Same pair: fails.
INSERT INTO t VALUES (1, 'x', 'r4');
SELECT a, b, c FROM t ORDER BY c;

-- NULL in one component: allowed repeatedly.
INSERT INTO t VALUES (1, NULL, 'r5');
INSERT INTO t VALUES (1, NULL, 'r6');
INSERT INTO t VALUES (NULL, 'x', 'r7');
INSERT INTO t VALUES (NULL, 'x', 'r8');
INSERT INTO t VALUES (NULL, NULL, 'r9');
INSERT INTO t VALUES (NULL, NULL, 'r10');
SELECT a, b, c FROM t ORDER BY c;

-- UPDATE that creates a duplicate pair fails.
UPDATE t SET b = 'x' WHERE c = 'r2';
-- UPDATE of one component to a free combination works.
UPDATE t SET b = 'z' WHERE c = 'r2';
SELECT a, b, c FROM t WHERE c IN ('r1', 'r2', 'r3') ORDER BY c;

-- Two independent table constraints plus a column constraint.
CREATE TABLE u(p, q, r UNIQUE, UNIQUE(p, q), UNIQUE(q, r));
INSERT INTO u VALUES (1, 1, 1);
INSERT INTO u VALUES (1, 2, 2);
-- Violates UNIQUE(p, q).
INSERT INTO u VALUES (1, 1, 3);
-- Violates UNIQUE(r).
INSERT INTO u VALUES (5, 5, 1);
-- Violates UNIQUE(q, r) and UNIQUE(r).
INSERT INTO u VALUES (9, 2, 2);
-- Fine.
INSERT INTO u VALUES (2, 1, 3);
SELECT p, q, r FROM u ORDER BY p, q;

-- Named table constraint and a three-column key.
CREATE TABLE w(x, y, z, CONSTRAINT xyz UNIQUE (x, y, z));
INSERT INTO w VALUES (1, 2, 3), (1, 2, 4), (1, 3, 3);
INSERT INTO w VALUES (1, 2, 3);
SELECT x, y, z FROM w ORDER BY x, y, z;
