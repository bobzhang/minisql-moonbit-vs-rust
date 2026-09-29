-- Errors from function calls: unknown function names and wrong argument
-- counts. The error is reported even if no row would call the function.

SELECT nosuchfunc(1);
SELECT abs(-1);
SELECT upper('ok');
-- Near-miss names are not aliases.
SELECT substrng('abc', 1);
SELECT substr('abc', 1), substring('abc', 1);
SELECT length('abc');
-- Wrong argument counts for fixed-arity functions.
SELECT abs(1, 2);
SELECT round(1.5), round(1.55, 1);
-- Functions with a variable number of arguments have limits too.
SELECT coalesce(1);
SELECT coalesce(NULL, 1);
SELECT substr('abcdef', 1, 2, 3);
SELECT substr('abcdef', 3);
-- The error happens even when the table is empty or the WHERE is false.
CREATE TABLE t(v INTEGER);
SELECT nosuchfunc(v) FROM t;
SELECT abs(v) FROM t;
INSERT INTO t VALUES (-3), (4);
SELECT abs(v) FROM t ORDER BY v;
-- A function error inside CASE or WHERE also fails the whole statement.
SELECT v FROM t WHERE nosuchfunc(v) = 1;
SELECT CASE WHEN 0 THEN nosuchfunc(1) ELSE 2 END;
SELECT v * 2 FROM t ORDER BY v;
-- Function names are case-insensitive.
SELECT UPPER('a'), Lower('B'), LeNgTh('abc');
SELECT coalesce(NULL, NULL, 'third'), ifnull(NULL, 'second');
SELECT v, abs(v) * 2 FROM t WHERE abs(v) > 3;
SELECT typeof(abs(v)) FROM t ORDER BY v;
-- Valid calls with the minimum and larger argument counts.
SELECT max(1, 2), min(3, 2, 1), concat('a'), concat_ws('-', 'a', 'b', 'c');
SELECT iif(1, 'a'), trim('xax', 'x'), round(2.567, 2), substr('abc', 2, 1);
SELECT printf('%d-%d-%d', 1, 2, 3), char(65, 66, 67, 68);
SELECT hex(v), quote(v) FROM t ORDER BY v;
