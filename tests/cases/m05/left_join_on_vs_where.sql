-- For outer joins, ON and WHERE differ: an ON condition decides which right
-- rows match (unmatched left rows survive with NULLs), while WHERE filters
-- the joined result afterwards.
CREATE TABLE p(id INTEGER, name TEXT);
CREATE TABLE c(pid INTEGER, kind TEXT, qty INTEGER);
INSERT INTO p VALUES (1, 'one'), (2, 'two'), (3, 'three');
INSERT INTO c VALUES (1, 'a', 10), (1, 'b', 20), (2, 'a', 30), (3, 'b', 40);

-- Filter on the right table inside ON: all p rows kept.
SELECT name, kind, qty FROM p LEFT JOIN c ON c.pid = p.id AND c.kind = 'a' ORDER BY p.id;
-- Same filter in WHERE: rows NULL-extended rows are removed (behaves like an inner join).
SELECT name, kind, qty FROM p LEFT JOIN c ON c.pid = p.id WHERE c.kind = 'a' ORDER BY p.id;
-- Filter on the left table inside ON: left rows failing it still appear, NULL-extended.
SELECT name, kind FROM p LEFT JOIN c ON c.pid = p.id AND p.id <> 2 ORDER BY p.id, kind;
-- Filter on the left table in WHERE: those left rows vanish entirely.
SELECT name, kind FROM p LEFT JOIN c ON c.pid = p.id WHERE p.id <> 2 ORDER BY p.id, kind;
-- WHERE ... IS NULL on the right side keeps only unmatched rows.
SELECT name FROM p LEFT JOIN c ON c.pid = p.id AND c.qty > 25 WHERE c.pid IS NULL ORDER BY p.id;
-- WHERE with OR IS NULL keeps NULL-extended rows as well.
SELECT name, kind FROM p LEFT JOIN c ON c.pid = p.id AND c.kind = 'b' WHERE c.qty > 15 OR c.qty IS NULL ORDER BY p.id;
-- Constant-false ON: all left rows NULL-extended; constant-false WHERE: no rows.
SELECT name, kind FROM p LEFT JOIN c ON c.pid = p.id AND 0 ORDER BY p.id;
SELECT name, kind FROM p LEFT JOIN c ON c.pid = p.id WHERE 0;
-- Aggregates show the difference clearly.
SELECT p.name, count(c.pid) FROM p LEFT JOIN c ON c.pid = p.id AND c.qty >= 30 GROUP BY p.id ORDER BY p.id;
SELECT p.name, count(c.pid) FROM p LEFT JOIN c ON c.pid = p.id WHERE c.qty >= 30 GROUP BY p.id ORDER BY p.id;
-- WHERE coalesce() over a NULL-extended column.
SELECT name, coalesce(qty, -1) FROM p LEFT JOIN c ON c.pid = p.id AND c.qty > 100 WHERE coalesce(qty, -1) = -1 ORDER BY p.id;
-- Comparing a NULL-extended column in WHERE is NULL, so the row is dropped.
SELECT count(*) FROM p LEFT JOIN c ON c.pid = p.id AND c.qty > 100 WHERE c.qty <> 5;
SELECT count(*) FROM p LEFT JOIN c ON c.pid = p.id AND c.qty > 100 WHERE NOT (c.qty = 5);
SELECT count(*) FROM p LEFT JOIN c ON c.pid = p.id AND c.qty > 100 WHERE c.qty IS NOT 5;
