-- @db file
-- ALTER TABLE ADD COLUMN only changes the schema text: rows written before
-- it have records with fewer fields than the table has columns. Reading a
-- missing field yields the column's DEFAULT (or NULL). Rows inserted
-- afterwards have full records. Several ADD COLUMNs are layered.
-- @phase sqlite
PRAGMA page_size = 1024;
CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 1000)
INSERT INTO t SELECT i, 'a' || i FROM c;
ALTER TABLE t ADD COLUMN b INTEGER DEFAULT 7;
ALTER TABLE t ADD COLUMN c TEXT;
ALTER TABLE t ADD COLUMN d REAL DEFAULT -2.5;
ALTER TABLE t ADD COLUMN e TEXT DEFAULT 'dflt' COLLATE NOCASE;
INSERT INTO t VALUES (1001, 'new', 1, 'c', 1.5, 'E');
ALTER TABLE t ADD COLUMN f BLOB DEFAULT x'00FF';
ALTER TABLE t ADD COLUMN g DEFAULT (-3);
ALTER TABLE t ADD COLUMN h INTEGER NOT NULL DEFAULT 0;
UPDATE t SET b = 99 WHERE id = 500;
INSERT INTO t(id, a) VALUES (1002, 'newest');
-- @phase engine
SELECT * FROM t WHERE id IN (1, 500, 1000, 1001, 1002) ORDER BY id;
SELECT typeof(b), typeof(c), typeof(d), typeof(e), typeof(f), typeof(g), typeof(h) FROM t WHERE id = 2;
SELECT count(*), sum(b), sum(d), count(c), sum(g), sum(h) FROM t;
SELECT count(*) FROM t WHERE b = 7;
SELECT count(*) FROM t WHERE e = 'DFLT';
SELECT id FROM t WHERE c IS NOT NULL;
SELECT b, count(*) FROM t GROUP BY b ORDER BY b;
SELECT id, b + h, d * 2 FROM t WHERE id IN (3, 1001) ORDER BY id;
SELECT hex(f) FROM t WHERE id = 10;
