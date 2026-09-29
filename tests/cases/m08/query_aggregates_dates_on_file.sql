-- @db file
-- M2/M4 features over file data: GROUP BY/HAVING, DISTINCT and FILTER
-- aggregates, group_concat with ORDER BY, date/time functions applied to
-- dates stored as text, printf and string functions.
-- @phase sqlite
PRAGMA page_size = 1024;
CREATE TABLE ev(id INTEGER PRIMARY KEY, kind TEXT, at TEXT, qty INTEGER, price REAL);
CREATE INDEX ev_kind_at ON ev(kind, at);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 6000)
INSERT INTO ev SELECT i, CASE i % 5 WHEN 0 THEN 'click' WHEN 1 THEN 'view' WHEN 2 THEN 'buy' WHEN 3 THEN 'view' ELSE NULL END,
  datetime('2023-12-25 06:00:00', '+' || ((i * 97) % 525600) || ' minutes'),
  CASE WHEN i % 7 = 0 THEN NULL ELSE i % 13 END, (i % 40) * 0.25 FROM c;
-- @phase engine
SELECT kind, count(*), count(qty), sum(qty), total(price), min(at), max(at) FROM ev GROUP BY kind ORDER BY kind;
SELECT strftime('%Y-%m', at) AS month, count(*) FROM ev GROUP BY month HAVING count(*) > 500 ORDER BY month;
SELECT count(DISTINCT kind), count(DISTINCT qty), count(DISTINCT date(at)) FROM ev;
SELECT count(*) FILTER (WHERE kind = 'buy'), sum(qty) FILTER (WHERE price > 5) FROM ev;
SELECT kind, group_concat(DISTINCT qty ORDER BY qty) FROM ev WHERE qty < 4 GROUP BY kind ORDER BY kind;
SELECT id, at, date(at, 'start of month'), time(at), julianday(at) - julianday('2024-01-01'), strftime('%w %j', at) FROM ev WHERE id IN (1, 2, 3000) ORDER BY id;
SELECT count(*) FROM ev WHERE at BETWEEN '2024-02-01' AND '2024-02-29 23:59:59';
SELECT unixepoch(min(at)), unixepoch(max(at)) FROM ev;
SELECT printf('%-6s|%5.2f', coalesce(kind, '-'), avg(price)) FROM ev GROUP BY kind ORDER BY kind;
SELECT upper(substr(kind, 1, 1)) || substr(kind, 2), length(kind) FROM ev WHERE kind IS NOT NULL GROUP BY kind ORDER BY kind;
SELECT qty, count(*) FROM ev GROUP BY qty ORDER BY count(*) DESC, qty LIMIT 4;
SELECT at, id FROM ev WHERE kind = 'buy' ORDER BY at DESC, id LIMIT 3;
SELECT sum(qty * price), avg(qty), max(price) FROM ev WHERE kind = 'view';
