-- Column and table constraints must be parsed in M1 (they are enforced from
-- M3). The inserted data satisfies every constraint and every column gets
-- an explicit value, so the results do not depend on enforcement.

CREATE TABLE people(
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT UNIQUE,
  age INTEGER CHECK (age >= 0),
  country TEXT DEFAULT 'NZ',
  score REAL DEFAULT 0.0,
  note TEXT DEFAULT NULL
);
INSERT INTO people VALUES (1, 'Ann', 'ann@example.com', 30, 'AU', 9.5, 'x');
INSERT INTO people VALUES (2, 'Bob', 'bob@example.com', 25, 'NZ', 7.0, NULL);
SELECT * FROM people ORDER BY id;
-- Named constraints, conflict clauses, sort order on PRIMARY KEY.
CREATE TABLE k(
  a INTEGER CONSTRAINT pk PRIMARY KEY ASC,
  b TEXT CONSTRAINT nn NOT NULL ON CONFLICT ABORT,
  c TEXT CONSTRAINT uq UNIQUE ON CONFLICT REPLACE,
  d INTEGER DEFAULT -1,
  e INTEGER DEFAULT +5,
  f TEXT DEFAULT (1 + 2),
  g TEXT COLLATE BINARY
);
INSERT INTO k VALUES (1, 'b', 'c', 4, 5, 'f', 'g');
SELECT * FROM k;
-- Table-level constraints, including multi-column keys and foreign keys.
CREATE TABLE orders(
  order_id INTEGER,
  line INTEGER,
  customer INTEGER REFERENCES people(id) ON DELETE CASCADE,
  qty INTEGER NOT NULL CHECK (qty > 0),
  PRIMARY KEY (order_id, line),
  UNIQUE (customer, order_id, line),
  CHECK (line >= 1),
  CONSTRAINT fk FOREIGN KEY (customer) REFERENCES people (id)
    ON UPDATE SET NULL DEFERRABLE INITIALLY DEFERRED
);
INSERT INTO orders VALUES (100, 1, 1, 3), (100, 2, 1, 1), (101, 1, 2, 7);
SELECT * FROM orders ORDER BY order_id, line;
-- AUTOINCREMENT and PRIMARY KEY DESC on a non-integer column.
CREATE TABLE seq(id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT);
INSERT INTO seq VALUES (10, 'ten'), (20, 'twenty');
SELECT id, v FROM seq ORDER BY id;
CREATE TABLE codes(code TEXT PRIMARY KEY DESC, label TEXT NOT NULL DEFAULT 'none');
INSERT INTO codes VALUES ('b', 'bee'), ('a', 'ay');
SELECT code, label FROM codes ORDER BY code;
-- A column whose declared type is omitted can still carry constraints.
CREATE TABLE notype(x PRIMARY KEY, y UNIQUE NOT NULL, z REFERENCES people);
INSERT INTO notype VALUES (1, 2, 1);
SELECT x, y, z FROM notype;
