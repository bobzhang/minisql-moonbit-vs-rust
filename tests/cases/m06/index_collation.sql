-- Collations and indexes: a UNIQUE index uses the collation of the column
-- (or the one given in the index definition) to decide what is a duplicate,
-- and lookups must return the same rows with or without indexes.
CREATE TABLE users(name TEXT);
CREATE UNIQUE INDEX users_name_ci ON users(name COLLATE NOCASE);
INSERT INTO users VALUES ('Alice');
INSERT INTO users VALUES ('ALICE');
INSERT INTO users VALUES ('alice ');
SELECT name FROM users ORDER BY name;
-- A column declared NOCASE makes a plain unique index case-insensitive.
CREATE TABLE tags(t TEXT COLLATE NOCASE);
CREATE UNIQUE INDEX tags_t ON tags(t);
INSERT INTO tags VALUES ('Red');
INSERT INTO tags VALUES ('RED');
-- ...unless the index overrides it with BINARY.
CREATE TABLE tags2(t TEXT COLLATE NOCASE);
CREATE UNIQUE INDEX tags2_t ON tags2(t COLLATE BINARY);
INSERT INTO tags2 VALUES ('Red'), ('RED');
SELECT count(*) FROM tags2;
-- Lookups on a NOCASE column find all case variants.
SELECT t FROM tags2 WHERE t = 'red' ORDER BY t;
SELECT t FROM tags2 WHERE t = 'red' COLLATE BINARY;
-- RTRIM unique index: trailing spaces are ignored.
CREATE TABLE codes(c TEXT);
CREATE UNIQUE INDEX codes_rtrim ON codes(c COLLATE RTRIM);
INSERT INTO codes VALUES ('ab');
INSERT INTO codes VALUES ('ab  ');
INSERT INTO codes VALUES (' ab');
SELECT '[' || c || ']' FROM codes ORDER BY c;
-- A non-unique NOCASE index and range queries on a BINARY column.
CREATE TABLE words(w TEXT);
INSERT INTO words VALUES ('apple'), ('Banana'), ('cherry'), ('Apple'), ('banana');
CREATE INDEX words_ci ON words(w COLLATE NOCASE);
SELECT w FROM words WHERE w >= 'b' ORDER BY w;
SELECT w FROM words WHERE w >= 'b' COLLATE NOCASE ORDER BY w COLLATE NOCASE, w;
SELECT w FROM words ORDER BY w COLLATE NOCASE, w DESC;
SELECT w FROM words WHERE w = 'APPLE' COLLATE NOCASE ORDER BY w;
SELECT count(*) FROM words WHERE w = 'APPLE';
-- Creating a NOCASE unique index over data with case-duplicates fails.
CREATE UNIQUE INDEX words_ci_u ON words(w COLLATE NOCASE);
SELECT count(*) FROM sqlite_schema WHERE name = 'words_ci_u';
