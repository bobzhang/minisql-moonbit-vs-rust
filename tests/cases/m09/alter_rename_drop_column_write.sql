-- @db file
-- ALTER TABLE RENAME COLUMN and DROP COLUMN by the engine. After RENAME
-- COLUMN the table, index and view definitions must use the new name.
-- After DROP COLUMN every record must match the new column list (SQLite
-- reads fields by position).
-- @phase engine
CREATE TABLE t(id INTEGER PRIMARY KEY, first TEXT, junk TEXT, amount INTEGER, last TEXT);
CREATE INDEX t_amount ON t(amount);
CREATE VIEW tv AS SELECT first, amount FROM t WHERE amount >= 20;
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 1000)
INSERT INTO t SELECT i, 'f' || i, printf('%.*c', i % 50, 'j'), i * 10, 'l' || i FROM c;
ALTER TABLE t RENAME COLUMN amount TO total;
ALTER TABLE t RENAME first TO given;
ALTER TABLE t DROP COLUMN junk;
INSERT INTO t VALUES (1001, 'given', 5, 'last');
ALTER TABLE t DROP COLUMN total;
ALTER TABLE t DROP COLUMN nosuch;
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT * FROM t WHERE id IN (1, 2, 1000, 1001) ORDER BY id;
SELECT count(*) FROM t;
SELECT * FROM tv ORDER BY given LIMIT 5;
-- @phase engine
CREATE TABLE u(id INTEGER PRIMARY KEY, a TEXT, b INTEGER, c TEXT);
CREATE INDEX u_b ON u(b);
INSERT INTO u VALUES (1, 'a1', 10, 'c1'), (2, 'a2', 20, 'c2');
ALTER TABLE u RENAME COLUMN b TO bee;
ALTER TABLE u DROP COLUMN a;
-- @phase sqlite
PRAGMA integrity_check;
SELECT * FROM u ORDER BY id;
SELECT id FROM u INDEXED BY u_b WHERE bee = 20;
