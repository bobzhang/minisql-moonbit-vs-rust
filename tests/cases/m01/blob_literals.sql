-- Blob literals: X'hex' / x'hex' with an even number of hex digits.

SELECT x'', X'00', x'ff', X'FF', x'aBcD';
SELECT x'0102030405060708090a0b0c0d0e0f10';
SELECT typeof(x'00'), typeof(X'');
-- Blobs whose bytes happen to be ASCII still print as hex.
SELECT x'414243';
-- Blobs in a table.
CREATE TABLE t(id INTEGER, b BLOB);
INSERT INTO t VALUES (1, x'00'), (2, x'0000'), (3, x''), (4, x'ff'), (5, x'7f');
SELECT id, b, typeof(b) FROM t ORDER BY id;
-- Blobs sort after everything else; among blobs, byte-wise (memcmp) order.
SELECT b FROM t ORDER BY b;
SELECT b FROM t ORDER BY b DESC;
-- Odd number of hex digits is an error.
SELECT x'abc';
-- Non-hex characters are an error.
SELECT x'zz';
-- With a space, x is a column name and 'ab' its alias: no such column.
SELECT x 'ab';
