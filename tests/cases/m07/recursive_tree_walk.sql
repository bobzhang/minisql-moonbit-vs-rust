-- Walking hierarchies (parent pointers) with recursive CTEs: descendants,
-- ancestors, depth, materialized paths, subtree aggregates.
CREATE TABLE node(id INTEGER PRIMARY KEY, parent INTEGER, name TEXT, size INTEGER);
INSERT INTO node VALUES
  (1, NULL, 'root', 1),
  (2, 1, 'usr', 2), (3, 1, 'etc', 3), (4, 1, 'home', 4),
  (5, 2, 'bin', 10), (6, 2, 'lib', 20), (7, 4, 'ann', 5), (8, 4, 'bob', 6),
  (9, 7, 'docs', 100), (10, 9, 'cv.txt', 7), (11, 5, 'ls', 8);

-- All descendants of 'home' with their depth relative to it.
WITH RECURSIVE sub(id, name, depth) AS (
  SELECT id, name, 0 FROM node WHERE name = 'home'
  UNION ALL
  SELECT n.id, n.name, s.depth + 1 FROM node n JOIN sub s ON n.parent = s.id)
SELECT name, depth FROM sub ORDER BY depth, name;

-- Full paths built from the root down.
WITH RECURSIVE p(id, path) AS (
  SELECT id, '/' || name FROM node WHERE parent IS NULL
  UNION ALL
  SELECT n.id, p.path || '/' || n.name FROM node n JOIN p ON n.parent = p.id)
SELECT path FROM p ORDER BY path;

-- Ancestors of 'cv.txt' walking upwards, nearest first.
WITH RECURSIVE anc(id, parent, name, lvl) AS (
  SELECT id, parent, name, 0 FROM node WHERE name = 'cv.txt'
  UNION ALL
  SELECT n.id, n.parent, n.name, a.lvl + 1 FROM node n JOIN anc a ON n.id = a.parent)
SELECT lvl, name FROM anc ORDER BY lvl;

-- Depth of every node; the maximum depth of the tree.
WITH RECURSIVE d(id, depth) AS (
  SELECT id, 0 FROM node WHERE parent IS NULL
  UNION ALL
  SELECT n.id, d.depth + 1 FROM node n JOIN d ON n.parent = d.id)
SELECT max(depth), count(*), sum(depth) FROM d;

-- Number of nodes at each depth.
WITH RECURSIVE d(id, depth) AS (
  SELECT id, 0 FROM node WHERE parent IS NULL
  UNION ALL
  SELECT n.id, d.depth + 1 FROM node n JOIN d ON n.parent = d.id)
SELECT depth, count(*) FROM d GROUP BY depth ORDER BY depth;

-- Subtree size totals for every node: pair each node with all its
-- descendants (including itself), then aggregate.
WITH RECURSIVE pairs(top, id) AS (
  SELECT id, id FROM node
  UNION ALL
  SELECT p.top, n.id FROM node n JOIN pairs p ON n.parent = p.id)
SELECT node.name, sum(s.size), count(*) FROM pairs JOIN node ON node.id = pairs.top
  JOIN node s ON s.id = pairs.id GROUP BY pairs.top ORDER BY pairs.top;

-- Leaves (nodes without children) reachable from 'usr'.
WITH RECURSIVE sub(id) AS (SELECT id FROM node WHERE name = 'usr'
  UNION ALL SELECT n.id FROM node n JOIN sub ON n.parent = sub.id)
SELECT name FROM node WHERE id IN sub AND NOT EXISTS (SELECT 1 FROM node c WHERE c.parent = node.id)
ORDER BY name;

-- Indented outline in depth-first order using ORDER BY in the recursive part;
-- the outer query orders by the materialized sort path, which reproduces the
-- depth-first order.
WITH RECURSIVE o(id, lvl, sortkey) AS (
  SELECT id, 0, name FROM node WHERE parent IS NULL
  UNION ALL
  SELECT n.id, o.lvl + 1, o.sortkey || '/' || n.name FROM node n JOIN o ON n.parent = o.id
  ORDER BY 2 DESC)
SELECT substr('........', 1, lvl * 2) || name FROM o JOIN node USING (id) ORDER BY sortkey;

-- Walking from a node that does not exist produces no rows.
WITH RECURSIVE sub(id) AS (SELECT id FROM node WHERE name = 'nope'
  UNION ALL SELECT n.id FROM node n JOIN sub ON n.parent = sub.id)
SELECT count(*) FROM sub;

-- Lowest common ancestor of 'ls' and 'cv.txt': intersect the ancestor sets
-- and take the deepest one.
WITH RECURSIVE
  a1(id, lvl) AS (SELECT id, 0 FROM node WHERE name = 'ls' UNION ALL SELECT n.parent, a1.lvl + 1 FROM node n JOIN a1 ON n.id = a1.id WHERE n.parent IS NOT NULL),
  a2(id) AS (SELECT id FROM node WHERE name = 'cv.txt' UNION ALL SELECT n.parent FROM node n JOIN a2 ON n.id = a2.id WHERE n.parent IS NOT NULL)
SELECT node.name FROM a1 JOIN node ON node.id = a1.id WHERE a1.id IN a2 ORDER BY a1.lvl LIMIT 1;

-- Moving a subtree with a CTE-driven UPDATE, then re-walking.
WITH RECURSIVE sub(id) AS (SELECT id FROM node WHERE name = 'ann'
  UNION ALL SELECT n.id FROM node n JOIN sub ON n.parent = sub.id)
UPDATE node SET size = size * 2 WHERE id IN sub;
SELECT name, size FROM node WHERE id IN (7, 9, 10) ORDER BY id;
