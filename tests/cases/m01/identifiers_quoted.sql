-- Quoted identifiers: "..." `...` [...] allow spaces, keywords and special
-- characters in table and column names.

CREATE TABLE "my table"("first col" INTEGER, [second col] TEXT, `third col` REAL);
INSERT INTO "my table" VALUES (1, 'a', 1.5);
SELECT "first col", [second col], `third col` FROM "my table";
-- The three quoting styles are interchangeable.
SELECT [first col], `second col`, "third col" FROM [my table];
SELECT * FROM `my table`;
-- Reserved words as identifiers when quoted.
CREATE TABLE "select"("from" INTEGER, [where] TEXT, `order` TEXT, "group" INTEGER);
INSERT INTO "select" VALUES (1, 'w', 'o', 2);
SELECT "from", [where], `order`, "group" FROM "select";
SELECT "select"."from", [select].[where] FROM [select];
-- Doubled quote characters inside quoted identifiers.
CREATE TABLE "a""b"("c""d" INTEGER, `e``f` INTEGER);
INSERT INTO "a""b" VALUES (1, 2);
SELECT "c""d", `e``f` FROM "a""b";
-- Quoted names match unquoted names case-insensitively.
CREATE TABLE plain(Col INTEGER);
INSERT INTO plain VALUES (5);
SELECT "col", [COL], `cOl` FROM "PLAIN";
-- Non-ASCII identifiers.
CREATE TABLE "données"("prénom" TEXT, "年齢" INTEGER);
INSERT INTO "données" VALUES ('Zoé', 30);
SELECT "prénom", "年齢" FROM "données";
-- Identifiers may contain digits, underscores and dollar signs.
CREATE TABLE t_1(col_2 INTEGER, _x INTEGER, a$b INTEGER);
INSERT INTO t_1 VALUES (1, 2, 3);
SELECT col_2, _x, a$b FROM t_1;
-- An unterminated quoted identifier is an error.
SELECT [unterminated FROM t_1;
