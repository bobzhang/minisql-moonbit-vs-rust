-- printf %s: the argument as text. Width pads, precision truncates; both
-- count bytes. NULL prints as an empty string.

SELECT printf('%s', 'hello'), printf('[%10s]', 'hi'), printf('[%-10s]', 'hi'), printf('[%.2s]', 'hello');
SELECT printf('[%5.1s]', 'hello'), printf('[%-5.3s]', 'hello'), printf('[%.0s]', 'hello'), printf('[%.10s]', 'hi');
SELECT printf('[%s]', NULL), printf('[%5s]', NULL), printf('[%s]', '');
-- Numbers are converted to text.
SELECT printf('%s', 42), printf('%s', -1.5), printf('%s', 100.0), printf('%s|%s', 0.25, 7);
-- Blobs are taken as text.
SELECT printf('%s', x'414243');
-- Width is a minimum; longer strings are not truncated.
SELECT printf('[%3s]', 'abcdef');
-- Width and precision are in bytes, so non-ASCII text pads less.
SELECT printf('[%5s]', 'é'), printf('[%-6s]', '中');
SELECT printf('[%s]', 'naïve café');
-- The '!' flag makes width and precision count characters instead.
SELECT printf('[%!5s]', 'é'), printf('[%!.2s]', 'éèê'), printf('[%!-4s]', '中文');
-- Mixed with other conversions.
SELECT printf('%s is %d years old', 'Ann', 30), printf('%s%s%s', 'a', 'b', 'c');
-- %% is a literal percent sign.
SELECT printf('100%%'), printf('%d%%', 50), printf('%%s'), printf('%%%s%%', 'x');
-- Text from a table.
CREATE TABLE t(id INTEGER, name TEXT);
INSERT INTO t VALUES (1, 'apple'), (2, 'fig'), (3, NULL), (4, 'watermelon');
SELECT printf('|%-8s|%8s|%.3s|', name, name, name) FROM t ORDER BY id;
