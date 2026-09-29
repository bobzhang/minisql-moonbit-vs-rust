-- LIKE with non-ASCII text and non-text operands. Case folding applies to
-- ASCII letters only; _ matches one character (not one byte).

SELECT 'é' LIKE '_', 'é' LIKE '__', '中文' LIKE '__', '😀' LIKE '_', 'aé' LIKE 'a_';
SELECT 'café' LIKE 'caf_', 'café' LIKE 'CAF%', 'naïve' LIKE '%ï%';
-- Non-ASCII letters are not case-folded.
SELECT 'é' LIKE 'É', 'ÄB' LIKE 'äb', 'Ä' LIKE 'Ä';
SELECT 'straße' LIKE 'STRASSE', 'straße' LIKE 'STRAßE';
-- Numbers and blobs are compared through their text form.
SELECT 42 LIKE '42', 42 LIKE '4_', -1 LIKE '-%', 2.5 LIKE '2.5', 0.001 LIKE '0.0%';
SELECT x'616263' LIKE 'abc', x'616263' LIKE 'A%';
-- The pattern may be a number.
SELECT '123' LIKE 123, 123 LIKE 123;
-- Whitespace and punctuation are literal.
SELECT 'a b' LIKE 'a b', 'a  b' LIKE 'a b', 'a b' LIKE 'a_b', 'a-b' LIKE 'a_b';
-- A newline is a character for _ as well.
SELECT 'a' || char(10) || 'b' LIKE 'a_b';
-- Pattern from a column.
CREATE TABLE p(id INTEGER, s TEXT, pat TEXT);
INSERT INTO p VALUES (1, 'Hello', 'h%'), (2, 'World', '%D'), (3, 'Ünïcode', 'ü%'), (4, 'Ünïcode', 'Ü%'), (5, 'x', NULL), (6, 'abc', 'a_c');
SELECT id, s LIKE pat FROM p ORDER BY id;
SELECT id FROM p WHERE s LIKE pat ORDER BY id;
-- LIKE on an INTEGER column.
CREATE TABLE n(v INTEGER);
INSERT INTO n VALUES (100), (105), (15), (1000), (-10);
SELECT v FROM n WHERE v LIKE '10%' ORDER BY v;
SELECT v FROM n WHERE v LIKE '%0' ORDER BY v;
