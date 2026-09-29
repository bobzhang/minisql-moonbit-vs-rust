-- GLOB: * matches any sequence, ? matches one character, and matching is
-- case-sensitive. % and _ are ordinary characters.

SELECT 'abc' GLOB 'abc', 'abc' GLOB 'ABC', 'abc' GLOB 'a*', 'abc' GLOB '*c', 'abc' GLOB '*b*';
SELECT 'abc' GLOB 'a?c', 'abc' GLOB '???', 'abc' GLOB '??', 'abc' GLOB '?*?';
SELECT '' GLOB '*', '' GLOB '?', '' GLOB '', 'a' GLOB '';
SELECT 'Abc' GLOB 'a*', 'Abc' GLOB 'A*';
-- % and _ are literal in GLOB.
SELECT 'a%' GLOB 'a%', 'ab' GLOB 'a%', 'a_' GLOB 'a_', 'ab' GLOB 'a_';
-- NOT GLOB.
SELECT 'abc' NOT GLOB 'a*', 'abc' NOT GLOB 'b*';
-- NULL.
SELECT NULL GLOB '*', 'a' GLOB NULL;
-- Non-ASCII: ? matches one character.
SELECT 'é' GLOB '?', '中文' GLOB '??', 'café' GLOB 'caf?', 'É' GLOB 'é';
-- Numbers are converted to text.
SELECT 123 GLOB '1*', 1.5 GLOB '1.?', -7 GLOB '-*';
-- GLOB in WHERE.
CREATE TABLE f(id INTEGER, name TEXT);
INSERT INTO f VALUES (1, 'report.txt'), (2, 'Report.TXT'), (3, 'data.csv'), (4, 'notes.txt.bak'), (5, 'a.txt'), (6, NULL);
SELECT id FROM f WHERE name GLOB '*.txt' ORDER BY id;
SELECT id FROM f WHERE name GLOB '*.txt*' ORDER BY id;
SELECT id FROM f WHERE name GLOB '?.txt' ORDER BY id;
SELECT id FROM f WHERE name NOT GLOB '*.txt' ORDER BY id;
SELECT id FROM f WHERE name GLOB 'R*' ORDER BY id;
SELECT id, name GLOB '*a*' FROM f ORDER BY id;
