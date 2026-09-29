-- Renaming a table or column also updates the objects that refer to it:
-- indexes (including expression and partial indexes), views, and CHECK
-- constraints keep working under the new names.
CREATE TABLE t(a INTEGER, b TEXT UNIQUE, c INTEGER CHECK (c < 100));
CREATE INDEX t_c_part ON t(c) WHERE a > 0;
CREATE INDEX t_lower_b ON t(lower(b));
CREATE VIEW pos AS SELECT a, b, t.c FROM t WHERE t.a > 0;
CREATE VIEW pairs AS SELECT x.b AS left_b, y.b AS right_b FROM t AS x JOIN t AS y ON x.a + 1 = y.a;
INSERT INTO t VALUES (1, 'x', 10), (2, 'y', 20), (-1, 'z', 30);

ALTER TABLE t RENAME COLUMN a TO aa;
ALTER TABLE t RENAME COLUMN c TO cc;
SELECT * FROM pos ORDER BY 1;
SELECT left_b, right_b FROM pairs ORDER BY left_b;
-- The CHECK constraint follows the renamed column.
INSERT INTO t VALUES (3, 'w', 500);
INSERT INTO t VALUES (3, 'w', 50);
SELECT * FROM pos ORDER BY 1;
-- Renaming the table: views and indexes follow.
ALTER TABLE t RENAME TO base;
SELECT * FROM pos ORDER BY 1;
SELECT left_b, right_b FROM pairs ORDER BY left_b;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
-- Uniqueness via the automatic index still enforced after both renames.
INSERT INTO base VALUES (4, 'x', 1);
ALTER TABLE base RENAME COLUMN b TO bb;
INSERT INTO base VALUES (4, 'y', 1);
INSERT INTO base VALUES (4, 'v', 1);
SELECT aa, bb, cc FROM base ORDER BY aa;
SELECT * FROM pos ORDER BY 1;
-- Queries on the renamed columns.
SELECT aa FROM base WHERE lower(bb) = 'v';
SELECT aa FROM base WHERE aa > 0 AND cc = 20;
-- Old names are gone.
SELECT a FROM base;
SELECT * FROM t;
