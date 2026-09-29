-- Correlated subqueries in ORDER BY: each row's sort key is computed from
-- other tables (or the same table) using that row's values.
CREATE TABLE cities(name TEXT, country TEXT);
CREATE TABLE visits(city TEXT, n INTEGER);
INSERT INTO cities VALUES ('paris', 'fr'), ('lyon', 'fr'), ('rome', 'it'), ('oslo', 'no'), ('bern', 'ch');
INSERT INTO visits VALUES ('paris', 5), ('paris', 7), ('rome', 9), ('lyon', 1), ('oslo', 3), ('oslo', 3);

-- Sort by total visits, most first; ties broken by name.
SELECT name FROM cities ORDER BY (SELECT sum(n) FROM visits WHERE city = name) DESC, name;
-- NULL keys (no visits) sort first ascending.
SELECT name, (SELECT sum(n) FROM visits WHERE city = name) FROM cities ORDER BY (SELECT sum(n) FROM visits WHERE city = name), name;
SELECT name FROM cities ORDER BY (SELECT sum(n) FROM visits WHERE city = name) NULLS LAST, name;
-- Sort by visit count, then by country size (another correlated subquery on the same table).
SELECT name FROM cities c ORDER BY (SELECT count(*) FROM visits v WHERE v.city = c.name) DESC,
  (SELECT count(*) FROM cities c2 WHERE c2.country = c.country) DESC, name;
-- A correlated EXISTS as sort key.
SELECT name FROM cities ORDER BY EXISTS (SELECT 1 FROM visits WHERE city = name), name;
-- Correlated ORDER BY with LIMIT.
SELECT name FROM cities ORDER BY (SELECT max(n) FROM visits WHERE city = name) DESC NULLS LAST, name LIMIT 2;
-- The sort key refers to an alias of the outer table.
SELECT c.name FROM cities AS c ORDER BY (SELECT count(*) FROM cities d WHERE d.name < c.name) DESC;
-- Correlated sort key in a joined query.
SELECT c.name, v.n FROM cities c JOIN visits v ON v.city = c.name
  ORDER BY (SELECT sum(n) FROM visits w WHERE w.city = c.name), v.n, c.name;
-- In a grouped query the sort key may be correlated with the group column.
SELECT country, count(*) FROM cities GROUP BY country
  ORDER BY (SELECT coalesce(sum(n), 0) FROM visits JOIN cities c2 ON c2.name = visits.city WHERE c2.country = cities.country) DESC, country;
