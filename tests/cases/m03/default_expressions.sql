-- DEFAULT clauses: literals, signed numbers, parenthesized expressions,
-- and affinity applied to the default value.
CREATE TABLE d(
  a DEFAULT (1 + 2),
  b DEFAULT -5,
  c DEFAULT +3.5,
  e DEFAULT 'txt',
  f DEFAULT x'0102',
  g DEFAULT NULL,
  h DEFAULT TRUE,
  i INTEGER DEFAULT '12',
  j TEXT DEFAULT 7,
  k DEFAULT (abs(-3) || 'z'),
  l DEFAULT -0x10,
  m REAL DEFAULT 2,
  n DEFAULT (upper('ab') || lower('CD')),
  o DEFAULT FALSE,
  p DEFAULT 1e3,
  q DEFAULT (NULL IS NULL),
  z
);
INSERT INTO d(z) VALUES ('row1');
SELECT a, typeof(a), b, typeof(b), c, typeof(c), e, f, g FROM d;
SELECT h, typeof(h), i, typeof(i), j, typeof(j), k, l FROM d;
SELECT m, typeof(m), n, o, p, typeof(p), q FROM d;

-- Defaults are evaluated per row.
INSERT INTO d(z) VALUES ('row2');
SELECT z, a, k FROM d ORDER BY z;

-- Explicit values override defaults.
INSERT INTO d(a, b, z) VALUES ('given', 99, 'row3');
SELECT z, a, b FROM d ORDER BY z;

-- A default with a CASE expression.
CREATE TABLE c(x, tag DEFAULT (CASE WHEN 1 > 2 THEN 'no' ELSE 'yes' END));
INSERT INTO c(x) VALUES (1);
SELECT x, tag FROM c;

-- Defaults with NUMERIC affinity.
CREATE TABLE nm(v NUMERIC DEFAULT '3.0', w NUMERIC DEFAULT '0x10', y);
INSERT INTO nm(y) VALUES (1);
SELECT v, typeof(v), w, typeof(w) FROM nm;

-- UPDATE does not use defaults.
UPDATE d SET a = NULL WHERE z = 'row1';
SELECT z, a FROM d ORDER BY z;

-- A default may not reference a column.
CREATE TABLE bad(a, b DEFAULT (a + 1));
-- An unparenthesized expression is not allowed.
CREATE TABLE bad2(a DEFAULT 1 + 2);
SELECT * FROM bad;
