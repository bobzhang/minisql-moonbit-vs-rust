-- @db file
-- SQLite adds columns with defaults to a populated table, so the old rows
-- have short records. The engine then updates some of those rows, inserts
-- new ones, and builds an index on an added column: the index must hold
-- the DEFAULT value for rows whose record lacks the column (integrity_check
-- compares index entries with the table's values).
-- @phase sqlite
CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 3000)
INSERT INTO t SELECT i, 'a' || i FROM c;
ALTER TABLE t ADD COLUMN b INTEGER DEFAULT 42;
ALTER TABLE t ADD COLUMN c TEXT DEFAULT 'cee';
ALTER TABLE t ADD COLUMN d REAL;
-- @phase engine
CREATE INDEX t_b ON t(b);
CREATE INDEX t_c_d ON t(c, d);
UPDATE t SET b = 7 WHERE id % 10 = 0;
UPDATE t SET d = 1.5 WHERE id % 4 = 0;
INSERT INTO t(id, a) VALUES (3001, 'engine');
SELECT b, count(*) FROM t GROUP BY b ORDER BY b;
-- @phase sqlite
PRAGMA integrity_check;
SELECT b, count(*) FROM t INDEXED BY t_b GROUP BY b ORDER BY b;
SELECT count(*) FROM t INDEXED BY t_c_d WHERE c = 'cee' AND d IS NULL;
SELECT * FROM t WHERE id IN (1, 4, 10, 3001) ORDER BY id;
