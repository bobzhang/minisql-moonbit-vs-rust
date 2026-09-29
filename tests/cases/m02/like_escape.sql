-- LIKE ... ESCAPE c: the escape character makes the following % or _ (or
-- the escape character itself) match literally.

SELECT '50%' LIKE '50\%' ESCAPE '\', '500' LIKE '50\%' ESCAPE '\';
SELECT 'a_b' LIKE 'a\_b' ESCAPE '\', 'axb' LIKE 'a\_b' ESCAPE '\';
SELECT 'a\b' LIKE 'a\\b' ESCAPE '\';
-- Without ESCAPE, backslash is an ordinary character.
SELECT 'a\b' LIKE 'a\b', 'a%' LIKE 'a\%';
-- Any single character can be the escape.
SELECT '10%' LIKE '10!%' ESCAPE '!', 'a_b' LIKE 'a#_b' ESCAPE '#', 'x|y' LIKE 'x||y' ESCAPE '|';
-- The escape character may be a letter.
SELECT 'a%' LIKE 'az%' ESCAPE 'z', 'az%' LIKE 'az%' ESCAPE 'z';
-- Escaped and unescaped wildcards together.
SELECT '100% sure' LIKE '%\%%' ESCAPE '\', 'no percent' LIKE '%\%%' ESCAPE '\';
SELECT 'file_name.txt' LIKE '%\_%.txt' ESCAPE '\', 'filename.txt' LIKE '%\_%.txt' ESCAPE '\';
-- Using % itself as the escape: '%%' is a literal percent.
SELECT '%' LIKE '%%' ESCAPE '%', 'a' LIKE '%%' ESCAPE '%', 'a%' LIKE 'a%%' ESCAPE '%';
-- A NULL escape gives NULL.
SELECT 'a' LIKE 'a' ESCAPE NULL;
-- A non-ASCII escape character.
SELECT '5%' LIKE '5é%' ESCAPE 'é', '55' LIKE '5é%' ESCAPE 'é';
-- NOT LIKE with ESCAPE.
SELECT '50%' NOT LIKE '50\%' ESCAPE '\', '500' NOT LIKE '50\%' ESCAPE '\';
-- ESCAPE in WHERE.
CREATE TABLE t(id INTEGER, s TEXT);
INSERT INTO t VALUES (1, 'a_1'), (2, 'ab1'), (3, '50%'), (4, '50 percent'), (5, 'a\1');
SELECT id FROM t WHERE s LIKE 'a\_%' ESCAPE '\' ORDER BY id;
SELECT id FROM t WHERE s LIKE 'a_%' ORDER BY id;
SELECT id FROM t WHERE s LIKE '%!%' ESCAPE '!' ORDER BY id;
SELECT id FROM t WHERE s LIKE 'a\\%' ESCAPE '\' ORDER BY id;
-- The escape must be a single character.
SELECT 'a' LIKE 'a' ESCAPE 'xy';
SELECT 'a' LIKE 'a' ESCAPE '';
