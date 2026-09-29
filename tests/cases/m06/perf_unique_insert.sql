-- @timeout 5
-- Performance: bulk inserts and updates into a table with UNIQUE
-- constraints. Each row's uniqueness check must use an index; checking by
-- scanning would take more than 10^9 comparisons.
CREATE TABLE d(x INTEGER);
INSERT INTO d VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);
-- 50,000 rows; code is a permutation of 0..49999 (7919 is coprime to 50000).
CREATE TABLE u(id INTEGER PRIMARY KEY, code INTEGER UNIQUE, name TEXT);
CREATE UNIQUE INDEX u_name ON u(name);
INSERT INTO u SELECT a.x*10000 + b.x*1000 + c.x*100 + e.x*10 + f.x,
    ((a.x*10000 + b.x*1000 + c.x*100 + e.x*10 + f.x) * 7919) % 50000,
    'n' || (a.x*10000 + b.x*1000 + c.x*100 + e.x*10 + f.x)
  FROM d a, d b, d c, d e, d f WHERE a.x < 5;
SELECT count(*), sum(code), min(code), max(code) FROM u;
-- Every row is re-checked against the unique index on code.
UPDATE u SET code = code + 50000;
SELECT min(code), max(code) FROM u;
-- A conflicting bulk insert fails as a whole (the first row already conflicts on name).
INSERT INTO u(code, name) SELECT code + 100000, name FROM u;
SELECT count(*) FROM u;
-- INSERT OR IGNORE: half of the rows conflict on code and are skipped.
INSERT OR IGNORE INTO u(code, name) SELECT code + 25000, name || 'z' FROM u;
SELECT count(*), max(code) FROM u;
SELECT count(*) FROM u WHERE name LIKE '%z';
