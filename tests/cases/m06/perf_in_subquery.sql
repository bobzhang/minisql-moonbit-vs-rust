-- @timeout 5
-- Performance: IN / NOT IN with subqueries over large tables. Checking each
-- row against the subquery result by scanning would take ~10^9 steps.
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
CREATE INDEX big_grp_code ON big(grp, code);
-- 100,000 outer rows tested against a 10,000-row subquery.
SELECT count(*), sum(id) FROM big WHERE code IN (SELECT x FROM probe);
SELECT count(*) FROM big WHERE code NOT IN (SELECT x FROM probe);
-- 10,000 outer rows tested against an indexed 100,000-row column.
SELECT count(*) FROM probe WHERE x IN (SELECT code FROM big);
SELECT count(*) FROM probe WHERE x + 100000 NOT IN (SELECT code FROM big);
-- Correlated IN using the (grp, code) index; each subquery yields about one row.
SELECT count(*) FROM probe WHERE x IN (SELECT code FROM big WHERE grp = probe.x % 100 AND code BETWEEN probe.x - 50 AND probe.x + 50);
-- EXISTS with an indexed correlated lookup.
SELECT count(*) FROM probe WHERE EXISTS (SELECT 1 FROM big WHERE code = probe.x AND grp < 50);
SELECT count(*) FROM probe WHERE NOT EXISTS (SELECT 1 FROM big WHERE code = probe.x * 2);
