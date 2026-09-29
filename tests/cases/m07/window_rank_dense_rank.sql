-- rank() and dense_rank(): peers (rows with equal ORDER BY values) get the
-- same rank; rank() leaves gaps after ties, dense_rank() does not.
CREATE TABLE r(id INTEGER PRIMARY KEY, grp TEXT, score INTEGER);
INSERT INTO r VALUES
  (1, 'a', 90), (2, 'a', 85), (3, 'a', 90), (4, 'a', 70), (5, 'a', 85), (6, 'a', 90),
  (7, 'b', 50), (8, 'b', 50), (9, 'b', NULL), (10, 'b', NULL), (11, 'b', 60), (12, 'c', 1);

-- Ranking by score descending over the whole table.
SELECT id, score, rank() OVER (ORDER BY score DESC), dense_rank() OVER (ORDER BY score DESC) FROM r ORDER BY id;

-- Ranking within partitions.
SELECT id, grp, score, rank() OVER (PARTITION BY grp ORDER BY score DESC),
  dense_rank() OVER (PARTITION BY grp ORDER BY score DESC) FROM r ORDER BY id;

-- NULLs are peers of each other; ascending puts them first.
SELECT id, score, rank() OVER (PARTITION BY grp ORDER BY score), dense_rank() OVER (PARTITION BY grp ORDER BY score)
FROM r WHERE grp = 'b' ORDER BY id;
-- NULLS LAST in the window ORDER BY.
SELECT id, score, rank() OVER (ORDER BY score NULLS LAST) FROM r WHERE grp = 'b' ORDER BY id;

-- Without ORDER BY every row is a peer: all ranks are 1.
SELECT id, rank() OVER (), dense_rank() OVER (), rank() OVER (PARTITION BY grp) FROM r ORDER BY id;

-- With unique keys rank = dense_rank = row_number.
SELECT id, rank() OVER (ORDER BY id), dense_rank() OVER (ORDER BY id), row_number() OVER (ORDER BY id)
FROM r WHERE id <= 4 ORDER BY id;

-- Ranking by multiple keys: peers need equality on all keys.
SELECT id, grp, score, rank() OVER (ORDER BY grp, score DESC) FROM r ORDER BY id;

-- Ranking by an expression (score rounded down to tens).
SELECT id, score, dense_rank() OVER (ORDER BY score / 10 DESC) FROM r WHERE score IS NOT NULL ORDER BY id;

-- Top-2 distinct scores per group using dense_rank in a subquery.
SELECT grp, score FROM (SELECT DISTINCT grp, score, dense_rank() OVER (PARTITION BY grp ORDER BY score DESC) AS dr FROM r)
WHERE dr <= 2 AND score IS NOT NULL ORDER BY grp, score DESC;

-- rank and dense_rank ignore any frame specification.
SELECT id, rank() OVER (ORDER BY score DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW),
  dense_rank() OVER (ORDER BY score DESC ROWS 1 PRECEDING) FROM r WHERE grp = 'a' ORDER BY id;

-- Ranking text with a collation: NOCASE makes 'A' and 'a' peers.
CREATE TABLE names(n TEXT);
INSERT INTO names VALUES ('b'), ('A'), ('a'), ('B'), ('c');
SELECT n, rank() OVER (ORDER BY n COLLATE NOCASE), rank() OVER (ORDER BY n) FROM names ORDER BY n;

-- Largest rank equals count when there are no ties at the end.
SELECT max(rk), count(*) FROM (SELECT rank() OVER (ORDER BY score) AS rk FROM r WHERE grp = 'a');
