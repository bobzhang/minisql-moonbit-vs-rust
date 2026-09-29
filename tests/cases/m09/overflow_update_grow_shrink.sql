-- @db file
-- The engine repeatedly grows and shrinks values so rows move between
-- fitting on the page and needing overflow chains; old overflow pages must
-- be freed or reused (integrity_check reports leaked or doubly used pages).
-- @phase engine
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT, note TEXT);
CREATE INDEX t_v ON t(v);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 200)
INSERT INTO t SELECT i, printf('%.*c', 10 + i, 'a'), 'row' || i FROM c;
UPDATE t SET v = printf('%.*c', 20000 + id * 10, 'b') WHERE id % 2 = 0;
UPDATE t SET v = printf('%.*c', 5, 'c') || id WHERE id % 4 = 0;
UPDATE t SET v = printf('%.*c', 70000, 'd') || id WHERE id % 10 = 1;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), sum(length(v)), max(length(v)), min(length(v)) FROM t;
SELECT id, length(v), substr(v, 1, 3), substr(v, -3) FROM t WHERE id IN (1, 2, 3, 4, 11, 200) ORDER BY id;
-- @phase engine
UPDATE t SET v = 'short' || id WHERE length(v) > 1000;
SELECT count(*), sum(length(v)), max(length(v)) FROM t;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), sum(length(v)), max(length(v)) FROM t;
SELECT id, v FROM t INDEXED BY t_v WHERE v = 'short11';
-- @phase engine
UPDATE t SET note = printf('%.*c', 9000, 'n') WHERE id <= 50;
DELETE FROM t WHERE id > 150;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), sum(length(note)), sum(length(v)) FROM t;
