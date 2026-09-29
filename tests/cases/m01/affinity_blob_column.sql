-- BLOB affinity (declared BLOB, or no declared type at all): values are
-- stored exactly as given, with no conversion.

CREATE TABLE t(id INTEGER, b BLOB, n);
INSERT INTO t VALUES (1, 1, 1), (2, '1', '1'), (3, 1.0, 1.0), (4, '1.0', '1.0');
INSERT INTO t VALUES (5, x'01', x'01'), (6, NULL, NULL), (7, 'abc', 'abc'), (8, ' 2 ', ' 2 ');
SELECT id, b, typeof(b), n, typeof(n) FROM t ORDER BY id;
-- Values of different classes do not compare equal.
SELECT id FROM t WHERE b = 1 ORDER BY id;
SELECT id FROM t WHERE n = '1' ORDER BY id;
SELECT id FROM t WHERE n = 1.0 ORDER BY id;
-- Sorting an untyped column uses cross-class order.
SELECT id, n FROM t ORDER BY n, id;
-- Arithmetic still converts the stored text when it is used as a number.
SELECT id, b + 1, n * 2 FROM t WHERE id <= 4 ORDER BY id;
-- A column declared BLOB keeps text exactly, including its spelling.
CREATE TABLE raw(v BLOB);
INSERT INTO raw VALUES ('007'), (7), ('7.0'), (7.0);
SELECT v, typeof(v) FROM raw ORDER BY typeof(v), v;
