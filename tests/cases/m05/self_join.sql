-- Self-joins: the same table appears several times under different aliases.
CREATE TABLE staff(id INTEGER PRIMARY KEY, name TEXT, boss INTEGER, pay INTEGER);
INSERT INTO staff VALUES
  (1, 'ceo', NULL, 300), (2, 'cto', 1, 250), (3, 'cfo', 1, 240),
  (4, 'dev1', 2, 150), (5, 'dev2', 2, 160), (6, 'acct', 3, 120), (7, 'intern', 4, 50);

-- Each employee with their manager (inner: the root disappears).
SELECT e.name, m.name FROM staff e JOIN staff m ON e.boss = m.id ORDER BY e.id;
-- LEFT self-join keeps the root with a NULL manager.
SELECT e.name, m.name FROM staff e LEFT JOIN staff m ON e.boss = m.id ORDER BY e.id;
-- Two levels up.
SELECT e.name, m.name, g.name FROM staff e JOIN staff m ON e.boss = m.id JOIN staff g ON m.boss = g.id ORDER BY e.id;
-- Employees paid more than their manager... none; employees paid within 100 of their manager.
SELECT e.name FROM staff e JOIN staff m ON e.boss = m.id WHERE e.pay > m.pay;
SELECT e.name, m.pay - e.pay FROM staff e JOIN staff m ON e.boss = m.id WHERE m.pay - e.pay <= 100 ORDER BY e.id;
-- Number of direct reports per manager (including zero).
SELECT m.name, count(e.id) FROM staff m LEFT JOIN staff e ON e.boss = m.id GROUP BY m.id ORDER BY m.id;
-- Siblings: pairs sharing a boss, each pair once.
SELECT a.name, b.name FROM staff a JOIN staff b ON a.boss = b.boss AND a.id < b.id ORDER BY a.id, b.id;
-- Rank by counting higher-paid colleagues.
SELECT s.name, count(h.id) + 1 AS rnk FROM staff s LEFT JOIN staff h ON h.pay > s.pay GROUP BY s.id ORDER BY rnk, s.name;
-- Comma-style self-join.
SELECT a.name, b.name FROM staff a, staff b WHERE a.pay = b.pay + 10 ORDER BY a.id;
-- Self-join with USING on a column pair.
CREATE TABLE edge(src INTEGER, dst INTEGER);
INSERT INTO edge VALUES (1, 2), (2, 3), (3, 1), (2, 4), (4, 4);
SELECT e1.src, e1.dst, e2.dst FROM edge e1 JOIN edge e2 ON e1.dst = e2.src ORDER BY 1, 2, 3;
-- Edges that have a reverse edge.
SELECT e1.src, e1.dst FROM edge e1 JOIN edge e2 ON e1.src = e2.dst AND e1.dst = e2.src ORDER BY 1, 2;
-- Triangles.
SELECT count(*) FROM edge a JOIN edge b ON a.dst = b.src JOIN edge c ON b.dst = c.src AND c.dst = a.src;
