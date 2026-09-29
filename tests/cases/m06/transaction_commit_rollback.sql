-- BEGIN ... COMMIT makes changes permanent; BEGIN ... ROLLBACK undoes every
-- change made since BEGIN. Changes are visible inside the transaction.
CREATE TABLE acct(id INTEGER PRIMARY KEY, bal INTEGER);
INSERT INTO acct VALUES (1, 100), (2, 50);

BEGIN;
UPDATE acct SET bal = bal - 30 WHERE id = 1;
UPDATE acct SET bal = bal + 30 WHERE id = 2;
SELECT id, bal FROM acct ORDER BY id;
COMMIT;
SELECT id, bal FROM acct ORDER BY id;

BEGIN;
DELETE FROM acct WHERE id = 1;
INSERT INTO acct VALUES (3, 999);
UPDATE acct SET bal = 0;
SELECT id, bal FROM acct ORDER BY id;
ROLLBACK;
SELECT id, bal FROM acct ORDER BY id;
-- An empty transaction.
BEGIN;
COMMIT;
BEGIN;
ROLLBACK;
SELECT count(*) FROM acct;
-- Many statements in one transaction.
BEGIN;
INSERT INTO acct VALUES (10, 1);
INSERT INTO acct VALUES (11, 2);
INSERT INTO acct SELECT id + 100, bal FROM acct WHERE id >= 10;
SELECT count(*), sum(bal) FROM acct;
ROLLBACK;
SELECT count(*), sum(bal) FROM acct;
-- rowids handed out in a rolled-back transaction can be reused.
BEGIN;
INSERT INTO acct(bal) VALUES (7);
SELECT max(id) FROM acct;
ROLLBACK;
INSERT INTO acct(bal) VALUES (8);
SELECT id, bal FROM acct ORDER BY id DESC LIMIT 1;
-- changes() and total_changes() inside a transaction.
BEGIN;
UPDATE acct SET bal = bal + 1;
SELECT changes();
COMMIT;
SELECT id, bal FROM acct ORDER BY id;
-- A transaction left open at the end of the script is discarded.
BEGIN;
DELETE FROM acct;
SELECT count(*) FROM acct;
