-- min/max across storage classes use the normal sort order:
-- NULL (ignored) < numbers < TEXT < BLOB.
CREATE TABLE t(v);
INSERT INTO t VALUES (10), (2.5), ('9'), ('abc'), (x'00'), (x'FF'), (NULL), (-1), ('');
SELECT min(v), max(v), typeof(min(v)), typeof(max(v)) FROM t;
SELECT min(v), max(v) FROM t WHERE typeof(v) <> 'blob';
SELECT min(v), max(v) FROM t WHERE typeof(v) IN ('integer', 'real');
SELECT min(v), max(v) FROM t WHERE typeof(v) = 'text';
SELECT min(v), max(v) FROM t WHERE typeof(v) = 'blob';

-- '9' (text) is greater than 10 (integer): text always sorts after numbers.
SELECT max(v) FROM t WHERE v IN (10, '9');

-- In an INTEGER/NUMERIC column, numeric-looking text is stored as a number.
CREATE TABLE n(v NUMERIC);
INSERT INTO n VALUES ('10'), ('9'), ('100'), ('2.5');
SELECT min(v), max(v), typeof(max(v)) FROM n;

-- In a TEXT column, numbers are stored as text and compare as strings.
CREATE TABLE s(v TEXT);
INSERT INTO s VALUES (10), (9), (100), (2.5);
SELECT min(v), max(v), typeof(max(v)) FROM s;

-- Grouped.
CREATE TABLE g(k TEXT, v);
INSERT INTO g VALUES ('x', 1), ('x', 'one'), ('y', x'01'), ('y', 5.5), ('z', NULL), ('z', '');
SELECT k, min(v), max(v) FROM g GROUP BY k ORDER BY k;

-- Blobs compare bytewise.
CREATE TABLE b(v BLOB);
INSERT INTO b VALUES (x'0102'), (x'01'), (x'0201'), (x'');
SELECT min(v), max(v) FROM b;
