-- @timeout 5
-- Performance: UPDATE and DELETE statements that locate rows through a
-- secondary index, many times over, with index maintenance on every change.
CREATE TABLE d(x INTEGER);
INSERT INTO d VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);
-- big: 100,000 rows. code is a permutation of 0..99999 (7919 is coprime to 100000).
CREATE TABLE big(id INTEGER PRIMARY KEY, code INTEGER, grp INTEGER, v TEXT);
INSERT INTO big SELECT a.x*10000 + b.x*1000 + c.x*100 + e.x*10 + f.x,
    ((a.x*10000 + b.x*1000 + c.x*100 + e.x*10 + f.x) * 7919) % 100000,
    (a.x*10000 + b.x*1000 + c.x*100 + e.x*10 + f.x) % 100,
    'v' || f.x
  FROM d a, d b, d c, d e, d f;
-- probe: 10,000 rows with values spread over 0..99999.
CREATE TABLE probe(x INTEGER);
INSERT INTO probe SELECT (a.x*1000 + b.x*100 + c.x*10 + e.x) * 10 + (a.x + e.x) % 10 FROM d a, d b, d c, d e;
CREATE INDEX big_code ON big(code);
CREATE INDEX big_v ON big(v);
-- 10,000 rows updated through the code index (IN list evaluated once).
UPDATE big SET grp = -1 WHERE code IN (SELECT x FROM probe);
SELECT count(*) FROM big WHERE grp = -1;
-- Correlated UPDATE of a small table using the index 10,000 times.
CREATE TABLE marks(x INTEGER PRIMARY KEY, found INTEGER);
INSERT INTO marks SELECT x, 0 FROM probe;
UPDATE marks SET found = (SELECT id FROM big WHERE code = marks.x);
SELECT count(*), sum(found) FROM marks;
-- Changing the indexed column of 10,000 rows, then looking rows up by old and new values.
UPDATE big SET code = code + 100000 WHERE grp = -1;
SELECT count((SELECT id FROM big WHERE code = probe.x)), count((SELECT id FROM big WHERE code = probe.x + 100000)) FROM probe;
-- Deleting 10,000 rows found through the index.
DELETE FROM big WHERE code >= 100000;
SELECT count(*) FROM big;
SELECT count((SELECT id FROM big WHERE code = probe.x + 1)) FROM probe;
-- Correlated DELETE on the small table, one index lookup per row.
DELETE FROM marks WHERE NOT EXISTS (SELECT 1 FROM big WHERE code = marks.x + 1);
SELECT count(*) FROM marks;
-- The index on v is still consistent.
SELECT v, count(*) FROM big WHERE v IN ('v0', 'v9') GROUP BY v ORDER BY v;
