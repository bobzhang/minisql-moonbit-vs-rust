-- With AUTOINCREMENT, once the largest possible id (9223372036854775807)
-- has been used, allocating a new id fails with SQLITE_FULL, even after the
-- row is deleted. Explicit ids still work.
CREATE TABLE a(id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT);
INSERT INTO a VALUES (9223372036854775806, 'almost');
INSERT INTO a(v) VALUES ('max');
SELECT id, v FROM a ORDER BY id;
-- No more automatic ids.
INSERT INTO a(v) VALUES ('fails');
SELECT id, v FROM a ORDER BY id;
DELETE FROM a WHERE v = 'max';
INSERT INTO a(v) VALUES ('still fails');
SELECT id, v FROM a ORDER BY id;
-- Explicit ids are fine.
INSERT INTO a VALUES (1, 'explicit one');
INSERT INTO a VALUES (9223372036854775807, 'explicit max');
SELECT id, v FROM a ORDER BY id;
-- A multi-row insert that needs an automatic id fails as a whole.
INSERT INTO a VALUES (2, 'two'), (NULL, 'auto');
SELECT id, v FROM a ORDER BY id;

-- Without AUTOINCREMENT the same situation still succeeds (random rowid).
CREATE TABLE p(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO p VALUES (9223372036854775807, 'max');
INSERT INTO p(v) VALUES ('ok');
SELECT v FROM p ORDER BY v;

-- A separate AUTOINCREMENT table is unaffected.
CREATE TABLE b(id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT);
INSERT INTO b(v) VALUES ('first');
SELECT id, v FROM b;
