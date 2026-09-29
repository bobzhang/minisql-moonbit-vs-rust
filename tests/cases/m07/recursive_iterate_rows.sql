-- Using recursion to iterate over table rows in key order: running totals,
-- state machines and carried-forward values. The recursive step joins the
-- next row by key.
CREATE TABLE tx(seq INTEGER PRIMARY KEY, kind TEXT, amount INTEGER);
INSERT INTO tx VALUES (1, 'dep', 100), (2, 'wd', 30), (3, 'wd', 90), (4, 'dep', 50),
  (5, 'fee', 5), (6, 'wd', 10), (7, 'dep', NULL);

-- Running balance: a withdrawal larger than the balance is rejected.
WITH RECURSIVE bal(seq, balance, note) AS (
  SELECT 0, 0, 'open'
  UNION ALL
  SELECT tx.seq,
         CASE WHEN tx.kind = 'dep' THEN bal.balance + coalesce(tx.amount, 0)
              WHEN tx.amount > bal.balance THEN bal.balance
              ELSE bal.balance - tx.amount END,
         CASE WHEN tx.kind <> 'dep' AND tx.amount > bal.balance THEN 'rejected' ELSE tx.kind END
  FROM bal JOIN tx ON tx.seq = bal.seq + 1)
SELECT seq, balance, note FROM bal ORDER BY seq;

-- Carry forward the last non-NULL amount.
WITH RECURSIVE cf(seq, last_amt) AS (
  SELECT seq, amount FROM tx WHERE seq = 1
  UNION ALL
  SELECT tx.seq, coalesce(tx.amount, cf.last_amt) FROM cf JOIN tx ON tx.seq = cf.seq + 1)
SELECT seq, last_amt FROM cf ORDER BY seq;

-- Count of consecutive withdrawals (run length) at each row.
WITH RECURSIVE run(seq, kind, len) AS (
  SELECT seq, kind, 1 FROM tx WHERE seq = 1
  UNION ALL
  SELECT tx.seq, tx.kind, CASE WHEN tx.kind = run.kind THEN run.len + 1 ELSE 1 END
  FROM run JOIN tx ON tx.seq = run.seq + 1)
SELECT seq, kind, len FROM run ORDER BY seq;

-- Iteration stops at a gap in the key sequence.
CREATE TABLE gappy(k INTEGER PRIMARY KEY, v TEXT);
INSERT INTO gappy VALUES (1, 'a'), (2, 'b'), (3, 'c'), (5, 'e'), (6, 'f');
WITH RECURSIVE w(k, acc) AS (SELECT k, v FROM gappy WHERE k = 1 UNION ALL
  SELECT g.k, w.acc || g.v FROM w JOIN gappy g ON g.k = w.k + 1)
SELECT k, acc FROM w ORDER BY k;

-- Stepping to the next existing key with a scalar subquery handles gaps.
WITH RECURSIVE w(k, acc) AS (SELECT 1, 'a' UNION ALL
  SELECT (SELECT min(k) FROM gappy WHERE k > w.k), w.acc || (SELECT v FROM gappy WHERE k = (SELECT min(k) FROM gappy WHERE k > w.k))
  FROM w WHERE w.k < (SELECT max(k) FROM gappy))
SELECT k, acc FROM w ORDER BY k;

-- A simple state machine driven by an input string.
WITH RECURSIVE sm(i, state) AS (SELECT 0, 'idle' UNION ALL
  SELECT i + 1, CASE substr('sspxsx', i + 1, 1)
                  WHEN 's' THEN CASE state WHEN 'idle' THEN 'run' WHEN 'run' THEN 'fast' ELSE state END
                  WHEN 'p' THEN 'paused'
                  WHEN 'x' THEN 'idle' END
  FROM sm WHERE i < 6)
SELECT i, state FROM sm ORDER BY i;

-- Compound interest: 5 years at 10%, values printed as REAL.
WITH RECURSIVE ci(y, amt) AS (SELECT 0, 1000.0 UNION ALL SELECT y + 1, amt * 1.1 FROM ci WHERE y < 5)
SELECT y, round(amt, 2) FROM ci ORDER BY y;

-- Save the running balances into a table with WITH ... INSERT.
CREATE TABLE snapshot(seq INTEGER PRIMARY KEY, running INTEGER);
WITH RECURSIVE r(seq, s) AS (SELECT 0, 0 UNION ALL SELECT tx.seq, r.s + coalesce(tx.amount, 0) FROM r JOIN tx ON tx.seq = r.seq + 1)
INSERT INTO snapshot SELECT seq, s FROM r WHERE seq > 0;
SELECT seq, running FROM snapshot ORDER BY seq;
