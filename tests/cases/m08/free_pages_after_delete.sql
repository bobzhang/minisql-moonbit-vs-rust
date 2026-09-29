-- @db file
-- auto_vacuum=NONE: deleting most rows and dropping tables puts pages on
-- the freelist (trunk and leaf pages). Their stale contents must be
-- ignored; only b-tree pages reachable from sqlite_schema matter. Then new
-- data reuses some of the free pages.
-- @phase sqlite
PRAGMA page_size = 1024;
PRAGMA auto_vacuum = NONE;
CREATE TABLE keep(id INTEGER PRIMARY KEY, v TEXT);
CREATE TABLE doomed(id INTEGER PRIMARY KEY, v TEXT);
CREATE INDEX doomed_v ON doomed(v);
CREATE TABLE shrink(id INTEGER PRIMARY KEY, v TEXT, big TEXT);
CREATE INDEX shrink_v ON shrink(v);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 5000)
INSERT INTO keep SELECT i, 'keep' || i FROM c;
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 5000)
INSERT INTO doomed SELECT i, 'doomed' || i FROM c;
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 5000)
INSERT INTO shrink SELECT i, 'shrink' || i, CASE WHEN i % 100 = 0 THEN printf('%05000d', i) END FROM c;
DROP TABLE doomed;
DELETE FROM shrink WHERE id > 100 AND id < 4900;
DELETE FROM keep WHERE id % 10 <> 0;
CREATE TABLE later(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO later VALUES (1, 'reused pages'), (2, 'maybe');
-- @phase engine
SELECT type, name FROM sqlite_schema ORDER BY name;
SELECT count(*), min(id), max(id) FROM keep;
SELECT v FROM keep WHERE id IN (10, 2500, 5000) ORDER BY id;
SELECT count(*), sum(length(big)), count(big) FROM shrink;
SELECT id, v, length(big) FROM shrink WHERE big IS NOT NULL ORDER BY id;
SELECT id FROM shrink WHERE v = 'shrink4950';
SELECT count(*) FROM shrink WHERE v BETWEEN 'shrink1' AND 'shrink2';
SELECT * FROM later ORDER BY id;
SELECT * FROM doomed;
