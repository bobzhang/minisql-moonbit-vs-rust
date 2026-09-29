-- printf %q, %Q and %w: SQL-quoting conversions.
--   %q doubles single quotes (for use inside '...');
--   %Q does the same and adds surrounding quotes, and prints NULL as NULL;
--   %w doubles double quotes (for use inside "...").

SELECT printf('%q', 'it''s'), printf('%q', 'plain'), printf('%q', ''''''), printf('%q', '');
SELECT printf('%Q', 'it''s'), printf('%Q', 'plain'), printf('%Q', ''), printf('%Q', NULL);
SELECT printf('%w', 'a"b'), printf('%w', 'say "hi"'), printf('%w', 'it''s');
-- %q and %w of NULL print "(NULL)".
SELECT printf('%q', NULL), printf('%w', NULL);
-- Numbers are converted to text first, then quoted.
SELECT printf('%q', 5), printf('%Q', 5), printf('%Q', 1.5), printf('%Q', -3);
-- Building a SQL statement.
SELECT printf('INSERT INTO t VALUES(%Q, %Q);', 'O''Brien', NULL);
SELECT printf('SELECT "%w" FROM "%w";', 'col"1', 'tab');
-- Precision limits the number of input characters used.
SELECT printf('%.3q', 'abcdef'), printf('%.2Q', 'abc');
-- Width pads the quoted result.
SELECT printf('[%8Q]', 'ab'), printf('[%-8q]', 'a''b');
-- Non-ASCII passes through.
SELECT printf('%Q', 'café'), printf('%q', 'l''été');
-- From a table.
CREATE TABLE t(id INTEGER, s TEXT);
INSERT INTO t VALUES (1, 'x'), (2, 'don''t'), (3, NULL), (4, '');
SELECT id, printf('%q|%Q|%w', s, s, s) FROM t ORDER BY id;
