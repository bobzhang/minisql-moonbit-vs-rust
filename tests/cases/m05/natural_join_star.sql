-- * expansion with NATURAL joins: shared columns appear once, in the left
-- table's column order, followed by the left table's other columns, then the
-- right table's non-shared columns.
CREATE TABLE a(k1 INTEGER, v TEXT, k2 INTEGER);
CREATE TABLE b(k2 INTEGER, w TEXT, k1 INTEGER);
CREATE TABLE c(w TEXT, z TEXT);
INSERT INTO a VALUES (1, 'v1', 10), (2, 'v2', 20), (3, 'v3', 30);
INSERT INTO b VALUES (10, 'w1', 1), (20, 'w2', 2), (99, 'w9', 3);
INSERT INTO c VALUES ('w1', 'z1'), ('w2', 'z2');

SELECT * FROM a NATURAL JOIN b ORDER BY k1;
SELECT * FROM b NATURAL JOIN a ORDER BY k1;
-- Qualified stars are unaffected by NATURAL.
SELECT a.* FROM a NATURAL JOIN b ORDER BY k1;
SELECT b.* FROM a NATURAL JOIN b ORDER BY k1;
-- Three-way natural join: c shares w with b.
SELECT * FROM a NATURAL JOIN b NATURAL JOIN c ORDER BY k1;
-- NATURAL LEFT JOIN keeps a's unmatched row; b's own columns are NULL.
SELECT * FROM a NATURAL LEFT JOIN b ORDER BY k1;
-- NATURAL RIGHT JOIN keeps b's unmatched row; shared columns come from b there.
SELECT * FROM a NATURAL RIGHT JOIN b ORDER BY k2;
-- NATURAL FULL JOIN.
SELECT * FROM a NATURAL FULL JOIN b ORDER BY k2, k1;
-- Star mixed with other expressions.
SELECT k1 * 100 + k2, * FROM a NATURAL JOIN b ORDER BY 1;
-- A natural join between a table and a copy of itself matches every row with itself.
SELECT * FROM a NATURAL JOIN a AS a2 ORDER BY k1;
SELECT count(*) FROM a NATURAL JOIN a AS a2;
-- ...except rows containing a NULL in any column.
INSERT INTO a VALUES (4, NULL, 40);
SELECT count(*) FROM a NATURAL JOIN a AS a2;
