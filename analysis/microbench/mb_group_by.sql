CREATE TABLE d(x INTEGER);
INSERT INTO d VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);
CREATE TABLE t(id INTEGER PRIMARY KEY, g INTEGER, s TEXT, r REAL);
INSERT INTO t SELECT a.x*100000 + b.x*10000 + c.x*1000 + e.x*100 + f.x*10 + h.x,
   (a.x*100000 + b.x*10000 + c.x*1000 + e.x*100 + f.x*10 + h.x) % 1000,
   'k' || (((a.x*100000 + b.x*10000 + c.x*1000 + e.x*100 + f.x*10 + h.x) * 7919) % 1000003),
   (a.x*100000 + b.x*10000 + c.x*1000 + e.x*100 + f.x*10 + h.x) * 0.37
 FROM d a, d b, d c, d e, d f, d h WHERE a.x < 3;
SELECT g, count(*), sum(id), max(s), min(r) FROM t GROUP BY g ORDER BY g LIMIT 5;
SELECT count(*) FROM (SELECT g, count(*) AS c FROM t GROUP BY g HAVING c > 250);
SELECT count(DISTINCT s) FROM t;
