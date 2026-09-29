-- group_concat(x [, sep]), string_agg(x, sep) and total(x) used with OVER.
-- The concatenation follows the window order within the frame.
CREATE TABLE g(id INTEGER PRIMARY KEY, grp TEXT, tag TEXT, n);
INSERT INTO g VALUES (1, 'a', 'x', 1), (2, 'a', 'y', 2.5), (3, 'a', NULL, NULL), (4, 'a', 'z', 4),
  (5, 'b', 'u', 10), (6, 'b', 'v', NULL), (7, 'c', NULL, NULL);

-- Running concatenation with the default separator ','.
SELECT id, group_concat(tag) OVER (ORDER BY id) FROM g ORDER BY id;

-- Custom separators; NULL values are skipped.
SELECT id, group_concat(tag, '-') OVER (PARTITION BY grp ORDER BY id), string_agg(tag, '') OVER (PARTITION BY grp ORDER BY id)
FROM g ORDER BY id;

-- Whole partition; an all-NULL partition gives NULL.
SELECT id, group_concat(tag, ';') OVER (PARTITION BY grp) IS NULL FROM g WHERE grp = 'c';
SELECT id, string_agg(tag, '+') OVER (PARTITION BY grp ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
FROM g WHERE grp = 'a' ORDER BY id;

-- Sliding frames: values leave the concatenation again.
SELECT id, group_concat(tag, '') OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM g ORDER BY id;

-- Reverse window order changes the concatenation order.
SELECT id, group_concat(id, '<') OVER (ORDER BY id DESC) FROM g WHERE grp = 'a' ORDER BY id;

-- Numbers are converted to text in the concatenation.
SELECT id, group_concat(n, '|') OVER (ORDER BY id) FROM g WHERE grp <> 'c' ORDER BY id;

-- total() always returns REAL and 0.0 instead of NULL.
SELECT id, total(n) OVER (ORDER BY id), sum(n) OVER (ORDER BY id) FROM g ORDER BY id;
SELECT id, total(n) OVER (PARTITION BY grp), typeof(total(n) OVER (PARTITION BY grp)) FROM g ORDER BY id;
SELECT id, total(n) OVER (ORDER BY id ROWS BETWEEN 1 FOLLOWING AND 2 FOLLOWING) FROM g ORDER BY id;

-- A separator given by an expression.
SELECT id, group_concat(tag, upper('_')) OVER (PARTITION BY grp ORDER BY id) FROM g WHERE grp = 'b' ORDER BY id;

-- Concatenation over a frame that excludes the current row.
SELECT id, group_concat(tag, '') OVER (ORDER BY id ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING EXCLUDE CURRENT ROW) FROM g ORDER BY id;

-- Errors: string_agg needs exactly two arguments; ORDER BY inside the
-- argument list is not allowed for window aggregates.
SELECT string_agg(tag) OVER (ORDER BY id) FROM g;
SELECT group_concat(tag ORDER BY tag) OVER (ORDER BY id) FROM g;
