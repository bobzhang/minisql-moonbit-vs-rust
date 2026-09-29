-- Condition placement with RIGHT JOIN: in ON it only limits which left rows
-- match; in WHERE it filters the final rows, including NULL-extended ones.
CREATE TABLE sales(region TEXT, yr INTEGER, amt INTEGER);
CREATE TABLE regions(name TEXT, active INTEGER);
INSERT INTO sales VALUES ('n', 2023, 10), ('n', 2024, 20), ('s', 2023, 5), ('e', 2024, 7), ('x', 2024, 1);
INSERT INTO regions VALUES ('n', 1), ('s', 1), ('e', 0), ('w', 1);

-- Year filter in ON: every region survives.
SELECT name, yr, amt FROM sales RIGHT JOIN regions ON sales.region = regions.name AND yr = 2024 ORDER BY name;
-- Year filter in WHERE: regions without 2024 sales disappear.
SELECT name, yr, amt FROM sales RIGHT JOIN regions ON sales.region = regions.name WHERE yr = 2024 ORDER BY name;
-- Filter on the preserved (right) side in ON: rows failing it are NULL-extended, not removed.
SELECT name, amt FROM sales RIGHT JOIN regions ON sales.region = regions.name AND active = 1 ORDER BY name, amt;
-- Same filter in WHERE removes them.
SELECT name, amt FROM sales RIGHT JOIN regions ON sales.region = regions.name WHERE active = 1 ORDER BY name, amt;
-- WHERE on a NULL-extended column with IS NULL.
SELECT name FROM sales RIGHT JOIN regions ON sales.region = regions.name AND amt > 6 WHERE amt IS NULL ORDER BY name;
-- Totals per region; ON filter keeps zero rows as NULL sums.
SELECT name, sum(amt), total(amt), count(amt) FROM sales RIGHT JOIN regions
  ON sales.region = regions.name AND yr = 2023 GROUP BY name ORDER BY name;
SELECT name, sum(amt) FROM sales RIGHT JOIN regions
  ON sales.region = regions.name WHERE yr = 2023 GROUP BY name ORDER BY name;
-- WHERE clause mixing both sides.
SELECT name, amt FROM sales RIGHT JOIN regions ON sales.region = regions.name
  WHERE amt IS NULL OR active = 0 ORDER BY name;
-- Constant ON conditions.
SELECT count(*) FROM sales RIGHT JOIN regions ON 1;
SELECT count(*) FROM sales RIGHT JOIN regions ON NULL;
SELECT count(*) FROM sales RIGHT JOIN regions ON sales.region = regions.name WHERE NULL;
