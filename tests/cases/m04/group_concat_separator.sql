-- group_concat(x, sep): custom separators, NULL separator, multi-character
-- and empty separators, and separators computed per row.
CREATE TABLE t(k INTEGER, v TEXT, sep TEXT);
INSERT INTO t VALUES (1, 'a', '-'), (2, 'b', '+'), (3, 'c', '*'), (4, NULL, '#'), (5, 'e', '/');

SELECT group_concat(v, ';' ORDER BY k) FROM t;
SELECT group_concat(v, ', ' ORDER BY k) FROM t;
SELECT group_concat(v, '' ORDER BY k) FROM t;
SELECT group_concat(v, ' and ' ORDER BY k DESC) FROM t;
-- A NULL separator acts like an empty string.
SELECT group_concat(v, NULL ORDER BY k) FROM t;
-- Numeric separator is converted to text.
SELECT group_concat(v, 0 ORDER BY k) FROM t;
-- Non-ASCII separator.
SELECT group_concat(v, '→' ORDER BY k) FROM t;

-- The separator may be any expression.
SELECT group_concat(v, upper('x') || '_' ORDER BY k) FROM t;

-- Grouped with a separator.
CREATE TABLE g(grp TEXT, n INTEGER);
INSERT INTO g VALUES ('x', 3), ('x', 1), ('x', 2), ('y', 10), ('z', NULL);
SELECT grp, group_concat(n, '|' ORDER BY n) FROM g GROUP BY grp ORDER BY grp;
SELECT grp, group_concat(n, '' ORDER BY n DESC) FROM g GROUP BY grp ORDER BY grp;

-- Only one value: the separator never appears.
SELECT group_concat(v, '###') FROM t WHERE k = 2;

-- Too many arguments.
SELECT group_concat(v, ',', ';') FROM t;
