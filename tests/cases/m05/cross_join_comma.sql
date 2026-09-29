-- Comma joins: the FROM list "a, b" produces the Cartesian product of the
-- tables, filtered by WHERE.
CREATE TABLE colors(name TEXT, rank INTEGER);
CREATE TABLE sizes(label TEXT, n INTEGER);
CREATE TABLE empty_t(z INTEGER);
INSERT INTO colors VALUES ('red', 1), ('green', 2), ('blue', 3);
INSERT INTO sizes VALUES ('S', 1), ('M', 2);

-- Full product: 3 x 2 = 6 rows.
SELECT name, label FROM colors, sizes ORDER BY rank, n;
SELECT count(*) FROM colors, sizes;
-- * expands to all columns of every table, left to right.
SELECT * FROM colors, sizes ORDER BY rank, n;
-- table.* selects one side only.
SELECT sizes.*, colors.name FROM colors, sizes ORDER BY colors.rank, sizes.n;
-- WHERE turns the product into an equi-join.
SELECT name, label FROM colors, sizes WHERE rank = n ORDER BY rank;
SELECT name, label FROM colors, sizes WHERE rank > n ORDER BY rank, n;
-- A table joined with itself through aliases.
SELECT c1.name, c2.name FROM colors c1, colors c2 WHERE c1.rank < c2.rank ORDER BY c1.rank, c2.rank;
-- Three tables in a comma list.
SELECT count(*) FROM colors, sizes, colors AS c3;
SELECT colors.name, sizes.label, c3.name FROM colors, sizes, colors AS c3
  WHERE colors.rank = 1 AND sizes.n = 2 ORDER BY c3.rank;
-- Joining with an empty table yields no rows at all.
SELECT * FROM colors, empty_t;
SELECT count(*) FROM empty_t, colors;
-- Expressions over columns from both sides.
SELECT name || '-' || label, rank * 10 + n FROM colors, sizes ORDER BY 2;
-- Unqualified names resolve to whichever table has them.
SELECT label, name FROM sizes, colors WHERE n = 2 AND rank = 3;
-- Errors: unknown table in the list, unknown qualified column.
SELECT * FROM colors, nosuch;
SELECT colors.label FROM colors, sizes;
