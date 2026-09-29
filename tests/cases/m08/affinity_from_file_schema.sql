-- @db file
-- Column affinity comes from the declared type in the stored CREATE text.
-- The values in the file were stored by SQLite after applying affinity;
-- comparisons in the engine must apply the same affinity rules
-- (e.g. a TEXT column compared with an integer literal).
-- @phase sqlite
CREATE TABLE a(i INT, t VARCHAR(10), b BLOB, r FLOAT, n DECIMAL(5,2), none_ty, s STRING, ch CHARINT);
INSERT INTO a VALUES ('10', 10, '10', '10', '10', '10', '10', '10');
INSERT INTO a VALUES ('1e3', 1e3, 1e3, '1e3', '1e3', '1e3', '1e3', '1e3');
INSERT INTO a VALUES (' 7 ', 7.5, x'37', '7.5', '7.50', 7.5, '  7', 'abc');
INSERT INTO a VALUES ('0x10', '0x10', 16, '-0', '9223372036854775808', 'x', '1.0', '12.0');
-- @phase engine
SELECT typeof(i), typeof(t), typeof(b), typeof(r), typeof(n), typeof(none_ty), typeof(s), typeof(ch) FROM a ORDER BY rowid;
SELECT i, t, b, r, n, none_ty, s, ch FROM a ORDER BY rowid;
SELECT rowid FROM a WHERE t = 10;
SELECT rowid FROM a WHERE t = '10';
SELECT rowid FROM a WHERE none_ty = 10;
SELECT rowid FROM a WHERE i = '10';
SELECT rowid FROM a WHERE r < 100 ORDER BY rowid;
SELECT rowid FROM a WHERE n > 5 ORDER BY rowid;
SELECT rowid FROM a WHERE s = 1 ORDER BY rowid;
SELECT rowid, ch + 1 FROM a ORDER BY rowid;
SELECT rowid FROM a ORDER BY t, rowid;
