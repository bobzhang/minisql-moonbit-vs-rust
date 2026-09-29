-- replace(X, Y, Z): every occurrence of Y in X replaced by Z, scanning left
-- to right without overlap. An empty Y leaves X unchanged; any NULL
-- argument gives NULL.

SELECT replace('hello', 'l', 'L'), replace('hello', 'll', ''), replace('hello', 'x', 'y');
SELECT replace('aaaa', 'aa', 'b'), replace('aaa', 'aa', 'b'), replace('abab', 'ab', 'ba');
SELECT replace('hello', '', 'x'), replace('', 'a', 'b'), replace('', '', 'x');
SELECT replace('abc', 'abc', ''), replace('abc', 'abcd', 'x');
-- Case-sensitive.
SELECT replace('Hello hello', 'hello', 'bye');
-- Replacement longer than the pattern.
SELECT replace('a-b-c', '-', ' -- '), replace('x', 'x', 'xxx');
-- NULL.
SELECT replace(NULL, 'a', 'b'), replace('a', NULL, 'b'), replace('a', 'a', NULL);
-- Non-ASCII.
SELECT replace('日本語', '本', 'X'), replace('café', 'é', 'e'), replace('ééé', 'é', 'e');
-- Numbers are converted to text; the result is TEXT.
SELECT replace(12321, 2, 9), replace(1.5, '.', ','), typeof(replace(123, 1, 1));
-- In a table.
CREATE TABLE t(id INTEGER, path TEXT);
INSERT INTO t VALUES (1, 'a/b/c'), (2, '/root/'), (3, 'none'), (4, NULL), (5, '//');
SELECT id, replace(path, '/', '\') FROM t ORDER BY id;
SELECT id, length(path) - length(replace(path, '/', '')) FROM t ORDER BY id;
SELECT id FROM t WHERE replace(path, '/', '') = 'abc';
-- Wrong number of arguments.
SELECT replace('a', 'b');
