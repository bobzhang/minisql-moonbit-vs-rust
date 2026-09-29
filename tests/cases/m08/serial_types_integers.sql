-- @db file
-- Every integer serial type: 8 and 9 (constants 0 and 1, no body bytes),
-- 1, 2, 3, 4, 6 and 8 byte big-endian two's complement values, at both the
-- positive and negative boundary of each width.
-- @phase sqlite
CREATE TABLE ints(id INTEGER PRIMARY KEY, v INTEGER, label TEXT);
INSERT INTO ints(v, label) VALUES
  (0, 'zero (serial 8)'), (1, 'one (serial 9)'),
  (2, 'serial 1'), (-1, 'serial 1'), (127, 'serial 1 max'), (-128, 'serial 1 min'),
  (128, 'serial 2'), (-129, 'serial 2'), (32767, 'serial 2 max'), (-32768, 'serial 2 min'),
  (32768, 'serial 3'), (-32769, 'serial 3'), (8388607, 'serial 3 max'), (-8388608, 'serial 3 min'),
  (8388608, 'serial 4'), (-8388609, 'serial 4'), (2147483647, 'serial 4 max'), (-2147483648, 'serial 4 min'),
  (2147483648, 'serial 5'), (-2147483649, 'serial 5'), (140737488355327, 'serial 5 max'), (-140737488355328, 'serial 5 min'),
  (140737488355328, 'serial 6'), (-140737488355329, 'serial 6'),
  (9223372036854775807, 'serial 6 max'), (-9223372036854775808, 'serial 6 min'),
  (255, 'byte pattern'), (65535, 'byte pattern'), (16777215, 'byte pattern'), (4294967295, 'byte pattern'),
  (-256, 'byte pattern'), (1099511627776, 'byte pattern'), (72057594037927936, 'byte pattern'),
  (NULL, 'null (serial 0)');
-- Same values in an untyped column and in several columns of one record.
CREATE TABLE multi(a, b, c, d, e, f, g, h);
INSERT INTO multi VALUES (0, 1, -1, 300, -70000, 3000000000, -300000000000000, 9000000000000000000);
INSERT INTO multi VALUES (1, 0, NULL, -300, 70000, -3000000000, 300000000000000, -9000000000000000000);
-- @phase engine
SELECT id, v, typeof(v), label FROM ints ORDER BY id;
SELECT count(*), count(v), min(v), max(v) FROM ints;
SELECT v FROM ints WHERE v < 0 ORDER BY v;
SELECT v + 1 FROM ints WHERE v = 2147483647;
SELECT v - 1 FROM ints WHERE v = -140737488355328;
SELECT label FROM ints WHERE v = 8388608;
SELECT sum(v) FROM ints WHERE v BETWEEN -1000000000000 AND 1000000000000;
-- abs() of the minimum 64-bit integer overflows.
SELECT abs(v) FROM ints WHERE v < -9223372036854775807;
SELECT hex(v) FROM ints WHERE id = 3;
SELECT * FROM multi ORDER BY a;
SELECT typeof(a), typeof(b), typeof(c), typeof(h) FROM multi ORDER BY a;
SELECT a + b + c + d + e FROM multi ORDER BY a;
