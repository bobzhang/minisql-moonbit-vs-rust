-- DISTINCT treats integer and real values that are numerically equal as
-- duplicates, but values of different storage classes (TEXT vs numbers) as
-- different. To avoid depending on which duplicate is kept, the results are
-- normalized before being shown.
CREATE TABLE m(v);
INSERT INTO m VALUES (1), (1.0), (2), ('1'), ('1.0'), (2.5), (2.50), (NULL), (NULL), (x'01');

-- 1 and 1.0 collapse; '1' and '1.0' are different texts.
CREATE TABLE out1(v);
INSERT INTO out1 SELECT DISTINCT v FROM m;
SELECT v + 0.0 FROM out1 WHERE typeof(v) IN ('integer', 'real') ORDER BY 1;
SELECT v FROM out1 WHERE typeof(v) = 'text' ORDER BY v;
SELECT typeof(v) FROM out1 WHERE v IS NULL OR typeof(v) = 'blob' ORDER BY 1;

-- After affinity in a REAL column all numeric-looking values are equal.
CREATE TABLE r(v REAL);
INSERT INTO r VALUES (1), (1.0), ('1'), ('1.0'), (2);
SELECT DISTINCT v FROM r ORDER BY v;

-- In a TEXT column 1 and '1' are the same text, but 1.0 is '1.0'.
CREATE TABLE s(v TEXT);
INSERT INTO s VALUES (1), ('1'), (1.0), ('1.0'), (2);
SELECT DISTINCT v FROM s ORDER BY v;

-- Two-column DISTINCT where only one column differs by type.
CREATE TABLE p(a, b);
INSERT INTO p VALUES (1, 'x'), (1.0, 'x'), (1, 'y'), ('1', 'x');
CREATE TABLE out2(a, b);
INSERT INTO out2 SELECT DISTINCT a, b FROM p;
SELECT typeof(a) = 'text', b FROM out2 ORDER BY 1, 2;

-- DISTINCT on a computed value.
SELECT DISTINCT v * 2 FROM r ORDER BY 1;
SELECT DISTINCT CAST(v AS INTEGER) FROM m WHERE typeof(v) <> 'blob' ORDER BY 1;
