-- Conflict resolution against UNIQUE indexes created with CREATE UNIQUE INDEX:
-- INSERT OR IGNORE / OR REPLACE, REPLACE INTO, UPDATE OR ..., and upsert.
CREATE TABLE kv(id INTEGER PRIMARY KEY, k TEXT, v INTEGER);
CREATE UNIQUE INDEX kv_k ON kv(k);
INSERT INTO kv VALUES (1, 'a', 10), (2, 'b', 20), (3, 'c', 30);

-- OR IGNORE skips only the conflicting rows.
INSERT OR IGNORE INTO kv VALUES (4, 'a', 99), (5, 'd', 40);
SELECT id, k, v FROM kv ORDER BY id;
-- OR REPLACE deletes the old row holding the key, then inserts.
INSERT OR REPLACE INTO kv VALUES (6, 'b', 21);
SELECT id, k, v FROM kv ORDER BY id;
REPLACE INTO kv VALUES (7, 'c', 31);
SELECT id, k, v FROM kv ORDER BY id;
-- A REPLACE that conflicts with two different rows (one by rowid, one by k) removes both.
REPLACE INTO kv VALUES (1, 'd', 41);
SELECT id, k, v FROM kv ORDER BY id;
-- UPDATE OR IGNORE leaves conflicting rows unchanged.
UPDATE OR IGNORE kv SET k = 'b' WHERE id = 1;
SELECT id, k FROM kv ORDER BY id;
-- UPDATE OR REPLACE removes the row that held the value.
UPDATE OR REPLACE kv SET k = 'b' WHERE id = 1;
SELECT id, k, v FROM kv ORDER BY id;
-- Plain conflicting UPDATE fails and changes nothing.
UPDATE kv SET k = 'c' WHERE id = 1;
SELECT id, k FROM kv ORDER BY id;
-- Upsert: the conflict target names the indexed column.
INSERT INTO kv(id, k, v) VALUES (8, 'c', 1) ON CONFLICT (k) DO UPDATE SET v = v + excluded.v;
SELECT id, k, v FROM kv ORDER BY id;
INSERT INTO kv(id, k, v) VALUES (9, 'e', 50) ON CONFLICT (k) DO UPDATE SET v = 0;
INSERT INTO kv(id, k, v) VALUES (10, 'e', 51) ON CONFLICT (k) DO NOTHING;
INSERT INTO kv(id, k, v) VALUES (11, 'e', 52) ON CONFLICT DO NOTHING;
SELECT id, k, v FROM kv ORDER BY id;
-- DO UPDATE ... WHERE: the update happens only if the condition holds.
INSERT INTO kv(id, k, v) VALUES (12, 'e', 5) ON CONFLICT (k) DO UPDATE SET v = excluded.v WHERE excluded.v > kv.v;
INSERT INTO kv(id, k, v) VALUES (13, 'e', 500) ON CONFLICT (k) DO UPDATE SET v = excluded.v WHERE excluded.v > kv.v;
SELECT id, k, v FROM kv WHERE k = 'e';
-- Upsert target that is not unique is an error.
INSERT INTO kv(id, k, v) VALUES (14, 'z', 1) ON CONFLICT (v) DO NOTHING;
-- changes() reflects the rows written.
INSERT OR IGNORE INTO kv VALUES (15, 'a', 0), (16, 'b', 0), (17, 'f', 0);
SELECT changes();
SELECT count(*) FROM kv;
