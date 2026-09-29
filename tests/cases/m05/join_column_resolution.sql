-- How names are resolved inside joins: qualification with table names and
-- aliases, table.* for each source, unknown names.
CREATE TABLE items(id INTEGER PRIMARY KEY, title TEXT, cat_id INTEGER);
CREATE TABLE cats(id INTEGER PRIMARY KEY, title TEXT);
INSERT INTO items VALUES (1, 'apple', 1), (2, 'pear', 1), (3, 'kale', 2), (4, 'rock', NULL);
INSERT INTO cats VALUES (1, 'fruit'), (2, 'veg');

-- Qualified references to identically named columns.
SELECT items.title, cats.title FROM items JOIN cats ON items.cat_id = cats.id ORDER BY items.id;
-- Aliases replace the table names completely.
SELECT i.title, c.title FROM items i JOIN cats c ON i.cat_id = c.id ORDER BY i.id;
SELECT items.title FROM items i JOIN cats c ON i.cat_id = c.id;
-- An alias may equal another table's name.
SELECT cats.title FROM items AS cats ORDER BY cats.id;
-- table.* for several tables, in any order.
SELECT c.*, i.* FROM items i JOIN cats c ON i.cat_id = c.id ORDER BY i.id;
SELECT i.id, c.* FROM items i LEFT JOIN cats c ON i.cat_id = c.id ORDER BY i.id;
-- table.* for a table not in FROM is an error.
SELECT nosuch.* FROM items;
-- rowid of each side of a join.
SELECT i.rowid, c.rowid FROM items i JOIN cats c ON i.cat_id = c.id ORDER BY 1;
-- Expressions in the select list mixing both sides.
SELECT i.title || ':' || c.title FROM items i JOIN cats c ON i.cat_id = c.id ORDER BY 1;
-- Column aliases in ORDER BY refer to result columns.
SELECT i.title AS item, c.title AS cat FROM items i JOIN cats c ON i.cat_id = c.id ORDER BY cat DESC, item;
-- Columns from a table that appears later in the FROM clause are visible in earlier ON clauses? No:
-- an ON clause may reference only tables to its left and the table it joins.
CREATE TABLE extra(item_id INTEGER, note TEXT);
INSERT INTO extra VALUES (1, 'crisp'), (3, 'leafy');
SELECT i.title, c.title, e.note FROM items i JOIN cats c ON i.cat_id = c.id JOIN extra e ON e.item_id = i.id ORDER BY i.id;
SELECT i.title, e.note FROM items i LEFT JOIN extra e ON e.item_id = i.id AND i.cat_id IS NOT NULL ORDER BY i.id;
-- Unknown qualified column.
SELECT i.nosuch FROM items i JOIN cats c ON 1;
-- Unknown alias.
SELECT z.title FROM items i JOIN cats c ON 1;
