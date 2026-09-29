-- @db file
-- Serial types for REAL (7), TEXT (odd >= 13) and BLOB (even >= 12):
-- empty text and blob, one-byte values, lengths whose serial type needs a
-- multi-byte varint (text length >= 58, blob length >= 58), and reals of
-- many magnitudes. NULLs in every position of a record.
-- @phase sqlite
CREATE TABLE v(id INTEGER PRIMARY KEY, t TEXT, b BLOB, r REAL, anyv);
INSERT INTO v VALUES
  (1, '', x'', 0.5, NULL),
  (2, 'a', x'00', -0.5, ''),
  (3, 'hello world', x'DEADBEEF', 3.141592653589793, x''),
  (4, NULL, NULL, NULL, NULL),
  (5, printf('%057d', 5), zeroblob(57), 1.0e-300, 2.5),
  (6, printf('%058d', 6), zeroblob(58), 1.7976931348623157e308, -2.5),
  (7, printf('%059d', 7), x'0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F303132333435363738393A3B', -123456.789, 'text'),
  (8, printf('%0200d', 8), zeroblob(200), 5.0e-324, x'FF'),
  (9, 'tab	and ''quote''', x'27', 1e15, 123),
  (10, 'x', x'78', -1e-5, 0.1);
-- @phase engine
SELECT id, typeof(t), typeof(b), typeof(r), typeof(anyv) FROM v ORDER BY id;
SELECT id, length(t), length(b) FROM v ORDER BY id;
SELECT id, t, hex(b), r, anyv FROM v WHERE id IN (1, 2, 3, 4, 9, 10) ORDER BY id;
SELECT id, r FROM v ORDER BY r, id;
SELECT id, substr(t, -3), hex(substr(b, -3)) FROM v WHERE id BETWEEN 5 AND 8 ORDER BY id;
SELECT hex(b) FROM v WHERE id = 7;
SELECT id FROM v WHERE t = '' AND b = x'';
SELECT id, anyv FROM v ORDER BY anyv, id;
SELECT count(*) FROM v WHERE b = zeroblob(58);
SELECT id, r * 2 FROM v WHERE r BETWEEN -1 AND 1 ORDER BY id;
