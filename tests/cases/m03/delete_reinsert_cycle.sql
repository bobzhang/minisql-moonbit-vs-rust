-- Interleaved DELETE/INSERT/UPDATE: table contents and rowid allocation
-- stay consistent.
CREATE TABLE q(id INTEGER PRIMARY KEY, job TEXT, state TEXT DEFAULT 'queued');
INSERT INTO q(job) VALUES ('a'), ('b'), ('c'), ('d');
UPDATE q SET state = 'done' WHERE id <= 2;
DELETE FROM q WHERE state = 'done';
INSERT INTO q(job) VALUES ('e');
SELECT id, job, state FROM q ORDER BY id;

-- Delete everything except the top row; new rows continue after it.
DELETE FROM q WHERE id < 5;
INSERT INTO q(job) VALUES ('f'), ('g');
SELECT id, job, state FROM q ORDER BY id;

-- Delete the top rows; ids are reused.
DELETE FROM q WHERE id >= 6;
INSERT INTO q(job) VALUES ('h');
SELECT id, job, state FROM q ORDER BY id;

-- Reinsert a row with an old id explicitly.
INSERT INTO q(id, job) VALUES (1, 'old one');
SELECT id, job, state FROM q ORDER BY id;

-- Delete and reinsert the same values: UNIQUE allows it after the delete.
CREATE TABLE u(k TEXT UNIQUE, v INTEGER);
INSERT INTO u VALUES ('x', 1), ('y', 2);
DELETE FROM u WHERE k = 'x';
INSERT INTO u VALUES ('x', 3);
SELECT rowid, k, v FROM u ORDER BY rowid;

-- Delete all then insert: rowids start at 1 again (no AUTOINCREMENT).
DELETE FROM u;
INSERT INTO u VALUES ('z', 4);
SELECT rowid, k, v FROM u;

-- DELETE with a WHERE that depends on values changed by an earlier UPDATE.
CREATE TABLE w(n INTEGER);
INSERT INTO w VALUES (1), (2), (3), (4), (5), (6);
UPDATE w SET n = n * 10 WHERE n % 2 = 0;
DELETE FROM w WHERE n > 10;
SELECT rowid, n FROM w ORDER BY rowid;
INSERT INTO w SELECT n + 100 FROM w ORDER BY rowid;
SELECT rowid, n FROM w ORDER BY rowid;
DELETE FROM w WHERE rowid > 5;
SELECT rowid, n FROM w ORDER BY rowid;
