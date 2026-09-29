-- total() is like sum() but always returns a REAL, and returns 0.0 (not
-- NULL) when there are no non-NULL inputs.
CREATE TABLE t(g TEXT, v);
INSERT INTO t VALUES ('a', 1), ('a', 2), ('b', 1.5), ('b', NULL), ('c', NULL), ('d', 'abc'), ('d', 4);
SELECT g, total(v), typeof(total(v)) FROM t GROUP BY g ORDER BY g;
SELECT total(v), sum(v) FROM t WHERE g = 'a';

-- Empty input: total is 0.0, sum is NULL.
CREATE TABLE e(v);
SELECT total(v), sum(v), typeof(total(v)), typeof(sum(v)) FROM e;
SELECT total(v) FROM t WHERE g = 'none';
-- All NULL.
SELECT total(v), sum(v) FROM t WHERE g = 'c';

-- Constants and expressions.
SELECT total(1), total(NULL), total(0.5) FROM t;
SELECT total(v * 2) FROM t WHERE g = 'a';
SELECT total(-v) FROM t WHERE g IN ('a', 'b');

-- Huge values: total returns a real where sum overflows.
CREATE TABLE big(v INTEGER);
INSERT INTO big VALUES (9223372036854775807), (9223372036854775807);
SELECT total(v) FROM big;

-- total in expressions.
SELECT total(v) / count(v) FROM t WHERE g IN ('a', 'b');
SELECT CAST(total(v) AS INTEGER) FROM t WHERE g = 'a';
SELECT total(v) = 3, total(v) = 3.0 FROM t WHERE g = 'a';
-- total() takes exactly one argument.
SELECT total(v, v) FROM t;
SELECT total() FROM t;
