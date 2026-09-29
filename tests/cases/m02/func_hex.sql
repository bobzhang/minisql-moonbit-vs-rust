-- hex(X): uppercase hexadecimal of the bytes of X's blob or text form.

SELECT hex('abc'), hex(''), hex('A'), typeof(hex('A'));
SELECT hex(x'00ff10'), hex(x''), hex(x'DEADBEEF');
-- Non-ASCII text shows its UTF-8 bytes.
SELECT hex('é'), hex('中'), hex('😀');
-- Numbers are converted to text first (not to their binary form).
SELECT hex(255), hex(-1), hex(0), hex(1.5), hex(100.0);
-- NULL gives an empty string, not NULL.
SELECT hex(NULL), typeof(hex(NULL));
-- hex of a zero-filled blob.
SELECT hex(zeroblob(4));
-- Round trip with unhex.
SELECT unhex(hex('hello')), CAST(unhex(hex('hello')) AS TEXT);
-- Over table rows.
CREATE TABLE t(id INTEGER, v);
INSERT INTO t VALUES (1, 'Hi'), (2, x'0102'), (3, 10), (4, NULL), (5, ' ');
SELECT id, hex(v), length(hex(v)) FROM t ORDER BY id;
SELECT id FROM t WHERE hex(v) = '3130';
-- Wrong number of arguments.
SELECT hex();
SELECT hex('a', 'b');
