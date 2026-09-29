-- LEFT JOIN ... WHERE right.col IS NULL finds left rows with no match.
CREATE TABLE users(uid INTEGER PRIMARY KEY, uname TEXT);
CREATE TABLE logins(uid INTEGER, day TEXT, note TEXT);
INSERT INTO users VALUES (1, 'ann'), (2, 'ben'), (3, 'cat'), (4, 'dov');
INSERT INTO logins VALUES (1, '2024-01-01', 'x'), (1, '2024-01-02', NULL), (3, '2024-01-05', 'y'), (7, '2024-01-01', 'z');

-- Users who never logged in.
SELECT uname FROM users LEFT JOIN logins ON logins.uid = users.uid WHERE logins.uid IS NULL ORDER BY uname;
-- Test on a nullable right column: a matched row whose note is NULL also passes,
-- so checking the join key (not an arbitrary column) matters.
SELECT uname, day FROM users LEFT JOIN logins ON logins.uid = users.uid WHERE logins.note IS NULL ORDER BY uname, day;
-- Users with no login in January 2nd or later.
SELECT uname FROM users LEFT JOIN logins ON logins.uid = users.uid AND day >= '2024-01-02'
  WHERE logins.uid IS NULL ORDER BY uname;
-- The same via NOT EXISTS / NOT IN.
SELECT uname FROM users WHERE NOT EXISTS (SELECT 1 FROM logins WHERE logins.uid = users.uid) ORDER BY uname;
SELECT uname FROM users WHERE uid NOT IN (SELECT uid FROM logins) ORDER BY uname;
-- Logins whose user does not exist (anti-join the other way).
SELECT logins.uid, day FROM logins LEFT JOIN users ON users.uid = logins.uid WHERE users.uid IS NULL ORDER BY day;
-- Count unmatched on each side.
SELECT count(*) FROM users LEFT JOIN logins USING (uid) WHERE day IS NULL;
SELECT count(*) FROM logins LEFT JOIN users USING (uid) WHERE uname IS NULL;
-- NOTNULL form keeps only matched rows (a semi-join with duplicates).
SELECT uname, count(*) FROM users LEFT JOIN logins ON logins.uid = users.uid WHERE logins.uid NOTNULL GROUP BY uname ORDER BY uname;
-- After deleting all logins every user is unmatched.
DELETE FROM logins;
SELECT uname FROM users LEFT JOIN logins ON logins.uid = users.uid WHERE logins.uid IS NULL ORDER BY users.uid;
