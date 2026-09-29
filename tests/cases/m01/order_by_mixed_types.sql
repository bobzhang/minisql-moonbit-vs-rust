-- Default ordering across storage classes:
-- NULL < INTEGER and REAL (by numeric value) < TEXT (binary) < BLOB (memcmp).
-- DESC reverses it, so NULLs come last.

CREATE TABLE t(id INTEGER, v);
INSERT INTO t VALUES
  (1, 3), (2, 1.5), (3, 'b'), (4, 'A'), (5, x'00'), (6, NULL), (7, -2),
  (8, '10'), (9, x''), (10, 2), (11, ''), (12, 2.0), (13, x'0001'), (14, NULL), (15, -2.5);
SELECT v FROM t ORDER BY v, id;
SELECT v FROM t ORDER BY v DESC, id;
SELECT id, typeof(v) FROM t ORDER BY v, id;
-- Integers and reals interleave by value; equal values tie (broken by id).
SELECT id, v FROM t WHERE v = 2 ORDER BY v, id DESC;
-- Numeric-looking text still sorts as text, after all numbers.
CREATE TABLE u(v);
INSERT INTO u VALUES ('100'), (100), ('20'), (20), ('3'), (3.5);
SELECT v, typeof(v) FROM u ORDER BY v;
SELECT v, typeof(v) FROM u ORDER BY v DESC;
-- Non-ASCII text sorts by UTF-8 bytes.
CREATE TABLE w(v TEXT);
INSERT INTO w VALUES ('z'), ('é'), ('e'), ('中'), ('Z'), ('ÿ'), ('😀');
SELECT v FROM w ORDER BY v;
-- Blobs sort by bytes, shorter prefix first.
CREATE TABLE b(v BLOB);
INSERT INTO b VALUES (x'FF'), (x'00'), (x'0000'), (x''), (x'7F'), (x'80'), (x'00FF');
SELECT v FROM b ORDER BY v;
SELECT v FROM b ORDER BY v DESC;
