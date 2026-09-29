-- Recursive CTEs whose body has several anchor selects and/or several
-- recursive selects combined with UNION / UNION ALL. All non-recursive
-- selects come first; each recursive select reads the rows produced so far.
-- Two anchors, one recursive arm.
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT 100 UNION ALL SELECT x + 1 FROM c WHERE x % 100 < 3)
SELECT x FROM c ORDER BY x;

-- One anchor, two recursive arms (x*2 and x*3), UNION ALL keeps duplicates.
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x * 2 FROM c WHERE x < 4 UNION ALL SELECT x * 3 FROM c WHERE x < 4)
SELECT x, count(*) FROM c GROUP BY x ORDER BY x;

-- Same with UNION: duplicates removed and recursion still terminates.
WITH RECURSIVE c(x) AS (SELECT 1 UNION SELECT x * 2 FROM c WHERE x < 50 UNION SELECT x * 3 FROM c WHERE x < 50)
SELECT group_concat(x, ',' ORDER BY x) FROM c;

-- Two recursive arms walking a graph in both directions.
CREATE TABLE link(a INTEGER, b INTEGER);
INSERT INTO link VALUES (1, 2), (2, 3), (4, 3), (5, 4), (6, 7);
WITH RECURSIVE r(n) AS (SELECT 1
  UNION SELECT link.b FROM link JOIN r ON link.a = r.n
  UNION SELECT link.a FROM link JOIN r ON link.b = r.n)
SELECT n FROM r ORDER BY n;

-- Anchor rows from a table plus a literal anchor.
WITH RECURSIVE r(n, src) AS (SELECT a, 'tbl' FROM link WHERE a > 5 UNION ALL SELECT 0, 'lit'
  UNION ALL SELECT n + 10, src FROM r WHERE n < 20)
SELECT n, src FROM r ORDER BY src, n;

-- Recursive arms producing different tags.
WITH RECURSIVE c(tag, v) AS (SELECT 'start', 1
  UNION ALL SELECT 'dbl', v * 2 FROM c WHERE v < 8 AND tag <> 'inc'
  UNION ALL SELECT 'inc', v + 1 FROM c WHERE v < 8 AND tag <> 'dbl')
SELECT tag, v FROM c ORDER BY v, tag;

-- Totals across all arms.
WITH RECURSIVE c(x) AS (SELECT 2 UNION ALL SELECT x + 2 FROM c WHERE x < 10 UNION ALL SELECT x + 3 FROM c WHERE x < 3)
SELECT count(*), sum(x) FROM c;

-- A single anchor from VALUES with several rows, UNION dedup across arms.
WITH RECURSIVE c(x) AS (VALUES (1), (2) UNION SELECT x + 2 FROM c WHERE x < 6 UNION SELECT x + 1 FROM c WHERE x < 3)
SELECT x FROM c ORDER BY x;

-- Error: a non-recursive select after a recursive one is not allowed.
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 3 UNION ALL SELECT 99) SELECT x FROM c;
