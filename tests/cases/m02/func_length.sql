-- length(X): characters for text, bytes for blobs, NULL for NULL; numbers
-- are measured by their text form. octet_length(X): bytes of the text form
-- (or blob).

SELECT length('hello'), length(''), length(' '), length('a b c');
SELECT length('日本語'), length('é'), length('😀'), length('naïve');
SELECT length(NULL), typeof(length(NULL)), typeof(length('a'));
-- Numbers.
SELECT length(123), length(-12), length(0), length(1.5), length(-0.25), length(100.0);
-- Blobs.
SELECT length(x'00ff00'), length(x''), length(zeroblob(10));
-- octet_length.
SELECT octet_length('hello'), octet_length(''), octet_length('日本語'), octet_length('é'), octet_length('😀');
SELECT octet_length(x'00ff'), octet_length(123), octet_length(1.5), octet_length(NULL);
-- Comparing the two.
SELECT length('café') < octet_length('café'), length('abc') = octet_length('abc');
-- In a table.
CREATE TABLE t(id INTEGER, s);
INSERT INTO t VALUES (1, 'abc'), (2, 'Ünïcödé'), (3, ''), (4, NULL), (5, 12345), (6, x'0102');
SELECT id, length(s), octet_length(s) FROM t ORDER BY id;
SELECT id FROM t WHERE length(s) > 3 ORDER BY id;
SELECT id FROM t ORDER BY length(s), id;
-- Wrong number of arguments.
SELECT length();
SELECT length('a', 'b');
