-- ORDER BY arbitrary expressions (not just columns).

CREATE TABLE t(id INTEGER, a INTEGER, b INTEGER, s TEXT);
INSERT INTO t VALUES (1, 5, 2, 'pear'), (2, -3, 8, 'Apple'), (3, 0, 0, 'fig'), (4, 7, -7, 'kiwi'), (5, 2, 9, 'date');
SELECT id FROM t ORDER BY a + b, id;
SELECT id FROM t ORDER BY a * b, id;
SELECT id FROM t ORDER BY -a;
SELECT id FROM t ORDER BY a - b DESC;
SELECT id FROM t ORDER BY b % 3, id;
-- Ordering by a text expression.
SELECT s FROM t ORDER BY s || 'x';
SELECT s FROM t ORDER BY 'z' || s DESC;
-- Ordering by a comparison or logical result (0/1), ties broken by id.
SELECT id FROM t ORDER BY a > b, id;
SELECT id FROM t ORDER BY a > 0 AND b > 0 DESC, id;
SELECT id FROM t ORDER BY s IS NULL, s;
-- Ordering by typeof() of a mixed column.
CREATE TABLE m(id INTEGER, v);
INSERT INTO m VALUES (1, 'x'), (2, 1), (3, NULL), (4, 2.5), (5, x'01');
SELECT id, typeof(v) FROM m ORDER BY typeof(v);
SELECT id FROM m ORDER BY typeof(v) DESC;
-- An expression that yields NULL for some rows: NULLs first.
SELECT id FROM t ORDER BY a / b, id;
SELECT id FROM t ORDER BY a / b DESC, id;
-- An expression mixing columns of different types.
SELECT id FROM t ORDER BY a || s;
