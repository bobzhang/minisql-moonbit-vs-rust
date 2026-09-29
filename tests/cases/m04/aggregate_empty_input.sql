-- Aggregates over zero rows. Without GROUP BY there is always exactly one
-- result row; with GROUP BY there are no groups and so no rows.
CREATE TABLE e(g TEXT, v INTEGER, s TEXT);
SELECT count(*), count(v), sum(v), total(v), avg(v), min(v), max(v), group_concat(s), string_agg(s, ';') FROM e;
SELECT typeof(count(*)), typeof(sum(v)), typeof(total(v)), typeof(avg(v)), typeof(min(v)), typeof(group_concat(s)) FROM e;

-- With GROUP BY: no output at all.
SELECT g, count(*) FROM e GROUP BY g;
SELECT count(*) FROM e GROUP BY g;

-- A WHERE clause that removes every row behaves the same way.
INSERT INTO e VALUES ('a', 1, 'x'), ('b', 2, 'y');
SELECT count(*), sum(v), total(v), avg(v), max(s) FROM e WHERE v > 10;
SELECT g, count(*) FROM e WHERE v > 10 GROUP BY g;

-- HAVING can filter out the single row of an ungrouped aggregate.
SELECT count(*) FROM e WHERE v > 10 HAVING count(*) > 0;
SELECT count(*) FROM e HAVING count(*) > 1;
SELECT count(*) FROM e HAVING count(*) > 5;

-- Expressions around empty aggregates.
SELECT coalesce(sum(v), 0), ifnull(max(s), 'none'), count(*) + 1 FROM e WHERE 0;
SELECT sum(v) IS NULL, total(v) = 0 FROM e WHERE 0;

-- DISTINCT and FILTER on empty input.
SELECT count(DISTINCT v), sum(DISTINCT v), count(*) FILTER (WHERE v > 0) FROM e WHERE 0;

-- LIMIT/OFFSET applied to the single aggregate row.
SELECT count(*) FROM e WHERE 0 LIMIT 1;
SELECT count(*) FROM e WHERE 0 LIMIT 1 OFFSET 1;

-- After deleting everything.
DELETE FROM e;
SELECT count(*), sum(v), avg(v), min(v) FROM e;
