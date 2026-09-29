-- GROUP BY on a column: one output row per distinct value.
CREATE TABLE sales(id INTEGER, region TEXT, product TEXT, qty INTEGER, price REAL);
INSERT INTO sales VALUES
  (1, 'north', 'apple', 10, 0.5), (2, 'south', 'apple', 5, 0.55), (3, 'north', 'pear', 3, 0.75),
  (4, 'east', 'apple', 8, 0.5), (5, 'south', 'pear', 7, 0.8), (6, 'north', 'apple', 2, 0.45),
  (7, 'east', 'fig', 1, 2.0), (8, 'south', 'apple', 4, 0.6);

SELECT region, count(*) FROM sales GROUP BY region ORDER BY region;
SELECT product, sum(qty), min(price), max(price) FROM sales GROUP BY product ORDER BY product;
SELECT region, sum(qty * price) FROM sales GROUP BY region ORDER BY region;
SELECT region, avg(qty) FROM sales GROUP BY region ORDER BY region DESC;

-- The grouping column does not have to be selected.
SELECT count(*), sum(qty) FROM sales GROUP BY region ORDER BY 1, 2;

-- WHERE filters rows before grouping.
SELECT region, count(*) FROM sales WHERE product = 'apple' GROUP BY region ORDER BY region;
SELECT product, sum(qty) FROM sales WHERE qty > 3 GROUP BY product ORDER BY product;

-- Grouping by a column with a single value.
SELECT product, count(*) FROM sales WHERE product = 'fig' GROUP BY product;

-- Grouping by a unique column gives one row per row.
SELECT id, count(*), sum(qty) FROM sales GROUP BY id ORDER BY id;

-- Grouping by the rowid.
SELECT rowid % 3, count(*) FROM sales GROUP BY rowid % 3 ORDER BY 1;

-- Output order is set by ORDER BY, which may use aggregates.
SELECT region, sum(qty) FROM sales GROUP BY region ORDER BY sum(qty) DESC;
SELECT product FROM sales GROUP BY product ORDER BY count(*), product;

-- Several aggregates of the same column.
SELECT region, count(qty), sum(qty), total(qty), min(qty), max(qty), group_concat(qty, '+' ORDER BY qty)
FROM sales GROUP BY region ORDER BY region;
