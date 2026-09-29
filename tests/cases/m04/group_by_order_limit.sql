-- GROUP BY combined with ORDER BY (on keys, aggregates, aliases, ordinals),
-- LIMIT/OFFSET and SELECT DISTINCT over aggregated rows.
CREATE TABLE v(id INTEGER, author TEXT, genre TEXT, pages INTEGER);
INSERT INTO v VALUES
  (1, 'ann', 'sf', 300), (2, 'ann', 'sf', 250), (3, 'bob', 'crime', 400), (4, 'cy', 'sf', 120),
  (5, 'bob', 'poetry', 80), (6, 'dee', 'crime', 310), (7, 'ann', 'poetry', 60), (8, 'eli', 'sf', 500),
  (9, 'dee', 'crime', 290);

SELECT author, count(*) AS n FROM v GROUP BY author ORDER BY n DESC, author LIMIT 3;
SELECT author, sum(pages) FROM v GROUP BY author ORDER BY 2 DESC LIMIT 2 OFFSET 1;
SELECT genre, avg(pages) AS a FROM v GROUP BY genre ORDER BY a;
SELECT genre, max(pages) - min(pages) FROM v GROUP BY genre ORDER BY genre DESC LIMIT 1;
SELECT author FROM v GROUP BY author ORDER BY count(*), max(pages) DESC;
SELECT author, count(*) FROM v GROUP BY author ORDER BY author LIMIT 2, 2;

-- DISTINCT applied to aggregated rows.
SELECT DISTINCT count(*) FROM v GROUP BY author ORDER BY 1;
SELECT DISTINCT genre, count(*) > 1 FROM v GROUP BY genre, author ORDER BY 1, 2;

-- LIMIT 0 and negative LIMIT.
SELECT author, count(*) FROM v GROUP BY author ORDER BY author LIMIT 0;
SELECT author, count(*) FROM v GROUP BY author ORDER BY author LIMIT -1 OFFSET 3;

-- ORDER BY an aggregate that is not in the result.
SELECT genre FROM v GROUP BY genre ORDER BY sum(pages) DESC;
-- ORDER BY with NULLS LAST on an aggregate that can be NULL.
SELECT author, max(pages) FILTER (WHERE genre = 'sf') AS sfmax FROM v GROUP BY author ORDER BY sfmax DESC NULLS LAST, author;
-- ORDER BY an expression mixing an aggregate and a grouping column.
SELECT author, count(*) FROM v GROUP BY author ORDER BY count(*) * 10 + length(author) DESC, author;
