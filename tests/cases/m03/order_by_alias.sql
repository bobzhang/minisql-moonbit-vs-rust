-- ORDER BY may name a result-column alias. An alias takes precedence over a
-- table column of the same name when the ORDER BY term is a bare identifier.
CREATE TABLE t(a INTEGER, b TEXT, c REAL);
INSERT INTO t VALUES (3, 'pear', 1.5), (1, 'apple', 9.25), (2, 'fig', -4.0), (5, 'kiwi', 0.0), (4, 'date', 2.5);

-- Plain alias.
SELECT a AS k, b FROM t ORDER BY k;
SELECT a AS k, b FROM t ORDER BY k DESC;
SELECT b AS name FROM t ORDER BY name;

-- Alias of an expression.
SELECT a * -1 AS neg, b FROM t ORDER BY neg;
SELECT length(b) AS len, b FROM t ORDER BY len, b;
SELECT a % 2 AS parity, a FROM t ORDER BY parity DESC, a ASC;

-- Alias that shadows a real column: "c" here is the alias for -a, so the
-- ordering follows -a, not the stored column c.
SELECT b, -a AS c FROM t ORDER BY c;
-- The alias "a" means column b here, so rows sort alphabetically by b.
SELECT b AS a, a AS b FROM t ORDER BY a;
SELECT b AS a, a AS b FROM t ORDER BY b;

-- Quoted and mixed-case aliases resolve case-insensitively.
SELECT a AS "Sort Key", b FROM t ORDER BY "Sort Key" DESC;
SELECT c AS Score, b FROM t ORDER BY SCORE;

-- A table column not in the select list is fine too.
SELECT b FROM t ORDER BY c DESC;
SELECT b FROM t ORDER BY t.a;

-- Alias combined with WHERE and LIMIT.
SELECT a + 10 AS shifted FROM t WHERE a > 1 ORDER BY shifted DESC LIMIT 2;

-- Alias with the ORDER BY COLLATE clause.
CREATE TABLE w(s TEXT);
INSERT INTO w VALUES ('b'), ('A'), ('c'), ('B2');
SELECT s AS word FROM w ORDER BY word;
SELECT s AS word FROM w ORDER BY word COLLATE NOCASE;

-- Unknown names in ORDER BY are errors.
SELECT a AS k FROM t ORDER BY nosuch;
SELECT a AS k FROM t ORDER BY k, missing DESC;
