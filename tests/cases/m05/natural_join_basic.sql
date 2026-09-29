-- NATURAL JOIN joins on every column name the two tables share (like USING
-- with all common columns); with no common columns it is a cross join.
CREATE TABLE person(pid INTEGER, name TEXT, city TEXT);
CREATE TABLE visit(pid INTEGER, city TEXT, yr INTEGER);
CREATE TABLE color(hue TEXT);
INSERT INTO person VALUES (1, 'ann', 'oslo'), (2, 'bo', 'rome'), (3, 'cy', NULL);
INSERT INTO visit VALUES (1, 'oslo', 2020), (1, 'rome', 2021), (2, 'rome', 2022), (3, NULL, 2023), (4, 'oslo', 2024);
INSERT INTO color VALUES ('red'), ('blue');

-- Joins on pid AND city.
SELECT name, city, yr FROM person NATURAL JOIN visit ORDER BY yr;
SELECT count(*) FROM person NATURAL JOIN visit;
-- Equivalent USING form.
SELECT name, city, yr FROM person JOIN visit USING (pid, city) ORDER BY yr;
-- NULLs in shared columns never match (cy's NULL city).
SELECT count(*) FROM person NATURAL JOIN visit WHERE name = 'cy';
-- No common columns: cross product.
SELECT name, hue FROM person NATURAL JOIN color ORDER BY name, hue;
SELECT count(*) FROM person NATURAL JOIN color;
-- NATURAL INNER JOIN is the same thing.
SELECT name, yr FROM person NATURAL INNER JOIN visit ORDER BY yr;
-- Shared columns may be used unqualified; qualified refs also work.
SELECT pid, person.pid, visit.pid, city FROM person NATURAL JOIN visit ORDER BY yr;
-- Case-insensitive column-name matching.
CREATE TABLE upper_t(PID INTEGER, Tag TEXT);
INSERT INTO upper_t VALUES (1, 't1'), (2, 't2');
SELECT name, tag FROM person NATURAL JOIN upper_t ORDER BY name;
-- NATURAL join with a FROM-subquery whose aliases define the shared columns.
SELECT name, bonus FROM person NATURAL JOIN (SELECT 2 AS pid, 50 AS bonus) ORDER BY name;
-- Aggregates over a natural join.
SELECT name, count(*) FROM person NATURAL JOIN visit GROUP BY name ORDER BY name;
-- Errors: NATURAL combined with ON or USING.
SELECT * FROM person NATURAL JOIN visit ON person.pid = visit.pid;
SELECT * FROM person NATURAL JOIN visit USING (pid);
