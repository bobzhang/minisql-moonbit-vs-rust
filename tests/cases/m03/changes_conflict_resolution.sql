-- How conflict resolution and upsert interact with changes() and
-- last_insert_rowid(). Rows deleted by REPLACE conflict resolution are NOT
-- counted by changes(); an upsert DO UPDATE counts as one change but does
-- not update last_insert_rowid().
CREATE TABLE t(id INTEGER PRIMARY KEY, u TEXT UNIQUE, v TEXT);
INSERT INTO t VALUES (1, 'a', 'x'), (2, 'b', 'y'), (3, 'c', 'z');
INSERT INTO t VALUES (7, 'q', 'w');
SELECT changes(), total_changes(), last_insert_rowid();

-- OR REPLACE deleting two conflicting rows: changes() is still 1.
INSERT OR REPLACE INTO t VALUES (2, 'c', 'two');
SELECT changes(), total_changes(), last_insert_rowid();
SELECT id, u, v FROM t ORDER BY id;

-- OR IGNORE: ignored rows are not counted.
INSERT OR IGNORE INTO t VALUES (8, 'a', 'ign'), (9, 'new', 'ok'), (1, 'zz', 'ign');
SELECT changes(), last_insert_rowid();
INSERT OR IGNORE INTO t VALUES (10, 'a', 'ign');
SELECT changes(), last_insert_rowid();

-- Upsert DO UPDATE: one change, last_insert_rowid() unchanged.
INSERT INTO t VALUES (1, 'other', 'upd') ON CONFLICT(id) DO UPDATE SET v = excluded.v;
SELECT changes(), last_insert_rowid();
-- DO NOTHING: no change.
INSERT INTO t VALUES (1, 'other', 'upd2') ON CONFLICT DO NOTHING;
SELECT changes(), last_insert_rowid();
-- DO UPDATE ... WHERE false: no change.
INSERT INTO t VALUES (1, 'other', 'upd3') ON CONFLICT(id) DO UPDATE SET v = excluded.v WHERE 0;
SELECT changes();
-- A mix of inserted and updated rows in one statement.
INSERT INTO t VALUES (1, 'm1', 'mix1'), (20, 'm2', 'mix2'), (2, 'm3', 'mix3')
  ON CONFLICT(id) DO UPDATE SET v = excluded.v;
SELECT changes(), last_insert_rowid();
SELECT id, u, v FROM t ORDER BY id;

-- UPDATE OR REPLACE that removes another row counts only the updated row.
UPDATE OR REPLACE t SET u = 'q' WHERE id = 1;
SELECT changes();
SELECT id, u, v FROM t ORDER BY id;

-- REPLACE INTO with no conflict behaves as a plain insert.
REPLACE INTO t VALUES (30, 'r', 'replace');
SELECT changes(), last_insert_rowid();
SELECT total_changes();
