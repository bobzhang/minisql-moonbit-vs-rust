-- The functions like(Y, X [, Z]) and glob(Y, X) implement "X LIKE Y
-- [ESCAPE Z]" and "X GLOB Y". Note the reversed argument order: the
-- pattern comes first.

SELECT like('a%', 'abc'), like('abc', 'a%'), like('A%', 'abc'), like('_b_', 'abc');
SELECT glob('a*', 'abc'), glob('abc', 'a*'), glob('A*', 'abc'), glob('[a-c]?c', 'abc');
-- The three-argument form of like() takes an escape character.
SELECT like('a|%', 'a%', '|'), like('a|%', 'ab', '|'), like('10\%', '10%', '\');
-- NULL arguments.
SELECT like(NULL, 'a'), like('a', NULL), glob(NULL, 'a'), glob('*', NULL), like('a', 'a', NULL);
-- Equivalence with the operators.
SELECT like('%x%', 'axb') = ('axb' LIKE '%x%'), glob('*x*', 'aXb') = ('aXb' GLOB '*x*');
-- Numbers are converted to text.
SELECT like('1%', 123), glob('?2?', 123);
-- Results are integers.
SELECT typeof(like('a', 'a')), typeof(glob('a', 'b'));
-- Using the function forms in WHERE.
CREATE TABLE t(id INTEGER, s TEXT, p TEXT);
INSERT INTO t VALUES (1, 'apple', 'a%'), (2, 'Banana', 'b%'), (3, 'cherry', 'C*'), (4, 'date', '*t*');
SELECT id FROM t WHERE like(p, s) ORDER BY id;
SELECT id FROM t WHERE glob(p, s) ORDER BY id;
SELECT id, like('%an%', s), glob('*an*', s) FROM t ORDER BY id;
-- Escape must be one character.
SELECT like('a', 'a', 'xy');
-- Wrong number of arguments.
SELECT like('a');
SELECT glob('a', 'b', 'c');
