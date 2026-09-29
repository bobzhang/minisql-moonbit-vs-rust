-- @db file
-- Index keys that overflow index pages (the local limit on index pages is
-- smaller than on table leaves). A plain index on long text, a UNIQUE
-- constraint on long text (sqlite_autoindex), and a composite index whose
-- second column follows a long first column. Queries that SQLite answers
-- from the indexes must return the same rows when the engine uses them.
-- @phase sqlite
PRAGMA page_size = 1024;
CREATE TABLE docs(id INTEGER PRIMARY KEY, title TEXT UNIQUE, body TEXT, rank INTEGER);
CREATE INDEX docs_body ON docs(body);
CREATE INDEX docs_body_rank ON docs(body, rank);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 400)
INSERT INTO docs SELECT i,
  'title-' || printf('%0*d', 100 + (i * 37) % 900, i),
  printf('%0*d', 150 + (i * 53) % 3000, (i * 7) % 400),
  i % 10 FROM c;
-- @phase engine
SELECT count(*), sum(length(title)), sum(length(body)), sum(rank) FROM docs;
SELECT id, length(title) FROM docs WHERE title = 'title-' || printf('%0*d', 100 + (123 * 37) % 900, 123);
-- Not present: right number, wrong width (no rows).
SELECT id FROM docs WHERE title = 'title-' || printf('%0*d', 101, 124);
SELECT id FROM docs WHERE title = 'title-' || printf('%0*d', 101, 73);
SELECT count(*) FROM docs WHERE title > 'title-' || printf('%0400d', 1);
SELECT id, length(body) FROM docs WHERE body = printf('%0*d', 150 + (200 * 53) % 3000, (200 * 7) % 400);
SELECT id, rank FROM docs WHERE body = printf('%0*d', 150 + (17 * 53) % 3000, (17 * 7) % 400) AND rank = 7;
SELECT id FROM docs ORDER BY body, id LIMIT 8;
SELECT id FROM docs ORDER BY title DESC LIMIT 5;
SELECT id FROM docs ORDER BY length(title), id LIMIT 5;
SELECT count(DISTINCT body), count(DISTINCT title) FROM docs;
SELECT min(body) = (SELECT body FROM docs ORDER BY body LIMIT 1), length(max(title)) FROM docs;
SELECT rank, count(*) FROM docs WHERE body > printf('%0700d', 0) GROUP BY rank ORDER BY rank;
