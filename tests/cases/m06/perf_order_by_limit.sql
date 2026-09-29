-- @timeout 5
-- Performance: ORDER BY ... LIMIT on an indexed column, repeated 10,000
-- times through a correlated subquery (successor/predecessor lookups).
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
SELECT id, code FROM big ORDER BY code LIMIT 3;
SELECT id, code FROM big ORDER BY code DESC LIMIT 3;
SELECT id FROM big WHERE code > 50000 ORDER BY code LIMIT 2;
-- For each probe: the id of the row with the next larger code.
SELECT sum((SELECT id FROM big WHERE code > probe.x ORDER BY code LIMIT 1)) FROM probe;
-- The next smaller code.
SELECT sum((SELECT code FROM big WHERE code < probe.x ORDER BY code DESC LIMIT 1)) FROM probe;
-- Fifth-next, via OFFSET.
SELECT sum((SELECT code FROM big WHERE code >= probe.x ORDER BY code LIMIT 1 OFFSET 4)) FROM probe;
-- min/max with a range condition.
SELECT sum((SELECT min(code) FROM big WHERE code > probe.x + 3)) FROM probe;
