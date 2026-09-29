-- @timeout 5
-- Performance: lookups, joins, updates and deletes by INTEGER PRIMARY KEY
-- (rowid) on a 100,000-row table, 10,000 at a time.
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
SELECT sum((SELECT code FROM big WHERE id = probe.x)) FROM probe;
SELECT sum((SELECT code FROM big WHERE rowid = probe.x + 1)) FROM probe;
SELECT count(*), sum(big.grp) FROM probe JOIN big ON big.id = probe.x;
SELECT sum((SELECT count(*) FROM big WHERE id BETWEEN probe.x AND probe.x + 4)) FROM probe;
-- Updates and deletes by rowid through IN (subquery).
UPDATE big SET v = 'hit' WHERE id IN (SELECT x FROM probe);
SELECT count(*) FROM big WHERE v = 'hit';
DELETE FROM big WHERE id IN (SELECT x + 1 FROM probe);
SELECT count(*) FROM big;
-- Updates by rowid via a correlated subquery on the other table.
CREATE TABLE lookup(k INTEGER PRIMARY KEY, val INTEGER);
INSERT INTO lookup SELECT x, x * 2 FROM probe;
UPDATE lookup SET val = (SELECT code FROM big WHERE big.id = lookup.k);
SELECT sum(val) FROM lookup;
-- ORDER BY rowid with LIMIT from the end.
SELECT id FROM big ORDER BY id DESC LIMIT 3;
