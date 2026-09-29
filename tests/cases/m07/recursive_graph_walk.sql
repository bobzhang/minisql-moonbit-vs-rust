-- Graph traversals with recursive CTEs: reachability with cycles, path
-- enumeration with cycle checks, shortest path length, and distance-limited
-- searches.
CREATE TABLE e(a TEXT, b TEXT, w INTEGER);
INSERT INTO e VALUES
  ('A', 'B', 1), ('A', 'C', 4), ('B', 'C', 2), ('B', 'D', 5), ('C', 'D', 1),
  ('D', 'A', 3), ('D', 'E', 2), ('F', 'G', 1);

-- Nodes reachable from A (UNION stops at the A->...->D->A cycle).
WITH RECURSIVE r(n) AS (SELECT 'A' UNION SELECT e.b FROM e JOIN r ON e.a = r.n)
SELECT n FROM r ORDER BY n;

-- Nodes that can reach E (walking edges backwards).
WITH RECURSIVE r(n) AS (SELECT 'E' UNION SELECT e.a FROM e JOIN r ON e.b = r.n)
SELECT n FROM r ORDER BY n;

-- All simple paths from A to E: the path string is used to avoid revisiting
-- a node (instr check), which terminates the UNION ALL recursion.
WITH RECURSIVE p(node, path, cost) AS (
  SELECT 'A', 'A', 0
  UNION ALL
  SELECT e.b, p.path || '>' || e.b, p.cost + e.w FROM e JOIN p ON e.a = p.node
  WHERE instr(p.path, e.b) = 0)
SELECT path, cost FROM p WHERE node = 'E' ORDER BY cost, path;

-- Cheapest cost to each node from A.
WITH RECURSIVE p(node, path, cost) AS (
  SELECT 'A', 'A', 0
  UNION ALL
  SELECT e.b, p.path || '>' || e.b, p.cost + e.w FROM e JOIN p ON e.a = p.node
  WHERE instr(p.path, e.b) = 0)
SELECT node, min(cost) FROM p GROUP BY node ORDER BY node;

-- Minimum number of hops (BFS levels) to every node reachable from A,
-- bounded by a hop limit.
WITH RECURSIVE h(node, hops) AS (
  SELECT 'A', 0
  UNION ALL
  SELECT e.b, h.hops + 1 FROM e JOIN h ON e.a = h.node WHERE h.hops < 4)
SELECT node, min(hops) FROM h GROUP BY node ORDER BY node;

-- Number of distinct walks of exactly 3 hops starting at A (cycles allowed).
WITH RECURSIVE h(node, hops) AS (
  SELECT 'A', 0 UNION ALL SELECT e.b, h.hops + 1 FROM e JOIN h ON e.a = h.node WHERE h.hops < 3)
SELECT node, count(*) FROM h WHERE hops = 3 GROUP BY node ORDER BY node;

-- A disconnected component: F reaches only G; G reaches nothing new.
WITH RECURSIVE r(n) AS (SELECT 'F' UNION SELECT e.b FROM e JOIN r ON e.a = r.n)
SELECT group_concat(n, ',' ORDER BY n) FROM r;
WITH RECURSIVE r(n) AS (SELECT 'G' UNION SELECT e.b FROM e JOIN r ON e.a = r.n)
SELECT group_concat(n, ',' ORDER BY n) FROM r;

-- Treating the graph as undirected: connected components labelled by their
-- smallest node.
WITH RECURSIVE
  u(x, y) AS (SELECT a, b FROM e UNION SELECT b, a FROM e),
  comp(start, n) AS (SELECT x, x FROM u UNION SELECT comp.start, u.y FROM comp JOIN u ON u.x = comp.n)
SELECT start, min(n) AS label FROM comp GROUP BY start ORDER BY start;

-- Transitive closure size: number of (from, to) pairs with a path.
WITH RECURSIVE tc(f, t) AS (SELECT a, b FROM e UNION SELECT tc.f, e.b FROM tc JOIN e ON e.a = tc.t)
SELECT count(*), sum(f = t) FROM tc;

-- The recursive table may appear on either side of the join.
WITH RECURSIVE r(n) AS (SELECT 'C' UNION SELECT e.b FROM r JOIN e ON e.a = r.n)
SELECT n FROM r ORDER BY n;

-- Recursive step with a WHERE that uses a subquery on the base table: only
-- the cheapest edges (w = 1) are followed, so A reaches only B.
WITH RECURSIVE r(n) AS (SELECT 'A' UNION SELECT e.b FROM e JOIN r ON e.a = r.n
  WHERE e.w <= (SELECT min(w) FROM e))
SELECT n FROM r ORDER BY n;
