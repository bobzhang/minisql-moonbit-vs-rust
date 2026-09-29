-- avg() returns a REAL (the mean of the non-NULL inputs), or NULL when there
-- are none. Non-numeric text counts as 0.
CREATE TABLE t(g TEXT, v);
INSERT INTO t VALUES
  ('a', 1), ('a', 2), ('b', 2), ('b', 4), ('c', 1), ('c', NULL), ('c', 2),
  ('d', NULL), ('e', 'abc'), ('e', 4), ('f', -3), ('f', 2);
SELECT g, avg(v), typeof(avg(v)) FROM t GROUP BY g ORDER BY g;

-- Result is REAL even when it is a whole number.
SELECT avg(v) FROM t WHERE g = 'b';
SELECT avg(5), avg(-5), avg(0) FROM t WHERE g = 'a';

-- Empty input.
CREATE TABLE e(v);
SELECT avg(v), typeof(avg(v)) FROM e;
SELECT avg(v) FROM t WHERE g = 'nope';

-- Non-terminating decimals.
CREATE TABLE r(v INTEGER);
INSERT INTO r VALUES (1), (1), (2);
SELECT avg(v) FROM r;
INSERT INTO r VALUES (0), (0), (0), (1);
SELECT avg(v) FROM r;

-- avg of reals.
CREATE TABLE f(v REAL);
INSERT INTO f VALUES (0.5), (0.25), (0.125);
SELECT avg(v) FROM f;

-- avg does not overflow even if the integer sum would.
CREATE TABLE big(v INTEGER);
INSERT INTO big VALUES (9223372036854775807), (9223372036854775807), (9223372036854775807);
SELECT avg(v) FROM big;

-- avg vs sum/count.
SELECT avg(v), sum(v) * 1.0 / count(v), total(v) / count(v) FROM t WHERE g IN ('a', 'b', 'c');

-- avg of an expression.
SELECT avg(v * 10), avg(v > 1), avg(v IS NULL) FROM t WHERE g IN ('a', 'c');
-- Rounding the result.
SELECT round(avg(v), 2) FROM r;
