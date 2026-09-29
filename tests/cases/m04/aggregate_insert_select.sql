-- Aggregate queries as the source of INSERT ... SELECT, and aggregates over
-- data changed by earlier DML.
CREATE TABLE tx(id INTEGER PRIMARY KEY, acct TEXT, amt INTEGER);
INSERT INTO tx(acct, amt) VALUES ('a', 100), ('b', 50), ('a', -30), ('c', 70), ('b', 25), ('a', 5);

CREATE TABLE bal(acct TEXT PRIMARY KEY, total INTEGER, n INTEGER);
INSERT INTO bal SELECT acct, sum(amt), count(*) FROM tx GROUP BY acct;
SELECT acct, total, n FROM bal ORDER BY acct;

-- Aggregate row inserted into a summary table.
CREATE TABLE summary(label TEXT, value);
INSERT INTO summary SELECT 'rows', count(*) FROM tx;
INSERT INTO summary SELECT 'max', max(amt) FROM tx;
INSERT INTO summary SELECT 'avg', avg(amt) FROM tx;
INSERT INTO summary SELECT 'empty sum', sum(amt) FROM tx WHERE 0;
SELECT label, value, typeof(value) FROM summary ORDER BY label;

-- An aggregate query with GROUP BY that yields no groups inserts nothing.
INSERT INTO summary SELECT acct, count(*) FROM tx WHERE amt > 1000 GROUP BY acct;
SELECT count(*) FROM summary;

-- Upsert fed by an aggregate.
INSERT INTO tx(acct, amt) VALUES ('c', 30), ('d', 1);
INSERT INTO bal SELECT acct, sum(amt), count(*) FROM tx GROUP BY acct HAVING true
  ON CONFLICT(acct) DO UPDATE SET total = excluded.total, n = excluded.n;
SELECT acct, total, n FROM bal ORDER BY acct;

-- Aggregates after UPDATE and DELETE.
UPDATE tx SET amt = amt * 2 WHERE acct = 'a';
DELETE FROM tx WHERE amt < 10;
SELECT acct, sum(amt), count(*) FROM tx GROUP BY acct ORDER BY acct;

-- Rows copied into another table and aggregated there.
CREATE TABLE log(v INTEGER);
INSERT INTO log SELECT amt FROM tx WHERE acct = 'b';
SELECT sum(v), group_concat(v, '+' ORDER BY v) FROM log;
