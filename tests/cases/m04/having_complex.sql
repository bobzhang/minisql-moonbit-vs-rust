-- More HAVING forms: arithmetic between aggregates, FILTER, DISTINCT,
-- CASE, IN, BETWEEN and LIKE on grouping columns.
CREATE TABLE p(cat TEXT, item TEXT, price REAL, stock INTEGER);
INSERT INTO p VALUES
  ('fruit', 'apple', 1.2, 10), ('fruit', 'pear', 1.5, 0), ('fruit', 'fig', 3.0, 5),
  ('veg', 'kale', 2.5, 0), ('veg', 'leek', 1.0, 8),
  ('nuts', 'pecan', 9.0, 2), ('nuts', 'almond', 7.5, 2), ('nuts', 'cashew', 8.0, 0),
  ('misc', 'salt', 0.5, 100);

SELECT cat FROM p GROUP BY cat HAVING max(price) - min(price) > 1.5 ORDER BY cat;
SELECT cat, sum(stock) FROM p GROUP BY cat HAVING sum(stock) * 2 > count(*) * 10 ORDER BY cat;
SELECT cat FROM p GROUP BY cat HAVING count(*) FILTER (WHERE stock = 0) >= 1 ORDER BY cat;
SELECT cat FROM p GROUP BY cat HAVING count(DISTINCT stock) < count(*) ORDER BY cat;
SELECT cat FROM p GROUP BY cat HAVING CASE WHEN count(*) > 2 THEN avg(price) > 5 ELSE 0 END ORDER BY cat;
SELECT cat, count(*) FROM p GROUP BY cat HAVING count(*) IN (1, 3) ORDER BY cat;
SELECT cat, avg(price) FROM p GROUP BY cat HAVING avg(price) BETWEEN 1 AND 3 ORDER BY cat;
SELECT cat FROM p GROUP BY cat HAVING cat LIKE '%u%' ORDER BY cat;
SELECT cat FROM p GROUP BY cat HAVING group_concat(item, ',' ORDER BY item) LIKE 'a%' ORDER BY cat;
SELECT cat FROM p GROUP BY cat HAVING min(item) > 'b' AND max(stock) < 50 ORDER BY cat;

-- HAVING using an aggregate over an expression.
SELECT cat, sum(price * stock) AS value FROM p GROUP BY cat HAVING sum(price * stock) > 10 ORDER BY value DESC;

-- HAVING with a result-column alias used inside an expression.
SELECT cat, count(*) AS n FROM p GROUP BY cat HAVING n * 2 >= 6 ORDER BY cat;

-- HAVING with an ordinal-like constant is just a truthy constant.
SELECT cat FROM p GROUP BY cat HAVING 2 ORDER BY cat;

-- An aggregate may not appear in WHERE.
SELECT cat FROM p WHERE count(*) > 1 GROUP BY cat;
