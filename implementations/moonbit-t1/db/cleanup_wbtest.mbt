///|
test "ABORT restores the statement and keeps the transaction open" {
  let db = Database::new()
  let total_before = conn.total_changes
  assert_eq(
    run_script(
      db, "CREATE TABLE t(x INTEGER UNIQUE); INSERT INTO t VALUES (1); BEGIN; INSERT INTO t VALUES (2);",
    ),
    "",
  )
  assert_eq(
    run_script(db, "INSERT OR ABORT INTO t VALUES (3), (1);"),
    "Error: UNIQUE constraint failed: t.x\n",
  )
  assert_true(db.txn is Some(_))
  assert_eq(conn.changes, 0L)
  assert_eq(conn.total_changes - total_before, 2L)
  assert_eq(
    run_script(
      db, "SELECT x FROM t ORDER BY x; INSERT INTO t VALUES (4); COMMIT; SELECT x FROM t ORDER BY x;",
    ),
    "1\n2\n1\n2\n4\n",
  )
  assert_true(db.txn is None)
}

///|
test "FAIL preserves earlier rows and counts only completed changes" {
  let db = Database::new()
  let total_before = conn.total_changes
  assert_eq(
    run_script(
      db, "CREATE TABLE t(x INTEGER UNIQUE); INSERT INTO t VALUES (1); BEGIN;",
    ),
    "",
  )
  assert_eq(
    run_script(db, "INSERT OR FAIL INTO t VALUES (2), (1), (3);"),
    "Error: UNIQUE constraint failed: t.x\n",
  )
  assert_true(db.txn is Some(_))
  assert_eq(conn.changes, 1L)
  assert_eq(conn.total_changes - total_before, 2L)
  assert_eq(
    run_script(
      db, "SELECT x FROM t ORDER BY x; ROLLBACK; SELECT x FROM t ORDER BY x;",
    ),
    "1\n2\n1\n",
  )
}

///|
test "ROLLBACK restores the transaction and permits a new transaction" {
  let db = Database::new()
  let total_before = conn.total_changes
  assert_eq(
    run_script(
      db, "CREATE TABLE t(x INTEGER UNIQUE); INSERT INTO t VALUES (1); BEGIN; INSERT INTO t VALUES (2); SAVEPOINT nested;",
    ),
    "",
  )
  assert_eq(
    run_script(db, "INSERT OR ROLLBACK INTO t VALUES (3), (1);"),
    "Error: UNIQUE constraint failed: t.x\n",
  )
  assert_true(db.txn is None)
  assert_eq(db.savepoints.length(), 0)
  assert_eq(conn.changes, 0L)
  // SQLite total_changes includes earlier statements even after rollback.
  assert_eq(conn.total_changes - total_before, 2L)
  assert_eq(
    run_script(
      db, "SELECT x FROM t ORDER BY x; BEGIN; INSERT INTO t VALUES (4); COMMIT; SELECT x FROM t ORDER BY x;",
    ),
    "1\n1\n4\n",
  )
}

///|
test "failed unique index creation restores schema" {
  let db = Database::new()
  assert_eq(
    run_script(db, "CREATE TABLE t(x INTEGER); INSERT INTO t VALUES (1), (1);"),
    "",
  )
  assert_eq(
    run_script(db, "CREATE UNIQUE INDEX ix ON t(x);"),
    "Error: UNIQUE constraint failed: t.x\n",
  )
  assert_eq(
    run_script(
      db, "SELECT count(*) FROM sqlite_schema WHERE name = 'ix'; CREATE INDEX ix ON t(x); SELECT count(*) FROM sqlite_schema WHERE name = 'ix'; SELECT count(*) FROM t;",
    ),
    "0\n1\n2\n",
  )
}

///|
test "failed CTE queries and DML restore the CTE stack" {
  let db = Database::new()
  assert_eq(
    run_script(db, "WITH c AS (SELECT * FROM missing) SELECT * FROM c;"),
    "Error: no such table: main.missing\n",
  )
  assert_eq(cte_stack.length(), 0)
  assert_eq(
    run_script(
      db, "CREATE TABLE t(x); WITH c AS (SELECT * FROM missing) INSERT INTO t SELECT * FROM c;",
    ),
    "Error: no such table: main.missing\n",
  )
  assert_eq(cte_stack.length(), 0)
  assert_eq(
    run_script(
      db, "WITH c AS (SELECT 7 AS x) INSERT INTO t SELECT x FROM c; SELECT x FROM t;",
    ),
    "7\n",
  )
}

///|
test "failed view expansion restores view and CTE stacks" {
  let db = Database::new()
  assert_eq(
    run_script(
      db, "CREATE VIEW v AS SELECT * FROM missing; WITH c AS (SELECT 7 AS x) SELECT * FROM v, c;",
    ),
    "Error: no such table: main.missing\n",
  )
  assert_eq(view_stack.length(), 0)
  assert_eq(cte_stack.length(), 0)
  assert_eq(
    run_script(
      db, "CREATE TABLE missing(x); INSERT INTO missing VALUES (3); WITH c AS (SELECT 7 AS x) SELECT v.x, c.x FROM v, c;",
    ),
    "3|7\n",
  )
}

///|
test "failed correlated subquery restores outer rows" {
  let db = Database::new()
  assert_eq(
    run_script(
      db, "CREATE TABLE t(x INTEGER); INSERT INTO t VALUES (-9223372036854775808); SELECT (SELECT abs(t.x)) FROM t;",
    ),
    "Error: integer overflow\n",
  )
  assert_eq(outer_stack.length(), 0)
  assert_eq(
    run_script(db, "UPDATE t SET x = 7; SELECT (SELECT abs(t.x)) FROM t;"),
    "7\n",
  )
}
