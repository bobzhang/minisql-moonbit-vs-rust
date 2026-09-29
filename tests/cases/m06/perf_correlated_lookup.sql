-- @timeout 5
-- Performance: correlated subqueries whose inner query is an indexed
-- lookup, in the select list, WHERE, and UPDATE, over 10,000 outer rows.
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
CREATE INDEX big_grp ON big(grp);
CREATE INDEX big_code ON big(code);
CREATE TABLE groups(g INTEGER PRIMARY KEY, total INTEGER);
INSERT INTO groups SELECT a.x*10 + b.x, NULL FROM d a, d b;
-- 100 groups, each aggregating 1,000 rows found through the grp index.
SELECT sum((SELECT count(*) FROM big WHERE grp = groups.g)) FROM groups;
UPDATE groups SET total = (SELECT sum(code) FROM big WHERE big.grp = groups.g);
SELECT sum(total), min(total), max(total) FROM groups;
-- 10,000 outer rows: lookup a row then compare.
SELECT count(*) FROM probe WHERE (SELECT grp FROM big WHERE code = probe.x) < 10;
SELECT sum(CASE WHEN (SELECT id FROM big WHERE code = probe.x) % 2 = 0 THEN 1 ELSE 0 END) FROM probe;
-- Correlated lookup inside a join condition.
CREATE TABLE p2(x INTEGER, y INTEGER);
INSERT INTO p2 SELECT x, x % 97 FROM probe;
SELECT count(*) FROM p2 JOIN big ON big.code = p2.x WHERE big.grp = (SELECT grp FROM big b2 WHERE b2.code = p2.x);
-- Correlated DELETE using the index.
DELETE FROM p2 WHERE (SELECT grp FROM big WHERE code = p2.x) >= 50;
SELECT count(*) FROM p2;
