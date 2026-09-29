-- nullif(X, Y) returns NULL if X = Y, else X.

SELECT nullif(1, 1), nullif(1, 2), nullif('a', 'a'), nullif('a', 'b');
SELECT nullif(NULL, 1), nullif(1, NULL), nullif(NULL, NULL);
-- Comparison is as with '=': 1 = 1.0, but text and numbers differ.
SELECT nullif(1, 1.0), nullif(1.0, 1), nullif(1, '1'), nullif('1', 1);
-- Case-sensitive for literals (BINARY).
SELECT nullif('a', 'A'), nullif('a', 'A' COLLATE NOCASE);
-- The result keeps X's type.
SELECT typeof(nullif(2.5, 1)), typeof(nullif(x'00', x'01')), nullif(x'00', x'00');
-- Common use: avoid division by zero / treat sentinels as NULL.
SELECT 10 / nullif(0, 0), 10 / nullif(5, 0);
CREATE TABLE t(id INTEGER, v INTEGER, s TEXT);
INSERT INTO t VALUES (1, 0, ''), (2, 5, 'x'), (3, -1, 'N/A'), (4, NULL, NULL);
SELECT id, nullif(v, 0), nullif(s, ''), nullif(s, 'N/A') FROM t ORDER BY id;
SELECT id, 100 / nullif(v, 0) FROM t ORDER BY id;
SELECT id FROM t WHERE nullif(v, -1) IS NULL ORDER BY id;
-- Column affinity applies to the comparison: INTEGER column vs '5'.
SELECT id, nullif(v, '5') FROM t WHERE id = 2;
-- Wrong number of arguments.
SELECT nullif(1);
SELECT nullif(1, 2, 3);
