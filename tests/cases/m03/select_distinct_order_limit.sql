-- SELECT DISTINCT together with ORDER BY, LIMIT and OFFSET: duplicates are
-- removed first, then the result is sorted and limited.
CREATE TABLE t(cat TEXT, v INTEGER);
INSERT INTO t VALUES
  ('b', 1), ('a', 2), ('b', 1), ('c', 3), ('a', 2), ('b', 4), (NULL, 5), (NULL, 5), ('c', 3), ('a', NULL);

SELECT DISTINCT cat FROM t ORDER BY cat;
SELECT DISTINCT cat FROM t ORDER BY cat DESC NULLS LAST;
SELECT DISTINCT cat FROM t ORDER BY cat LIMIT 2;
SELECT DISTINCT cat FROM t ORDER BY cat LIMIT 2 OFFSET 2;
SELECT DISTINCT cat FROM t ORDER BY cat LIMIT 1, 10;

SELECT DISTINCT cat, v FROM t ORDER BY cat, v;
SELECT DISTINCT cat, v FROM t ORDER BY v DESC, cat LIMIT 3;
SELECT DISTINCT cat, v FROM t ORDER BY 2 NULLS LAST, 1 NULLS LAST LIMIT -1 OFFSET 3;

-- DISTINCT with an alias in ORDER BY.
SELECT DISTINCT upper(cat) AS u FROM t ORDER BY u DESC;
-- DISTINCT with WHERE.
SELECT DISTINCT v FROM t WHERE cat <> 'c' ORDER BY v;
-- DISTINCT result with ORDER BY on an expression of the selected column.
SELECT DISTINCT v FROM t ORDER BY v % 3, v;

-- LIMIT 0 and OFFSET past the distinct rows.
SELECT DISTINCT cat FROM t ORDER BY cat LIMIT 0;
SELECT DISTINCT cat FROM t ORDER BY cat LIMIT 10 OFFSET 4;

-- DISTINCT * over all columns.
SELECT DISTINCT * FROM t ORDER BY cat, v;
