-- @db file
-- Column-level COLLATE clauses in the stored schema determine how the
-- engine compares, sorts, groups and deduplicates those columns, including
-- through an index declared on them. RTRIM is included too.
-- @phase sqlite
CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT COLLATE NOCASE, code TEXT COLLATE RTRIM, city TEXT);
CREATE INDEX people_name ON people(name);
CREATE INDEX people_city_nocase ON people(city COLLATE NOCASE);
INSERT INTO people VALUES
  (1, 'alice', 'A1', 'Paris'), (2, 'Alice', 'A1  ', 'paris'), (3, 'BOB', 'B2', 'Rome'),
  (4, 'bob', 'b2', 'ROME'), (5, 'Carol', 'C3 ', 'Oslo'), (6, 'dave', 'D4', 'oslo'),
  (7, 'Émile', 'E5', 'Lyon'), (8, 'émile', 'E5', 'lyon');
-- @phase engine
SELECT id FROM people WHERE name = 'ALICE' ORDER BY id;
SELECT id FROM people WHERE code = 'A1' ORDER BY id;
SELECT id FROM people WHERE city = 'paris' ORDER BY id;
SELECT id FROM people WHERE city = 'paris' COLLATE NOCASE ORDER BY id;
SELECT name, id FROM people ORDER BY name, id;
SELECT count(DISTINCT name), count(DISTINCT code), count(DISTINCT city) FROM people;
-- Which spelling represents a NOCASE group is unspecified, so print lower().
SELECT lower(name), count(*) FROM people GROUP BY name ORDER BY 1;
SELECT id FROM people WHERE name > 'b' ORDER BY id;
SELECT id FROM people WHERE name BETWEEN 'a' AND 'BZ' ORDER BY id;
SELECT lower(min(name)), max(name) FROM people;
SELECT id FROM people WHERE name IN ('CAROL', 'DAVE') ORDER BY id;
SELECT DISTINCT rtrim(code) FROM people ORDER BY 1;
