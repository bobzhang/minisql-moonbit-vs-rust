-- Sorting across storage classes: NULL < numbers (INTEGER and REAL compared by
-- value) < TEXT < BLOB. TEXT sorts with memcmp (BINARY), BLOB with memcmp.
CREATE TABLE t(id INTEGER, x);
INSERT INTO t VALUES
  (1, 10), (2, '10'), (3, 9.5), (4, x'0A'), (5, NULL), (6, -3), (7, 'abc'),
  (8, 'Abc'), (9, x''), (10, 1e100), (11, ''), (12, -1.5e-3), (13, x'FF00'), (14, '9');
SELECT id, x, typeof(x) FROM t ORDER BY x, id;
SELECT id, x FROM t ORDER BY x DESC, id;

-- Integers and reals interleave by numeric value; equal values tie.
CREATE TABLE n(id INTEGER, v);
INSERT INTO n VALUES (1, 2), (2, 2.0), (3, 1.9999), (4, 3), (5, -0.0), (6, 0), (7, 9223372036854775807), (8, 9.3e18), (9, -9223372036854775808);
SELECT id, v FROM n ORDER BY v, id;
SELECT id, v FROM n ORDER BY v DESC, id DESC;

-- Text is not numeric in ORDER BY: '10' < '9' because it compares bytes.
CREATE TABLE s(id INTEGER, v TEXT);
INSERT INTO s VALUES (1, '10'), (2, '9'), (3, '100'), (4, 'a'), (5, 'B'), (6, 'b'), (7, ' z'), (8, 'é'), (9, 'e');
SELECT v FROM s ORDER BY v;
SELECT v FROM s ORDER BY v DESC;

-- A column with NUMERIC affinity stores '10' as 10, so it sorts numerically.
CREATE TABLE a(id INTEGER, v NUMERIC);
INSERT INTO a VALUES (1, '10'), (2, '9'), (3, '100'), (4, 'x'), (5, '2.5');
SELECT v, typeof(v) FROM a ORDER BY v;

-- Blobs compare bytewise, shorter prefix first.
CREATE TABLE b(id INTEGER, v BLOB);
INSERT INTO b VALUES (1, x'0102'), (2, x'01'), (3, x'00FF'), (4, x'02'), (5, x'');
SELECT id, v FROM b ORDER BY v;
SELECT id, v FROM b ORDER BY v DESC;

-- Sorting by an expression of mixed type.
SELECT id, x FROM t WHERE id <= 8 ORDER BY typeof(x), id DESC;
