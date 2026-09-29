-- GROUPS frames: offsets count peer groups (sets of rows with equal ORDER BY
-- values) rather than rows or values.
CREATE TABLE gr(id INTEGER PRIMARY KEY, k INTEGER, v INTEGER);
INSERT INTO gr VALUES (1, 10, 1), (2, 10, 2), (3, 20, 4), (4, 30, 8), (5, 30, 16), (6, 30, 32), (7, 45, 64), (8, 60, 128);

-- One group before and after.
SELECT id, k, sum(v) OVER (ORDER BY k GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM gr ORDER BY id;

-- Short form: two groups back to the current group.
SELECT id, k, sum(v) OVER (ORDER BY k GROUPS 2 PRECEDING) FROM gr ORDER BY id;

-- The current group only, and the current group through the end.
SELECT id, k, sum(v) OVER (ORDER BY k GROUPS CURRENT ROW), sum(v) OVER (ORDER BY k GROUPS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)
FROM gr ORDER BY id;

-- Groups strictly before / after.
SELECT id, k, sum(v) OVER (ORDER BY k GROUPS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
  sum(v) OVER (ORDER BY k GROUPS BETWEEN 1 FOLLOWING AND 2 FOLLOWING) FROM gr ORDER BY id;

-- Compare ROWS / RANGE / GROUPS with the same "1 PRECEDING" start.
SELECT id, k, sum(v) OVER (ORDER BY k, id ROWS 1 PRECEDING), sum(v) OVER (ORDER BY k RANGE 10 PRECEDING),
  sum(v) OVER (ORDER BY k GROUPS 1 PRECEDING) FROM gr ORDER BY id;

-- GROUPS with multiple ORDER BY terms (allowed, unlike RANGE offsets).
SELECT id, sum(v) OVER (ORDER BY k, v / 16 GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM gr ORDER BY id;

-- Per partition.
SELECT id, k, sum(v) OVER (PARTITION BY k > 25 ORDER BY k GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM gr ORDER BY id;

-- Offsets larger than the number of groups.
SELECT id, count(*) OVER (ORDER BY k GROUPS BETWEEN 10 PRECEDING AND 10 FOLLOWING) FROM gr ORDER BY id;

-- DESC ordering.
SELECT id, k, sum(v) OVER (ORDER BY k DESC GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM gr ORDER BY id;

-- Without ORDER BY, the whole partition is a single peer group.
SELECT DISTINCT sum(v) OVER (GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM gr;

-- Unique keys: GROUPS behaves like ROWS.
SELECT id, sum(v) OVER (ORDER BY id GROUPS 1 PRECEDING) = sum(v) OVER (ORDER BY id ROWS 1 PRECEDING) FROM gr ORDER BY id;

-- NULL keys form their own peer group.
CREATE TABLE gn(id INTEGER PRIMARY KEY, k INTEGER, v INTEGER);
INSERT INTO gn VALUES (1, NULL, 1), (2, NULL, 2), (3, 1, 4), (4, 2, 8);
SELECT id, sum(v) OVER (ORDER BY k GROUPS BETWEEN CURRENT ROW AND 1 FOLLOWING) FROM gn ORDER BY id;

-- Error: a non-integer GROUPS offset.
SELECT sum(v) OVER (ORDER BY k GROUPS 1.5 PRECEDING) FROM gr;
