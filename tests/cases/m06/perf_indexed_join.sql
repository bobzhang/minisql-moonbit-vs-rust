-- @timeout 5
-- Performance: joins between large tables on indexed columns. A nested-loop
-- join without an index would compare 5*10^9 row pairs.
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
-- other: 50,000 rows referring to big.code.
CREATE TABLE other(oid INTEGER PRIMARY KEY, ref INTEGER, w INTEGER);
INSERT INTO other SELECT a.x*10000 + b.x*1000 + c.x*100 + e.x*10 + f.x,
    ((a.x*10000 + b.x*1000 + c.x*100 + e.x*10 + f.x) * 3) % 100000,
    f.x
  FROM d a, d b, d c, d e, d f WHERE a.x < 5;
SELECT count(*) FROM other;
SELECT count(*), sum(big.id) FROM other JOIN big ON big.code = other.ref;
-- LEFT JOIN: rows of other whose ref has no match (none, since code covers 0..99999).
SELECT count(*) FROM other LEFT JOIN big ON big.code = other.ref + 100000 WHERE big.id IS NULL;
-- Join on the INTEGER PRIMARY KEY.
SELECT count(*), sum(big.code % 10) FROM other JOIN big ON big.id = other.ref;
-- With an index on other.ref, big can be the outer table as well.
CREATE INDEX other_ref ON other(ref);
SELECT count(*), sum(other.w) FROM big JOIN other ON other.ref = big.code WHERE big.grp = 7;
-- Three-way join through two indexes.
SELECT count(*) FROM probe JOIN big ON big.code = probe.x JOIN other ON other.ref = big.code;
