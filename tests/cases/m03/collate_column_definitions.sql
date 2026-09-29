-- COLLATE in column definitions: the declared collation is used by
-- comparisons, ORDER BY, DISTINCT and UNIQUE on that column, and can be
-- combined with other constraints in any order.
CREATE TABLE t(
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL COLLATE NOCASE,
  code TEXT COLLATE RTRIM UNIQUE,
  raw TEXT COLLATE BINARY DEFAULT 'x'
);
INSERT INTO t(name, code, raw) VALUES ('Alice', 'A1', 'ALICE'), ('bob', 'b2  ', 'bob'), ('CAROL', 'c3', 'carol');

-- WHERE comparisons use the column's collation.
SELECT id FROM t WHERE name = 'alice';
SELECT id FROM t WHERE raw = 'alice';
SELECT id FROM t WHERE raw = 'ALICE';
SELECT id FROM t WHERE code = 'b2';
SELECT id FROM t WHERE name > 'b' ORDER BY id;
SELECT id FROM t WHERE name IN ('ALICE', 'Bob') ORDER BY id;
SELECT id FROM t WHERE name BETWEEN 'a' AND 'BZZ' ORDER BY id;

-- ORDER BY uses it.
SELECT name FROM t ORDER BY name;
SELECT raw FROM t ORDER BY raw;

-- UNIQUE uses it: 'b2' equals 'b2  ' under RTRIM.
INSERT INTO t(name, code) VALUES ('dave', 'b2');
INSERT INTO t(name, code) VALUES ('dave', ' b2');
SELECT id, name, '[' || code || ']' FROM t ORDER BY id;

-- The collation of the left operand wins when both columns have one;
-- an explicit COLLATE overrides both.
SELECT id FROM t WHERE name = raw ORDER BY id;
SELECT id FROM t WHERE raw = name ORDER BY id;
SELECT id FROM t WHERE raw = name COLLATE NOCASE ORDER BY id;

-- Collation is part of the column, so it survives UPDATE.
UPDATE t SET name = 'ALICE' WHERE id = 1;
SELECT id FROM t WHERE name = 'alice';

-- A column copied with INSERT ... SELECT takes the target column's collation.
CREATE TABLE c(v TEXT);
INSERT INTO c SELECT name FROM t;
SELECT v FROM c WHERE v = 'alice';
SELECT v FROM c WHERE v = 'ALICE';

-- COLLATE before other constraints and with a type-less column.
CREATE TABLE d(k COLLATE NOCASE PRIMARY KEY, v);
INSERT INTO d VALUES ('Key', 1);
INSERT INTO d VALUES ('KEY', 2);
SELECT k, v FROM d WHERE k = 'key';

-- Unknown collation names are rejected when the table is created.
CREATE TABLE bad(a TEXT COLLATE nosuch);
