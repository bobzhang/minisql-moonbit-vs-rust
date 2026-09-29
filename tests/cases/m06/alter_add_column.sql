-- ALTER TABLE t ADD [COLUMN] def: existing rows get the column's default (or
-- NULL); the new column is last in * order; later inserts use it normally.
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO t VALUES (1, 'a'), (2, 'b');

ALTER TABLE t ADD COLUMN score INTEGER;
SELECT * FROM t ORDER BY id;
SELECT id, typeof(score) FROM t ORDER BY id;
-- COLUMN keyword is optional; defaults fill existing rows.
ALTER TABLE t ADD flag INTEGER DEFAULT 1;
ALTER TABLE t ADD COLUMN label TEXT DEFAULT 'none';
ALTER TABLE t ADD COLUMN ratio REAL DEFAULT -2.5;
ALTER TABLE t ADD COLUMN raw BLOB DEFAULT x'00ff';
SELECT * FROM t ORDER BY id;
-- New rows can set the new columns or take their defaults.
INSERT INTO t(id, name, score) VALUES (3, 'c', 30);
INSERT INTO t VALUES (4, 'd', 40, 0, 'set', 1.0, NULL);
SELECT * FROM t ORDER BY id;
-- The declared type applies affinity to new values.
INSERT INTO t(id, name, score) VALUES (5, 'e', '55');
SELECT score, typeof(score) FROM t WHERE id = 5;
-- Updating the new column in old rows.
UPDATE t SET score = id * 100 WHERE score IS NULL;
SELECT id, score FROM t ORDER BY id;
-- NOT NULL is allowed when there is a non-NULL default.
ALTER TABLE t ADD COLUMN must TEXT NOT NULL DEFAULT 'm';
SELECT DISTINCT must FROM t;
INSERT INTO t(id, name, must) VALUES (6, 'f', NULL);
-- CHECK constraints, COLLATE and REFERENCES are allowed on added columns.
ALTER TABLE t ADD COLUMN pos INTEGER CHECK (pos >= 0);
ALTER TABLE t ADD COLUMN tag TEXT COLLATE NOCASE;
ALTER TABLE t ADD COLUMN parent INTEGER REFERENCES t(id);
INSERT INTO t(id, name, pos) VALUES (7, 'g', -1);
UPDATE t SET tag = 'Hello' WHERE id = 1;
SELECT id FROM t WHERE tag = 'HELLO';
-- Indexing an added column.
CREATE INDEX t_label ON t(label);
SELECT id FROM t WHERE label = 'none' ORDER BY id;
-- Add a column to an empty table.
CREATE TABLE e(a);
ALTER TABLE e ADD COLUMN b DEFAULT 'bee';
INSERT INTO e(a) VALUES (1);
SELECT * FROM e;
