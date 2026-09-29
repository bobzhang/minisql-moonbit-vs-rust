-- INTEGER affinity on storage: text that looks like a number is converted;
-- reals with no fractional part become integers; other values are kept.

CREATE TABLE t(id INTEGER, v INTEGER);
INSERT INTO t VALUES (1, 42), (2, '42'), (3, '  42  '), (4, '-17'), (5, '+7');
-- Text holding a real with no fractional part becomes INTEGER.
INSERT INTO t VALUES (6, '3.0'), (7, '1e2'), (8, '-0'), (9, '-0.0'), (10, '0003');
-- Text holding a real with a fractional part becomes REAL.
INSERT INTO t VALUES (11, '3.5'), (12, '1e-2'), (13, '.5');
-- A REAL value with no fractional part becomes INTEGER; otherwise stays REAL.
INSERT INTO t VALUES (14, 3.0), (15, -2.0), (16, 2.5), (17, 1e20);
-- Text that is not a well-formed number stays TEXT.
INSERT INTO t VALUES (18, 'abc'), (19, '12abc'), (20, '0x10'), (21, ''), (22, '1,000'), (23, '1 2');
-- Blobs and NULL are never converted.
INSERT INTO t VALUES (24, x'3432'), (25, NULL);
-- Integers beyond 64 bits stay REAL.
INSERT INTO t VALUES (26, '9223372036854775807'), (27, '9223372036854775808'), (28, '-9223372036854775808');
SELECT id, v, typeof(v) FROM t ORDER BY id;
-- The stored values behave as their stored type.
SELECT id FROM t WHERE v = 42 ORDER BY id;
SELECT id FROM t WHERE v = 3 ORDER BY id;
SELECT id, v + 1 FROM t WHERE id = 2 OR id = 11 OR id = 18 ORDER BY id;
-- INT, BIGINT and friends have the same affinity.
CREATE TABLE u(a INT, b BIGINT, c TINYINT, d SMALLINT, e MEDIUMINT, f UNSIGNED BIG INT, g INT8, h INT2);
INSERT INTO u VALUES ('1', '2', '3', '4.0', '5', '6', '7e0', '8');
SELECT a, b, c, d, e, f, g, h FROM u;
SELECT typeof(a), typeof(b), typeof(c), typeof(d), typeof(e), typeof(f), typeof(g), typeof(h) FROM u;
