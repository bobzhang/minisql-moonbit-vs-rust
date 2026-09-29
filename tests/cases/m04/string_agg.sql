-- string_agg(x, sep) is group_concat with a required separator.
CREATE TABLE t(g TEXT, k INTEGER, v TEXT);
INSERT INTO t VALUES ('a', 1, 'red'), ('a', 2, 'green'), ('a', 3, NULL), ('b', 1, 'blue'), ('c', 1, NULL);
SELECT string_agg(v, ',' ORDER BY k) FROM t WHERE g = 'a';
SELECT g, string_agg(v, '; ' ORDER BY v) FROM t GROUP BY g ORDER BY g;
SELECT string_agg(v, '' ORDER BY g, k) FROM t;
SELECT string_agg(v, NULL ORDER BY g DESC, k DESC) FROM t;

-- Same result as group_concat with the same separator.
SELECT string_agg(v, '-' ORDER BY v) = group_concat(v, '-' ORDER BY v) FROM t;

-- Empty input and all-NULL input give NULL.
SELECT string_agg(v, ',') FROM t WHERE g = 'none';
SELECT string_agg(v, ','), typeof(string_agg(v, ',')) FROM t WHERE g = 'c';

-- Numbers.
CREATE TABLE n(x);
INSERT INTO n VALUES (3), (1.5), (-2);
SELECT string_agg(x, ' ' ORDER BY x) FROM n;
SELECT string_agg(x * 10, '/' ORDER BY x DESC) FROM n;

-- With DISTINCT: not allowed with two arguments.
SELECT string_agg(DISTINCT v, ',') FROM t;
-- One argument is not enough.
SELECT string_agg(v) FROM t;

-- With FILTER.
SELECT string_agg(v, ',' ORDER BY k DESC) FILTER (WHERE g = 'a') FROM t;
