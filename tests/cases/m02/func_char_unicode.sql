-- char(X1, X2, ...) builds a string from Unicode code points;
-- unicode(X) returns the code point of the first character of X.

SELECT char(72, 105), char(65), char(97, 98, 99);
-- With no arguments, char() returns an empty string.
SELECT char(), typeof(char()), length(char());
-- Non-ASCII code points: 2-, 3- and 4-byte UTF-8.
SELECT char(233), char(20013, 25991), char(128512), char(0x10FFFF) = char(1114111);
SELECT hex(char(233)), hex(char(8364)), hex(char(128512));
-- Arguments are converted to integers.
SELECT char('65'), char(65.9), char('66', 67.2);
-- unicode().
SELECT unicode('A'), unicode('abc'), unicode('é'), unicode('中'), unicode('😀');
SELECT unicode(''), unicode(NULL), typeof(unicode(''));
-- unicode() of a number uses its text form; of a blob, its bytes.
SELECT unicode(65), unicode(-1), unicode(x'41'), unicode(x'C3A9');
-- Round trips.
SELECT unicode(char(955)), char(unicode('ß')), char(unicode('x'), unicode('y'));
-- Over table rows.
CREATE TABLE t(id INTEGER, s TEXT);
INSERT INTO t VALUES (1, 'Zebra'), (2, 'émile'), (3, '中文'), (4, ''), (5, NULL), (6, '😀!');
SELECT id, unicode(s) FROM t ORDER BY id;
SELECT id, char(unicode(s)) FROM t WHERE s <> '' ORDER BY id;
SELECT id FROM t WHERE unicode(s) > 127 ORDER BY id;
SELECT id FROM t ORDER BY unicode(s), id;
-- Building text from computed code points.
SELECT char(64 + 1, 64 + 2, 64 + 26);
-- Wrong number of arguments for unicode().
SELECT unicode();
SELECT unicode('a', 'b');
