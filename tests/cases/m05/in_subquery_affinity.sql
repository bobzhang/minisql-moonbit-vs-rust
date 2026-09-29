-- Type conversions in IN (SELECT ...): when the left operand is a column with
-- numeric affinity, text-looking numbers from the subquery compare as numbers;
-- when neither side has affinity, 1 and '1' are different values.
CREATE TABLE nums(n INTEGER);
CREATE TABLE strs(s TEXT);
CREATE TABLE raw(r);
INSERT INTO nums VALUES (1), (2), (3);
INSERT INTO strs VALUES ('1'), ('2.0'), ('03'), ('x');
INSERT INTO raw VALUES (1), ('2'), (3.0);

-- INTEGER column IN a TEXT column.
SELECT n FROM nums WHERE n IN (SELECT s FROM strs) ORDER BY n;
-- TEXT column IN an INTEGER column.
SELECT s FROM strs WHERE s IN (SELECT n FROM nums) ORDER BY s;
-- Untyped column IN an INTEGER column.
SELECT r FROM raw WHERE r IN (SELECT n FROM nums) ORDER BY r;
-- Literal on the left has no affinity.
SELECT 1 IN (SELECT s FROM strs), '1' IN (SELECT s FROM strs), 1 IN (SELECT n FROM nums), '1' IN (SELECT n FROM nums);
SELECT 1 IN (SELECT r FROM raw), '1' IN (SELECT r FROM raw), 2 IN (SELECT r FROM raw), '2' IN (SELECT r FROM raw);
-- Integer and real compare equal.
SELECT 3 IN (SELECT r FROM raw), 3.0 IN (SELECT n FROM nums), 2.5 IN (SELECT n FROM nums);
-- NOT IN mirrors IN.
SELECT n FROM nums WHERE n NOT IN (SELECT s FROM strs) ORDER BY n;
SELECT s FROM strs WHERE s NOT IN (SELECT n FROM nums) ORDER BY s;
-- CAST in the subquery changes the comparison. A CAST expression has the
-- affinity of its target type; against an untyped column (BLOB affinity) no
-- conversion happens, so only values of the same storage class can match.
SELECT count(*) FROM raw WHERE r IN (SELECT CAST(n AS TEXT) FROM nums);
SELECT count(*) FROM raw WHERE r IN (SELECT CAST(s AS INTEGER) FROM strs);
-- Collation: a NOCASE column on the left makes IN case-insensitive.
CREATE TABLE ci(w TEXT COLLATE NOCASE);
CREATE TABLE words(w TEXT);
INSERT INTO ci VALUES ('Apple'), ('pear');
INSERT INTO words VALUES ('APPLE'), ('Pear'), ('plum');
SELECT w FROM ci WHERE w IN (SELECT w FROM words) ORDER BY w;
SELECT w FROM words WHERE w IN (SELECT w FROM ci) ORDER BY w;
