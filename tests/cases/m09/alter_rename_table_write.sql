-- @db file
-- ALTER TABLE RENAME TO by the engine. SQLite requires the schema to stay
-- consistent: the table row's name and tbl_name change, indexes get the
-- new tbl_name and their CREATE text refers to the new name, autoindexes
-- are renamed to sqlite_autoindex_<new>_N, and views that referenced the
-- old name are rewritten. Otherwise SQLite reports a malformed schema.
-- @phase engine
CREATE TABLE old_t(id INTEGER PRIMARY KEY, code TEXT UNIQUE, v INTEGER);
CREATE INDEX old_t_v ON old_t(v);
CREATE VIEW old_view AS SELECT code, v FROM old_t WHERE v > 1;
INSERT INTO old_t VALUES (1, 'a', 1), (2, 'b', 2), (3, 'c', 3);
ALTER TABLE old_t RENAME TO new_t;
INSERT INTO new_t VALUES (4, 'd', 4);
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT * FROM new_t ORDER BY id;
SELECT * FROM old_view ORDER BY v;
SELECT id FROM new_t INDEXED BY sqlite_autoindex_new_t_1 WHERE code = 'c';
SELECT id FROM new_t INDEXED BY old_t_v WHERE v = 4;
INSERT INTO new_t VALUES (5, 'a', 5);
SELECT * FROM old_t;
-- @phase engine
ALTER TABLE new_t RENAME TO "Final Name";
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT * FROM "Final Name" ORDER BY id;
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT count(*) FROM old_view;
INSERT INTO "Final Name" VALUES (6, 'f', 6);
SELECT code FROM "Final Name" INDEXED BY "sqlite_autoindex_Final Name_1" WHERE code = 'f';
