-- @db file
-- Several engine processes in a row, each building on what the previous one
-- committed (data and schema), before SQLite checks the final file.
-- @phase engine
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT, n INTEGER);
INSERT INTO t VALUES (1, 'first', 10);
-- @phase engine
SELECT * FROM t;
CREATE INDEX t_n ON t(n);
WITH RECURSIVE c(i) AS (SELECT 2 UNION ALL SELECT i + 1 FROM c WHERE i < 3000)
INSERT INTO t SELECT i, 'row' || i, i * 10 FROM c;
CREATE TABLE u(k TEXT PRIMARY KEY, t_id INTEGER);
INSERT INTO u VALUES ('x', 1), ('y', 2);
-- @phase engine
SELECT count(*), sum(n) FROM t;
SELECT * FROM u ORDER BY k;
UPDATE t SET v = upper(v) WHERE id % 1000 = 0;
DELETE FROM t WHERE id BETWEEN 100 AND 199;
CREATE VIEW tu AS SELECT u.k, t.v FROM u JOIN t ON t.id = u.t_id;
-- @phase engine
SELECT count(*), sum(n) FROM t;
SELECT v FROM t WHERE id IN (1000, 2000, 3000) ORDER BY id;
SELECT * FROM tu ORDER BY k;
DROP TABLE u;
ALTER TABLE t ADD COLUMN extra TEXT DEFAULT 'e';
-- @phase engine
SELECT type, name FROM sqlite_schema ORDER BY name;
SELECT id, v, n, extra FROM t WHERE id <= 2 ORDER BY id;
SELECT * FROM tu;
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT count(*), sum(n), count(extra) FROM t;
SELECT id FROM t INDEXED BY t_n WHERE n = 29990;
SELECT v FROM t WHERE id IN (1000, 2000, 3000) ORDER BY id;
