-- RTRIM collation: like BINARY but trailing space characters are ignored.

SELECT 'x' = 'x ' COLLATE RTRIM, 'x' = 'x          ' COLLATE RTRIM, 'x ' = 'x  ' COLLATE RTRIM;
-- Leading and inner spaces still count.
SELECT ' x' = 'x' COLLATE RTRIM, 'a b' = 'ab' COLLATE RTRIM, 'a  b' = 'a b' COLLATE RTRIM;
-- Only the space character is trimmed: tabs and newlines are not.
SELECT 'x' || char(9) = 'x' COLLATE RTRIM, 'x' || char(10) = 'x' COLLATE RTRIM;
-- Case still matters.
SELECT 'X' = 'x ' COLLATE RTRIM;
-- Ordering ignores trailing spaces.
SELECT 'a ' < 'a' COLLATE RTRIM, 'a ' > 'a' COLLATE RTRIM, 'a  ' < 'a!' COLLATE RTRIM;
SELECT 'a ' < 'a!', 'a' < 'a ' COLLATE BINARY;
-- Empty string and all spaces are equal under RTRIM.
SELECT '' = '   ' COLLATE RTRIM, '' = '' COLLATE RTRIM;
-- Non-ASCII.
SELECT 'é ' = 'é' COLLATE RTRIM, 'É' = 'é  ' COLLATE RTRIM;
-- RTRIM in WHERE over padded data.
CREATE TABLE codes(id INTEGER, code TEXT);
INSERT INTO codes VALUES (1, 'AB'), (2, 'AB  '), (3, ' AB'), (4, 'ab'), (5, 'AB' || char(9)), (6, 'ABC');
SELECT id FROM codes WHERE code = 'AB' ORDER BY id;
SELECT id FROM codes WHERE code = 'AB' COLLATE RTRIM ORDER BY id;
SELECT id FROM codes WHERE code COLLATE RTRIM = 'AB   ' ORDER BY id;
SELECT id FROM codes WHERE code COLLATE RTRIM IN ('AB', 'ABC ') ORDER BY id;
SELECT id FROM codes WHERE code < 'AC' COLLATE RTRIM ORDER BY id;
SELECT id, code = 'AB ' COLLATE RTRIM, code = 'AB ' FROM codes ORDER BY id;
