-- ORDER BY with an integer constant refers to a result column by position
-- (1-based). Out-of-range ordinals are errors.
CREATE TABLE t(id INTEGER, name TEXT, score REAL);
INSERT INTO t VALUES (1, 'mia', 7.5), (2, 'al', 9.0), (3, 'zed', 7.5), (4, 'bo', NULL), (5, 'cy', 3.25);

SELECT id, name FROM t ORDER BY 2;
SELECT id, name FROM t ORDER BY 2 DESC;
SELECT name, score FROM t ORDER BY 2, 1;
SELECT name, score FROM t ORDER BY 2 DESC, 1 DESC;

-- Ordinals refer to expressions too.
SELECT name, length(name) FROM t ORDER BY 2 DESC, 1;
SELECT id * 3 % 5, id FROM t ORDER BY 1, 2;

-- Ordinals with *.
SELECT * FROM t ORDER BY 3, 1;
SELECT * FROM t ORDER BY 2;

-- Mixing ordinals, aliases and plain expressions.
SELECT name AS n, score FROM t ORDER BY 2 DESC, n;
SELECT id, name FROM t ORDER BY id % 2, 2;

-- Ordinal with NULLS LAST and COLLATE.
SELECT name, score FROM t ORDER BY 2 NULLS LAST, 1;
CREATE TABLE w(s TEXT);
INSERT INTO w VALUES ('b'), ('A'), ('a2'), ('C');
SELECT s FROM w ORDER BY 1;
SELECT s FROM w ORDER BY 1 COLLATE NOCASE;

-- A non-integer constant is not an ordinal: it is a constant sort key, so
-- the ORDER BY term below leaves the tie to be broken by the second key.
SELECT id FROM t ORDER BY 'x', 1 DESC;

-- Out of range ordinals.
SELECT id, name FROM t ORDER BY 0;
SELECT id, name FROM t ORDER BY 3;
SELECT * FROM t ORDER BY 4;
SELECT id FROM t ORDER BY 1, 2;
