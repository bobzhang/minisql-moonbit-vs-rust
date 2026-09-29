-- Join comparisons use collations: an explicit COLLATE wins, otherwise the
-- collation of the left operand if it is a column (a column without a
-- COLLATE clause counts as BINARY), otherwise the right operand's.
CREATE TABLE names_ci(n TEXT COLLATE NOCASE, id INTEGER);
CREATE TABLE names_bin(n TEXT, id INTEGER);
INSERT INTO names_ci VALUES ('Alice', 1), ('BOB', 2), ('carol ', 3);
INSERT INTO names_bin VALUES ('alice', 10), ('Bob', 20), ('carol', 30), ('ALICE', 40);

-- Left operand is NOCASE: case-insensitive matches.
SELECT names_ci.id, names_bin.id FROM names_ci JOIN names_bin ON names_ci.n = names_bin.n ORDER BY 1, 2;
-- Left operand is a plain (BINARY) column, so BINARY is used even though the
-- right column is NOCASE: no rows match.
SELECT names_ci.id, names_bin.id FROM names_bin JOIN names_ci ON names_bin.n = names_ci.n ORDER BY 1, 2;
-- Explicit BINARY overrides the column collation.
SELECT names_ci.id, names_bin.id FROM names_ci JOIN names_bin ON names_ci.n = names_bin.n COLLATE BINARY ORDER BY 1, 2;
-- Explicit NOCASE between two binary columns.
SELECT a.id, b.id FROM names_bin a JOIN names_bin b ON a.n = b.n COLLATE NOCASE AND a.id < b.id ORDER BY 1, 2;
-- RTRIM ignores trailing spaces.
SELECT names_ci.id, names_bin.id FROM names_ci JOIN names_bin ON names_ci.n = names_bin.n COLLATE RTRIM ORDER BY 1, 2;
-- USING compares with the left table's column collation.
CREATE TABLE u_ci(n TEXT COLLATE NOCASE, x TEXT);
CREATE TABLE u_bin(n TEXT, y TEXT);
INSERT INTO u_ci VALUES ('a', 'x1'), ('B', 'x2');
INSERT INTO u_bin VALUES ('A', 'y1'), ('b', 'y2'), ('a', 'y3');
SELECT x, y FROM u_ci JOIN u_bin USING (n) ORDER BY x, y;
SELECT x, y FROM u_bin JOIN u_ci USING (n) ORDER BY x, y;
-- Range comparisons with NOCASE.
SELECT names_ci.id, names_bin.id FROM names_ci JOIN names_bin ON names_ci.n < names_bin.n ORDER BY 1, 2;
-- Collation of a left-join condition: unmatched rows NULL-extended.
SELECT names_bin.id, names_ci.id FROM names_bin LEFT JOIN names_ci ON names_bin.n = names_ci.n COLLATE BINARY ORDER BY 1;
-- GROUP BY a NOCASE column after a join groups case-insensitively.
SELECT names_ci.n, count(*) FROM names_ci JOIN names_bin ON names_ci.n = names_bin.n GROUP BY names_ci.n ORDER BY 1;
