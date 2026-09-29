-- ALTER TABLE t RENAME TO u: the table keeps its rows, columns, constraints
-- and indexes under the new name; the old name disappears.
CREATE TABLE old_t(id INTEGER PRIMARY KEY, name TEXT NOT NULL, code TEXT UNIQUE);
CREATE INDEX old_t_name ON old_t(name);
INSERT INTO old_t VALUES (1, 'a', 'x1'), (2, 'b', 'x2');

ALTER TABLE old_t RENAME TO new_t;
SELECT * FROM new_t ORDER BY id;
SELECT * FROM old_t;
-- Indexes keep their names but now belong to the new table.
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
-- Constraints still apply.
INSERT INTO new_t VALUES (3, NULL, 'x3');
INSERT INTO new_t VALUES (3, 'c', 'x1');
INSERT INTO new_t VALUES (3, 'c', 'x3');
SELECT id FROM new_t WHERE name = 'c';
-- rowid assignment continues after the existing max.
INSERT INTO new_t(name, code) VALUES ('d', 'x4');
SELECT id, name FROM new_t ORDER BY id DESC LIMIT 1;
-- The old name is free again.
CREATE TABLE old_t(z);
INSERT INTO old_t VALUES ('fresh');
SELECT * FROM old_t;
-- Renaming to a name already in use fails (tables, views and indexes share names).
ALTER TABLE new_t RENAME TO old_t;
ALTER TABLE new_t RENAME TO old_t_name;
ALTER TABLE new_t RENAME TO New_T;
-- Renaming a missing table fails.
ALTER TABLE nosuch RENAME TO other;
-- Quoted and mixed-case new names.
ALTER TABLE new_t RENAME TO "Spaced Name";
SELECT count(*) FROM "Spaced Name";
SELECT count(*) FROM [spaced name];
ALTER TABLE "Spaced Name" RENAME TO plain;
SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name;
-- Renaming back and forth preserves the data.
ALTER TABLE plain RENAME TO tmp;
ALTER TABLE tmp RENAME TO plain;
SELECT id, name, code FROM plain ORDER BY id;
