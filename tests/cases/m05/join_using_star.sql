-- * expansion with USING: each USING column appears once, at the position of
-- the left table's column; the right table's copy is omitted. table.* still
-- lists all of that table's own columns.
CREATE TABLE a(id INTEGER, x TEXT, y TEXT);
CREATE TABLE b(y TEXT, z TEXT, id INTEGER);
CREATE TABLE c(z TEXT, w TEXT, id INTEGER);
INSERT INTO a VALUES (1, 'x1', 'y1'), (2, 'x2', 'y2');
INSERT INTO b VALUES ('y1', 'z1', 1), ('y9', 'z2', 2);
INSERT INTO c VALUES ('z1', 'w1', 1), ('z2', 'w2', 2);

SELECT * FROM a JOIN b USING (id) ORDER BY id;
SELECT * FROM a JOIN b USING (id, y) ORDER BY id;
SELECT * FROM b JOIN a USING (id) ORDER BY id;
-- Qualified stars keep all columns of that table.
SELECT a.* FROM a JOIN b USING (id) ORDER BY id;
SELECT b.* FROM a JOIN b USING (id) ORDER BY id;
SELECT b.*, a.* FROM a JOIN b USING (id, y) ORDER BY id;
-- Mixing * with extra expressions.
SELECT *, a.id + b.id FROM a JOIN b USING (id) ORDER BY id;
-- Three tables: id is shared by all three and appears once.
SELECT * FROM a JOIN b USING (id) JOIN c USING (id) ORDER BY id;
-- The second USING can name a column from the middle table.
SELECT * FROM a JOIN b USING (id) JOIN c USING (z) ORDER BY id;
-- Star over a LEFT JOIN USING.
INSERT INTO a VALUES (3, 'x3', 'y3');
SELECT * FROM a LEFT JOIN b USING (id) ORDER BY id;
SELECT * FROM a LEFT JOIN b USING (id, y) ORDER BY id;
-- Counting output columns indirectly via a FROM-subquery.
SELECT count(*) FROM (SELECT * FROM a JOIN b USING (id, y));
