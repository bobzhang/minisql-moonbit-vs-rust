-- Rowid boundaries. The largest rowid is 9223372036854775807. Once a table
-- holds that rowid, new rows get some other unused rowid (chosen at random,
-- so this test only checks that the inserts succeed, not which rowid).
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO t VALUES (9223372036854775807, 'max');
SELECT id, typeof(id), v FROM t;
INSERT INTO t(v) VALUES ('second');
INSERT INTO t(v) VALUES ('third');
SELECT v FROM t ORDER BY v;
SELECT v FROM t WHERE id = 9223372036854775807;
SELECT v FROM t WHERE id > 0 AND id < 9223372036854775807 ORDER BY v;

-- The smallest rowid.
CREATE TABLE s(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO s VALUES (-9223372036854775808, 'min');
INSERT INTO s(v) VALUES ('next');
SELECT id, v FROM s ORDER BY id;

-- One past the maximum is a REAL, which is not a valid rowid.
INSERT INTO s VALUES (9223372036854775808, 'too big');
INSERT INTO s VALUES (-9223372036854775809, 'too small');
SELECT id, v FROM s ORDER BY id;

-- Text holding the max value is converted to an integer rowid.
CREATE TABLE r(v);
INSERT INTO r(rowid, v) VALUES ('9223372036854775807', 'text max');
SELECT rowid, typeof(rowid), v FROM r;
INSERT INTO r(v) VALUES ('after max');
SELECT v FROM r ORDER BY v;
-- Duplicate of the maximum is still a conflict.
INSERT INTO r(rowid, v) VALUES (9223372036854775807, 'dup');
SELECT v FROM r ORDER BY v;

-- Arithmetic near the boundary switches to REAL and cannot be a rowid.
INSERT INTO r(rowid, v) VALUES (9223372036854775807 + 1, 'overflow');
SELECT v FROM r ORDER BY v;
