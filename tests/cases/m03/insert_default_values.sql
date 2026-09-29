-- INSERT INTO t DEFAULT VALUES and omitted columns taking their defaults.
CREATE TABLE t(id INTEGER PRIMARY KEY, a DEFAULT 1, b TEXT DEFAULT 'none', c REAL, d INTEGER DEFAULT -3);

INSERT INTO t DEFAULT VALUES;
SELECT * FROM t ORDER BY id;
INSERT INTO t DEFAULT VALUES;
SELECT * FROM t ORDER BY id;

-- Omitting columns from the column list uses their defaults (or NULL).
INSERT INTO t(b) VALUES ('given');
INSERT INTO t(c, a) VALUES (1.25, 'A');
SELECT * FROM t ORDER BY id;

-- Explicit NULL is not replaced by the default.
INSERT INTO t(a, b) VALUES (NULL, NULL);
SELECT id, a, b, d FROM t ORDER BY id;

-- DEFAULT VALUES on a table where every column has no default.
CREATE TABLE n(x, y);
INSERT INTO n DEFAULT VALUES;
INSERT INTO n DEFAULT VALUES;
SELECT rowid, x, y FROM n ORDER BY rowid;

-- DEFAULT VALUES fails if a NOT NULL column has no default...
CREATE TABLE nn(x NOT NULL, y DEFAULT 2);
INSERT INTO nn DEFAULT VALUES;
SELECT x, y FROM nn;
-- ...but works if it has one.
CREATE TABLE nd(x NOT NULL DEFAULT 'ok', y);
INSERT INTO nd DEFAULT VALUES;
SELECT x, y FROM nd;

-- Rowids keep increasing.
SELECT id FROM t ORDER BY id DESC LIMIT 1;

-- Errors: DEFAULT VALUES cannot take a column list.
INSERT INTO t(a) DEFAULT VALUES;
SELECT id, a, b FROM t ORDER BY id;
