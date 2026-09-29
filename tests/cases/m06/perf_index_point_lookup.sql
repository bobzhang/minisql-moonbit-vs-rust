-- @timeout 5
-- Performance: 10,000 equality lookups on an indexed column of a
-- 100,000-row table, via a correlated scalar subquery. Without using the
-- index this is 10^9 row comparisons.
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
SELECT count(*), sum(code), min(code), max(code) FROM big;
SELECT count(*) FROM probe;
-- Each probe finds exactly one row.
SELECT count(*), sum((SELECT id FROM big WHERE code = probe.x)) FROM probe;
SELECT sum((SELECT grp FROM big WHERE code = probe.x + 1)) FROM probe;
-- Lookups that find nothing.
SELECT count((SELECT id FROM big WHERE code = probe.x + 100000)) FROM probe;
-- Lookups with a text constant that converts to the column's affinity.
SELECT id FROM big WHERE code = '12345';
SELECT id FROM big WHERE code = 7919;
