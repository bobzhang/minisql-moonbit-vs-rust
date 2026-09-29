-- Name scoping between queries and subqueries: inner names shadow outer
-- names, derived-table aliases hide the inner tables, and an unqualified name
-- that is not found inside falls back to the enclosing query.
CREATE TABLE t(id INTEGER, v TEXT);
CREATE TABLE u(id INTEGER, w TEXT);
INSERT INTO t VALUES (1, 't1'), (2, 't2'), (3, 't3');
INSERT INTO u VALUES (2, 'u2'), (3, 'u3'), (4, 'u4');

-- Unqualified id inside refers to u.id (innermost), so the subquery is uncorrelated.
SELECT id, (SELECT count(*) FROM u WHERE id > 2) FROM t ORDER BY id;
-- Qualified t.id inside refers to the outer row.
SELECT id, (SELECT count(*) FROM u WHERE u.id > t.id) FROM t ORDER BY id;
-- v exists only in t, so inside a subquery over u it refers to the outer row.
SELECT id, (SELECT group_concat(w || v, ',') FROM (SELECT w FROM u ORDER BY w)) FROM t ORDER BY id;
-- Same table in both levels: the inner alias shadows.
SELECT id, (SELECT max(id) FROM t) FROM t ORDER BY id;
SELECT id, (SELECT max(t2.id) FROM t t2 WHERE t2.id < t.id) FROM t ORDER BY id;
-- The inner table can reuse the outer table's name; the inner one wins.
SELECT t.id, (SELECT count(*) FROM u AS t WHERE t.id >= 3) FROM t ORDER BY t.id;
-- Derived-table columns are only visible through the derived table.
SELECT s.x FROM (SELECT id AS x FROM t) s ORDER BY s.x;
SELECT x FROM (SELECT id AS x FROM t) ORDER BY x;
-- A derived table cannot see sibling FROM items.
SELECT count(*) FROM t, (SELECT w FROM u) WHERE w > v;
-- Result aliases of the outer query are not visible inside a subquery's FROM tables,
-- but outer columns are visible in the subquery's WHERE.
SELECT v, (SELECT w FROM u WHERE u.id = t.id + 1) AS nxt FROM t ORDER BY v;
-- The same alias used at two levels.
SELECT a.id, (SELECT count(*) FROM u a WHERE a.id > 2) FROM t a ORDER BY a.id;
-- Errors: a derived table's inner alias is not visible outside.
SELECT inner_t.id FROM (SELECT id FROM t AS inner_t);
-- A column of a subquery's table is not visible in the outer query.
SELECT w FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.id = t.id);
