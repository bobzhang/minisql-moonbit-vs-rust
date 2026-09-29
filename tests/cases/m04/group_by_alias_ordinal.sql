-- GROUP BY may name a result-column alias or a 1-based result-column number.
CREATE TABLE t(id INTEGER, city TEXT, temp REAL);
INSERT INTO t VALUES
  (1, 'oslo', -3.5), (2, 'rome', 14.0), (3, 'oslo', 1.5), (4, 'lima', 19.0),
  (5, 'rome', 16.0), (6, 'oslo', -1.0), (7, 'lima', 21.0);

-- Ordinal.
SELECT city, count(*) FROM t GROUP BY 1 ORDER BY 1;
SELECT count(*), city FROM t GROUP BY 2 ORDER BY 2 DESC;
-- Ordinal referring to an expression.
SELECT temp > 0, count(*) FROM t GROUP BY 1 ORDER BY 1;
SELECT upper(city), max(temp) FROM t GROUP BY 1 ORDER BY 1;

-- Alias.
SELECT upper(city) AS c, min(temp) FROM t GROUP BY c ORDER BY c;
SELECT CAST(temp AS INTEGER) / 10 AS band, count(*) FROM t GROUP BY band ORDER BY band;
SELECT id % 2 AS parity, sum(temp) FROM t GROUP BY parity ORDER BY parity;

-- Mixing alias, ordinal and expression across several GROUP BY terms.
SELECT city AS c, temp > 10 AS warm, count(*) FROM t GROUP BY c, 2 ORDER BY 1, 2;

-- Ordinal and alias in ORDER BY as well.
SELECT city AS c, avg(temp) AS a FROM t GROUP BY 1 ORDER BY a DESC;

-- GROUP BY an alias of a column, and an ordinal combined with WHERE.
SELECT city AS place, count(*) FROM t GROUP BY place ORDER BY place DESC;
SELECT city, sum(temp) FROM t WHERE temp > 0 GROUP BY 1 ORDER BY 2;

-- Out-of-range ordinals are errors.
SELECT city, count(*) FROM t GROUP BY 3;
SELECT city, count(*) FROM t GROUP BY 0;
-- An ordinal pointing at an aggregate is an error.
SELECT city, count(*) FROM t GROUP BY 2;
-- An aggregate in GROUP BY is an error.
SELECT city FROM t GROUP BY count(*);
