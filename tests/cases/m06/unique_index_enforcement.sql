-- A UNIQUE index rejects rows whose indexed value already exists. The failing
-- statement has no effect at all (statement atomicity).
CREATE TABLE users(id INTEGER PRIMARY KEY, email TEXT, nick TEXT);
CREATE UNIQUE INDEX users_email ON users(email);
INSERT INTO users VALUES (1, 'a@x', 'al'), (2, 'b@x', 'bo');

-- Duplicate on insert.
INSERT INTO users VALUES (3, 'a@x', 'cy');
SELECT count(*) FROM users;
-- Multi-row insert with one duplicate: nothing is inserted.
INSERT INTO users VALUES (3, 'c@x', 'cy'), (4, 'b@x', 'di');
SELECT count(*) FROM users;
-- Duplicates within the same statement.
INSERT INTO users VALUES (5, 'e@x', 'ed'), (6, 'e@x', 'ef');
SELECT id FROM users ORDER BY id;
-- Duplicate on update.
UPDATE users SET email = 'a@x' WHERE id = 2;
SELECT email FROM users WHERE id = 2;
-- Updating a row to its own value is fine.
UPDATE users SET email = 'a@x' WHERE id = 1;
-- Shifting every value of a unique column to a fresh range succeeds.
CREATE TABLE seq(n INTEGER);
CREATE UNIQUE INDEX seq_n ON seq(n);
INSERT INTO seq VALUES (1), (2), (3);
UPDATE seq SET n = n + 10;
SELECT n FROM seq ORDER BY n;
-- Values differing only in type: integer 1 and text '1' are distinct in an untyped column.
CREATE TABLE loose(v);
CREATE UNIQUE INDEX loose_v ON loose(v);
INSERT INTO loose VALUES (1), ('1'), (x'31');
INSERT INTO loose VALUES (1.0);
SELECT count(*) FROM loose;
-- Case matters with the default BINARY collation.
INSERT INTO users VALUES (7, 'A@X', 'up');
SELECT count(*) FROM users;
-- After deleting the conflicting row the value can be reused.
DELETE FROM users WHERE id = 7;
DELETE FROM users WHERE email = 'b@x';
INSERT INTO users VALUES (8, 'b@x', 'new');
SELECT id, email FROM users ORDER BY id;
-- Dropping the index removes the constraint.
DROP INDEX users_email;
INSERT INTO users VALUES (9, 'b@x', 'dup');
SELECT count(*) FROM users WHERE email = 'b@x';
