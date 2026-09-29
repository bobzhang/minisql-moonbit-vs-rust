-- @db file
-- When a record overflows, the columns after a large value live on the
-- overflow pages, not on the b-tree page. Here small integers, reals and
-- text come after big blobs/text, so reading them requires following the
-- overflow chain. Also a record whose header itself is local but whose
-- whole body is in overflow, and big values in several columns of one row.
-- @phase sqlite
PRAGMA page_size = 512;
CREATE TABLE t(id INTEGER PRIMARY KEY, big BLOB, a INTEGER, b REAL, c TEXT, big2 TEXT, d INTEGER);
INSERT INTO t VALUES (1, zeroblob(100), 1, 1.5, 'one', 'x', 11);
INSERT INTO t VALUES (2, zeroblob(470), 2, 2.5, 'two', 'y', 22);
INSERT INTO t VALUES (3, zeroblob(2000), 3, 3.5, 'three', 'z', 33);
INSERT INTO t VALUES (4, zeroblob(5000), -4, -4.5, 'four', printf('%03000d', 4), 44);
INSERT INTO t VALUES (5, x'0102', 5, 5.5, printf('%0700d', 5), printf('%0900d', 55), 55);
INSERT INTO t VALUES (6, NULL, 6, NULL, NULL, NULL, 66);
INSERT INTO t VALUES (7, zeroblob(40000), 7000000000, 7.25, 'seven', printf('%0100d', 7), -77);
UPDATE t SET big = unhex('AB' || hex(zeroblob(length(big) - 2)) || 'CD') WHERE length(big) > 2;
-- @phase engine
SELECT id, a, b, c, d FROM t WHERE id <> 5 ORDER BY id;
SELECT id, length(big), hex(substr(big, 1, 1)), hex(substr(big, -1)) FROM t ORDER BY id;
SELECT id, length(c), length(big2), substr(big2, -3) FROM t ORDER BY id;
SELECT sum(a), sum(d), sum(b) FROM t;
SELECT id FROM t WHERE d > 40 ORDER BY d;
SELECT id, typeof(big), typeof(a), typeof(b), typeof(c), typeof(big2), typeof(d) FROM t ORDER BY id;
SELECT id FROM t WHERE c = printf('%0700d', 5);
SELECT count(*) FROM t WHERE big2 = printf('%03000d', 4);
