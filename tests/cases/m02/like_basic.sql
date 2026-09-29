-- LIKE: % matches any sequence (including empty), _ matches exactly one
-- character. ASCII letters match case-insensitively.

SELECT 'abc' LIKE 'abc', 'abc' LIKE 'ab', 'abc' LIKE 'abcd';
SELECT 'abc' LIKE 'a%', 'abc' LIKE '%c', 'abc' LIKE '%b%', 'abc' LIKE '%', 'abc' LIKE '%%%';
SELECT 'abc' LIKE 'a_c', 'abc' LIKE '___', 'abc' LIKE '__', 'abc' LIKE '____', 'abc' LIKE '_%_';
SELECT '' LIKE '', '' LIKE '%', '' LIKE '_', 'a' LIKE '';
-- Case-insensitive for ASCII.
SELECT 'ABC' LIKE 'abc', 'abc' LIKE 'A%', 'MiXeD' LIKE 'mixed', 'z' LIKE 'Z';
-- NOT LIKE.
SELECT 'abc' NOT LIKE 'a%', 'abc' NOT LIKE 'x%';
-- NULL on either side gives NULL.
SELECT NULL LIKE 'a', 'a' LIKE NULL, NULL NOT LIKE '%';
-- Other characters are literal, including regex-like ones.
SELECT 'a.c' LIKE 'a.c', 'abc' LIKE 'a.c', 'a*c' LIKE 'a*c', '[a]' LIKE '[a]', 'a+' LIKE 'a+';
-- % in the middle, multiple %.
SELECT 'hello world' LIKE 'h%o%d', 'hello world' LIKE '%o w%', 'hello' LIKE '%l%l%', 'helo' LIKE '%l%l%';
-- Numbers are converted to text first.
SELECT 123 LIKE '1%', 123 LIKE '%3', 1.5 LIKE '1._', 100 LIKE '1__';
-- LIKE in WHERE.
CREATE TABLE t(id INTEGER, name TEXT);
INSERT INTO t VALUES (1, 'Alice'), (2, 'alfred'), (3, 'Bob'), (4, 'ALBERT'), (5, NULL), (6, 'Al'), (7, 'xAlx');
SELECT id FROM t WHERE name LIKE 'al%' ORDER BY id;
SELECT id FROM t WHERE name LIKE '%al%' ORDER BY id;
SELECT id FROM t WHERE name NOT LIKE 'al%' ORDER BY id;
SELECT id FROM t WHERE name LIKE '__' ORDER BY id;
SELECT id FROM t WHERE name LIKE '%t' ORDER BY id;
SELECT id, name LIKE 'a%' FROM t ORDER BY id;
-- LIKE has the same precedence as '='.
SELECT 'a' LIKE 'A' = 1, 'a' || 'b' LIKE 'AB';
