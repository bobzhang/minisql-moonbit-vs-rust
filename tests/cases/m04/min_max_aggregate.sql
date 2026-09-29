-- min(x) and max(x) with ONE argument are aggregates. They ignore NULLs and
-- return NULL for empty input. The result keeps the value's storage class.
CREATE TABLE t(g TEXT, v);
INSERT INTO t VALUES ('a', 3), ('a', 10), ('a', -2), ('b', 2.5), ('b', 2), ('c', NULL), ('c', 7), ('d', NULL);
SELECT min(v), max(v) FROM t;
SELECT g, min(v), max(v), typeof(min(v)), typeof(max(v)) FROM t GROUP BY g ORDER BY g;

-- Empty table.
CREATE TABLE e(v);
SELECT min(v), max(v), typeof(min(v)) FROM e;
SELECT min(v) FROM t WHERE g = 'zzz';

-- Strings compare with BINARY by default.
CREATE TABLE s(v TEXT);
INSERT INTO s VALUES ('pear'), ('Apple'), ('apple'), ('banana'), ('');
SELECT min(v), max(v) FROM s;
SELECT min(length(v)), max(length(v)) FROM s;

-- min/max of expressions.
SELECT min(v * -1), max(v % 4) FROM t WHERE g = 'a';
SELECT max(abs(v)) FROM t;

-- Two or more arguments make min/max the SCALAR functions (NULL if any
-- argument is NULL), which work row by row.
SELECT g, max(v, 5), min(v, 5) FROM t WHERE g IN ('a', 'c') ORDER BY g, v;

-- Mixing the aggregate and scalar forms.
SELECT max(min(v, 0)) FROM t;
SELECT min(max(v, 0)) FROM t;

-- Integer boundaries.
CREATE TABLE b(v INTEGER);
INSERT INTO b VALUES (9223372036854775807), (-9223372036854775808), (0);
SELECT min(v), max(v) FROM b;

-- Real with the same value as an integer: both are equal, result prints its own class.
CREATE TABLE r(v);
INSERT INTO r VALUES (1.5), (3.0), (2);
SELECT max(v), typeof(max(v)), min(v), typeof(min(v)) FROM r;

-- min() and max() with no arguments are errors.
SELECT max() FROM t;
SELECT min() FROM t;
