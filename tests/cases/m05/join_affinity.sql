-- Join conditions compare values with the usual affinity rules: if either
-- operand is a column with numeric affinity, text operands that look like
-- numbers are converted; a TEXT column compared with an expression that has no
-- affinity converts that expression to text; a TEXT column compared with an
-- untyped (BLOB-affinity) column converts nothing, so values compare by
-- storage class.
CREATE TABLE ints(i INTEGER, tag TEXT);
CREATE TABLE texts(t TEXT, tag TEXT);
CREATE TABLE anys(a, tag TEXT);
CREATE TABLE reals(r REAL, tag TEXT);
INSERT INTO ints VALUES (1, 'i1'), (2, 'i2'), (10, 'i10');
INSERT INTO texts VALUES ('1', 't1'), ('2.0', 't2.0'), ('10', 't10'), ('abc', 'tabc');
INSERT INTO anys VALUES (1, 'a1'), ('1', 'a''1'''), (2.0, 'a2.0'), ('10', 'a''10''');
INSERT INTO reals VALUES (1.0, 'r1'), (2.5, 'r2.5'), (10.0, 'r10');

-- INTEGER column vs TEXT column: text is converted to a number.
SELECT ints.tag, texts.tag FROM ints JOIN texts ON i = t ORDER BY ints.tag, texts.tag;
SELECT ints.tag, texts.tag FROM texts JOIN ints ON t = i ORDER BY ints.tag, texts.tag;
-- INTEGER column vs untyped column: the untyped text '1' converts too.
SELECT ints.tag, anys.tag FROM ints JOIN anys ON i = a ORDER BY ints.tag, anys.tag;
-- TEXT column vs untyped column: no conversion, so only the text values match
-- (the integer 1 and the real 2.0 do not).
SELECT texts.tag, anys.tag FROM texts JOIN anys ON t = a ORDER BY texts.tag, anys.tag;
-- REAL vs INTEGER: numeric comparison, 1 = 1.0.
SELECT ints.tag, reals.tag FROM ints JOIN reals ON i = r ORDER BY ints.tag;
-- REAL vs TEXT.
SELECT reals.tag, texts.tag FROM reals JOIN texts ON r = t ORDER BY reals.tag;
-- Untyped vs untyped: no conversion, 1 and '1' differ.
SELECT x.tag, y.tag FROM anys x JOIN anys y ON x.a = y.a ORDER BY x.tag, y.tag;
-- An expression has no affinity: i + 0 vs texts.t still converts t (column side has TEXT affinity,
-- the other operand has none, so TEXT affinity applies to the number).
SELECT ints.tag, texts.tag FROM ints JOIN texts ON i + 0 = t ORDER BY ints.tag, texts.tag;
-- CAST forces the comparison type.
SELECT ints.tag, texts.tag FROM ints JOIN texts ON CAST(i AS TEXT) = t ORDER BY ints.tag, texts.tag;
SELECT ints.tag, texts.tag FROM ints JOIN texts ON i = CAST(t AS INTEGER) ORDER BY ints.tag, texts.tag;
-- USING applies the same comparison rules.
CREATE TABLE ik(k INTEGER, iv TEXT);
CREATE TABLE tk(k TEXT, tv TEXT);
INSERT INTO ik VALUES (5, 'five'), (6, 'six');
INSERT INTO tk VALUES ('5', 'cinq'), ('06', 'six?'), ('x', 'x');
SELECT k, iv, tv FROM ik JOIN tk USING (k) ORDER BY iv;
SELECT iv, tv FROM ik NATURAL JOIN tk ORDER BY iv;
-- Range conditions across types.
SELECT ints.tag, texts.tag FROM ints JOIN texts ON i < t ORDER BY ints.tag, texts.tag;
