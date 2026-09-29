-- The || operator converts both operands to TEXT and concatenates them.
-- NULL on either side gives NULL.

SELECT 'a' || 'b', 'a' || '' || 'b', '' || '';
SELECT 'x' || 1, 1 || 2, typeof(1 || 2), -1 || -2;
SELECT 1.5 || '', 100.0 || '', 0.25 || 'x', -2.5 || '';
SELECT 'a' || NULL, NULL || 'a', NULL || NULL, typeof(NULL || 'a');
-- Blob operands: bytes are taken as text.
SELECT x'41' || 'b', x'41' || x'42', typeof(x'41' || x'42');
SELECT 'n=' || 42 || ';' || 'r=' || 0.5;
-- Non-ASCII text.
SELECT 'café' || '中文', '😀' || '!';
-- || binds tighter than arithmetic.
SELECT 1 + 2 || 3, 2 * 3 || 4, 1 || 2 + 3;
SELECT (1 + 2) || 3, 1 || (2 + 3);
-- Result of || used as a number.
SELECT ('1' || '2') + 1, typeof(('1' || '2') + 1);
-- Concatenation of columns.
CREATE TABLE p(first TEXT, last TEXT, age INTEGER);
INSERT INTO p VALUES ('Ada', 'Lovelace', 36), ('Alan', 'Turing', 41), ('Grace', NULL, 85);
SELECT first || ' ' || last FROM p ORDER BY first;
SELECT first || ':' || age FROM p ORDER BY age;
SELECT first FROM p WHERE first || last = 'AlanTuring';
