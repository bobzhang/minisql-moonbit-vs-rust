-- If any input to sum() is a REAL (or a non-numeric value), the result is
-- a REAL. Non-numeric text counts as 0.
CREATE TABLE t(g TEXT, v);
INSERT INTO t VALUES
  ('ints', 1), ('ints', 2),
  ('mixed', 1), ('mixed', 2.5),
  ('reals', 0.5), ('reals', 0.25),
  ('whole', 1.0), ('whole', 2.0),
  ('text', 'abc'), ('text', 'xyz'),
  ('textnum', 2), ('textnum', 'hello'),
  ('decimal', '1.5'), ('decimal', 2),
  ('neg', -1.5), ('neg', 1.5);
SELECT g, sum(v), typeof(sum(v)) FROM t GROUP BY g ORDER BY g;

-- A single REAL value makes the result REAL even if it is integral.
SELECT sum(v), typeof(sum(v)) FROM t WHERE g IN ('ints', 'whole');

-- Real results print with a fractional part.
SELECT sum(v) FROM t WHERE g = 'neg';

-- Mixed with NULLs.
CREATE TABLE m(v);
INSERT INTO m VALUES (NULL), (1.5), (NULL), (2);
SELECT sum(v), typeof(sum(v)) FROM m;

-- REAL column affinity turns integers into reals.
CREATE TABLE r(v REAL);
INSERT INTO r VALUES (1), (2), (3);
SELECT sum(v), typeof(sum(v)) FROM r;

-- Very large reals and infinities.
CREATE TABLE big(v REAL);
INSERT INTO big VALUES (1e308), (1e308);
SELECT sum(v) FROM big;
INSERT INTO big VALUES (-1e308 * 10);
SELECT typeof(sum(v)) FROM big WHERE v < 0;
SELECT sum(v) FROM big WHERE v < 0;

-- Summing an expression that produces reals.
SELECT sum(v / 2.0) FROM t WHERE g = 'ints';
SELECT sum(v / 2) FROM t WHERE g = 'ints';
SELECT sum(CAST(v AS REAL)) FROM t WHERE g = 'ints';
