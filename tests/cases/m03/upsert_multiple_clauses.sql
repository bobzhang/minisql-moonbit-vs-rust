-- Several ON CONFLICT clauses may be given; each is tied to its own target
-- and the last one may omit the target. Conflicts that no clause covers use
-- the statement's normal conflict resolution.
CREATE TABLE t(id INTEGER PRIMARY KEY, email TEXT UNIQUE, name TEXT, n INTEGER DEFAULT 0);
INSERT INTO t VALUES (1, 'a@x', 'ann', 0), (2, 'b@x', 'bob', 0);

-- Conflict on email only: the email clause runs.
INSERT INTO t VALUES (3, 'a@x', 'ANN', 0)
  ON CONFLICT(id) DO UPDATE SET n = n + 100
  ON CONFLICT(email) DO UPDATE SET n = n + 1, name = excluded.name;
SELECT id, email, name, n FROM t ORDER BY id;

-- Conflict on id only: the id clause runs.
INSERT INTO t VALUES (2, 'new@x', 'x', 0)
  ON CONFLICT(id) DO UPDATE SET n = n + 100
  ON CONFLICT(email) DO UPDATE SET n = n + 1;
SELECT id, email, name, n FROM t ORDER BY id;

-- The last clause without a target catches other uniqueness conflicts.
INSERT INTO t VALUES (9, 'b@x', 'dup', 0)
  ON CONFLICT(id) DO NOTHING
  ON CONFLICT DO UPDATE SET n = n + 10;
SELECT id, email, name, n FROM t ORDER BY id;

-- No conflict at all.
INSERT INTO t VALUES (4, 'd@x', 'dee', 0)
  ON CONFLICT(id) DO NOTHING
  ON CONFLICT(email) DO NOTHING;
SELECT id, email, name, n FROM t ORDER BY id;

-- A conflict on a constraint that is not a target is an error.
INSERT INTO t VALUES (1, 'zzz@x', 'z', 0) ON CONFLICT(email) DO NOTHING;
SELECT id, email, name, n FROM t ORDER BY id;

-- The OR clause handles conflicts not covered by the upsert target...
INSERT OR REPLACE INTO t VALUES (1, 'q@x', 'replaced', 5) ON CONFLICT(email) DO NOTHING;
SELECT id, email, name, n FROM t ORDER BY id;
-- ...while the upsert takes priority for its own target.
INSERT OR IGNORE INTO t VALUES (4, 'other@x', 'o', 0) ON CONFLICT(id) DO UPDATE SET n = 77;
SELECT id, email, name, n FROM t ORDER BY id;

-- DO UPDATE that creates a new uniqueness violation is an error.
INSERT INTO t VALUES (2, 'b@x', 'x', 0) ON CONFLICT(id) DO UPDATE SET email = 'q@x';
SELECT id, email, name, n FROM t ORDER BY id;

-- A clause without a target must be the last one.
INSERT INTO t VALUES (5, 'e@x', 'e', 0) ON CONFLICT DO NOTHING ON CONFLICT(id) DO NOTHING;
SELECT id, email FROM t ORDER BY id;
