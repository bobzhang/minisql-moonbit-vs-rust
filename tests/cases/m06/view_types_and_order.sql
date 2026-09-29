-- Column properties seen through views: declared affinity and collation of
-- base columns are kept for plain column references, while expressions have
-- none; ORDER BY inside a view does not order the outer query unless the
-- outer query asks.
CREATE TABLE t(i INTEGER, s TEXT, c TEXT COLLATE NOCASE);
INSERT INTO t VALUES (1, '1', 'Apple'), (2, '10', 'banana'), (10, '2', 'CHERRY');
CREATE VIEW v AS SELECT i, s, c, i + 0 AS e, s || '' AS se FROM t;

-- s keeps TEXT affinity: comparing with a number converts the number.
SELECT count(*) FROM v WHERE s = 1;
-- i keeps INTEGER affinity.
SELECT count(*) FROM v WHERE i = '10';
-- An expression column has no affinity: 1 and '1' differ.
SELECT count(*) FROM v WHERE e = '1';
SELECT count(*) FROM v WHERE se = 1;
-- Ordering follows the storage class: s sorts as text, i as numbers.
SELECT s FROM v ORDER BY s;
SELECT i FROM v ORDER BY i;
-- c keeps its NOCASE collation through the view.
SELECT c FROM v WHERE c = 'apple';
SELECT c FROM v ORDER BY c;
SELECT c FROM v ORDER BY c COLLATE BINARY;
-- typeof values pass through unchanged.
SELECT typeof(i), typeof(s), typeof(e), typeof(se) FROM v WHERE i = 1;
-- A view with ORDER BY and LIMIT: the rows chosen are fixed by the view.
CREATE VIEW first2 AS SELECT i FROM t ORDER BY i DESC LIMIT 2;
SELECT i FROM first2 ORDER BY i;
SELECT sum(i) FROM first2;
-- A view over a compound with ORDER BY inside.
CREATE VIEW combo AS SELECT s AS x FROM t UNION SELECT c FROM t ORDER BY 1;
SELECT x FROM combo ORDER BY x;
SELECT count(*) FROM combo;
-- DISTINCT through a NOCASE column collapses case variants.
INSERT INTO t VALUES (3, '3', 'apple');
CREATE VIEW dc AS SELECT DISTINCT c FROM t;
SELECT count(*) FROM dc;
