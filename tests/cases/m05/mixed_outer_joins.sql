-- Sequences of different join kinds are evaluated left to right:
-- "a LEFT JOIN b RIGHT JOIN c" is "(a LEFT JOIN b) RIGHT JOIN c".
CREATE TABLE a(id INTEGER, av TEXT);
CREATE TABLE b(id INTEGER, bv TEXT);
CREATE TABLE c(id INTEGER, cv TEXT);
INSERT INTO a VALUES (1, 'a1'), (2, 'a2'), (3, 'a3');
INSERT INTO b VALUES (2, 'b2'), (3, 'b3'), (4, 'b4');
INSERT INTO c VALUES (3, 'c3'), (4, 'c4'), (5, 'c5');

-- LEFT then LEFT.
SELECT av, bv, cv FROM a LEFT JOIN b ON a.id = b.id LEFT JOIN c ON b.id = c.id ORDER BY av;
-- LEFT then LEFT, with the second join keyed on a instead of b.
SELECT av, bv, cv FROM a LEFT JOIN b ON a.id = b.id LEFT JOIN c ON a.id = c.id ORDER BY av;
-- LEFT then INNER on b: rows where b is NULL cannot match.
SELECT av, bv, cv FROM a LEFT JOIN b ON a.id = b.id JOIN c ON b.id = c.id ORDER BY av;
-- INNER then RIGHT.
SELECT av, bv, cv FROM a JOIN b ON a.id = b.id RIGHT JOIN c ON b.id = c.id ORDER BY cv;
-- LEFT then RIGHT.
SELECT av, bv, cv FROM a LEFT JOIN b ON a.id = b.id RIGHT JOIN c ON c.id = b.id ORDER BY cv, av;
-- RIGHT then LEFT.
SELECT av, bv, cv FROM a RIGHT JOIN b ON a.id = b.id LEFT JOIN c ON c.id = b.id ORDER BY bv;
-- FULL then FULL on a coalesced key.
SELECT av, bv, cv FROM a FULL JOIN b ON a.id = b.id FULL JOIN c ON c.id = coalesce(a.id, b.id) ORDER BY coalesce(a.id, b.id, c.id);
-- FULL then INNER.
SELECT av, bv, cv FROM a FULL JOIN b ON a.id = b.id JOIN c ON c.id = b.id ORDER BY cv;
-- RIGHT then RIGHT.
SELECT av, bv, cv FROM a RIGHT JOIN b ON a.id = b.id RIGHT JOIN c ON c.id = b.id ORDER BY cv;
-- Counts for each combination.
SELECT count(*), count(av), count(bv), count(cv) FROM a LEFT JOIN b ON a.id = b.id LEFT JOIN c ON c.id = b.id;
SELECT count(*), count(av), count(bv), count(cv) FROM a FULL JOIN b ON a.id = b.id FULL JOIN c ON c.id = b.id;
SELECT count(*), count(av), count(bv), count(cv) FROM a RIGHT JOIN b ON a.id = b.id FULL JOIN c ON c.id = a.id;
-- WHERE after a mix of outer joins.
SELECT av, bv, cv FROM a LEFT JOIN b ON a.id = b.id FULL JOIN c ON c.id = b.id WHERE av IS NULL OR cv IS NULL ORDER BY av, bv, cv;
