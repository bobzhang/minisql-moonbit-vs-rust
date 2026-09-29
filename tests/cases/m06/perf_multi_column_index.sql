-- @timeout 5
-- Performance: a two-column index used for equality on the first column plus
-- equality or range on the second, 10,000 times.
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
CREATE INDEX big_grp_code ON big(grp, code);
SELECT sum((SELECT count(*) FROM big WHERE grp = probe.x % 100 AND code > probe.x - 3000 AND code < probe.x)) FROM probe;
SELECT sum((SELECT count(*) FROM big WHERE grp = probe.x % 100 AND code BETWEEN probe.x AND probe.x + 1000)) FROM probe;
SELECT count(*) FROM probe WHERE EXISTS (SELECT 1 FROM big WHERE grp = probe.x % 100 AND code = probe.x);
SELECT sum((SELECT max(code) FROM big WHERE grp = probe.x % 100 AND code < probe.x)) FROM probe;
SELECT sum((SELECT min(code) FROM big WHERE grp = probe.x % 100 AND code > probe.x)) FROM probe;
-- The first column alone still selects through the index.
SELECT sum((SELECT count(*) FROM big WHERE grp = probe.x % 100)) FROM probe WHERE x < 5000;
