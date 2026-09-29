-- coalesce(X, Y, ...) returns its first non-NULL argument (NULL if none);
-- ifnull(X, Y) is coalesce with exactly two arguments.

SELECT coalesce(NULL, 1), coalesce(1, NULL), coalesce(NULL, NULL), coalesce(NULL, NULL, 'c');
SELECT coalesce('a', 'b', 'c'), coalesce(NULL, 'b', 'c'), coalesce(NULL, NULL, NULL, 4);
SELECT ifnull(NULL, 2), ifnull(3, 2), ifnull(NULL, NULL), ifnull('', 'x'), ifnull(0, 'x');
-- The result keeps the chosen argument's type.
SELECT typeof(coalesce(NULL, 1.5)), typeof(coalesce(NULL, x'00')), typeof(ifnull(NULL, '1'));
-- Arguments after the first non-NULL one are not evaluated.
SELECT coalesce(1, abs(-9223372036854775808)), ifnull('ok', abs(-9223372036854775808));
-- ...but earlier ones are.
SELECT coalesce(NULL, abs(-9223372036854775808), 1);
-- Expressions.
SELECT coalesce(1 / 0, 2 / 0, 3), coalesce(NULL || 'a', 'b' || 'c');
-- Replacing NULLs from a table.
CREATE TABLE t(id INTEGER, nick TEXT, name TEXT, score INTEGER);
INSERT INTO t VALUES (1, 'Al', 'Alan', 5), (2, NULL, 'Bea', NULL), (3, NULL, NULL, 7), (4, '', 'Dee', 0);
SELECT id, coalesce(nick, name, '?'), ifnull(score, -1) FROM t ORDER BY id;
SELECT id FROM t WHERE coalesce(score, 0) = 0 ORDER BY id;
SELECT id, ifnull(nick, 'none') || '/' || ifnull(name, 'none') FROM t ORDER BY id;
SELECT id FROM t ORDER BY coalesce(score, 100), id;
-- Wrong number of arguments: coalesce needs at least 2, ifnull exactly 2.
SELECT coalesce(1);
SELECT ifnull(1);
SELECT ifnull(1, 2, 3);
