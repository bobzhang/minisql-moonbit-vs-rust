-- String literals: single quotes, doubled quotes for escaping, no backslash
-- escapes, non-ASCII content.

SELECT 'hello';
SELECT '';
SELECT 'it''s', '''', '''''', 'a''b''c';
-- Backslashes have no special meaning.
SELECT 'back\slash', 'tab\t', '\';
-- Double quotes inside single-quoted strings are ordinary characters.
SELECT 'say "hi"', '"';
-- Keywords and operators inside strings are text.
SELECT 'SELECT * FROM t', 'a -- b', '1 + 1';
-- Non-ASCII.
SELECT 'naïve', 'Straße', '日本語', 'Ελληνικά';
SELECT typeof('abc'), typeof('123'), typeof('');
-- A string that looks like a number is still TEXT when selected as a literal.
SELECT '123', '1.5', typeof('1.5');
-- Adjacent strings are not concatenated: the second one is taken as a
-- column alias for the first, so this prints just 'a'.
SELECT 'a' 'b';
SELECT 'recovered';
-- An unterminated string at the very end of the script is an error.
SELECT 'unterminated