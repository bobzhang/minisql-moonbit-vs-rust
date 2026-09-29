-- Invalid frame specifications, each paired with the nearest valid form.
CREATE TABLE fe(id INTEGER PRIMARY KEY, k INTEGER, v INTEGER);
INSERT INTO fe VALUES (1, 1, 10), (2, 2, 20), (3, 3, 30);

-- Error: frame start after frame end (CURRENT ROW ... PRECEDING).
SELECT sum(v) OVER (ORDER BY id ROWS BETWEEN CURRENT ROW AND 1 PRECEDING) FROM fe;
-- Valid: the reversed bounds.
SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM fe ORDER BY id;
SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING) FROM fe ORDER BY id;

-- Error: short form with a FOLLOWING start (the implied end is CURRENT ROW).
SELECT sum(v) OVER (ORDER BY id ROWS 1 FOLLOWING) FROM fe;
-- Valid: short form with PRECEDING or CURRENT ROW.
SELECT id, sum(v) OVER (ORDER BY id ROWS CURRENT ROW) FROM fe ORDER BY id;

-- Error: UNBOUNDED FOLLOWING cannot start a frame.
SELECT sum(v) OVER (ORDER BY id ROWS BETWEEN UNBOUNDED FOLLOWING AND UNBOUNDED FOLLOWING) FROM fe;
-- Valid: the full frame.
SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM fe ORDER BY id;

-- Error: negative and non-integer ROWS offsets.
SELECT sum(v) OVER (ORDER BY id ROWS -1 PRECEDING) FROM fe;
SELECT sum(v) OVER (ORDER BY id ROWS 1.5 PRECEDING) FROM fe;
-- Valid: an integer constant expression as offset.
SELECT id, sum(v) OVER (ORDER BY id ROWS (1 + 1) PRECEDING) FROM fe ORDER BY id;
-- Valid: RANGE offsets may be non-integer.
SELECT id, sum(v) OVER (ORDER BY k RANGE 1.5 PRECEDING) FROM fe ORDER BY id;

-- Error: a column reference as offset.
SELECT sum(v) OVER (ORDER BY id ROWS k PRECEDING) FROM fe;
-- Valid: large constant offsets.
SELECT id, count(*) OVER (ORDER BY id ROWS BETWEEN 1000 PRECEDING AND 1000 FOLLOWING) FROM fe ORDER BY id;

-- Valid: GROUPS/RANGE without ORDER BY when the bounds are not offsets.
SELECT id, sum(v) OVER (RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), sum(v) OVER (GROUPS CURRENT ROW) FROM fe ORDER BY id;

-- Valid: frames entirely after the current row (start and end both FOLLOWING).
SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN 1 FOLLOWING AND 3 FOLLOWING) FROM fe ORDER BY id;
SELECT id, sum(v) OVER (ORDER BY k RANGE BETWEEN 1 FOLLOWING AND 2 FOLLOWING) FROM fe ORDER BY id;
-- Valid: EXCLUDE options with an explicit frame.
SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING EXCLUDE TIES) FROM fe ORDER BY id;
SELECT id, sum(v) OVER (ORDER BY id RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING EXCLUDE GROUP) FROM fe ORDER BY id;
-- Valid: frames on functions that ignore them are accepted.
SELECT id, row_number() OVER (ORDER BY id ROWS 1 PRECEDING), ntile(2) OVER (ORDER BY id GROUPS CURRENT ROW) FROM fe ORDER BY id;
-- Valid: a zero offset.
SELECT id, sum(v) OVER (ORDER BY id ROWS 0 PRECEDING) FROM fe ORDER BY id;
