-- How printf handles its arguments: missing arguments act as NULL/0/'',
-- extra arguments are ignored, '*' takes width/precision from arguments,
-- a NULL format gives NULL, and a non-text format is converted to text.

SELECT printf('%d and %d', 1), printf('[%s]'), printf('%d'), printf('%f');
SELECT printf('%d', 1, 2, 3), printf('no conversions', 'ignored');
SELECT printf(NULL), printf(NULL, 1), typeof(printf(NULL, 'x'));
SELECT printf(42), printf(1.5), typeof(printf(42));
-- A format with no conversions is returned as is.
SELECT printf('plain text'), printf('a%%b');
-- '*' width and precision.
SELECT printf('[%*d]', 5, 42), printf('[%-*d]', 5, 42), printf('[%.*f]', 2, 3.14159), printf('[%*.*f]', 8, 3, 3.14159);
-- A negative '*' width means left-justify.
SELECT printf('[%*d]', -5, 42);
-- '*' from a table column.
CREATE TABLE t(w INTEGER, v TEXT);
INSERT INTO t VALUES (3, 'a'), (6, 'bb'), (1, 'ccc');
SELECT printf('[%*s]', w, v) FROM t ORDER BY w;
-- Argument types: each conversion converts its argument independently.
SELECT printf('%s %d %f %x', '10', '10', '10', '10');
SELECT printf('%d|%s|%.1f', 2.9, 2.9, 2.9);
-- Result is TEXT.
SELECT typeof(printf('%d', 5)), typeof(format('%s', 'x'));
-- sprintf is not a SQLite function.
SELECT sprintf('%d', 1);
