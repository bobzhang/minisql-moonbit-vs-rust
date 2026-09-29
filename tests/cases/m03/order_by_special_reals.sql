-- Ordering of special numeric values: infinities, negative zero, very small
-- and very large magnitudes, and integers beyond 2^53 next to reals.
-- 1e308 * 10 overflows to +Inf. The text 'Infinity' is TEXT and sorts after
-- every number.
CREATE TABLE t(id INTEGER, v);
INSERT INTO t VALUES
  (1, 1e308 * 10), (2, -1e308 * 10), (3, 0.0), (4, -0.0), (5, 5e-324), (6, -5e-324),
  (7, 1.7976931348623157e308), (8, 9223372036854775807), (9, 9.223372036854775807e18),
  (10, -9223372036854775808), (11, 1), (12, 0.9999999999999999), (13, 'Infinity'), (14, NULL);
SELECT id, v FROM t ORDER BY v, id;
SELECT id, v FROM t ORDER BY v DESC, id;
SELECT id, v FROM t ORDER BY v DESC NULLS LAST, id DESC;

-- Large integers compare exactly against reals.
CREATE TABLE b(id INTEGER, v);
INSERT INTO b VALUES (1, 9007199254740993), (2, 9007199254740992.0), (3, 9007199254740992), (4, 9007199254740994.0);
SELECT id, v FROM b ORDER BY v, id;
SELECT id FROM b WHERE v > 9007199254740992.0 ORDER BY id;

-- Real values from arithmetic.
CREATE TABLE r(id INTEGER, v REAL);
INSERT INTO r VALUES (1, 0.1 + 0.2), (2, 0.3), (3, 1.0 / 3), (4, 0.333), (5, 2.0 / 6);
SELECT id, v FROM r ORDER BY v, id;
SELECT id FROM r ORDER BY v DESC, id DESC LIMIT 2;
