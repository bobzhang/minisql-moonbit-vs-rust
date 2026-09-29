-- Window functions inside larger expressions and in the ORDER BY clause of
-- the query, plus expressions as window arguments and keys.
CREATE TABLE ex(id INTEGER PRIMARY KEY, name TEXT, score INTEGER);
INSERT INTO ex VALUES (1, 'amy', 70), (2, 'ben', 95), (3, 'cal', 85), (4, 'dot', 60), (5, 'eve', 95);

-- Arithmetic and CASE over window results.
SELECT name, score - avg(score) OVER (), CASE WHEN rank() OVER (ORDER BY score DESC) = 1 THEN 'top' ELSE 'rest' END FROM ex ORDER BY id;
SELECT name, round(100.0 * score / sum(score) OVER (), 1) FROM ex ORDER BY id;

-- Two window functions combined.
SELECT name, row_number() OVER (ORDER BY id) - rank() OVER (ORDER BY score DESC) FROM ex ORDER BY id;

-- Window functions in the query's ORDER BY.
SELECT name FROM ex ORDER BY row_number() OVER (ORDER BY score DESC, id DESC);
SELECT name, score FROM ex ORDER BY sum(score) OVER (ORDER BY id ROWS 1 PRECEDING) DESC, id;

-- Ordering by an alias of a window result.
SELECT name, percent_rank() OVER (ORDER BY score) AS pr FROM ex ORDER BY pr DESC, name;

-- Expression arguments.
SELECT name, sum(score * 2 - 100) OVER (ORDER BY id), max(length(name) + score) OVER () FROM ex ORDER BY id;

-- Expression in the window ORDER BY and PARTITION BY.
SELECT name, rank() OVER (ORDER BY abs(score - 80)), count(*) OVER (PARTITION BY score >= 85) FROM ex ORDER BY id;

-- Window results passed to scalar functions.
SELECT name, printf('%03d', row_number() OVER (ORDER BY name)), coalesce(lag(name) OVER (ORDER BY id), '-') FROM ex ORDER BY id;
SELECT name, upper(first_value(name) OVER (ORDER BY score DESC, id)) FROM ex ORDER BY id;

-- Comparisons with window values.
SELECT name, score = max(score) OVER () FROM ex ORDER BY id;
SELECT name, score > lag(score, 1, 0) OVER (ORDER BY id) FROM ex ORDER BY id;

-- typeof and CAST of window results.
SELECT name, typeof(avg(score) OVER ()), CAST(avg(score) OVER () AS INTEGER) FROM ex WHERE id = 1;

-- LIMIT and OFFSET are applied after window functions are computed.
SELECT name, row_number() OVER (ORDER BY id), count(*) OVER () FROM ex ORDER BY id LIMIT 2 OFFSET 1;

-- Error: a window function cannot be an argument of a normal aggregate.
SELECT sum(row_number() OVER (ORDER BY id)) FROM ex;
-- Error: window functions cannot be nested.
SELECT sum(rank() OVER (ORDER BY id)) OVER () FROM ex;
