-- CHECK failures combined with conflict resolution:
--   OR IGNORE skips the row, OR FAIL keeps earlier rows,
--   OR REPLACE behaves like ABORT (there is nothing to replace).
CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER CHECK (n >= 0), CONSTRAINT small CHECK (n < 100));
INSERT INTO t VALUES (1, 10);

INSERT OR IGNORE INTO t VALUES (2, -5), (3, 30), (4, 500), (5, 50);
SELECT id, n FROM t ORDER BY id;
SELECT changes();

INSERT OR FAIL INTO t VALUES (6, 60), (7, -7), (8, 80);
SELECT id, n FROM t ORDER BY id;

INSERT OR REPLACE INTO t VALUES (1, -1);
SELECT id, n FROM t ORDER BY id;
INSERT OR REPLACE INTO t VALUES (1, 11);
SELECT id, n FROM t ORDER BY id;

INSERT OR ABORT INTO t VALUES (9, 9), (10, 1000);
SELECT id, n FROM t ORDER BY id;

-- UPDATE OR IGNORE skips rows whose new value fails the CHECK.
UPDATE OR IGNORE t SET n = n * 2;
SELECT id, n FROM t ORDER BY id;
UPDATE OR IGNORE t SET n = n - 25;
SELECT id, n FROM t ORDER BY id;

-- UPDATE OR REPLACE with a CHECK failure is still an error.
UPDATE OR REPLACE t SET n = -1 WHERE id = 1;
SELECT id, n FROM t ORDER BY id;

-- CHECK and NOT NULL checked together; OR IGNORE covers both.
CREATE TABLE u(a NOT NULL, b CHECK (b <> 'bad'));
INSERT OR IGNORE INTO u VALUES (1, 'ok'), (NULL, 'ok'), (3, 'bad'), (4, NULL);
SELECT a, b FROM u ORDER BY a;
