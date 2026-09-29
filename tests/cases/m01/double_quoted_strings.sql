-- A double-quoted token that does not resolve to a column is treated as a
-- string literal (SQLite's legacy behavior). If it matches a column, it is
-- the column.

SELECT "hello";
SELECT "hello", typeof("hello");
SELECT "it's", "a""b";
CREATE TABLE t(a INTEGER, b TEXT);
INSERT INTO t VALUES (1, 'x'), (2, 'a');
-- "a" is the column a; "nosuch" is the text 'nosuch'.
SELECT "a", "nosuch" FROM t ORDER BY a;
-- In WHERE: "a" is a column, "x" is text.
SELECT a FROM t WHERE b = "x";
SELECT a FROM t WHERE b = "a";
-- In INSERT VALUES a double-quoted token is a string.
INSERT INTO t VALUES (3, "dq");
SELECT a, b, typeof(b) FROM t ORDER BY a;
-- Single-quoted text is always text, never a column.
SELECT 'a' FROM t ORDER BY a;
-- Double-quoted strings in expressions.
SELECT "abc" || "def", "5" + 1;
-- Backtick and bracket quoting always name identifiers, never strings.
SELECT [nosuch] FROM t;
SELECT `nosuch` FROM t;
