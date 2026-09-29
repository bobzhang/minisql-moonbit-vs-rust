-- @db file
-- The engine writes values of every storage class and integer width:
-- boundaries of the 1/2/3/4/6/8-byte integer serial types, 0 and 1, reals
-- (including ones that are not integers and extreme magnitudes), empty and
-- non-empty text and blobs, and NULLs. SQLite reads them back exactly.
-- @phase engine
CREATE TABLE v(id INTEGER PRIMARY KEY, x);
INSERT INTO v(x) VALUES (0), (1), (-1), (127), (-128), (128), (-129), (32767), (-32768), (32768), (-32769),
  (8388607), (-8388608), (8388608), (-8388609), (2147483647), (-2147483648), (2147483648), (-2147483649),
  (140737488355327), (-140737488355328), (140737488355328), (-140737488355329),
  (9223372036854775807), (-9223372036854775808),
  (0.5), (-0.5), (3.141592653589793), (1.0e-300), (1.7976931348623157e308), (5.0e-324), (-1e15), (2.5e-7),
  (''), ('a'), (printf('%.*c', 100, 'q')), (x''), (x'00'), (x'0102FEFF'), (zeroblob(100)), (NULL), (NULL);
CREATE TABLE multi(a INTEGER, b REAL, c TEXT, d BLOB, e);
INSERT INTO multi VALUES (NULL, NULL, NULL, NULL, NULL), (1, 1.5, 'one', x'01', 1), (0, 0.0, '', x'', 0),
  (-7, -7.25, 'neg', x'FF', -7.25);
-- @phase sqlite
PRAGMA integrity_check;
SELECT id, x, typeof(x) FROM v WHERE typeof(x) IN ('integer', 'real', 'null') ORDER BY id;
SELECT id, length(x), typeof(x), hex(substr(x, 1, 4)) FROM v WHERE typeof(x) IN ('text', 'blob') ORDER BY id;
SELECT sum(x = -2147483649), sum(x = 9223372036854775807), sum(x = 5.0e-324) FROM v;
SELECT a, typeof(a), b, typeof(b), c, typeof(c), hex(d), typeof(d), e, typeof(e) FROM multi ORDER BY rowid;
-- @phase engine
SELECT count(*), sum(typeof(x) = 'integer'), sum(typeof(x) = 'real'), sum(typeof(x) = 'text'), sum(typeof(x) = 'blob') FROM v;
SELECT max(x), min(x) FROM v WHERE typeof(x) = 'integer';
