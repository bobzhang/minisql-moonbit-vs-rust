-- @db file
-- Index b-trees must be ordered by each column's collation and direction:
-- NOCASE (from the column declaration or the index), RTRIM, and DESC
-- columns. integrity_check looks every row up in each index using the
-- index's own ordering, so a mis-sorted index is reported.
-- @phase engine
CREATE TABLE p(id INTEGER PRIMARY KEY, name TEXT COLLATE NOCASE, code TEXT, tag TEXT COLLATE RTRIM, n INTEGER);
CREATE INDEX p_name ON p(name);
CREATE INDEX p_code_nocase ON p(code COLLATE NOCASE DESC, n);
CREATE INDEX p_tag ON p(tag);
CREATE INDEX p_n_desc ON p(n DESC, id DESC);
CREATE UNIQUE INDEX p_code_u ON p(code COLLATE NOCASE, id);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 3000)
INSERT INTO p SELECT i,
  CASE i % 3 WHEN 0 THEN 'Name' WHEN 1 THEN 'name' ELSE 'NAME' END || (i % 500),
  CASE i % 2 WHEN 0 THEN 'abc' ELSE 'ABC' END || char(65 + i % 26) || (i % 7),
  't' || (i % 40) || CASE WHEN i % 4 = 0 THEN '   ' ELSE '' END,
  (i * 37) % 101 FROM c;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*) FROM p INDEXED BY p_name WHERE name = 'NAME17';
SELECT count(*) FROM p INDEXED BY p_code_nocase WHERE code = 'abcd3' COLLATE NOCASE;
SELECT count(*) FROM p INDEXED BY p_tag WHERE tag = 't5';
SELECT id, n FROM p INDEXED BY p_n_desc ORDER BY n DESC, id DESC LIMIT 3;
SELECT lower(min(name)), count(DISTINCT name) FROM p;
