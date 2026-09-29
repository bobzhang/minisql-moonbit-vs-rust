-- REAL affinity on storage: integers and numeric text are stored as REAL.

CREATE TABLE t(id INTEGER, v REAL);
INSERT INTO t VALUES (1, 5), (2, -3), (3, 0), (4, '5'), (5, '2.5'), (6, '1e2'), (7, '  7 ');
INSERT INTO t VALUES (8, 1.25), (9, '-0.5'), (10, '.5'), (11, '5.');
-- Large integers become the nearest REAL.
INSERT INTO t VALUES (12, 9223372036854775807), (13, '12345678901234567890');
-- Non-numeric text, blobs and NULL are kept.
INSERT INTO t VALUES (14, 'abc'), (15, '5 5'), (16, x'35'), (17, NULL), (18, '');
SELECT id, v, typeof(v) FROM t ORDER BY id;
-- Arithmetic on stored values: they are REAL now.
SELECT id, v / 2 FROM t WHERE id <= 4 ORDER BY id;
-- DOUBLE, FLOAT and friends have REAL affinity.
CREATE TABLE u(a DOUBLE, b FLOAT, c DOUBLE PRECISION, d FLOAT8, e REAL);
INSERT INTO u VALUES (1, '2', 3, '4', 5);
SELECT a, b, c, d, e FROM u;
SELECT typeof(a), typeof(b), typeof(c), typeof(d), typeof(e) FROM u;
-- Comparing a REAL column with integers.
SELECT id FROM t WHERE v = 5 ORDER BY id;
SELECT id FROM t WHERE v > 2 AND v < 10 ORDER BY id;
