-- pi(), degrees(X) and radians(X).

SELECT pi(), typeof(pi());
SELECT round(degrees(pi()), 10), round(degrees(pi() / 2), 10), degrees(0), round(degrees(-pi()), 10);
SELECT round(radians(180), 12), round(radians(90) * 2, 12), radians(0), round(radians(-180), 12);
SELECT degrees(1), radians(1);
SELECT round(degrees(radians(123.456)), 10), round(radians(degrees(0.5)), 12);
-- Integer input gives REAL output.
SELECT typeof(degrees(180)), typeof(radians(180));
-- NULL and text.
SELECT degrees(NULL), radians(NULL), round(radians('180'), 12), degrees('x');
-- Using pi() in expressions.
SELECT round(2 * pi() * 10, 10), round(pi() * 3 * 3, 10);
-- Converting a table of angles.
CREATE TABLE t(d INTEGER);
INSERT INTO t VALUES (0), (45), (90), (360), (-90);
SELECT d, round(radians(d), 12), round(degrees(radians(d)), 9) FROM t ORDER BY d;
-- pi takes no arguments.
SELECT pi(1);
SELECT degrees();
SELECT radians(1, 2);
