-- sum() and avg() as window functions: running totals, partition totals,
-- moving averages; NULL handling and integer/real result types.
CREATE TABLE m(id INTEGER PRIMARY KEY, acct TEXT, amt INTEGER);
INSERT INTO m VALUES (1, 'a', 10), (2, 'a', 20), (3, 'a', NULL), (4, 'a', 5),
  (5, 'b', 100), (6, 'b', -40), (7, 'b', 15), (8, 'c', NULL);

-- Running total over the whole table and per account.
SELECT id, sum(amt) OVER (ORDER BY id), sum(amt) OVER (PARTITION BY acct ORDER BY id) FROM m ORDER BY id;

-- Partition totals (no ORDER BY: frame is the whole partition).
SELECT id, acct, sum(amt) OVER (PARTITION BY acct), avg(amt) OVER (PARTITION BY acct) FROM m ORDER BY id;

-- Grand total and share of total.
SELECT id, amt, sum(amt) OVER (), round(amt * 100.0 / sum(amt) OVER (), 3) FROM m ORDER BY id;

-- Running average; avg ignores NULLs and returns REAL.
SELECT id, avg(amt) OVER (ORDER BY id), typeof(avg(amt) OVER (ORDER BY id)) FROM m ORDER BY id;

-- Moving sum/average over the current and previous row.
SELECT id, sum(amt) OVER w, avg(amt) OVER w FROM m WINDOW w AS (ORDER BY id ROWS 1 PRECEDING) ORDER BY id;

-- A partition where every value is NULL: sum and avg are NULL.
SELECT id, sum(amt) OVER (PARTITION BY acct), avg(amt) OVER (PARTITION BY acct) FROM m WHERE acct = 'c';

-- Integer sums stay integer; a REAL input makes the sum REAL.
SELECT id, typeof(sum(amt) OVER (ORDER BY id)) FROM m WHERE acct = 'a' ORDER BY id;
SELECT id, sum(x) OVER (ORDER BY id) FROM (SELECT id, CASE WHEN id = 2 THEN 2.5 ELSE id END AS x FROM m WHERE id <= 4) ORDER BY id;

-- Sum over an expression.
SELECT id, sum(amt * 2 + 1) OVER (PARTITION BY acct ORDER BY id) FROM m ORDER BY id;

-- Descending running total (a "remaining" balance).
SELECT id, sum(amt) OVER (PARTITION BY acct ORDER BY id DESC) FROM m ORDER BY id;

-- Integer overflow in a window sum is an error.
CREATE TABLE big(id INTEGER PRIMARY KEY, v INTEGER);
INSERT INTO big VALUES (1, 9223372036854775807), (2, 1), (3, -5);
SELECT id, sum(v) OVER (ORDER BY id) FROM big ORDER BY id;
-- A frame that never adds the two large values together is fine.
SELECT id, sum(v) OVER (ORDER BY id ROWS CURRENT ROW) FROM big ORDER BY id;
-- avg does not overflow.
SELECT id, avg(v) OVER (ORDER BY id ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING) FROM big ORDER BY id;

-- Sum of text values that look like numbers.
CREATE TABLE tx(id INTEGER PRIMARY KEY, s TEXT);
INSERT INTO tx VALUES (1, '5'), (2, '7'), (3, '1.5');
SELECT id, sum(s) OVER (ORDER BY id), avg(s) OVER (ORDER BY id) FROM tx ORDER BY id;
