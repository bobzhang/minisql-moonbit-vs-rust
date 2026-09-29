-- Aggregation over joined rows: GROUP BY columns of either side, HAVING,
-- aggregates of NULL-extended columns, DISTINCT inside aggregates.
CREATE TABLE authors(aid INTEGER PRIMARY KEY, aname TEXT, country TEXT);
CREATE TABLE books(bid INTEGER PRIMARY KEY, aid INTEGER, title TEXT, pages INTEGER, yr INTEGER);
INSERT INTO authors VALUES (1, 'austen', 'uk'), (2, 'borges', 'ar'), (3, 'cortazar', 'ar'), (4, 'dickens', 'uk'), (5, 'eco', 'it');
INSERT INTO books VALUES
  (1, 1, 'emma', 400, 1815), (2, 1, 'persuasion', 250, 1817), (3, 2, 'ficciones', 200, 1944),
  (4, 2, 'aleph', 150, 1949), (5, 3, 'rayuela', 600, 1963), (6, 4, 'bleak house', 900, 1853),
  (7, 4, 'hard times', 300, 1854), (8, 4, 'dorrit', 800, 1857), (9, 9, 'orphan', 100, 2000);

SELECT aname, count(*), sum(pages) FROM authors JOIN books USING (aid) GROUP BY aname ORDER BY aname;
-- LEFT JOIN: authors without books have count 0 and NULL sums.
SELECT aname, count(bid), sum(pages), total(pages), max(yr) FROM authors LEFT JOIN books USING (aid) GROUP BY aid ORDER BY aid;
-- Group by a column of the other table.
SELECT country, count(*), min(yr), max(yr) FROM authors JOIN books USING (aid) GROUP BY country ORDER BY country;
SELECT country, count(DISTINCT aid), count(*) FROM authors JOIN books USING (aid) GROUP BY country ORDER BY country;
-- HAVING on joined aggregates.
SELECT aname FROM authors JOIN books USING (aid) GROUP BY aname HAVING sum(pages) > 500 ORDER BY aname;
SELECT country FROM authors LEFT JOIN books USING (aid) GROUP BY country HAVING count(bid) = 0 ORDER BY country;
-- Aggregate without GROUP BY over a join.
SELECT count(*), sum(pages), avg(pages) FROM authors JOIN books ON books.aid = authors.aid;
SELECT count(*), count(title) FROM authors LEFT JOIN books ON books.aid = authors.aid;
-- group_concat with ORDER BY inside the aggregate.
SELECT aname, group_concat(title, ', ' ORDER BY yr) FROM authors JOIN books USING (aid) GROUP BY aname ORDER BY aname;
-- Bare column alongside max(): the row with the maximum supplies title.
SELECT aname, max(pages), title FROM authors JOIN books USING (aid) GROUP BY aname ORDER BY aname;
-- FILTER inside a joined aggregate.
SELECT country, count(*) FILTER (WHERE yr < 1900) FROM authors JOIN books USING (aid) GROUP BY country ORDER BY country;
-- Joining two aggregated subqueries.
SELECT a.country, a.n_authors, b.n_books FROM
  (SELECT country, count(*) AS n_authors FROM authors GROUP BY country) a
  LEFT JOIN (SELECT country, count(*) AS n_books FROM authors JOIN books USING (aid) GROUP BY country) b
  USING (country) ORDER BY a.country;
-- A join multiplies rows: summing a left-side value per book double counts.
SELECT sum(authors.aid) FROM authors JOIN books USING (aid);
SELECT sum(DISTINCT authors.aid) FROM authors JOIN books USING (aid);
