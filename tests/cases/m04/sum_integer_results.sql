-- sum() of integers is an integer; sum() of no non-NULL values is NULL.
CREATE TABLE t(g TEXT, v INTEGER);
INSERT INTO t VALUES ('a', 1), ('a', 2), ('a', 3), ('b', -5), ('b', 5), ('c', NULL), ('d', 9007199254740993), ('d', 1);
SELECT sum(v), typeof(sum(v)) FROM t WHERE g IN ('a', 'b');
SELECT g, sum(v), typeof(sum(v)) FROM t GROUP BY g ORDER BY g;

-- Integer sums are exact even beyond 2^53.
SELECT sum(v) FROM t WHERE g = 'd';
SELECT sum(v) - 9007199254740993 FROM t WHERE g = 'd';

-- Sum of an empty set is NULL (not 0).
SELECT sum(v) FROM t WHERE g = 'zzz';
SELECT sum(v), typeof(sum(v)) FROM t WHERE v IS NULL;
CREATE TABLE e(v INTEGER);
SELECT sum(v) FROM e;

-- NULLs are ignored.
SELECT sum(v) FROM t WHERE g IN ('a', 'c');

-- Negative and zero.
SELECT sum(-v) FROM t WHERE g = 'a';
SELECT sum(v * 0) FROM t WHERE g <> 'c';

-- Sum of an expression and of a constant.
SELECT sum(v * v) FROM t WHERE g = 'a';
SELECT sum(1) FROM t;
SELECT sum(v % 2) FROM t WHERE g IN ('a', 'b');

-- Values stored with INTEGER affinity from text are integers.
CREATE TABLE a(v INTEGER);
INSERT INTO a VALUES ('10'), ('20'), (30);
SELECT sum(v), typeof(sum(v)) FROM a;

-- Large but non-overflowing sums.
CREATE TABLE b(v INTEGER);
INSERT INTO b VALUES (4611686018427387904), (4611686018427387903);
SELECT sum(v), typeof(sum(v)) FROM b;
INSERT INTO b VALUES (-9223372036854775807);
SELECT sum(v) FROM b;
