-- sqlite_schema (alias sqlite_master) lists tables, indexes and views with
-- their type, name and tbl_name (the table an index belongs to; for tables
-- and views, the object itself).
SELECT count(*) FROM sqlite_schema;
SELECT type, name, tbl_name FROM sqlite_schema;
CREATE TABLE customers(id INTEGER PRIMARY KEY, email TEXT UNIQUE, name TEXT);
CREATE TABLE orders(id INTEGER PRIMARY KEY, cust INTEGER, total REAL);
CREATE INDEX orders_cust ON orders(cust);
CREATE UNIQUE INDEX customers_name ON customers(name);
CREATE VIEW big_orders AS SELECT * FROM orders WHERE total > 100;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
-- The alias sqlite_master shows the same rows.
SELECT type, name, tbl_name FROM sqlite_master ORDER BY name;
SELECT count(*) FROM sqlite_master;
-- It can be filtered, grouped, joined and used in subqueries like any table.
SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name;
SELECT type, count(*) FROM sqlite_schema GROUP BY type ORDER BY type;
SELECT tbl_name, count(*) FROM sqlite_schema WHERE type = 'index' GROUP BY tbl_name ORDER BY tbl_name;
SELECT s.name, i.name FROM sqlite_schema s JOIN sqlite_schema i ON i.tbl_name = s.name AND i.type = 'index'
  WHERE s.type = 'table' ORDER BY s.name, i.name;
SELECT name FROM sqlite_schema WHERE name IN (SELECT tbl_name FROM sqlite_schema WHERE type = 'index') AND type = 'table' ORDER BY name;
SELECT EXISTS (SELECT 1 FROM sqlite_schema WHERE type = 'view' AND name = 'big_orders');
-- Qualified column references and aliases.
SELECT m.name FROM sqlite_master AS m WHERE m.type = 'view';
SELECT sqlite_schema.tbl_name FROM sqlite_schema WHERE name = 'orders_cust';
-- Names keep the case they were created with.
CREATE TABLE MixedCase(Col INTEGER);
SELECT name FROM sqlite_schema WHERE name = 'MixedCase';
SELECT name FROM sqlite_schema WHERE lower(name) = 'mixedcase';
-- Quoted names with spaces.
CREATE TABLE "odd name"(x);
CREATE INDEX "odd index" ON "odd name"(x);
SELECT type, name, tbl_name FROM sqlite_schema WHERE name LIKE 'odd%' ORDER BY name;
-- sqlite_schema is read-only.
DELETE FROM sqlite_schema;
INSERT INTO sqlite_master(type, name, tbl_name) VALUES ('table', 'fake', 'fake');
SELECT count(*) FROM sqlite_schema;
