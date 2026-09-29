-- @timeout 5
-- Performance: 10,000 range scans (each covering a handful of rows) on an
-- indexed column of a 100,000-row table.
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
SELECT sum((SELECT count(*) FROM big WHERE code BETWEEN probe.x AND probe.x + 9)) FROM probe;
SELECT sum((SELECT count(*) FROM big WHERE code > probe.x AND code < probe.x + 5)) FROM probe;
SELECT sum((SELECT sum(id) FROM big WHERE code >= probe.x AND code <= probe.x + 2)) FROM probe;
-- Open-ended ranges near the ends of the key space.
SELECT sum((SELECT count(*) FROM big WHERE code >= 99990 + probe.x % 10)) FROM probe;
SELECT sum((SELECT count(*) FROM big WHERE code < probe.x % 7)) FROM probe;
-- Single big ranges.
SELECT count(*) FROM big WHERE code BETWEEN 25000 AND 74999;
SELECT count(*), min(id), max(id) FROM big WHERE code < 10;
