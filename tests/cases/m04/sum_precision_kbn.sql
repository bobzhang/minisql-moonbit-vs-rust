-- sum(), total() and avg() of REAL values use compensated (Kahan-Babuska-
-- Neumaier) summation, so rounding error does not accumulate: ten 0.1s sum
-- to exactly 1.0 (plain left-to-right addition would give
-- 0.9999999999999999).
CREATE TABLE t(v REAL);
INSERT INTO t VALUES (0.1), (0.1), (0.1), (0.1), (0.1), (0.1), (0.1), (0.1), (0.1), (0.1);
SELECT sum(v), total(v), avg(v) FROM t;
SELECT sum(v) = 1.0, total(v) = 1.0 FROM t;
-- Compare with explicit left-to-right addition.
SELECT 0.1 + 0.1 + 0.1 + 0.1 + 0.1 + 0.1 + 0.1 + 0.1 + 0.1 + 0.1;

-- Large and small magnitudes: the small values survive.
CREATE TABLE m(v REAL);
INSERT INTO m VALUES (1e16), (1.0), (1.0), (-1e16);
SELECT sum(v), total(v) FROM m;

-- Cancellation.
CREATE TABLE c(v REAL);
INSERT INTO c VALUES (1e100), (1.0), (-1e100);
SELECT sum(v), total(v), avg(v) FROM c;

-- Integers mixed with reals.
CREATE TABLE x(v);
INSERT INTO x VALUES (1), (0.1), (0.2);
SELECT sum(v), total(v) FROM x;

-- Per group.
CREATE TABLE g(k TEXT, v REAL);
INSERT INTO g VALUES ('a', 0.1), ('a', 0.2), ('b', 1e16), ('b', 1.0), ('b', 1.0), ('b', 1.0), ('b', 1.0);
SELECT k, sum(v), avg(v) FROM g GROUP BY k ORDER BY k;
