-- A partial UNIQUE index enforces uniqueness only among rows that satisfy its
-- WHERE clause; rows outside the predicate never conflict.
CREATE TABLE acct(id INTEGER PRIMARY KEY, username TEXT, active INTEGER);
CREATE UNIQUE INDEX acct_active_user ON acct(username) WHERE active = 1;
INSERT INTO acct VALUES (1, 'kim', 1), (2, 'kim', 0), (3, 'kim', 0);
-- A second active 'kim' conflicts.
INSERT INTO acct VALUES (4, 'kim', 1);
-- Inactive duplicates are fine.
INSERT INTO acct VALUES (4, 'kim', 0), (5, 'lee', 1);
SELECT id, username, active FROM acct ORDER BY id;
-- Activating a duplicate through UPDATE conflicts.
UPDATE acct SET active = 1 WHERE id = 2;
-- Deactivate the old one first, then activate another.
UPDATE acct SET active = 0 WHERE id = 1;
UPDATE acct SET active = 1 WHERE id = 2;
SELECT id FROM acct WHERE username = 'kim' AND active = 1;
-- NULL in the predicate column means "not in the index".
INSERT INTO acct VALUES (6, 'lee', NULL), (7, 'lee', NULL);
SELECT count(*) FROM acct WHERE username = 'lee';
-- OR REPLACE only replaces rows that are inside the index.
INSERT OR REPLACE INTO acct VALUES (8, 'kim', 1);
SELECT id, username, active FROM acct WHERE username = 'kim' ORDER BY id;
-- OR IGNORE likewise.
INSERT OR IGNORE INTO acct VALUES (9, 'lee', 1), (10, 'lee', 0);
SELECT id FROM acct WHERE username = 'lee' ORDER BY id;
-- Upsert without a conflict target covers the partial unique index too.
INSERT INTO acct VALUES (11, 'lee', 1) ON CONFLICT DO NOTHING;
INSERT INTO acct VALUES (12, 'lee', 0) ON CONFLICT DO NOTHING;
SELECT id, active FROM acct WHERE username = 'lee' ORDER BY id;
-- Creating a partial unique index fails if existing rows inside the predicate collide.
CREATE TABLE tags(name TEXT, pinned INTEGER);
INSERT INTO tags VALUES ('x', 1), ('x', 1), ('y', 0), ('y', 0);
CREATE UNIQUE INDEX tags_pinned ON tags(name) WHERE pinned = 1;
CREATE UNIQUE INDEX tags_unpinned ON tags(name) WHERE pinned = 0 AND name <> 'y';
INSERT INTO tags VALUES ('z', 0), ('y', 0);
INSERT INTO tags VALUES ('z', 0);
SELECT name, count(*) FROM tags GROUP BY name ORDER BY name;
