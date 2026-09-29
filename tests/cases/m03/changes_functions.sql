-- changes(): rows changed by the most recent completed INSERT/UPDATE/DELETE.
-- total_changes(): all rows changed since the connection opened.
-- last_insert_rowid(): rowid of the most recent successful row insert.
SELECT changes(), total_changes(), last_insert_rowid();

CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO t VALUES (1, 'a'), (2, 'b'), (3, 'c');
SELECT changes(), total_changes(), last_insert_rowid();

INSERT INTO t(v) VALUES ('d');
SELECT changes(), total_changes(), last_insert_rowid();

-- UPDATE: changes counts matched rows, even if the value is unchanged.
UPDATE t SET v = v WHERE id <= 2;
SELECT changes(), total_changes(), last_insert_rowid();
UPDATE t SET v = 'z' WHERE id > 100;
SELECT changes(), total_changes();

-- DELETE with and without WHERE.
DELETE FROM t WHERE id = 4;
SELECT changes(), total_changes(), last_insert_rowid();
DELETE FROM t;
SELECT changes(), total_changes();

-- SELECT and DDL statements do not reset changes().
SELECT 1;
SELECT changes();
CREATE TABLE u(x);
SELECT changes(), total_changes();

-- Explicit rowid and INSERT ... SELECT: last row inserted.
INSERT INTO t VALUES (50, 'fifty');
SELECT last_insert_rowid();
INSERT INTO t(v) SELECT 'copy of ' || v FROM t;
SELECT changes(), last_insert_rowid();

-- last_insert_rowid() is per connection, not per table.
INSERT INTO u VALUES ('x'), ('y');
SELECT last_insert_rowid();
INSERT INTO t VALUES (7, 'seven');
SELECT last_insert_rowid();

-- A failing INSERT does not change last_insert_rowid().
INSERT INTO t VALUES (7, 'dup');
SELECT last_insert_rowid();

-- Values usable inside expressions.
SELECT changes() + 10, last_insert_rowid() * 2;
SELECT v FROM t WHERE id = last_insert_rowid();

-- Wrong argument count.
SELECT changes(1);
