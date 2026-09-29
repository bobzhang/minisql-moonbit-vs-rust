-- Comparing values of different storage classes (no column affinity is
-- involved: only literals and untyped columns). The order is
-- NULL < INTEGER/REAL < TEXT < BLOB, and no conversion happens.

-- A number is always less than any text, even numeric-looking text.
SELECT 1 < '1', 1 = '1', '1' = 1, 1 > '0', 999999 < 'a';
SELECT 1.5 < '', -1 < '-1', 0 = '';
-- Text is always less than a blob.
SELECT 'a' < x'00', 'zzz' < x'', x'41' = 'A', x'41' > 'A';
-- A number is less than a blob.
SELECT 1 < x'00', 9e300 < x'';
-- INTEGER and REAL compare by numeric value.
SELECT 1 = 1.0, 2 > 1.5, 3 < 3.5, -1 = -1.0, 0 = -0.0;
-- Columns without a declared type have no affinity, so the stored class is
-- kept and cross-class rules apply.
CREATE TABLE u(id INTEGER, v);
INSERT INTO u VALUES (1, 1), (2, '1'), (3, 1.0), (4, x'31'), (5, NULL), (6, 'abc'), (7, 2);
SELECT id, typeof(v) FROM u ORDER BY id;
SELECT id FROM u WHERE v = 1 ORDER BY id;
SELECT id FROM u WHERE v = '1' ORDER BY id;
SELECT id FROM u WHERE v = x'31' ORDER BY id;
SELECT id FROM u WHERE v < 'a' ORDER BY id;
SELECT id FROM u WHERE v > 100 ORDER BY id;
SELECT id FROM u WHERE v >= x'00' ORDER BY id;
-- Comparing two untyped columns.
CREATE TABLE pairs(id INTEGER, a, b);
INSERT INTO pairs VALUES (1, 1, '1'), (2, 'x', x'78'), (3, 2, 2.0), (4, NULL, 1), (5, 'b', 'a');
SELECT id, a = b, a < b, a > b FROM pairs ORDER BY id;
