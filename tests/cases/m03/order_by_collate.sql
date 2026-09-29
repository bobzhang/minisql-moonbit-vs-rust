-- COLLATE in ORDER BY and declared column collations.
CREATE TABLE t(id INTEGER, plain TEXT, nc TEXT COLLATE NOCASE, rt TEXT COLLATE RTRIM);
INSERT INTO t VALUES
  (1, 'b', 'b', 'b'),
  (2, 'A', 'A', 'a  '),
  (3, 'a', 'a', 'a'),
  (4, 'B', 'B', 'a '),
  (5, 'c', 'C', 'c'),
  (6, '_x', '_x', 'b ');

-- BINARY by default: uppercase before lowercase.
SELECT plain FROM t ORDER BY plain, id;
-- NOCASE collation on the ORDER BY term.
SELECT plain, id FROM t ORDER BY plain COLLATE NOCASE, id;
SELECT plain, id FROM t ORDER BY plain COLLATE NOCASE DESC, id;

-- The declared collation of the column is used automatically.
SELECT nc, id FROM t ORDER BY nc, id;
SELECT nc, id FROM t ORDER BY nc DESC, id DESC;
-- ...and can be overridden by an explicit COLLATE.
SELECT nc, id FROM t ORDER BY nc COLLATE BINARY, id;

-- RTRIM ignores trailing spaces.
SELECT '[' || rt || ']', id FROM t ORDER BY rt, id;
SELECT '[' || rt || ']', id FROM t ORDER BY rt COLLATE BINARY, id;

-- An alias of a NOCASE column keeps its collation.
SELECT nc AS k, id FROM t ORDER BY k, id;
-- An ordinal referring to a NOCASE column also keeps it.
SELECT nc, id FROM t ORDER BY 1, 2 DESC;
-- An expression built from the column (||) loses the declared collation.
SELECT nc || '', id FROM t ORDER BY 1, 2;

-- COLLATE on a later sort key.
SELECT id % 2 AS p, plain FROM t ORDER BY p, plain COLLATE NOCASE, id;

-- NOCASE only folds ASCII letters.
CREATE TABLE u(s TEXT);
INSERT INTO u VALUES ('É'), ('é'), ('E'), ('e'), ('f');
SELECT s FROM u ORDER BY s COLLATE NOCASE, s;

-- Unknown collation is an error.
SELECT plain FROM t ORDER BY plain COLLATE nosuchcoll;
