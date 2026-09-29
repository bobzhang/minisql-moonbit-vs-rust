-- Statement splitting (SPEC §2.2): semicolons inside strings, quoted
-- identifiers and comments do not end a statement; empty pieces are ignored.

-- Semicolons inside string literals.
SELECT 'a;b', ';', ';;;';
SELECT 'it''s; fine', 'x' || ';' || 'y';

-- Empty statements between semicolons print nothing.
;;
SELECT 1;;;SELECT 2;

-- Several statements on one line.
SELECT 3; SELECT 4; SELECT 5;

-- Semicolons inside quoted identifiers.
CREATE TABLE "semi;colon" ("a;b" INTEGER, [c;d] TEXT, `e;f` REAL);
INSERT INTO "semi;colon" VALUES (1, 'one', 1.5);
SELECT "a;b", [c;d], `e;f` FROM "semi;colon";

-- Semicolons inside comments.
SELECT 6 -- a comment; with a semicolon
;
SELECT /* block; comment; */ 7;
SELECT 8 /* ; */ + /* ; */ 1;

-- A statement spanning several lines.
SELECT
  10,
  20
  ,
  30
;

-- A doubled quote inside a quoted identifier does not end it.
CREATE TABLE "q""t" ("x""y" INTEGER);
INSERT INTO "q""t" VALUES (42);
SELECT "x""y" FROM "q""t";

-- A piece that holds only a comment is ignored.
-- just a comment;
/* only a block comment */;

-- The text after the last semicolon is a statement too.
SELECT 'last statement without semicolon'
