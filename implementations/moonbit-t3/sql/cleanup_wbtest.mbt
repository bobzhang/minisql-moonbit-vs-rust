///|
test "failed view expansion restores the active view set" {
  let db = Database::new()
  ignore(db.execute("CREATE VIEW v AS SELECT * FROM missing"))
  let message = try {
    ignore(db.execute("WITH c AS (SELECT 7 AS x) SELECT * FROM v, c"))
    "unexpected success"
  } catch {
    SqlError(message) => message
  }
  assert_eq(message, "no such table: missing")
  // execute clears this set on entry, so check before executing another SQL.
  assert_eq(db.expanding.length(), 0)
  assert_eq(cte_env.val.length(), 0)
  ignore(db.execute("CREATE TABLE missing(x)"))
  ignore(db.execute("INSERT INTO missing VALUES (3)"))
  let rows = db.execute("WITH c AS (SELECT 7 AS x) SELECT v.x, c.x FROM v, c").rows
  assert_eq(rows.length(), 1)
  assert_eq(rows[0][0].to_output(), "3")
  assert_eq(rows[0][1].to_output(), "7")
}

///|
test "window FILTER still binds and rejects unknown columns" {
  let db = Database::new()
  ignore(db.execute("CREATE TABLE t(x INTEGER)"))
  ignore(db.execute("INSERT INTO t VALUES (1), (2)"))
  let message = try {
    ignore(
      db.execute("SELECT sum(x) FILTER (WHERE missing > 0) OVER () FROM t"),
    )
    "unexpected success"
  } catch {
    SqlError(message) => message
  }
  assert_eq(message, "no such column: missing")
  let rows = db.execute("SELECT sum(x) FILTER (WHERE x > 1) OVER () FROM t").rows
  assert_eq(rows.length(), 2)
  assert_eq(rows[0][0].to_output(), "2")
  assert_eq(rows[1][0].to_output(), "2")
}
