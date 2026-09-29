-- WITH ... UPDATE and WITH ... DELETE: CTEs usable in WHERE, SET and
-- subqueries of data-modifying statements.
CREATE TABLE acct(id INTEGER PRIMARY KEY, owner TEXT, bal INTEGER);
INSERT INTO acct VALUES (1, 'ann', 100), (2, 'bob', 50), (3, 'cid', 0), (4, 'dee', 75), (5, 'eve', NULL);

-- UPDATE whose WHERE uses a CTE.
WITH poor AS (SELECT id FROM acct WHERE bal < 60)
UPDATE acct SET bal = bal + 10 WHERE id IN (SELECT id FROM poor);
SELECT id, bal FROM acct ORDER BY id;

-- UPDATE whose SET uses a CTE in a scalar subquery.
WITH bonus(amount) AS (SELECT 5)
UPDATE acct SET bal = bal + (SELECT amount FROM bonus) WHERE owner = 'ann';
SELECT bal FROM acct WHERE id = 1;

-- A correlated subquery in SET that reads a CTE keyed by id.
WITH adj(id, delta) AS (VALUES (2, -1), (4, 1000))
UPDATE acct SET bal = bal + (SELECT delta FROM adj WHERE adj.id = acct.id) WHERE id IN (SELECT id FROM adj);
SELECT id, bal FROM acct ORDER BY id;

-- WITH ... UPDATE ... RETURNING.
WITH t(n) AS (VALUES ('eve')) UPDATE acct SET bal = 1 WHERE owner IN t RETURNING id, owner, bal;

-- A recursive CTE in an UPDATE.
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 2 FROM c WHERE x < 5)
UPDATE acct SET owner = upper(owner) WHERE id IN (SELECT x FROM c);
SELECT id, owner FROM acct ORDER BY id;

-- DELETE whose WHERE uses a CTE.
WITH gone AS (SELECT id FROM acct WHERE bal > 500)
DELETE FROM acct WHERE id IN gone;
SELECT id FROM acct ORDER BY id;

-- DELETE with a CTE and RETURNING.
WITH lo AS (SELECT min(bal) AS m FROM acct)
DELETE FROM acct WHERE bal = (SELECT m FROM lo) RETURNING id, bal;
SELECT id, bal FROM acct ORDER BY id;

-- DELETE with EXISTS against a CTE; nothing matches.
WITH names(n) AS (VALUES ('zed'))
DELETE FROM acct WHERE EXISTS (SELECT 1 FROM names WHERE n = owner);
SELECT count(*) FROM acct;

-- A CTE that reads the table being modified sees its state before the change.
WITH total AS (SELECT sum(bal) AS s FROM acct)
UPDATE acct SET bal = (SELECT s FROM total);
SELECT id, bal FROM acct ORDER BY id;

-- The CTE's name can shadow the target table in subqueries only; the
-- target of UPDATE/DELETE is always the real table.
WITH acct AS (SELECT 1 AS id)
DELETE FROM acct WHERE id IN (SELECT id FROM acct);
SELECT count(*) FROM acct;

-- Error: unknown column in the CTE body aborts the whole UPDATE.
WITH bad AS (SELECT nope FROM acct) UPDATE acct SET bal = 0 WHERE id IN (SELECT nope FROM bad);
SELECT sum(bal) FROM acct;
