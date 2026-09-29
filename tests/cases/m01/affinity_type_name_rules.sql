-- Column affinity is derived from the declared type name by SQLite's rules,
-- applied in order:
--   1. contains "INT"                     -> INTEGER
--   2. contains "CHAR", "CLOB" or "TEXT"  -> TEXT
--   3. contains "BLOB" or no type          -> BLOB
--   4. contains "REAL", "FLOA" or "DOUB"  -> REAL
--   5. otherwise                          -> NUMERIC
-- Each column below receives the text '5.0' and the integer 7; the stored
-- types reveal the affinity.

CREATE TABLE t(
  a FLOATING POINT,   -- "POINT" contains INT: INTEGER
  b CHARINT,          -- rule 1 before rule 2: INTEGER
  c STRING,           -- no rule matches: NUMERIC
  d TEXTBLOB,         -- rule 2 before rule 3: TEXT
  e BLOBREAL,         -- rule 3 before rule 4: BLOB
  f DOUBLECHAR,       -- rule 2 before rule 4: TEXT
  g INTERVAL,         -- contains INT: INTEGER
  h VARBINARY,        -- no rule matches: NUMERIC
  i FLOAT,            -- REAL
  j NOTEXT,           -- contains TEXT: TEXT
  k                   -- no type: BLOB
);
INSERT INTO t VALUES ('5.0', '5.0', '5.0', '5.0', '5.0', '5.0', '5.0', '5.0', '5.0', '5.0', '5.0');
INSERT INTO t VALUES (7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7);
SELECT typeof(a), typeof(b), typeof(c), typeof(d), typeof(e), typeof(f), typeof(g), typeof(h), typeof(i), typeof(j), typeof(k)
  FROM t ORDER BY typeof(k) DESC;
SELECT a, b, c, d, e, f, g, h, i, j, k FROM t ORDER BY typeof(k) DESC;
-- Case does not matter in the type name.
CREATE TABLE u(a int, b Char(3), c blob, d real, e numeric, f dOuBlE);
INSERT INTO u VALUES ('5.0', 5, 5, '5', '5.0', '5');
SELECT a, typeof(a), b, typeof(b), c, typeof(c), d, typeof(d), e, typeof(e), f, typeof(f) FROM u;
-- Type arguments do not affect affinity.
CREATE TABLE v(a VARCHAR(10), b DECIMAL(5, 2), c INT(11), d FLOAT(24));
INSERT INTO v VALUES (1, '2.50', '3', '4');
SELECT a, typeof(a), b, typeof(b), c, typeof(c), d, typeof(d) FROM v;
