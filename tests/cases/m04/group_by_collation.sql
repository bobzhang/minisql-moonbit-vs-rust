-- GROUP BY uses the collation of the grouping expression. A NOCASE column
-- puts 'a' and 'A' in the same group. The group key shown is normalized with
-- upper()/lower() so the test does not depend on which spelling is kept.
CREATE TABLE t(name TEXT COLLATE NOCASE, tag TEXT, n INTEGER);
INSERT INTO t VALUES ('apple', 'x', 1), ('APPLE', 'X', 2), ('Apple', 'y', 3), ('pear', 'y', 4), ('Pear', 'Y', 5), ('fig', 'x', 6);

SELECT upper(name), count(*), sum(n) FROM t GROUP BY name ORDER BY 1;
-- tag has BINARY collation: 'x' and 'X' are different groups.
SELECT tag, count(*), sum(n) FROM t GROUP BY tag ORDER BY tag;
-- COLLATE in GROUP BY.
SELECT lower(tag), count(*), sum(n) FROM t GROUP BY tag COLLATE NOCASE ORDER BY 1;
SELECT count(*), sum(n) FROM t GROUP BY name COLLATE BINARY ORDER BY 2;

-- RTRIM: trailing spaces are ignored for grouping.
CREATE TABLE r(s TEXT COLLATE RTRIM, n INTEGER);
INSERT INTO r VALUES ('a', 1), ('a ', 2), ('a  ', 3), ('b', 4), (' a', 5);
SELECT rtrim(s), count(*), sum(n) FROM r GROUP BY s ORDER BY sum(n);

-- Multi-column grouping with one NOCASE column.
SELECT upper(name), lower(tag), count(*) FROM t GROUP BY name, tag COLLATE NOCASE ORDER BY 1, 2;

-- Grouping by an expression drops the column collation.
SELECT name || '' AS k, count(*) FROM t GROUP BY k ORDER BY k;

-- Aggregates within NOCASE groups.
SELECT upper(name), group_concat(tag, '' ORDER BY n) FROM t GROUP BY name ORDER BY 1;
