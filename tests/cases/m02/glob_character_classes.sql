-- GLOB character classes: [abc], ranges [a-z], negation [^...], and the
-- special placement rules for ']' and '-'.

SELECT 'a' GLOB '[abc]', 'd' GLOB '[abc]', 'b' GLOB '[a-c]', 'B' GLOB '[a-c]';
SELECT 'x1' GLOB '[a-z][0-9]', 'x11' GLOB '[a-z][0-9]', 'x11' GLOB '[a-z][0-9]*';
-- Negation with ^.
SELECT 'd' GLOB '[^abc]', 'a' GLOB '[^abc]', '5' GLOB '[^a-z]';
-- '!' is not a negation marker in SQLite's GLOB; it is a literal member.
SELECT '!' GLOB '[!a]', 'b' GLOB '[!a]', 'a' GLOB '[!a]';
-- ']' first in the set is a literal member.
SELECT ']' GLOB '[]]', ']' GLOB '[]a]', 'a' GLOB '[]a]', 'b' GLOB '[]a]';
SELECT ']' GLOB '[^]]', 'x' GLOB '[^]]';
-- '-' first or last in the set is literal.
SELECT '-' GLOB '[-a]', '-' GLOB '[a-]', 'b' GLOB '[a-]';
-- Wildcard characters inside a set are literal.
SELECT '*' GLOB '[*]', 'x' GLOB '[*]', '?' GLOB '[?]', 'a*b' GLOB 'a[*]b';
-- A '^' that is not first in the set is literal.
SELECT '^' GLOB '[a^]', '^' GLOB '[^^]', 'a' GLOB '[^^]';
-- Multiple ranges.
SELECT 'Q' GLOB '[a-zA-Z]', '7' GLOB '[a-zA-Z]', '_' GLOB '[a-zA-Z0-9_]';
-- An unterminated set never matches.
SELECT 'a' GLOB '[a', '[a' GLOB '[a';
-- Non-ASCII in a set and range.
SELECT 'é' GLOB '[éè]', 'e' GLOB '[éè]', 'β' GLOB '[α-γ]';
-- Classes in WHERE.
CREATE TABLE c(id INTEGER, code TEXT);
INSERT INTO c VALUES (1, 'A1'), (2, 'b2'), (3, 'C3x'), (4, '9Z'), (5, 'a-'), (6, 'Z9');
SELECT id FROM c WHERE code GLOB '[A-Z][0-9]' ORDER BY id;
SELECT id FROM c WHERE code GLOB '[a-zA-Z][0-9]*' ORDER BY id;
SELECT id FROM c WHERE code GLOB '*[^0-9]' ORDER BY id;
SELECT id FROM c WHERE code GLOB '?[-]' ORDER BY id;
