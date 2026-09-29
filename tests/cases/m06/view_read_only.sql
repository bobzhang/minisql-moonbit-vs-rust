-- Views are read-only: INSERT, UPDATE, DELETE, REPLACE and upsert on a view
-- are errors and change nothing. Other table-only operations fail too.
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO t VALUES (1, 'a'), (2, 'b');
CREATE VIEW tv AS SELECT id, v FROM t;

INSERT INTO tv VALUES (3, 'c');
UPDATE tv SET v = 'z' WHERE id = 1;
DELETE FROM tv;
REPLACE INTO tv VALUES (1, 'q');
INSERT OR IGNORE INTO tv VALUES (5, 'e');
-- The base table is untouched.
SELECT id, v FROM t ORDER BY id;
SELECT id, v FROM tv ORDER BY id;
-- Views cannot be indexed, altered, or dropped with DROP TABLE.
CREATE INDEX tv_v ON tv(v);
ALTER TABLE tv ADD COLUMN w;
DROP TABLE tv;
-- A table cannot be dropped with DROP VIEW.
DROP VIEW t;
-- Writing to the base table is still allowed and visible through the view.
INSERT INTO t VALUES (3, 'c');
UPDATE t SET v = upper(v) WHERE id = 1;
DELETE FROM t WHERE id = 2;
SELECT id, v FROM tv ORDER BY id;
-- A view can feed INSERT ... SELECT into a real table.
CREATE TABLE copy(id INTEGER, v TEXT);
INSERT INTO copy SELECT * FROM tv WHERE id > 1;
SELECT id, v FROM copy;
-- Both objects still exist.
SELECT type, name FROM sqlite_schema ORDER BY name;
-- DML statements on views inside other statements' subqueries are fine (reads only).
UPDATE t SET v = (SELECT max(v) FROM tv) WHERE id = 3;
SELECT id, v FROM t ORDER BY id;
DELETE FROM t WHERE id IN (SELECT id FROM tv WHERE v = 'A');
SELECT count(*) FROM tv;
-- The view keeps working after all the failed writes.
SELECT count(*), min(id), max(id) FROM tv;
SELECT v FROM tv WHERE id = 3;
INSERT INTO t VALUES (4, 'd'), (5, 'e');
SELECT group_concat(v, ',') FROM (SELECT v FROM tv ORDER BY id);
UPDATE t SET v = 'x' WHERE id IN (SELECT id FROM tv WHERE id > 3);
SELECT id, v FROM tv WHERE v = 'x' ORDER BY id;
SELECT count(*) FROM tv JOIN copy USING (id);
SELECT id FROM tv EXCEPT SELECT id FROM copy ORDER BY id;
SELECT type, name FROM sqlite_schema WHERE type = 'view';
SELECT max(v) FROM tv;
SELECT id FROM tv WHERE id NOT IN (SELECT id FROM copy) ORDER BY id;
