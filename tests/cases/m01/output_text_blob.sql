-- How TEXT and BLOB values are printed: text verbatim, blobs as X'..' with
-- uppercase hex digits.

SELECT 'plain', 'with space', '  leading and trailing  ';
-- A '|' inside text is printed verbatim (it is not escaped).
SELECT 'a|b', '|';
-- Non-ASCII UTF-8 text.
SELECT 'café', '中文', 'emoji 😀', 'Ωmega';
SELECT 'NULL', 'null';
-- Empty text prints as nothing.
SELECT '', 'x', '';
-- Blobs.
SELECT x'00', x'0a0B0c', X'DEADBEEF', x'deadbeef';
SELECT x'', X'';
SELECT x'48656C6C6F';
SELECT typeof(x''), typeof('');
-- Mixed columns in one row.
SELECT 1, 'two', 3.0, NULL, x'04';
-- Stored in a table.
CREATE TABLE t(k INTEGER, v);
INSERT INTO t VALUES (1, 'text'), (2, x'CAFE'), (3, ''), (4, x''), (5, 'ü');
SELECT k, v, typeof(v) FROM t ORDER BY k;
