-- The WINDOW clause: named window definitions referenced with OVER name.
-- Several functions can share one window; several windows can be defined.
CREATE TABLE nw(id INTEGER PRIMARY KEY, cat TEXT, qty INTEGER);
INSERT INTO nw VALUES (1, 'x', 5), (2, 'y', 3), (3, 'x', 8), (4, 'y', 1), (5, 'x', 2), (6, 'z', 9);

-- One named window used by several functions.
SELECT id, row_number() OVER w, sum(qty) OVER w, max(qty) OVER w FROM nw
WINDOW w AS (PARTITION BY cat ORDER BY id) ORDER BY id;

-- Two named windows.
SELECT id, sum(qty) OVER byid, sum(qty) OVER bycat FROM nw
WINDOW byid AS (ORDER BY id), bycat AS (PARTITION BY cat) ORDER BY id;

-- A named window with a frame.
SELECT id, sum(qty) OVER w3 FROM nw WINDOW w3 AS (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) ORDER BY id;

-- An empty named window (whole table).
SELECT id, count(*) OVER everything, sum(qty) OVER everything FROM nw WINDOW everything AS () ORDER BY id;

-- Mixing named windows and inline OVER clauses.
SELECT id, rank() OVER w, rank() OVER (ORDER BY qty) FROM nw WINDOW w AS (ORDER BY qty DESC) ORDER BY id;

-- The WINDOW clause comes after HAVING/GROUP BY and before ORDER BY/LIMIT.
SELECT cat, sum(qty), rank() OVER w FROM nw GROUP BY cat HAVING count(*) >= 1 WINDOW w AS (ORDER BY sum(qty) DESC) ORDER BY cat LIMIT 3;

-- A named window defined but not used is fine.
SELECT id FROM nw WINDOW unused AS (ORDER BY id) ORDER BY id LIMIT 2;

-- Window names are case-insensitive.
SELECT id, sum(qty) OVER MyWin FROM nw WINDOW mywin AS (ORDER BY id) ORDER BY id;

-- The same window name used by every function type.
SELECT id, lag(qty) OVER w, lead(qty) OVER w, first_value(qty) OVER w, ntile(2) OVER w, percent_rank() OVER w
FROM nw WINDOW w AS (ORDER BY id) ORDER BY id;

-- Named windows in a subquery and in the outer query are independent.
SELECT id, s, sum(s) OVER w FROM (SELECT id, sum(qty) OVER w AS s FROM nw WINDOW w AS (ORDER BY id))
WINDOW w AS (ORDER BY id DESC) ORDER BY id;

-- Named windows with a compound query: each SELECT has its own WINDOW clause.
SELECT id, sum(qty) OVER w FROM nw WHERE cat = 'x' WINDOW w AS (ORDER BY id)
UNION ALL
SELECT id, count(*) OVER w FROM nw WHERE cat = 'y' WINDOW w AS (ORDER BY id)
ORDER BY 1;

-- Errors: an undefined window name; a window defined in another SELECT.
SELECT id, sum(qty) OVER nosuch FROM nw;
SELECT id, sum(qty) OVER w FROM nw WHERE cat = 'x' UNION ALL SELECT id, 0 FROM nw WHERE cat = 'z' WINDOW w AS (ORDER BY id);
