-- Indexes stay consistent through INSERT, UPDATE (of indexed and unindexed
-- columns, and of the rowid), DELETE, REPLACE and upsert.
CREATE TABLE inv(id INTEGER PRIMARY KEY, sku TEXT, qty INTEGER, loc TEXT);
CREATE INDEX inv_sku ON inv(sku);
CREATE INDEX inv_qty ON inv(qty);
CREATE INDEX inv_loc_qty ON inv(loc, qty);
INSERT INTO inv VALUES (1, 'a1', 5, 'x'), (2, 'b2', 0, 'y'), (3, 'c3', 12, 'x'), (4, 'a1', 7, 'z');

SELECT id FROM inv WHERE sku = 'a1' ORDER BY id;
-- Update an indexed column: old key disappears, new key appears.
UPDATE inv SET sku = 'd4' WHERE id = 1;
SELECT id FROM inv WHERE sku = 'a1';
SELECT id FROM inv WHERE sku = 'd4';
-- Update a column covered by a composite index.
UPDATE inv SET qty = qty + 10 WHERE loc = 'x';
SELECT id, qty FROM inv WHERE loc = 'x' ORDER BY qty;
SELECT id FROM inv WHERE qty > 10 ORDER BY id;
SELECT id FROM inv WHERE qty = 5;
-- Update the rowid itself.
UPDATE inv SET id = 40 WHERE id = 4;
SELECT id FROM inv WHERE sku = 'a1';
SELECT id, sku FROM inv WHERE qty = 7;
-- Delete by an indexed column.
DELETE FROM inv WHERE qty = 0;
SELECT count(*) FROM inv WHERE loc = 'y';
SELECT id FROM inv ORDER BY id;
-- REPLACE through the primary key replaces index entries too.
REPLACE INTO inv VALUES (3, 'e5', 1, 'w');
SELECT id FROM inv WHERE sku = 'c3';
SELECT id FROM inv WHERE sku = 'e5';
SELECT id FROM inv WHERE loc = 'x' ORDER BY id;
-- Upsert updating an indexed column.
INSERT INTO inv VALUES (40, 'zz', 0, 'q') ON CONFLICT (id) DO UPDATE SET sku = 'f6', loc = excluded.loc;
SELECT id, sku, qty, loc FROM inv WHERE sku = 'f6';
SELECT count(*) FROM inv WHERE sku = 'a1';
SELECT id FROM inv WHERE loc = 'q' AND qty = 7;
-- Mass update and delete.
UPDATE inv SET qty = 100;
SELECT count(*) FROM inv WHERE qty = 100;
SELECT count(*) FROM inv WHERE qty < 100;
DELETE FROM inv WHERE sku > 'e';
SELECT id, sku FROM inv ORDER BY sku;
DELETE FROM inv;
SELECT count(*) FROM inv WHERE sku = 'd4';
INSERT INTO inv VALUES (1, 'd4', 1, 'x');
SELECT id FROM inv WHERE sku = 'd4' AND qty = 1;
