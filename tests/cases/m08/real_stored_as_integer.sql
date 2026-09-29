-- @db file
-- SQLite stores integer-valued REALs in REAL-affinity columns using an
-- integer serial type to save space. Reading them back must still give
-- REAL values (typeof 'real', printed with '.0'). Columns without REAL
-- affinity keep real serial types; an INTEGER column stores 3.0 as 3.
-- @phase sqlite
CREATE TABLE r(id INTEGER PRIMARY KEY, x REAL, y DOUBLE, z FLOAT, n NUMERIC, i INTEGER, a);
INSERT INTO r VALUES (1, 3.0, 3.0, 3.0, 3.0, 3.0, 3.0);
INSERT INTO r VALUES (2, 0.0, -0.0, 1.0, 1.0, 1.0, 1.0);
INSERT INTO r VALUES (3, -7.0, 1e15, 100000.0, 2.5, 2.5, 2.5);
INSERT INTO r VALUES (4, 4, '5', '6.0', '7.0', '8.0', '9.0');
INSERT INTO r VALUES (5, 9007199254740992.0, -2147483648.0, 128.0, NULL, NULL, NULL);
INSERT INTO r VALUES (6, 0.5, 1.25, -3.75, 1e20, 1e20, 1e20);
CREATE INDEX r_x ON r(x);
-- @phase engine
SELECT id, x, typeof(x), y, typeof(y), z, typeof(z) FROM r ORDER BY id;
SELECT id, n, typeof(n), i, typeof(i), a, typeof(a) FROM r ORDER BY id;
SELECT id FROM r WHERE x = 3 ORDER BY id;
SELECT id, x FROM r WHERE x > 1 ORDER BY x;
SELECT sum(x), total(x), typeof(sum(x)) FROM r;
SELECT x / 2, y / 2 FROM r WHERE id = 1;
SELECT id FROM r ORDER BY x DESC, id;
SELECT max(x), min(x), typeof(max(x)) FROM r;
