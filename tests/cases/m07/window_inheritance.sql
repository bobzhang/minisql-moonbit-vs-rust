-- Window inheritance: OVER (base-window ...) extends a named window. The new
-- window may add an ORDER BY (if the base has none) and a frame, but may not
-- change the base's PARTITION BY or ORDER BY, and a base window with a
-- frame can only be used as OVER name.
CREATE TABLE wi(id INTEGER PRIMARY KEY, g TEXT, v INTEGER);
INSERT INTO wi VALUES (1, 'a', 1), (2, 'a', 2), (3, 'b', 4), (4, 'a', 8), (5, 'b', 16), (6, 'b', 32);

-- Base: partition only; derived windows add different orders.
SELECT id, sum(v) OVER (p ORDER BY id), sum(v) OVER (p ORDER BY id DESC), sum(v) OVER p FROM wi
WINDOW p AS (PARTITION BY g) ORDER BY id;

-- Base with partition and order; derived windows add frames.
SELECT id, sum(v) OVER (po ROWS 1 PRECEDING), sum(v) OVER (po ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING), sum(v) OVER po
FROM wi WINDOW po AS (PARTITION BY g ORDER BY id) ORDER BY id;

-- Derived windows with RANGE and GROUPS frames.
SELECT id, sum(v) OVER (o RANGE BETWEEN 2 PRECEDING AND 2 FOLLOWING), sum(v) OVER (o GROUPS 1 PRECEDING) FROM wi
WINDOW o AS (ORDER BY id) ORDER BY id;

-- A window defined in terms of another window in the WINDOW clause.
SELECT id, sum(v) OVER b, sum(v) OVER c FROM wi WINDOW a AS (PARTITION BY g), b AS (a ORDER BY id), c AS (b ROWS CURRENT ROW) ORDER BY id;

-- OVER (name) with parentheses and nothing else equals OVER name when the
-- base has no frame.
SELECT id, sum(v) OVER (po), sum(v) OVER po FROM wi WINDOW po AS (PARTITION BY g ORDER BY id) ORDER BY id;

-- A base window with a frame referenced as OVER name (allowed).
SELECT id, sum(v) OVER fr FROM wi WINDOW fr AS (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) ORDER BY id;

-- Derived window with EXCLUDE.
SELECT id, sum(v) OVER (po ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE CURRENT ROW) FROM wi
WINDOW po AS (PARTITION BY g ORDER BY id) ORDER BY id;

-- Ranking functions over derived windows.
SELECT id, row_number() OVER (p ORDER BY v DESC), rank() OVER (p ORDER BY g) FROM wi WINDOW p AS (PARTITION BY g) ORDER BY id;

-- A chain of three windows used by value and ranking functions.
SELECT id, lag(v) OVER c2, ntile(2) OVER c2, first_value(v) OVER (c2 ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM wi
WINDOW c1 AS (PARTITION BY g), c2 AS (c1 ORDER BY id) ORDER BY id;

-- The base's ORDER BY is inherited even when the new window adds a frame
-- with EXCLUDE GROUP on a peer-aware ordering.
SELECT id, sum(v) OVER (byg RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE GROUP) FROM wi
WINDOW byg AS (ORDER BY g) ORDER BY id;

-- Errors: overriding PARTITION BY, overriding ORDER BY, and adding to a
-- window that already has a frame.
SELECT sum(v) OVER (p PARTITION BY id) FROM wi WINDOW p AS (PARTITION BY g);
SELECT sum(v) OVER (po ORDER BY v) FROM wi WINDOW po AS (PARTITION BY g ORDER BY id);
SELECT sum(v) OVER (fr) FROM wi WINDOW fr AS (ORDER BY id ROWS 1 PRECEDING);
-- Error: the base window does not exist.
SELECT sum(v) OVER (nope ORDER BY id) FROM wi;
