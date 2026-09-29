-- ALTER TABLE t RENAME [COLUMN] a TO b: data is kept, the new name must be
-- used afterwards, and the old name no longer resolves.
CREATE TABLE t(id INTEGER PRIMARY KEY, first TEXT, amount INTEGER DEFAULT 5, note TEXT);
INSERT INTO t VALUES (1, 'ann', 10, 'x'), (2, 'bob', 20, NULL);

ALTER TABLE t RENAME COLUMN first TO given;
SELECT id, given FROM t ORDER BY id;
SELECT first FROM t;
-- The COLUMN keyword is optional.
ALTER TABLE t RENAME amount TO qty;
SELECT qty FROM t ORDER BY qty;
-- The default value stays attached to the renamed column.
INSERT INTO t(id, given) VALUES (3, 'cy');
SELECT id, qty FROM t WHERE id = 3;
-- * uses the new names in the same positions.
SELECT * FROM t ORDER BY id;
-- Renaming the INTEGER PRIMARY KEY keeps it as the rowid alias.
ALTER TABLE t RENAME COLUMN id TO pk;
SELECT pk, rowid FROM t ORDER BY pk;
INSERT INTO t(given) VALUES ('di');
SELECT pk, given FROM t ORDER BY pk DESC LIMIT 1;
-- Case-only renames and quoted names.
ALTER TABLE t RENAME COLUMN note TO Note;
SELECT count(Note) FROM t;
ALTER TABLE t RENAME COLUMN Note TO "the note";
SELECT "the note" FROM t WHERE pk = 1;
-- Errors: unknown column, name already used by another column, unknown table.
ALTER TABLE t RENAME COLUMN nosuch TO x;
ALTER TABLE t RENAME COLUMN given TO qty;
ALTER TABLE nosuch RENAME COLUMN a TO b;
-- Constraints follow the column.
CREATE TABLE c(a INTEGER NOT NULL, b INTEGER CHECK (b > 0), UNIQUE (a, b));
INSERT INTO c VALUES (1, 1);
ALTER TABLE c RENAME COLUMN b TO bb;
INSERT INTO c VALUES (1, 0);
INSERT INTO c VALUES (1, 1);
INSERT INTO c VALUES (1, 2);
ALTER TABLE c RENAME COLUMN a TO aa;
INSERT INTO c(aa, bb) VALUES (NULL, 3);
SELECT aa, bb FROM c ORDER BY bb;
