-- GROUP BY several columns: one row per distinct combination.
CREATE TABLE o(id INTEGER, cust TEXT, year INTEGER, status TEXT, amount INTEGER);
INSERT INTO o VALUES
  (1, 'ann', 2023, 'paid', 100), (2, 'ann', 2023, 'paid', 50), (3, 'ann', 2024, 'open', 70),
  (4, 'bob', 2023, 'open', 20), (5, 'bob', 2024, 'paid', 90), (6, 'bob', 2024, 'paid', 10),
  (7, 'cy', 2024, 'open', 40), (8, 'ann', 2024, 'paid', 30);

SELECT cust, year, count(*), sum(amount) FROM o GROUP BY cust, year ORDER BY cust, year;
SELECT year, status, sum(amount) FROM o GROUP BY year, status ORDER BY year, status;
SELECT cust, year, status, count(*) FROM o GROUP BY cust, year, status ORDER BY cust, year, status;

-- Column order in GROUP BY does not change the groups.
SELECT cust, year, count(*) FROM o GROUP BY year, cust ORDER BY cust, year;

-- Not selecting every grouping column.
SELECT cust, sum(amount) FROM o GROUP BY cust, status ORDER BY cust, sum(amount);

-- Grouping by a column and an expression.
SELECT cust, amount >= 50, count(*) FROM o GROUP BY cust, amount >= 50 ORDER BY 1, 2;

-- Duplicate grouping terms are harmless.
SELECT cust, count(*) FROM o GROUP BY cust, cust ORDER BY cust;

-- Aggregates ordered within groups.
SELECT cust, year, group_concat(id, ',' ORDER BY id) FROM o GROUP BY cust, year ORDER BY cust, year;

-- Order the groups by an aggregate, with ties broken by the keys.
SELECT cust, year, sum(amount) AS s FROM o GROUP BY cust, year ORDER BY s DESC, cust, year;
