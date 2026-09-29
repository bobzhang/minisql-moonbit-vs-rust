-- @db file
-- REAL-affinity columns may be stored with an integer serial type when the
-- value is a whole number (SQLite does this to save space); either way the
-- value must read back as REAL. NUMERIC/INTEGER affinity must convert text
-- as SQLite does. This checks the engine writes values SQLite reads
-- identically, and that the engine reads SQLite's compact form.
-- @phase engine
CREATE TABLE r(id INTEGER PRIMARY KEY, x REAL, n NUMERIC, i INTEGER, t TEXT, a);
CREATE INDEX r_x ON r(x);
INSERT INTO r VALUES (1, 3, '3.0', '3.0', 3.0, 3.0);
INSERT INTO r VALUES (2, '4', '4.5', '4.5', 4.5, '4');
INSERT INTO r VALUES (3, 1e15, '1e3', ' 12 ', 12, x'31');
INSERT INTO r VALUES (4, -0.0, 'abc', 'abc', NULL, -0.0);
INSERT INTO r VALUES (5, 9007199254740993, '9223372036854775807', 1e20, 1e20, 0.1);
-- @phase sqlite
PRAGMA integrity_check;
SELECT id, x, typeof(x), n, typeof(n), i, typeof(i), t, typeof(t), a, typeof(a) FROM r ORDER BY id;
SELECT id FROM r INDEXED BY r_x WHERE x = 3;
INSERT INTO r VALUES (6, 7, 7, 7, 7, 7);
-- @phase engine
SELECT id, x, typeof(x) FROM r ORDER BY x, id;
SELECT sum(x), typeof(sum(x)) FROM r WHERE id IN (1, 6);
