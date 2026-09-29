-- Upsert: ON CONFLICT (target) DO UPDATE SET ... [WHERE ...].
-- "excluded.col" is the value that would have been inserted; bare column
-- names (or table-qualified ones) refer to the existing row.
CREATE TABLE inv(item TEXT PRIMARY KEY, qty INTEGER, updated INTEGER DEFAULT 0);
INSERT INTO inv(item, qty) VALUES ('apple', 5), ('pear', 3);

INSERT INTO inv(item, qty) VALUES ('apple', 2)
  ON CONFLICT(item) DO UPDATE SET qty = qty + excluded.qty, updated = updated + 1;
SELECT item, qty, updated FROM inv ORDER BY item;

-- Table-qualified reference to the existing row.
INSERT INTO inv(item, qty) VALUES ('pear', 10)
  ON CONFLICT(item) DO UPDATE SET qty = inv.qty * excluded.qty;
SELECT item, qty, updated FROM inv ORDER BY item;

-- No conflict: plain insert, DO UPDATE is not used.
INSERT INTO inv(item, qty) VALUES ('fig', 1)
  ON CONFLICT(item) DO UPDATE SET qty = 999;
SELECT item, qty, updated FROM inv ORDER BY item;

-- excluded.* sees the value after defaults are filled in.
INSERT INTO inv(item, qty) VALUES ('fig', 7)
  ON CONFLICT(item) DO UPDATE SET updated = excluded.updated + 50, qty = excluded.qty;
SELECT item, qty, updated FROM inv ORDER BY item;

-- DO UPDATE ... WHERE: the update only happens if the condition holds.
INSERT INTO inv(item, qty) VALUES ('apple', 100)
  ON CONFLICT(item) DO UPDATE SET qty = excluded.qty WHERE excluded.qty < qty;
INSERT INTO inv(item, qty) VALUES ('apple', 1)
  ON CONFLICT(item) DO UPDATE SET qty = excluded.qty WHERE excluded.qty < qty;
SELECT item, qty, updated FROM inv ORDER BY item;

-- Several rows hitting the same key are applied one after another.
INSERT INTO inv(item, qty) VALUES ('pear', 1), ('pear', 2), ('kiwi', 4), ('kiwi', 5)
  ON CONFLICT(item) DO UPDATE SET qty = qty + excluded.qty, updated = updated + 1;
SELECT item, qty, updated FROM inv ORDER BY item;

-- Target is an INTEGER PRIMARY KEY.
CREATE TABLE c(id INTEGER PRIMARY KEY, hits INTEGER);
INSERT INTO c VALUES (1, 1) ON CONFLICT(id) DO UPDATE SET hits = hits + 1;
INSERT INTO c VALUES (1, 1) ON CONFLICT(id) DO UPDATE SET hits = hits + 1;
INSERT INTO c VALUES (1, 1) ON CONFLICT(id) DO UPDATE SET hits = hits + 1;
SELECT id, hits FROM c;

-- Affinity applies to the updated values.
CREATE TABLE a(k TEXT PRIMARY KEY, n INTEGER, s TEXT);
INSERT INTO a VALUES ('x', 1, 'one');
INSERT INTO a VALUES ('x', '42', 7) ON CONFLICT(k) DO UPDATE SET n = excluded.n, s = excluded.s;
SELECT k, n, typeof(n), s, typeof(s) FROM a;

-- Upsert applies to INSERT ... SELECT as well; "WHERE true" is needed so
-- the ON CONFLICT is not parsed as part of the SELECT.
CREATE TABLE src(k TEXT, n INTEGER);
INSERT INTO src VALUES ('x', 5), ('y', 6);
INSERT INTO a(k, n) SELECT k, n FROM src WHERE true
  ON CONFLICT(k) DO UPDATE SET n = a.n + excluded.n;
SELECT k, n, s FROM a ORDER BY k;

-- Target with a NOCASE unique column.
CREATE TABLE ci(name TEXT UNIQUE COLLATE NOCASE, cnt INTEGER);
INSERT INTO ci VALUES ('Bob', 1);
INSERT INTO ci VALUES ('BOB', 1) ON CONFLICT(name) DO UPDATE SET cnt = cnt + 1, name = excluded.name;
SELECT name, cnt FROM ci;
