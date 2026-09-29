-- group_concat(x) joins the non-NULL values with ',' (ORDER BY inside the
-- call fixes the order). NULL values are skipped; all-NULL/empty input
-- gives NULL.
CREATE TABLE t(g TEXT, v);
INSERT INTO t VALUES ('a', 'x'), ('a', 'y'), ('a', 'z'), ('b', 'only'), ('c', NULL), ('d', NULL), ('d', 'q'), ('d', NULL);
SELECT group_concat(v ORDER BY v) FROM t;
SELECT g, group_concat(v ORDER BY v) FROM t GROUP BY g ORDER BY g;
SELECT g, typeof(group_concat(v ORDER BY v)) FROM t GROUP BY g ORDER BY g;

-- Empty input.
CREATE TABLE e(v);
SELECT group_concat(v), typeof(group_concat(v)) FROM e;

-- Numbers are converted to text.
CREATE TABLE n(k INTEGER, v);
INSERT INTO n VALUES (1, 1), (2, 2.5), (3, -3), (4, 100), (5, 0.125);
SELECT group_concat(v ORDER BY k) FROM n;
SELECT typeof(group_concat(v ORDER BY k)) FROM n;
SELECT group_concat(v * 2 ORDER BY k) FROM n;

-- A single value is returned as text without any separator.
SELECT group_concat(v), typeof(group_concat(v)) FROM n WHERE k = 1;

-- Empty strings are values (not NULL): separators still appear.
CREATE TABLE s(k INTEGER, v TEXT);
INSERT INTO s VALUES (1, ''), (2, ''), (3, 'a'), (4, '');
SELECT group_concat(v ORDER BY k) FROM s;
SELECT length(group_concat(v ORDER BY k)) FROM s;
SELECT '[' || group_concat(v) || ']' FROM s WHERE k = 1;

-- Non-ASCII text.
CREATE TABLE u(k INTEGER, v TEXT);
INSERT INTO u VALUES (1, 'é'), (2, '中文'), (3, '😀');
SELECT group_concat(v ORDER BY k) FROM u;
SELECT length(group_concat(v ORDER BY k)) FROM u;

-- Expressions and concatenation inside.
SELECT group_concat(k || ':' || v ORDER BY k) FROM n;
SELECT group_concat(upper(v) ORDER BY v DESC) FROM t WHERE g = 'a';

-- group_concat with no arguments is an error.
SELECT group_concat() FROM t;
