-- Every constraint form in one place: named constraints, several
-- constraints on one column in any order, table constraints, conflict
-- clauses, and REFERENCES / FOREIGN KEY clauses (parsed, not enforced).
CREATE TABLE parent(id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE t(
  id INTEGER CONSTRAINT pk PRIMARY KEY ASC ON CONFLICT ABORT,
  a TEXT CONSTRAINT a_nn NOT NULL ON CONFLICT FAIL CONSTRAINT a_uq UNIQUE DEFAULT 'none' COLLATE NOCASE,
  b INTEGER DEFAULT -1 CHECK (b <> 0) CONSTRAINT b_ref REFERENCES parent(id) ON DELETE CASCADE,
  c REAL DEFAULT +2.5 NOT NULL,
  d BLOB DEFAULT x'00' UNIQUE ON CONFLICT IGNORE,
  pid INTEGER,
  CONSTRAINT two UNIQUE (b, c),
  CHECK (c >= 0),
  FOREIGN KEY (pid) REFERENCES parent(id) ON UPDATE SET NULL
);

INSERT INTO t(id) VALUES (1);
SELECT id, a, b, c, d, pid FROM t;

-- Foreign keys are not enforced: pid 999 has no parent row.
INSERT INTO t(id, a, b, d, pid) VALUES (2, 'x', 5, x'01', 999);
SELECT id, a, b, c, d, pid FROM t ORDER BY id;

-- a is NOT NULL, UNIQUE and NOCASE.
INSERT INTO t(id, a, d) VALUES (3, NULL, x'02');
INSERT INTO t(id, a, b, d) VALUES (3, 'X', 8, x'02');
-- b CHECK.
INSERT INTO t(id, a, b, d) VALUES (3, 'y', 0, x'03');
-- UNIQUE(b, c): (5, 2.5) exists.
INSERT INTO t(id, a, b, d) VALUES (3, 'y', 5, x'04');
-- Table CHECK on c.
INSERT INTO t(id, a, b, c, d) VALUES (3, 'y', 6, -1, x'05');
-- d UNIQUE ON CONFLICT IGNORE: silently skipped.
INSERT INTO t(id, a, b, d) VALUES (3, 'y', 7, x'00');
SELECT id, a, b, c, d FROM t ORDER BY id;
-- A valid row.
INSERT INTO t(id, a, b, d) VALUES (3, 'y', 7, x'06');
SELECT id, a, b, c, d FROM t ORDER BY id;

-- Column constraints without a type, and a table with only constraints
-- after the columns.
CREATE TABLE u(x NOT NULL UNIQUE, y CHECK (y > 0) DEFAULT 1, UNIQUE (x, y), PRIMARY KEY (y, x));
INSERT INTO u(x) VALUES ('p');
INSERT INTO u VALUES ('q', 2);
INSERT INTO u VALUES ('p', 3);
SELECT x, y FROM u ORDER BY x;

-- Deleting a referenced parent row is allowed (no enforcement).
INSERT INTO parent VALUES (5, 'five');
DELETE FROM parent WHERE id = 5;
SELECT id, b FROM t WHERE b = 5;

-- IF NOT EXISTS with constraints.
CREATE TABLE IF NOT EXISTS t(z UNIQUE);
SELECT id FROM t ORDER BY id;
