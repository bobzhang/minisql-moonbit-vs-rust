-- Functions that compare text use collations too: scalar max()/min() use
-- the collation of their leftmost argument that has one; nullif() uses the
-- normal comparison rules; instr() and replace() do not use
-- collations.

CREATE TABLE t(id INTEGER, n TEXT COLLATE NOCASE, b TEXT);
INSERT INTO t VALUES (1, 'abc', 'abc'), (2, 'ABC', 'ABC'), (3, 'Abe', 'Abe');
-- max()/min() over a NOCASE column vs a BINARY one.
SELECT id, max(n, 'ABD'), max(b, 'ABD') FROM t ORDER BY id;
SELECT id, min(n, 'abd'), min(b, 'abd') FROM t ORDER BY id;
-- An explicit COLLATE on any argument.
SELECT max('abc', 'ABD' COLLATE NOCASE), max('abc', 'ABD'), min('B', 'a' COLLATE NOCASE), min('B', 'a');
-- The leftmost collation wins.
SELECT max('abc' COLLATE BINARY, 'ABD' COLLATE NOCASE), max('abc' COLLATE NOCASE, 'ABD' COLLATE BINARY);
-- nullif(a, b) compares a = b with the usual collation rules.
SELECT id, nullif(n, 'ABC'), nullif(b, 'ABC'), nullif('ABC', n) FROM t ORDER BY id;
-- instr and replace are always case-sensitive.
SELECT id, instr(n, 'B'), replace(n, 'b', '_') FROM t ORDER BY id;
-- A function result is a plain value with no collation: comparing it
-- with a literal uses BINARY.
SELECT id FROM t WHERE max(n, 'a') = 'ABC' ORDER BY id;
-- Three or more arguments: the collation still comes from the leftmost
-- argument that has one.
SELECT max('b', 'C', 'a'), max('b', 'C' COLLATE NOCASE, 'a'), min('b', 'C', 'A'), min('b', 'C', 'A' COLLATE NOCASE);
-- Overriding a column's collation inside max().
SELECT id, max(n COLLATE BINARY, 'ABD') FROM t ORDER BY id;
-- A NULL argument still makes the result NULL.
SELECT max(n, NULL), min(NULL, n) FROM t WHERE id = 1;
-- nullif() with an explicit COLLATE.
SELECT nullif('abc', 'ABC' COLLATE NOCASE), nullif('abc' COLLATE BINARY, 'ABC');
