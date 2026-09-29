-- @db file
-- Emptying tables completely (DELETE with and without WHERE) and filling
-- them again, within one engine process and across processes.
-- @phase engine
CREATE TABLE a(id INTEGER PRIMARY KEY, v TEXT);
CREATE INDEX a_v ON a(v);
CREATE TABLE b(x INTEGER, y TEXT UNIQUE);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 5000)
INSERT INTO a SELECT i, 'v' || i FROM c;
INSERT INTO b SELECT id, v FROM a;
DELETE FROM a;
DELETE FROM b WHERE x > 0;
INSERT INTO a VALUES (1, 'again');
-- @phase sqlite
PRAGMA integrity_check;
SELECT * FROM a;
SELECT count(*) FROM b;
-- @phase engine
INSERT INTO b VALUES (1, 'one'), (2, 'two');
DELETE FROM a;
SELECT count(*) FROM a;
SELECT * FROM b ORDER BY x;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*) FROM a;
SELECT * FROM b ORDER BY x;
INSERT INTO a(v) VALUES ('from sqlite');
SELECT id, v FROM a;
