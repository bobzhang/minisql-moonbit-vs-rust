-- sum() raises "integer overflow" if an all-integer sum leaves the 64-bit
-- range. total() never raises; it always works in floating point. (Every
-- input here is non-negative, so the overflow happens in any summation
-- order.)
CREATE TABLE t(v INTEGER);
INSERT INTO t VALUES (9223372036854775807), (1);
SELECT sum(v) FROM t;
SELECT total(v) FROM t;
SELECT avg(v) FROM t;

CREATE TABLE u(v INTEGER);
INSERT INTO u VALUES (5000000000000000000), (5000000000000000000);
SELECT sum(v) FROM u;
SELECT total(v), typeof(total(v)) FROM u;

-- Negative overflow.
CREATE TABLE n(v INTEGER);
INSERT INTO n VALUES (-9223372036854775808), (-1);
SELECT sum(v) FROM n;
SELECT total(v) FROM n;

-- Exactly at the limits is fine.
CREATE TABLE ok(v INTEGER);
INSERT INTO ok VALUES (9223372036854775806), (1);
SELECT sum(v) FROM ok;
CREATE TABLE ok2(v INTEGER);
INSERT INTO ok2 VALUES (-9223372036854775807), (-1);
SELECT sum(v) FROM ok2;

-- Overflow in one group fails the whole statement (no rows printed).
CREATE TABLE g(k TEXT, v INTEGER);
INSERT INTO g VALUES ('a', 1), ('a', 2), ('b', 9223372036854775807), ('b', 9223372036854775807);
SELECT k, sum(v) FROM g GROUP BY k ORDER BY k;
SELECT k, total(v) FROM g GROUP BY k ORDER BY k;
SELECT k, sum(v) FROM g WHERE k = 'a' GROUP BY k;

-- With a REAL among the inputs, sum() works in floating point: no error.
CREATE TABLE r(v);
INSERT INTO r VALUES (9223372036854775807), (9223372036854775807), (1.0);
SELECT sum(v), typeof(sum(v)) FROM r;

-- An overflowing sum inside an INSERT ... SELECT aborts the insert.
CREATE TABLE dst(s);
INSERT INTO dst SELECT sum(v) FROM u;
SELECT s FROM dst;
INSERT INTO dst SELECT total(v) FROM u;
SELECT s FROM dst;
