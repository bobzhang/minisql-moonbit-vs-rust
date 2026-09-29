-- Trigonometric functions: sin cos tan asin acos atan atan2 (radians).
-- Results that are not exact are rounded to 12 places so the test does not
-- depend on the last bit of the platform's math library.

SELECT sin(0), cos(0), tan(0), asin(0), atan(0), acos(1);
SELECT round(sin(1), 12), round(cos(1), 12), round(tan(1), 12);
SELECT round(sin(pi() / 2), 12), round(cos(pi()), 12), round(tan(pi() / 4), 12), round(sin(pi() / 6), 12);
SELECT round(sin(-1), 12), round(cos(-1), 12), round(sin(100), 12);
-- Inverse functions.
SELECT round(asin(1), 12), round(acos(0), 12), round(atan(1), 12), round(acos(-1), 12), round(asin(-0.5), 12);
-- Out of domain gives NULL.
SELECT asin(2), acos(-1.5), asin(-1.0000001);
-- atan2(Y, X) chooses the quadrant from both signs.
SELECT round(atan2(1, 1), 12), round(atan2(1, -1), 12), round(atan2(-1, -1), 12), round(atan2(-1, 1), 12);
SELECT round(atan2(0, -1), 12), atan2(0, 1), round(atan2(1, 0), 12), round(atan2(-1, 0), 12);
-- All results are REAL, even for integer input.
SELECT typeof(sin(0)), typeof(cos(0)), typeof(atan2(0, 1));
-- NULL and non-numeric text give NULL; numeric text is converted.
SELECT sin(NULL), cos('abc'), tan(x'30'), sin('0'), round(cos('1'), 12), atan2(NULL, 1);
-- Identity checks.
SELECT round(sin(0.7) * sin(0.7) + cos(0.7) * cos(0.7), 12), round(tan(0.3) - sin(0.3) / cos(0.3), 12);
-- From a table of angles (degrees converted to radians).
CREATE TABLE a(deg INTEGER);
INSERT INTO a VALUES (0), (30), (45), (60), (90), (180), (270);
SELECT deg, round(sin(radians(deg)), 10), round(cos(radians(deg)), 10) FROM a ORDER BY deg;
-- Wrong number of arguments.
SELECT sin();
SELECT atan2(1);
