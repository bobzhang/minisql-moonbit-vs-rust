-- The bare-column rule per group: each group's bare columns come from the
-- row holding that group's min()/max(). Each group's extremum is unique.
CREATE TABLE s(id INTEGER, region TEXT, rep TEXT, amount INTEGER, day TEXT);
INSERT INTO s VALUES
  (1, 'n', 'ann', 300, '2024-01-03'), (2, 'n', 'bob', 450, '2024-01-01'), (3, 'n', 'cy', 120, '2024-01-07'),
  (4, 's', 'dee', 200, '2024-01-02'), (5, 's', 'eli', 90, '2024-01-05'),
  (6, 'e', 'fox', 500, '2024-01-04'), (7, 'w', 'gil', NULL, '2024-01-06'), (8, 'w', 'hal', 70, '2024-01-08');

-- Top rep per region.
SELECT region, rep, max(amount) FROM s GROUP BY region ORDER BY region;
-- Lowest amount per region, with its day and id.
SELECT region, min(amount), day, id FROM s GROUP BY region ORDER BY region;
-- Earliest day per region.
SELECT region, rep, min(day) FROM s GROUP BY region ORDER BY region;

-- With HAVING and ORDER BY on the bare column.
SELECT region, rep, max(amount) AS top FROM s GROUP BY region HAVING count(*) > 1 ORDER BY rep;
SELECT region, rep, max(amount) FROM s GROUP BY region ORDER BY max(amount) DESC;

-- Grouping by an expression.
SELECT id % 2 AS odd, rep, max(amount) FROM s GROUP BY odd ORDER BY odd;

-- WHERE applied first.
SELECT region, rep, max(amount) FROM s WHERE amount < 400 GROUP BY region ORDER BY region;

-- A group whose only non-NULL value decides.
SELECT rep, min(amount) FROM s WHERE region = 'w';

-- Bare column inside an expression.
SELECT region, rep || '@' || day, max(amount) FROM s GROUP BY region ORDER BY region;
