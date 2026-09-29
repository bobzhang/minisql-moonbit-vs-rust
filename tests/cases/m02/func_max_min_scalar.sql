-- Scalar max(X, Y, ...) and min(X, Y, ...) with two or more arguments return
-- the largest / smallest argument using the normal cross-class ordering.
-- Any NULL argument makes the result NULL.

SELECT max(1, 2), min(1, 2), max(3, 1, 2), min(3, 1, 2), max(-1, -2), min(-1, -2);
SELECT max(1, 2.5), min(1, 2.5), max(2.5, 3), typeof(max(1, 2.5));
-- NULL anywhere gives NULL.
SELECT max(1, NULL), min(NULL, 1), max(NULL, NULL), max(1, 2, NULL);
-- Cross-class order: numbers < text < blobs.
SELECT max(1, 'a'), min(1, 'a'), max('z', x'00'), min('z', x'00'), max(100, '9');
-- Text compares with BINARY by default.
SELECT max('a', 'B'), min('a', 'B'), max('apple', 'apricot'), min('', 'a');
-- Result keeps the type of the chosen argument.
SELECT typeof(max(1, '0')), typeof(min(1, '0')), typeof(max(x'01', 'x'));
-- Many arguments.
SELECT max(5, 3, 9, 1, 7, 2), min(5, 3, 9, 1, 7, 2);
-- Row-wise max/min across columns.
CREATE TABLE t(id INTEGER, a INTEGER, b INTEGER, c INTEGER);
INSERT INTO t VALUES (1, 1, 5, 3), (2, 9, 2, 4), (3, -1, -5, 0), (4, 7, NULL, 8);
SELECT id, max(a, b, c), min(a, b, c) FROM t ORDER BY id;
SELECT id FROM t WHERE max(a, c) > 5 ORDER BY id;
SELECT id, max(a, 0), min(c, 3) FROM t ORDER BY id;
-- Clamping a value into a range.
SELECT id, max(0, min(a, 5)) FROM t ORDER BY id;
-- With zero arguments max/min are errors.
SELECT max();
SELECT min();
