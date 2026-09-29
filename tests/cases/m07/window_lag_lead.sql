-- lag(x) / lead(x): the value of x in the previous / next row of the
-- partition (in window order); NULL when there is no such row.
CREATE TABLE price(day INTEGER, sym TEXT, px REAL, PRIMARY KEY (sym, day));
INSERT INTO price VALUES
  (1, 'abc', 10.0), (2, 'abc', 10.5), (3, 'abc', 10.25), (4, 'abc', 11.0), (5, 'abc', NULL), (6, 'abc', 12.0),
  (1, 'xyz', 100.0), (2, 'xyz', 98.0), (4, 'xyz', 99.5);

-- Previous and next price per symbol.
SELECT sym, day, px, lag(px) OVER (PARTITION BY sym ORDER BY day), lead(px) OVER (PARTITION BY sym ORDER BY day)
FROM price ORDER BY sym, day;

-- Day-over-day change; NULL for the first row and around NULL prices.
SELECT sym, day, px - lag(px) OVER (PARTITION BY sym ORDER BY day) FROM price ORDER BY sym, day;

-- Without PARTITION BY, lag crosses symbol boundaries.
SELECT sym, day, lag(sym) OVER (ORDER BY sym, day), lead(day) OVER (ORDER BY sym, day) FROM price ORDER BY sym, day;

-- Descending window order reverses the meaning of lag/lead.
SELECT day, lag(day) OVER (ORDER BY day DESC), lead(day) OVER (ORDER BY day DESC) FROM price WHERE sym = 'abc' ORDER BY day;

-- lag of an expression, lead of a text column.
SELECT day, lag(px * 2) OVER (ORDER BY day), lead(sym || day) OVER (ORDER BY day) FROM price WHERE sym = 'xyz' ORDER BY day;

-- Detect gaps in the day sequence.
SELECT sym, day FROM (SELECT sym, day, lag(day) OVER (PARTITION BY sym ORDER BY day) AS prev FROM price)
WHERE day - prev > 1 ORDER BY sym, day;

-- lag/lead ignore the frame specification.
SELECT day, lag(day) OVER (ORDER BY day ROWS CURRENT ROW), lead(day) OVER (ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
FROM price WHERE sym = 'abc' ORDER BY day;

-- A single-row partition has neither previous nor next row.
SELECT sym, lag(day) OVER (PARTITION BY sym ORDER BY day), lead(day) OVER (PARTITION BY sym ORDER BY day)
FROM price WHERE day = 4 ORDER BY sym;

-- The type of the fetched value is preserved.
SELECT day, typeof(lag(px) OVER (ORDER BY day)), typeof(lag(day) OVER (ORDER BY day)) FROM price WHERE sym = 'abc' ORDER BY day;

-- Both in one expression: is the price a local maximum?
SELECT sym, day FROM (SELECT sym, day, px, lag(px) OVER w AS p, lead(px) OVER w AS n FROM price
  WINDOW w AS (PARTITION BY sym ORDER BY day)) WHERE px > p AND px > n ORDER BY sym, day;

-- Errors: wrong number of arguments.
SELECT lag() OVER (ORDER BY day) FROM price;
SELECT lead(px, 1, 0, 0) OVER (ORDER BY day) FROM price;
