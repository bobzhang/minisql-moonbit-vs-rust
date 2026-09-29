-- Windows over values of mixed storage classes: ORDER BY uses SQLite's
-- cross-class order (NULL < numbers < text < blob), numbers compare by value
-- regardless of INTEGER/REAL, and aggregates follow the M4 type rules.
CREATE TABLE mt(id INTEGER PRIMARY KEY, x);
INSERT INTO mt VALUES (1, 3), (2, 'abc'), (3, 2.5), (4, NULL), (5, x'00'), (6, 'Abc'), (7, 10), (8, 2.5);

-- Ranking across storage classes.
SELECT id, x, typeof(x), rank() OVER (ORDER BY x) FROM mt ORDER BY id;
SELECT id, dense_rank() OVER (ORDER BY x DESC) FROM mt ORDER BY id;

-- Integer and real values are peers when equal.
CREATE TABLE ir(id INTEGER PRIMARY KEY, n);
INSERT INTO ir VALUES (1, 1), (2, 1.0), (3, 2), (4, 1.5), (5, '1');
SELECT id, rank() OVER (ORDER BY n), count(*) OVER (ORDER BY n RANGE CURRENT ROW) FROM ir ORDER BY id;

-- sum over integers and reals: REAL as soon as any REAL is included.
SELECT id, sum(n) OVER (ORDER BY id), typeof(sum(n) OVER (ORDER BY id)) FROM ir WHERE id <= 4 ORDER BY id;

-- min/max across classes in running frames.
SELECT id, min(x) OVER (ORDER BY id), max(x) OVER (ORDER BY id) FROM mt ORDER BY id;

-- Text ordering in windows is BINARY by default ('Abc' < 'abc').
SELECT id, row_number() OVER (ORDER BY x, id) FROM mt WHERE typeof(x) = 'text' ORDER BY id;
-- ... and NOCASE when requested.
SELECT id, rank() OVER (ORDER BY x COLLATE NOCASE) FROM mt WHERE typeof(x) = 'text' ORDER BY id;

-- Affinity: a TEXT column holding digits orders as text, an INTEGER column as numbers.
CREATE TABLE aff(id INTEGER PRIMARY KEY, t TEXT, i INTEGER);
INSERT INTO aff VALUES (1, '10', '10'), (2, '9', '9'), (3, '100', '100');
SELECT id, row_number() OVER (ORDER BY t), row_number() OVER (ORDER BY i) FROM aff ORDER BY id;

-- RANGE offsets over REAL and INTEGER values mixed.
SELECT id, n, count(*) OVER (ORDER BY n RANGE BETWEEN 0.5 PRECEDING AND 0.5 FOLLOWING) FROM ir WHERE typeof(n) <> 'text' ORDER BY id;

-- lag/lead preserve the type of the fetched value.
SELECT id, typeof(lag(x) OVER (ORDER BY id)), quote(lead(x) OVER (ORDER BY id)) FROM mt ORDER BY id;

-- group_concat over integers and text values.
SELECT id, group_concat(x, ',') OVER (ORDER BY id) FROM mt WHERE typeof(x) IN ('integer', 'text') ORDER BY id;

-- avg over integers yields REAL; total always REAL.
SELECT DISTINCT avg(n) OVER (), total(n) OVER () FROM ir WHERE typeof(n) = 'integer';
