-- Restrictions on ALTER TABLE ADD COLUMN, each checked after the failure to
-- confirm nothing changed.
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO t VALUES (1, 'a');
CREATE VIEW tv AS SELECT * FROM t;

-- Duplicate column name (case-insensitive).
ALTER TABLE t ADD COLUMN name TEXT;
-- PRIMARY KEY and UNIQUE columns cannot be added.
ALTER TABLE t ADD COLUMN k INTEGER PRIMARY KEY;
ALTER TABLE t ADD COLUMN u TEXT UNIQUE;
-- NOT NULL without a non-NULL default cannot be added.
ALTER TABLE t ADD COLUMN nn TEXT NOT NULL;
-- Unknown table, or a view.
ALTER TABLE nosuch ADD COLUMN x;
ALTER TABLE tv ADD COLUMN x;
-- The table is unchanged.
SELECT * FROM t;
SELECT count(*) FROM tv;
-- Valid additions after the errors.
ALTER TABLE t ADD COLUMN nn TEXT NOT NULL DEFAULT '';
ALTER TABLE t ADD COLUMN u TEXT;
CREATE UNIQUE INDEX t_u ON t(u);
INSERT INTO t(id, name, u) VALUES (2, 'b', 'x');
INSERT INTO t(id, name, u) VALUES (3, 'c', 'x');
INSERT INTO t(id, name) VALUES (3, 'c');
SELECT id, name, '[' || nn || ']', u FROM t ORDER BY id;
-- The view expands * to the current columns.
SELECT * FROM tv ORDER BY id;
-- Adding a column with a negative or quoted default.
ALTER TABLE t ADD COLUMN neg INTEGER DEFAULT -7;
ALTER TABLE t ADD COLUMN q TEXT DEFAULT 'it''s';
SELECT neg, q FROM t WHERE id = 1;
SELECT count(*) FROM t WHERE neg = -7 AND q = 'it''s';
-- Adding many columns in sequence.
ALTER TABLE t ADD COLUMN c1;
ALTER TABLE t ADD COLUMN c2 DEFAULT 2;
ALTER TABLE t ADD COLUMN c3 DEFAULT 3;
SELECT c1, c2, c3 FROM t WHERE id = 2;
-- Rows inserted before and after each ADD COLUMN see consistent values.
INSERT INTO t(id, name) VALUES (4, 'd');
SELECT id, c2, c3, neg FROM t ORDER BY id;
UPDATE t SET c1 = id * 2;
SELECT sum(c1), count(c1) FROM t;
SELECT count(*) FROM tv WHERE c3 = 3;
