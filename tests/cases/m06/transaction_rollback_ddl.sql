-- ROLLBACK undoes schema changes as well as data changes: CREATE/DROP TABLE,
-- CREATE/DROP INDEX, CREATE/DROP VIEW and every ALTER TABLE form.
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, extra TEXT);
INSERT INTO t VALUES (1, 'a', 'e1'), (2, 'b', 'e2');
CREATE INDEX t_name ON t(name);
CREATE VIEW tv AS SELECT id, name FROM t;

-- CREATE TABLE and its rows vanish.
BEGIN;
CREATE TABLE fresh(x);
INSERT INTO fresh VALUES (1);
SELECT * FROM fresh;
ROLLBACK;
SELECT * FROM fresh;
-- DROP TABLE is undone, with its data, indexes and dependent views working again.
BEGIN;
DROP TABLE t;
SELECT * FROM tv;
ROLLBACK;
SELECT * FROM tv ORDER BY id;
SELECT id FROM t WHERE name = 'b';
-- Index creation and deletion are undone.
BEGIN;
DROP INDEX t_name;
CREATE UNIQUE INDEX t_extra ON t(extra);
ROLLBACK;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
INSERT INTO t VALUES (3, 'c', 'e1');
-- Views.
BEGIN;
DROP VIEW tv;
CREATE VIEW tv2 AS SELECT 1;
ROLLBACK;
SELECT count(*) FROM tv;
SELECT * FROM tv2;
-- ALTER TABLE RENAME TO.
BEGIN;
ALTER TABLE t RENAME TO t_renamed;
SELECT count(*) FROM t_renamed;
ROLLBACK;
SELECT count(*) FROM t;
SELECT count(*) FROM t_renamed;
-- ALTER TABLE RENAME COLUMN / ADD COLUMN / DROP COLUMN.
BEGIN;
ALTER TABLE t RENAME COLUMN name TO nm;
ALTER TABLE t ADD COLUMN added INTEGER DEFAULT 9;
ALTER TABLE t DROP COLUMN extra;
SELECT * FROM t ORDER BY id;
ROLLBACK;
SELECT * FROM t ORDER BY id;
-- Mixed DDL and DML, then COMMIT keeps everything.
BEGIN;
ALTER TABLE t ADD COLUMN flag INTEGER DEFAULT 0;
UPDATE t SET flag = 1 WHERE id = 2;
CREATE INDEX t_flag ON t(flag);
COMMIT;
SELECT id, flag FROM t ORDER BY id;
SELECT name FROM sqlite_schema WHERE type = 'index' ORDER BY name;
