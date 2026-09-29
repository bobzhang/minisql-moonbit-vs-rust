-- Upsert edge cases: targets that do not match a unique constraint,
-- unknown excluded columns, DO UPDATE on constraints and parse ambiguity.
CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT UNIQUE, v INTEGER, w INTEGER);
INSERT INTO t VALUES (1, 'a', 10, 0), (2, 'b', 20, 0);

-- Target on a column that is not unique.
INSERT INTO t VALUES (3, 'a', 1, 1) ON CONFLICT(v) DO NOTHING;
-- Unknown column in excluded.
INSERT INTO t VALUES (1, 'a', 1, 1) ON CONFLICT(id) DO UPDATE SET v = excluded.nosuch;
SELECT id, k, v, w FROM t ORDER BY id;

-- DO UPDATE whose new row violates NOT NULL or CHECK fails and changes nothing.
CREATE TABLE c(k TEXT PRIMARY KEY, n INTEGER NOT NULL CHECK (n < 100));
INSERT INTO c VALUES ('x', 1);
INSERT INTO c VALUES ('x', 5) ON CONFLICT(k) DO UPDATE SET n = NULL;
INSERT INTO c VALUES ('x', 5) ON CONFLICT(k) DO UPDATE SET n = excluded.n + 200;
SELECT k, n FROM c;
-- Upsert only handles uniqueness conflicts: the candidate row itself is
-- still checked for NOT NULL and CHECK, so this fails even though the
-- DO UPDATE would produce a valid row.
INSERT INTO c VALUES ('x', 200) ON CONFLICT(k) DO UPDATE SET n = 2;
SELECT k, n FROM c;
-- A valid update.
INSERT INTO c VALUES ('x', 50) ON CONFLICT(k) DO UPDATE SET n = excluded.n + c.n;
SELECT k, n FROM c;
INSERT INTO c VALUES ('y', 60) ON CONFLICT(k) DO UPDATE SET n = excluded.n + c.n;
SELECT k, n FROM c ORDER BY k;

-- A statement that fails midway through a multi-row upsert leaves nothing.
INSERT INTO t VALUES (1, 'a', 0, 0), (5, 'e', 0, 0), (2, 'b', 0, 0)
  ON CONFLICT(id) DO UPDATE SET k = 'a';
SELECT id, k, v, w FROM t ORDER BY id;

-- The SET clause may update several columns, including the key.
INSERT INTO t VALUES (2, 'b', 0, 0) ON CONFLICT(k) DO UPDATE SET id = 20, w = w + 1;
SELECT id, k, v, w FROM t ORDER BY id;

-- DO UPDATE WHERE referencing excluded and the existing row.
INSERT INTO t VALUES (1, 'a', 99, 0) ON CONFLICT(id) DO UPDATE SET v = excluded.v WHERE t.v < excluded.v AND excluded.k = t.k;
INSERT INTO t VALUES (1, 'zz', 5, 0) ON CONFLICT(id) DO UPDATE SET v = excluded.v WHERE t.v < excluded.v;
SELECT id, k, v, w FROM t ORDER BY id;

-- A SELECT source without FROM needs no WHERE true.
INSERT INTO t SELECT 1, 'a', 7, 7 ON CONFLICT(id) DO UPDATE SET w = excluded.w;
SELECT id, k, v, w FROM t ORDER BY id;
