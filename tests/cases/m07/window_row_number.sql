-- row_number(): sequential numbering in window order, restarting in each
-- partition. The window ORDER BY keys are unique so the numbering is fully
-- determined.
CREATE TABLE s(id INTEGER PRIMARY KEY, team TEXT, player TEXT, pts INTEGER);
INSERT INTO s VALUES
  (1, 'red', 'ann', 30), (2, 'red', 'bob', 12), (3, 'red', 'cy', 25),
  (4, 'blue', 'dee', 18), (5, 'blue', 'ed', 40), (6, 'green', 'fi', 7),
  (7, 'blue', 'gus', 22), (8, 'red', 'hal', NULL);

-- Numbering over the whole table.
SELECT id, row_number() OVER (ORDER BY id) FROM s ORDER BY id;
SELECT player, row_number() OVER (ORDER BY player DESC) FROM s ORDER BY player;

-- Numbering within partitions.
SELECT team, player, row_number() OVER (PARTITION BY team ORDER BY player) FROM s ORDER BY team, player;

-- Numbering by a descending expression; NULL sorts first ascending, last descending.
SELECT player, pts, row_number() OVER (ORDER BY pts DESC) FROM s ORDER BY player;
SELECT player, pts, row_number() OVER (ORDER BY pts) FROM s ORDER BY player;

-- Multiple ORDER BY terms in the window.
SELECT team, pts, row_number() OVER (ORDER BY team, pts DESC) FROM s ORDER BY team, pts DESC;

-- The result column can be used in expressions.
SELECT player, row_number() OVER (ORDER BY id) * 10 + 1 FROM s ORDER BY id;

-- The window order is independent of the query's final ORDER BY.
SELECT player, row_number() OVER (ORDER BY pts DESC) AS rn FROM s ORDER BY id DESC;

-- Filtering on row_number requires a subquery.
SELECT team, player FROM (SELECT team, player, row_number() OVER (PARTITION BY team ORDER BY id) AS rn FROM s)
WHERE rn = 1 ORDER BY team;

-- row_number() with an empty OVER numbers rows in an unspecified order, but
-- the set of numbers is always 1..n.
SELECT count(*), sum(rn), min(rn), max(rn) FROM (SELECT row_number() OVER () AS rn FROM s);
SELECT team, count(*), sum(rn), max(rn) FROM (SELECT team, row_number() OVER (PARTITION BY team) AS rn FROM s) GROUP BY team ORDER BY team;

-- WHERE is applied before window functions are computed.
SELECT player, row_number() OVER (ORDER BY id) FROM s WHERE pts > 20 ORDER BY id;

-- Window over an empty result produces no rows.
SELECT player, row_number() OVER (ORDER BY id) FROM s WHERE pts > 1000;

-- Partition by an expression.
SELECT id, id % 3, row_number() OVER (PARTITION BY id % 3 ORDER BY id) FROM s ORDER BY id;

-- typeof of the result is integer.
SELECT DISTINCT typeof(row_number() OVER (ORDER BY id)) FROM s;
