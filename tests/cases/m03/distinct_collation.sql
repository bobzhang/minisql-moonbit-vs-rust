-- DISTINCT compares values using the collation of the result expression.
-- To avoid depending on which of several equal values is kept, results are
-- copied into another table and inspected in a case-insensitive way.
CREATE TABLE t(id INTEGER PRIMARY KEY, nc TEXT COLLATE NOCASE, rt TEXT COLLATE RTRIM, bin TEXT);
INSERT INTO t(nc, rt, bin) VALUES ('abc', 'x', 'abc'), ('ABC', 'x ', 'ABC'), ('Abc', 'x  ', 'Abc'), ('def', 'y', 'def'), ('DEF', 'y', 'DEF');

-- BINARY column: all five spellings are distinct.
SELECT DISTINCT bin FROM t ORDER BY bin;

-- NOCASE column: only two distinct values survive.
CREATE TABLE out1(v TEXT);
INSERT INTO out1 SELECT DISTINCT nc FROM t;
SELECT upper(v) FROM out1 ORDER BY 1;

-- RTRIM column: 'x', 'x ', 'x  ' are one value.
CREATE TABLE out2(v TEXT);
INSERT INTO out2 SELECT DISTINCT rt FROM t;
SELECT rtrim(v) FROM out2 ORDER BY 1;

-- COLLATE in the select list changes DISTINCT's comparison.
CREATE TABLE out3(v TEXT);
INSERT INTO out3 SELECT DISTINCT bin COLLATE NOCASE FROM t;
SELECT lower(v) FROM out3 ORDER BY 1;

-- Overriding the column collation with BINARY brings duplicates back.
SELECT DISTINCT nc COLLATE BINARY FROM t ORDER BY 1;

-- An expression like lower(nc) has no collation of its own... but the
-- values are already equal after folding.
SELECT DISTINCT lower(nc) FROM t ORDER BY 1;
SELECT DISTINCT upper(bin) FROM t ORDER BY 1;
