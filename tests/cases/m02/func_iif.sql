-- iif(C, X, Y) and its alias if(C, X, Y): X if C is true, else Y. With two
-- arguments, a false condition gives NULL. Only the chosen branch is
-- evaluated.

SELECT iif(1, 'yes', 'no'), iif(0, 'yes', 'no'), iif(NULL, 'yes', 'no');
SELECT if(1, 'yes', 'no'), if(0, 'yes', 'no');
-- Truthiness of the condition.
SELECT iif(2, 'T', 'F'), iif(0.1, 'T', 'F'), iif(0.0, 'T', 'F'), iif('abc', 'T', 'F'), iif('1abc', 'T', 'F');
SELECT iif(x'00', 'T', 'F'), iif(x'31', 'T', 'F');
-- Two-argument form.
SELECT iif(1, 'x'), iif(0, 'x'), iif(NULL, 'x'), if(1, 5);
-- The result keeps the chosen branch's type.
SELECT typeof(iif(1, 1, 'a')), typeof(iif(0, 1, 'a')), typeof(iif(1, 1.5, 2)), iif(1, x'AB', 0);
-- Only the chosen branch is evaluated.
SELECT iif(1, 'safe', abs(-9223372036854775808)), iif(0, abs(-9223372036854775808), 'safe');
SELECT iif(0, abs(-9223372036854775808));
-- The condition is evaluated.
SELECT iif(abs(-9223372036854775808), 1, 2);
-- Nested.
SELECT iif(1 > 2, 'a', iif(2 > 1, 'b', 'c'));
-- Over rows.
CREATE TABLE t(id INTEGER, v INTEGER);
INSERT INTO t VALUES (1, 5), (2, -3), (3, 0), (4, NULL);
SELECT id, iif(v > 0, 'pos', iif(v < 0, 'neg', 'zero-or-null')) FROM t ORDER BY id;
SELECT id, if(v IS NULL, 'missing', v * 10) FROM t ORDER BY id;
SELECT id FROM t WHERE iif(v >= 0, 1, 0) ORDER BY id;
-- Wrong number of arguments.
SELECT iif(1);
SELECT iif();
