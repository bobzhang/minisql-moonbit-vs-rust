-- @db file
-- ALTER TABLE ADD COLUMN by the engine: SQLite must see the new column
-- with its DEFAULT for rows written before the change, whether the engine
-- rewrites old records or leaves them short.
-- @phase engine
CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 2000)
INSERT INTO t SELECT i, 'a' || i FROM c;
ALTER TABLE t ADD COLUMN b INTEGER DEFAULT 7;
ALTER TABLE t ADD c TEXT;
ALTER TABLE t ADD COLUMN d REAL DEFAULT -2.5;
ALTER TABLE t ADD COLUMN e TEXT DEFAULT 'dflt' COLLATE NOCASE;
INSERT INTO t VALUES (2001, 'new', 1, 'c', 1.5, 'E');
ALTER TABLE t ADD COLUMN f BLOB DEFAULT x'00FF';
ALTER TABLE t ADD COLUMN g INTEGER NOT NULL DEFAULT 0;
INSERT INTO t(id, a) VALUES (2002, 'newest');
ALTER TABLE t ADD COLUMN a TEXT;
ALTER TABLE t ADD COLUMN h INTEGER PRIMARY KEY;
-- @phase sqlite
PRAGMA integrity_check;
SELECT * FROM t WHERE id IN (1, 2000, 2001, 2002) ORDER BY id;
SELECT count(*), sum(b), sum(d), count(c), sum(g) FROM t;
SELECT count(*) FROM t WHERE e = 'DFLT';
INSERT INTO t(id, a) VALUES (2003, 'by sqlite');
SELECT * FROM t WHERE id = 2003;
-- @phase engine
SELECT * FROM t WHERE id IN (1, 2003) ORDER BY id;
CREATE INDEX t_b ON t(b);
UPDATE t SET b = 8 WHERE id % 2 = 0;
-- @phase sqlite
PRAGMA integrity_check;
SELECT b, count(*) FROM t INDEXED BY t_b GROUP BY b ORDER BY b;
