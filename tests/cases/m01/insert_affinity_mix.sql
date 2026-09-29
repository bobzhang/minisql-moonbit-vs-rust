-- One INSERT touching columns of every affinity: each value is converted
-- (or not) according to its own column's affinity.

CREATE TABLE t(id INTEGER, i INT, r REAL, n NUMERIC, s TEXT, b BLOB);
INSERT INTO t VALUES (1, '10', '10', '10', 10, '10');
INSERT INTO t VALUES (2, 2.0, 2, '2.0', 2.0, 2.0);
INSERT INTO t VALUES (3, '2.5', '2.5', '2.5', 2.5, '2.5');
INSERT INTO t VALUES (4, 'x', 'x', 'x', 'x', 'x');
INSERT INTO t VALUES (5, x'41', x'41', x'41', x'41', x'41');
INSERT INTO t VALUES (6, NULL, NULL, NULL, NULL, NULL);
INSERT INTO t VALUES (7, ' 8 ', ' 8 ', ' 8 ', ' 8 ', ' 8 ');
INSERT INTO t VALUES (8, -0.0, -0, '-5', -5, -5);
SELECT id, i, r, n, s, b FROM t ORDER BY id;
SELECT id, typeof(i), typeof(r), typeof(n), typeof(s), typeof(b) FROM t ORDER BY id;
-- Column list order does not change which affinity applies.
INSERT INTO t (b, s, n, r, i, id) VALUES ('9', 9, '9', '9', '9', 9);
SELECT i, typeof(i), r, typeof(r), n, typeof(n), s, typeof(s), b, typeof(b) FROM t WHERE id = 9;
-- Affinity is applied to the result of an expression too.
INSERT INTO t VALUES (10, '1' || '1', 5 + 5, '1.' || '5', 3 * 4, 3 * 4);
SELECT i, typeof(i), r, typeof(r), n, typeof(n), s, typeof(s), b, typeof(b) FROM t WHERE id = 10;
