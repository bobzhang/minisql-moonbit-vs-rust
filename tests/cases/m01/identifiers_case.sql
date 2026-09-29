-- Identifiers are case-insensitive; column references keep resolving no
-- matter how they are spelled.

CREATE TABLE Items(ItemId INTEGER, ItemName TEXT);
INSERT INTO items VALUES (1, 'pen');
INSERT INTO ITEMS VALUES (2, 'cup');
SELECT itemid, ITEMNAME FROM Items ORDER BY ItemId;
SELECT Items.itemid, items.ItemName FROM ITEMS ORDER BY items.ITEMID;
SELECT iTeMs.* FROM items ORDER BY itemid DESC;
-- Keywords and function names are case-insensitive too.
select TYPEOF(itemid), TypeOf(itemname) from items where ITEMID = 1;
-- Table aliases are case-insensitive.
SELECT X.itemname FROM items AS x ORDER BY x.ITEMID;
SELECT x.itemname FROM items X WHERE X.itemid = 2;
-- Column list in INSERT is case-insensitive.
INSERT INTO items (ITEMNAME, itemID) VALUES ('box', 3);
SELECT ItemId, ItemName FROM items ORDER BY ItemId;
-- Non-ASCII letters are not case-folded: these are different columns.
CREATE TABLE u("é" INTEGER, "É" INTEGER);
INSERT INTO u VALUES (1, 2);
SELECT "é", "É" FROM u;
-- ASCII case folding applies to quoted names too.
CREATE TABLE "CamelCase"(v INTEGER);
INSERT INTO camelcase VALUES (7);
SELECT "camelcase".v, CAMELCASE.V FROM CamelCase;
-- Errors: misspelled names are not found regardless of case.
SELECT itemnam FROM items;
SELECT itemid FROM itemz;
