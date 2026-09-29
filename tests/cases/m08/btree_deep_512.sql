-- @db file
-- Deep b-trees: 60000 rows with page_size=512 give a table b-tree with
-- several interior levels and an index on a 40-byte text key whose index
-- b-tree is 5+ levels deep (each interior index page holds only a few
-- keys). Every row must be found, in order, from both trees.
-- @phase sqlite
PRAGMA page_size = 512;
CREATE TABLE t(id INTEGER PRIMARY KEY, grp INTEGER, tag TEXT, val INTEGER);
CREATE INDEX t_tag ON t(tag);
CREATE INDEX t_grp_val ON t(grp, val);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 60000)
INSERT INTO t SELECT i, i % 97, 'tag-' || printf('%08d', (i * 48271) % 60001) || '-padding-padding-pad', (i * 31) % 1000 FROM c;
-- @phase engine
-- Full scans.
SELECT count(*), sum(grp), sum(val), min(id), max(id) FROM t;
SELECT count(DISTINCT tag), min(tag), max(tag) FROM t;
-- Point lookups by rowid at the edges and in the middle of the tree.
SELECT id, grp, tag, val FROM t WHERE id IN (1, 255, 256, 30000, 59999, 60000) ORDER BY id;
SELECT count(*) FROM t WHERE id > 60000;
SELECT count(*) FROM t WHERE id BETWEEN 12345 AND 23456;
-- Lookups through the deep text index.
SELECT id FROM t WHERE tag = 'tag-00000001-padding-padding-pad';
SELECT id FROM t WHERE tag = 'tag-00060000-padding-padding-pad';
SELECT id FROM t WHERE tag = 'tag-00030000-padding-padding-pad';
SELECT count(*) FROM t WHERE tag = 'tag-00000000-padding-padding-pad';
SELECT count(*) FROM t WHERE tag >= 'tag-00020000' AND tag < 'tag-00020100';
SELECT id, tag FROM t ORDER BY tag LIMIT 3;
SELECT id, tag FROM t ORDER BY tag DESC LIMIT 3;
-- Composite index (grp, val).
SELECT count(*), min(id), max(id) FROM t WHERE grp = 42 AND val BETWEEN 100 AND 300;
SELECT grp, count(*) FROM t WHERE grp < 3 GROUP BY grp ORDER BY grp;
SELECT id FROM t WHERE grp = 96 ORDER BY val DESC, id DESC LIMIT 4;
