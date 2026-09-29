-- An aggregate query without GROUP BY treats the whole (filtered) table as
-- one group and returns exactly one row.
CREATE TABLE t(id INTEGER, cat TEXT, price REAL, qty INTEGER);
INSERT INTO t VALUES
  (1, 'fruit', 1.25, 10), (2, 'fruit', 0.5, 4), (3, 'veg', 2.0, 3),
  (4, 'veg', 3.5, NULL), (5, 'dairy', 4.75, 2);

SELECT count(*), sum(qty), min(price), max(price), avg(qty) FROM t;
SELECT count(*), sum(qty) FROM t WHERE cat = 'fruit';
SELECT sum(price * qty), total(price * qty) FROM t;
SELECT max(price) - min(price), sum(qty) / count(qty) FROM t;

-- Constants and aggregates together.
SELECT 'total', count(*), 42 FROM t;
SELECT count(*) || ' rows', sum(qty) + 1000 FROM t;

-- Aggregates of aggregatable expressions using CASE.
SELECT sum(CASE WHEN cat = 'veg' THEN 1 ELSE 0 END), sum(CASE cat WHEN 'fruit' THEN qty END) FROM t;

-- Aggregates without FROM.
SELECT count(*), sum(5), max('x'), avg(2), group_concat('only');
SELECT count(*) WHERE 0;
SELECT count(*), max(1) WHERE 1;

-- ORDER BY on a one-row aggregate result is allowed.
SELECT count(*) FROM t ORDER BY count(*);
SELECT sum(qty) AS s FROM t ORDER BY s DESC;

-- DISTINCT on a one-row aggregate result.
SELECT DISTINCT count(*) FROM t;

-- Aggregate + WHERE on columns not in the select list.
SELECT avg(price) FROM t WHERE qty IS NOT NULL AND id <> 5;
SELECT max(id) FROM t WHERE price < 3;
