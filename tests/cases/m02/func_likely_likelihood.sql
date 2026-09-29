-- likely(X), unlikely(X) and likelihood(X, P) are planner hints: they return
-- X unchanged. P must be a constant REAL between 0.0 and 1.0.

SELECT likely(1), likely(0), likely('abc'), likely(NULL), likely(2.5), likely(x'01');
SELECT unlikely(1), unlikely(0), unlikely('abc'), unlikely(NULL);
SELECT likelihood(5, 0.5), likelihood('a', 0.0), likelihood(NULL, 1.0), likelihood(7, 0.9375);
-- The type is preserved.
SELECT typeof(likely('1')), typeof(unlikely(1.0)), typeof(likelihood(1, 0.5));
-- Usable in WHERE like any expression.
CREATE TABLE t(id INTEGER, v INTEGER);
INSERT INTO t VALUES (1, 10), (2, 20), (3, NULL), (4, 40);
SELECT id FROM t WHERE likely(v > 15) ORDER BY id;
SELECT id FROM t WHERE unlikely(v IS NULL) ORDER BY id;
SELECT id FROM t WHERE likelihood(v < 30, 0.25) ORDER BY id;
SELECT id, likely(v) + unlikely(v) FROM t ORDER BY id;
-- An out-of-range or non-REAL probability is an error.
SELECT likelihood(1, 1.5);
SELECT likelihood(1, -0.5);
-- Wrong number of arguments.
SELECT likelihood(1);
