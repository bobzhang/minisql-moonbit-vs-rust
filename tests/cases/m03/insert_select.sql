-- INSERT INTO t [(cols)] SELECT ...
CREATE TABLE src(id INTEGER, name TEXT, score REAL);
INSERT INTO src VALUES (1, 'ann', 9.5), (2, 'bob', 7.0), (3, 'cy', NULL), (4, 'di', 8.25);

CREATE TABLE dst(id INTEGER, name TEXT, score REAL);
INSERT INTO dst SELECT * FROM src WHERE score > 7.5;
SELECT * FROM dst ORDER BY id;

-- Column list and expressions.
CREATE TABLE d2(label TEXT, n INTEGER, extra DEFAULT 'dflt');
INSERT INTO d2(n, label) SELECT id * 10, upper(name) FROM src;
SELECT label, n, extra FROM d2 ORDER BY n;

-- SELECT without FROM.
INSERT INTO d2 SELECT 'lit', 1, 2;
SELECT label, n, extra FROM d2 WHERE label = 'lit';

-- Selecting from the same table reads the rows as they were before the
-- statement started, so this doubles the table exactly once.
CREATE TABLE self(v INTEGER);
INSERT INTO self VALUES (1), (2), (3);
INSERT INTO self SELECT v + 10 FROM self;
SELECT v FROM self ORDER BY v;

-- Affinity of the target columns is applied to selected values.
CREATE TABLE aff(i INTEGER, t TEXT, r REAL);
INSERT INTO aff SELECT '7', 8, '9' ;
INSERT INTO aff SELECT name, id, id FROM src WHERE id = 1;
SELECT i, typeof(i), t, typeof(t), r, typeof(r) FROM aff ORDER BY t;

-- ORDER BY and LIMIT in the SELECT decide which rows are inserted and the
-- order in which they get rowids.
CREATE TABLE ranked(name TEXT);
INSERT INTO ranked SELECT name FROM src ORDER BY score DESC LIMIT 3;
SELECT rowid, name FROM ranked ORDER BY rowid;

-- DISTINCT in the SELECT.
CREATE TABLE g(k);
INSERT INTO g SELECT DISTINCT id % 2 FROM src;
SELECT k FROM g ORDER BY k;

-- Empty SELECT inserts nothing.
INSERT INTO g SELECT id FROM src WHERE id > 100;
SELECT k FROM g ORDER BY k;

-- Errors: column count mismatch, unknown source table, unknown column.
INSERT INTO dst SELECT id, name FROM src;
INSERT INTO dst(id) SELECT id, name FROM src;
INSERT INTO dst SELECT * FROM nosuch;
INSERT INTO dst(nosuch) SELECT id FROM src;
SELECT * FROM dst ORDER BY id;
