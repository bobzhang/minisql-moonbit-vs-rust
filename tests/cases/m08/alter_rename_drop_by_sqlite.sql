-- @db file
-- SQLite renames a table and a column and drops a column. RENAME rewrites
-- the stored CREATE text of the table, its indexes and the views that
-- reference it; DROP COLUMN rewrites every record. The engine reads the
-- resulting schema and data.
-- @phase sqlite
CREATE TABLE old_name(id INTEGER PRIMARY KEY, old_col TEXT UNIQUE, junk TEXT, keep INTEGER);
CREATE INDEX old_keep_idx ON old_name(keep);
CREATE VIEW v AS SELECT old_col, keep FROM old_name WHERE keep > 1;
INSERT INTO old_name VALUES (1, 'one', 'j1', 1), (2, 'two', 'j2', 2), (3, 'three', 'j3', 3);
ALTER TABLE old_name RENAME TO new_name;
ALTER TABLE new_name RENAME COLUMN old_col TO new_col;
ALTER TABLE new_name DROP COLUMN junk;
INSERT INTO new_name VALUES (4, 'four', 4);
-- @phase engine
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT * FROM new_name ORDER BY id;
SELECT id FROM new_name WHERE new_col = 'three';
SELECT id FROM new_name WHERE keep = 4;
SELECT * FROM v ORDER BY keep;
SELECT * FROM old_name;
SELECT old_col FROM new_name;
SELECT junk FROM new_name;
