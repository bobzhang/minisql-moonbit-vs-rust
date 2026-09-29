-- Indexed lookups must follow the same comparison and affinity rules as full
-- scans: the constant is converted to the column's affinity before being
-- compared, and values of different storage classes order as
-- NULL < numbers < text < blob.
CREATE TABLE ti(n INTEGER);
CREATE TABLE tt(s TEXT);
CREATE TABLE tr(r REAL);
CREATE TABLE tn(v);
INSERT INTO ti VALUES (1), (5), (10), (NULL), ('7'), ('x');
INSERT INTO tt VALUES ('1'), ('5'), ('10'), (5), (NULL), ('abc');
INSERT INTO tr VALUES (1.5), (5), ('2.5'), (10);
INSERT INTO tn VALUES (1), ('1'), (2.5), ('abc'), (x'01'), (NULL), (10), ('10');
CREATE INDEX ti_n ON ti(n);
CREATE INDEX tt_s ON tt(s);
CREATE INDEX tr_r ON tr(r);
CREATE INDEX tn_v ON tn(v);

-- INTEGER column: text constants that look like numbers are converted.
SELECT n FROM ti WHERE n = '5';
SELECT n FROM ti WHERE n = 7;
SELECT n FROM ti WHERE n > '4' ORDER BY n;
SELECT n, typeof(n) FROM ti WHERE n >= 5 ORDER BY n;
SELECT n FROM ti WHERE n IN ('1', 10, '10') ORDER BY n;
-- TEXT column: numeric constants are converted to text, so comparisons are textual.
SELECT s FROM tt WHERE s = 5 ORDER BY s;
SELECT s FROM tt WHERE s > 2 ORDER BY s;
SELECT s FROM tt WHERE s < '5' ORDER BY s;
SELECT s FROM tt WHERE s BETWEEN 1 AND 5 ORDER BY s;
-- REAL column.
SELECT r FROM tr WHERE r = 5 ORDER BY r;
SELECT r FROM tr WHERE r = '2.5';
SELECT r FROM tr WHERE r > 2 ORDER BY r;
-- Untyped column: no conversion; numbers sort before text before blobs.
SELECT v FROM tn WHERE v = 1;
SELECT v FROM tn WHERE v = '1';
SELECT v FROM tn WHERE v > 2 ORDER BY v;
SELECT v FROM tn WHERE v > '1' ORDER BY v;
SELECT v FROM tn WHERE v < 'a' ORDER BY v;
SELECT typeof(v), count(*) FROM tn GROUP BY typeof(v) ORDER BY 1;
SELECT v FROM tn WHERE v >= x'00' ORDER BY v;
-- An expression on the column side has no affinity.
SELECT s FROM tt WHERE s + 0 = 5 ORDER BY s;
SELECT n FROM ti WHERE n || '' = '10';
-- min/max with mixed types.
SELECT min(v), max(v) FROM tn;
SELECT min(s), max(s) FROM tt;
