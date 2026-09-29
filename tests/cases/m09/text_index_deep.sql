-- @db file
-- An index on long-ish text keys (about 60 bytes) over 20000 rows gives an
-- index b-tree with several levels; integrity_check verifies the order of
-- keys across interior and leaf pages and that every row is indexed.
-- A second index is composite with a DESC column.
-- @phase engine
CREATE TABLE t(id INTEGER PRIMARY KEY, tag TEXT, grp INTEGER, val INTEGER);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 20000)
INSERT INTO t SELECT i, 'tag-' || printf('%08d', (i * 48271) % 20011) || '-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnop', i % 13, (i * 31) % 997 FROM c;
CREATE INDEX t_tag ON t(tag);
CREATE INDEX t_grp_val ON t(grp, val DESC);
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), count(DISTINCT tag) FROM t;
SELECT id FROM t INDEXED BY t_tag WHERE tag >= 'tag-00010000' AND tag < 'tag-00010010' ORDER BY tag;
SELECT count(*) FROM t INDEXED BY t_grp_val WHERE grp = 5 AND val BETWEEN 100 AND 200;
SELECT val FROM t INDEXED BY t_grp_val WHERE grp = 12 ORDER BY val DESC LIMIT 3;
-- SQLite adds rows to the engine-built index.
INSERT INTO t VALUES (20001, 'tag-00000000-first', 0, 0), (20002, 'zzz', 0, 0);
PRAGMA integrity_check;
-- @phase engine
SELECT id FROM t WHERE tag = 'tag-00000000-first';
SELECT id FROM t ORDER BY tag DESC LIMIT 2;
SELECT count(*) FROM t WHERE grp = 0;
