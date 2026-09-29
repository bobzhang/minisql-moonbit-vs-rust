-- Recursive CTEs over text: splitting delimited strings, reversing,
-- character-by-character scans and string building.
CREATE TABLE csv(id INTEGER PRIMARY KEY, line TEXT);
INSERT INTO csv VALUES (1, 'red,green,blue'), (2, 'one'), (3, ''), (4, 'a,,b,');

-- Split each line on commas: (id, index, piece). Empty pieces are kept.
WITH RECURSIVE split(id, idx, piece, rest) AS (
  SELECT id, 0, NULL, line || ',' FROM csv
  UNION ALL
  SELECT id, idx + 1, substr(rest, 1, instr(rest, ',') - 1), substr(rest, instr(rest, ',') + 1)
  FROM split WHERE rest <> '')
SELECT id, idx, piece FROM split WHERE idx > 0 ORDER BY id, idx;

-- Number of pieces per line.
WITH RECURSIVE split(id, idx, rest) AS (
  SELECT id, 0, line || ',' FROM csv
  UNION ALL
  SELECT id, idx + 1, substr(rest, instr(rest, ',') + 1) FROM split WHERE rest <> '')
SELECT id, max(idx) FROM split GROUP BY id ORDER BY id;

-- Reverse a string one character at a time (works for non-ASCII).
WITH RECURSIVE r(i, acc) AS (SELECT 1, '' UNION ALL SELECT i + 1, substr('héllo wörld', i, 1) || acc FROM r WHERE i <= length('héllo wörld'))
SELECT acc FROM r WHERE i = length('héllo wörld') + 1;

-- Characters of a word with their unicode code points.
WITH RECURSIVE ch(i, c) AS (SELECT 1, substr('Añ中', 1, 1) UNION ALL SELECT i + 1, substr('Añ中', i + 1, 1) FROM ch WHERE i < length('Añ中'))
SELECT i, c, unicode(c) FROM ch ORDER BY i;

-- Count vowels in a sentence.
WITH RECURSIVE ch(i, c) AS (SELECT 1, substr('the quick brown fox', 1, 1) UNION ALL
  SELECT i + 1, substr('the quick brown fox', i + 1, 1) FROM ch WHERE i < length('the quick brown fox'))
SELECT sum(c IN ('a', 'e', 'i', 'o', 'u')), count(*) FROM ch;

-- Character frequency table.
WITH RECURSIVE ch(i, c) AS (SELECT 1, substr('mississippi', 1, 1) UNION ALL
  SELECT i + 1, substr('mississippi', i + 1, 1) FROM ch WHERE i < 11)
SELECT c, count(*) FROM ch GROUP BY c ORDER BY count(*) DESC, c;

-- Repeat a string n times (a replacement for a missing repeat()).
WITH RECURSIVE rep(n, s) AS (SELECT 1, 'ab' UNION ALL SELECT n + 1, s || 'ab' FROM rep WHERE n < 5)
SELECT n, s, length(s) FROM rep ORDER BY n;

-- Binary representation of integers via repeated halving.
WITH RECURSIVE b(orig, v, bits) AS (SELECT column1, column1, '' FROM (VALUES (5), (10), (255), (0))
  UNION ALL SELECT orig, v / 2, (v % 2) || bits FROM b WHERE v > 0)
SELECT orig, CASE WHEN bits = '' THEN '0' ELSE bits END FROM b WHERE v = 0 ORDER BY orig;

-- Replace every occurrence of a set of words, one per recursion step.
CREATE TABLE subst(step INTEGER PRIMARY KEY, old TEXT, new TEXT);
INSERT INTO subst VALUES (1, 'cat', 'dog'), (2, 'red', 'blue'), (3, 'sat', 'stood');
WITH RECURSIVE r(step, s) AS (SELECT 0, 'the red cat sat on the red mat'
  UNION ALL SELECT r.step + 1, replace(r.s, subst.old, subst.new) FROM r JOIN subst ON subst.step = r.step + 1)
SELECT step, s FROM r ORDER BY step;

-- Join the split pieces back with a different separator.
WITH RECURSIVE split(idx, piece, rest) AS (
  SELECT 0, NULL, 'x;y;z' || ';'
  UNION ALL
  SELECT idx + 1, substr(rest, 1, instr(rest, ';') - 1), substr(rest, instr(rest, ';') + 1) FROM split WHERE rest <> '')
SELECT group_concat(upper(piece), '-' ORDER BY idx) FROM split WHERE idx > 0;
