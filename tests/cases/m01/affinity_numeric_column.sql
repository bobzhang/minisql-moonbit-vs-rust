-- NUMERIC affinity on storage: numeric text becomes INTEGER if it is an
-- integer (or a real with no fractional part that fits), else REAL.

CREATE TABLE t(id INTEGER, v NUMERIC);
INSERT INTO t VALUES (1, '42'), (2, '3.0'), (3, '3.5'), (4, '1e2'), (5, '1.5e3'), (6, '2.5e-1');
INSERT INTO t VALUES (7, ' 12 '), (8, '-0'), (9, '0003'), (10, '1.');
INSERT INTO t VALUES (11, 7), (12, 7.0), (13, 7.25);
-- Too big for INTEGER: REAL.
INSERT INTO t VALUES (14, '9223372036854775807'), (15, '9223372036854775808'), (16, '1e20');
-- Not numbers: kept as TEXT; blobs and NULL kept.
INSERT INTO t VALUES (17, 'abc'), (18, '3 apples'), (19, ''), (20, x'3432'), (21, NULL), (22, '0x1F');
SELECT id, v, typeof(v) FROM t ORDER BY id;
-- DECIMAL, BOOLEAN, DATE and other unrecognized names have NUMERIC affinity.
CREATE TABLE u(a DECIMAL(10, 2), b BOOLEAN, c DATE, d DATETIME, e NUMBER, f MONEY);
INSERT INTO u VALUES ('1.50', '1', '2024', '3.0', '12', '9.99');
SELECT a, b, c, d, e, f FROM u;
SELECT typeof(a), typeof(b), typeof(c), typeof(d), typeof(e), typeof(f) FROM u;
-- A date-like string is not a number, so it stays text.
INSERT INTO u VALUES ('x', 'true', '2024-01-01', '2024-01-01 10:00:00', 'n', '$5');
SELECT a, typeof(a), b, typeof(b), c, typeof(c), d, typeof(d) FROM u ORDER BY typeof(a), a;
