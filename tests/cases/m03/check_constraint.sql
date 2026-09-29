-- CHECK constraints: the expression is evaluated on the new row (after
-- affinity is applied). The row is rejected if the result is false (0);
-- NULL counts as passing.
CREATE TABLE p(
  id INTEGER PRIMARY KEY,
  price INTEGER CHECK (price > 0),
  code TEXT CHECK (length(code) = 3),
  lo INTEGER,
  hi INTEGER,
  CHECK (lo <= hi)
);
INSERT INTO p VALUES (1, 10, 'abc', 1, 2);
INSERT INTO p VALUES (2, 0, 'abc', 1, 2);
INSERT INTO p VALUES (3, 5, 'abcd', 1, 2);
INSERT INTO p VALUES (4, 5, 'xyz', 3, 2);
SELECT * FROM p ORDER BY id;

-- NULL makes the CHECK expression NULL, which passes.
INSERT INTO p VALUES (5, NULL, NULL, NULL, 7);
SELECT * FROM p ORDER BY id;

-- Affinity is applied before the check: '12' becomes 12 in an INTEGER column.
INSERT INTO p VALUES (6, '12', 'def', 0, 0);
SELECT id, price, typeof(price) FROM p WHERE id = 6;
-- In a TEXT column, the integer 123 becomes '123' (length 3).
INSERT INTO p VALUES (7, 1, 123, 0, 0);
SELECT id, code, typeof(code) FROM p WHERE id = 7;

-- UPDATE is checked too; a failing UPDATE changes nothing.
UPDATE p SET price = NULL WHERE id = 7;
UPDATE p SET price = 2 WHERE id = 7;
UPDATE p SET lo = 100 WHERE id IN (1, 6);
UPDATE p SET price = price * 2;
SELECT id, price, lo, hi FROM p ORDER BY id;

-- The CHECK result is interpreted as a boolean like WHERE: text is converted
-- to a number, so 'abc' is false and '1x' is true.
CREATE TABLE b(v, CHECK (v));
INSERT INTO b VALUES (1);
INSERT INTO b VALUES (0.5);
INSERT INTO b VALUES ('1x');
INSERT INTO b VALUES (NULL);
INSERT INTO b VALUES ('abc');
SELECT v, typeof(v) FROM b ORDER BY v;

-- Named constraints and constraints using functions and IN / BETWEEN.
CREATE TABLE s(
  status TEXT CONSTRAINT valid_status CHECK (status IN ('new', 'done')),
  pct REAL CHECK (pct BETWEEN 0 AND 1),
  tag TEXT CHECK (tag = lower(tag))
);
INSERT INTO s VALUES ('new', 0.5, 'ok');
INSERT INTO s VALUES ('old', 0.5, 'ok');
INSERT INTO s VALUES ('new', 1, 'x_y');
INSERT INTO s VALUES ('done', 1, 'OK');
INSERT INTO s VALUES ('done', 0, 'fine');
SELECT status, pct, tag FROM s ORDER BY status;

-- CHECK may not reference unknown columns.
CREATE TABLE bad(a CHECK (a > nosuch));
