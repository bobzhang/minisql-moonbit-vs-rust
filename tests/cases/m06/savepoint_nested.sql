-- Nested savepoints form a stack. ROLLBACK TO or RELEASE of an outer
-- savepoint also affects every savepoint created after it.
CREATE TABLE log(step TEXT);

BEGIN;
INSERT INTO log VALUES ('base');
SAVEPOINT s1;
INSERT INTO log VALUES ('in s1');
SAVEPOINT s2;
INSERT INTO log VALUES ('in s2');
SAVEPOINT s3;
INSERT INTO log VALUES ('in s3');
-- Roll back to the innermost: only its change goes.
ROLLBACK TO s3;
SELECT step FROM log ORDER BY rowid;
-- Roll back to the middle: s2's and s3's changes go; s3 is gone, s2 stays open.
INSERT INTO log VALUES ('again in s3');
ROLLBACK TO s2;
SELECT step FROM log ORDER BY rowid;
ROLLBACK TO s3;
-- s1 and s2 still exist.
INSERT INTO log VALUES ('after s2 rollback');
RELEASE s1;
-- Releasing s1 also released s2.
ROLLBACK TO s2;
COMMIT;
SELECT step FROM log ORDER BY rowid;
-- Releasing an inner savepoint merges its changes into the outer one,
-- which can still roll them back.
BEGIN;
SAVEPOINT outer_sp;
INSERT INTO log VALUES ('x');
SAVEPOINT inner_sp;
INSERT INTO log VALUES ('y');
RELEASE inner_sp;
SELECT count(*) FROM log;
ROLLBACK TO outer_sp;
SELECT count(*) FROM log;
RELEASE outer_sp;
COMMIT;
-- Duplicate names: the most recent savepoint with the name is used.
BEGIN;
SAVEPOINT dup;
INSERT INTO log VALUES ('first dup');
SAVEPOINT dup;
INSERT INTO log VALUES ('second dup');
ROLLBACK TO dup;
RELEASE dup;
INSERT INTO log VALUES ('after inner release');
ROLLBACK TO dup;
RELEASE dup;
COMMIT;
SELECT step FROM log ORDER BY rowid;
