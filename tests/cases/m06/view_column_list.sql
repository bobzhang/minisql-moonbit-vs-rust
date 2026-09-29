-- CREATE VIEW name(col, ...) AS select: the column list renames the view's
-- columns positionally.
CREATE TABLE t(a INTEGER, b TEXT, c REAL);
INSERT INTO t VALUES (1, 'x', 1.5), (2, 'y', 2.5), (3, 'z', NULL);
CREATE VIEW v(num, letter, amount) AS SELECT a, b, c FROM t;

SELECT num, letter, amount FROM v ORDER BY num;
SELECT * FROM v ORDER BY num DESC;
SELECT letter FROM v WHERE amount IS NULL;
-- The original column names are not visible through the view.
SELECT a FROM v;
SELECT v.b FROM v;
-- Column list over expressions.
CREATE VIEW sums(k, total, n) AS SELECT b, a + coalesce(c, 0), 1 FROM t;
SELECT k, total, n FROM sums ORDER BY total;
SELECT sum(total), count(n) FROM sums;
-- Column list over an aggregate query.
CREATE VIEW agg(cnt, mx, mn) AS SELECT count(*), max(a), min(b) FROM t;
SELECT * FROM agg;
SELECT cnt * mx FROM agg;
-- Column list over a compound query.
CREATE VIEW both_(val) AS SELECT a FROM t UNION SELECT 10;
SELECT val FROM both_ ORDER BY val;
-- Column list over a join.
CREATE TABLE u(a INTEGER, d TEXT);
INSERT INTO u VALUES (1, 'one'), (3, 'three');
CREATE VIEW j(id, word, letter) AS SELECT t.a, u.d, t.b FROM t JOIN u ON u.a = t.a;
SELECT id, word, letter FROM j ORDER BY id;
SELECT word FROM j WHERE id = 3;
-- Quoted column names in the list.
CREATE VIEW q("first col", [second]) AS SELECT a, b FROM t;
SELECT "first col", second FROM q ORDER BY 1;
-- A column list that does not match the number of result columns is an
-- error when the view is used.
CREATE VIEW bad(p, q) AS SELECT a, b, c FROM t;
SELECT * FROM bad;
