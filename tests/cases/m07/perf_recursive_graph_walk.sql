-- @timeout 5
-- Performance: walking a 100k-node tree (parent pointers, indexed) with a
-- recursive CTE, and UNION-based deduplication over 20k distinct values.
-- Each recursion step must use the index on parent (equality lookup), and
-- UNION's duplicate check must not be a linear scan of all previous rows.
CREATE TABLE node(id INTEGER PRIMARY KEY, parent INTEGER, w INTEGER);
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100000)
INSERT INTO node SELECT x, CASE WHEN x = 1 THEN NULL ELSE x / 2 END, x % 10 FROM c;
CREATE INDEX node_parent ON node(parent);

-- All descendants of the root with their depth (a binary heap: depth = floor(log2(id))).
WITH RECURSIVE d(id, depth) AS (SELECT 1, 0 UNION ALL SELECT n.id, d.depth + 1 FROM node n JOIN d ON n.parent = d.id)
SELECT count(*), max(depth), sum(depth), sum(depth = 16) FROM d;

-- Subtree of node 3: size and weight.
WITH RECURSIVE d(id) AS (SELECT 3 UNION ALL SELECT n.id FROM node n JOIN d ON n.parent = d.id)
SELECT count(*), sum(node.w) FROM d JOIN node ON node.id = d.id;

-- Ancestors of many leaves: walk upward from 1000 start nodes.
WITH RECURSIVE up(start, id) AS (SELECT id, id FROM node WHERE id > 99000 UNION ALL
  SELECT up.start, n.parent FROM up JOIN node n ON n.id = up.id WHERE n.parent IS NOT NULL)
SELECT count(*), count(DISTINCT id) FROM up;

-- UNION dedup: x -> (x + 7) mod 20000 visits all 20000 values once, then stops.
WITH RECURSIVE c(x) AS (SELECT 0 UNION SELECT (x + 7) % 20000 FROM c)
SELECT count(*), sum(x), max(x) FROM c;

-- UNION dedup with two recursive arms producing many duplicates.
WITH RECURSIVE c(x) AS (SELECT 1 UNION SELECT (x * 2) % 30011 FROM c UNION SELECT (x * 3) % 30011 FROM c)
SELECT count(*), sum(x) FROM c;

-- Reachability in a graph with many cycles (UNION terminates).
CREATE TABLE edge(a INTEGER, b INTEGER);
WITH RECURSIVE c(x) AS (SELECT 0 UNION ALL SELECT x + 1 FROM c WHERE x < 29999)
INSERT INTO edge SELECT x, (x * 17 + 3) % 30000 FROM c UNION ALL SELECT x, (x + 1) % 30000 FROM c WHERE x % 2 = 0;
CREATE INDEX edge_a ON edge(a);
WITH RECURSIVE r(n) AS (SELECT 5 UNION SELECT e.b FROM edge e JOIN r ON e.a = r.n)
SELECT count(*), min(n), max(n) FROM r;
