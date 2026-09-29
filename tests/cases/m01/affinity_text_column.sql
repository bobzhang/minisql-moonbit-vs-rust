-- TEXT affinity on storage: numbers are converted to their text form;
-- blobs and NULL are kept.

CREATE TABLE t(id INTEGER, v TEXT);
INSERT INTO t VALUES (1, 5), (2, -12), (3, 0), (4, 9223372036854775807);
INSERT INTO t VALUES (5, 1.5), (6, 0.1), (7, 100.0), (8, -2.25), (9, 0.0001), (10, 123456789.125);
INSERT INTO t VALUES (11, 'already text'), (12, ''), (13, x'00ff'), (14, NULL), (15, '007');
SELECT id, v, typeof(v) FROM t ORDER BY id;
-- The stored text keeps its exact spelling ('007' stays '007').
SELECT id FROM t WHERE v = '007';
SELECT id FROM t WHERE v = '5';
SELECT id FROM t WHERE v = '100.0';
-- Text sorts differently from numbers.
SELECT v FROM t WHERE id <= 8 ORDER BY v;
-- CHAR, VARCHAR, CLOB and similar names have TEXT affinity.
CREATE TABLE u(a CHAR(5), b VARCHAR(10), c CLOB, d NCHAR(2), e TINYTEXT, f CHARACTER VARYING(4));
INSERT INTO u VALUES (1, 2.5, 3, 4, 5, 6);
SELECT a, b, c, d, e, f FROM u;
SELECT typeof(a), typeof(b), typeof(c), typeof(d), typeof(e), typeof(f) FROM u;
-- Concatenating stored text.
SELECT a || b || c FROM u;
