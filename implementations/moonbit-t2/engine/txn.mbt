// Transactions and savepoints (in-memory snapshots of the database).

///|
fn Database::end_txn(self : Database) -> Unit {
  self.in_txn = false
  self.txn_by_savepoint = false
  self.txn_snap = None
  self.savepoints.clear()
}

///|
fn Database::find_savepoint(self : Database, name : String) -> Int? {
  for i = self.savepoints.length() - 1; i >= 0; i = i - 1 {
    if self.savepoints[i].0.equal_ignore_ascii_case(name) {
      return Some(i)
    }
  }
  None
}

///|
fn Database::txn_control(self : Database, st : Stmt) -> Unit raise SqlError {
  match st {
    BeginStmt => {
      if self.in_txn {
        raise SqlError("cannot start a transaction within a transaction")
      }
      self.in_txn = true
      self.txn_by_savepoint = false
      self.txn_snap = Some(self.snapshot())
    }
    CommitStmt => {
      if !self.in_txn {
        raise SqlError("cannot commit - no transaction is active")
      }
      self.end_txn()
    }
    RollbackStmt(None) => {
      if !self.in_txn {
        raise SqlError("cannot rollback - no transaction is active")
      }
      if self.txn_snap is Some(s) {
        self.restore(s)
      }
      self.end_txn()
    }
    RollbackStmt(Some(name)) => {
      guard self.find_savepoint(name) is Some(i) else {
        raise SqlError("no such savepoint: \{name}")
      }
      self.restore(self.savepoints[i].1)
      self.savepoints.truncate(i + 1)
    }
    SavepointStmt(name) => {
      let snap = self.snapshot()
      if !self.in_txn {
        self.in_txn = true
        self.txn_by_savepoint = true
        self.txn_snap = Some(snap)
      }
      self.savepoints.push((name, snap))
    }
    ReleaseStmt(name) => {
      guard self.find_savepoint(name) is Some(i) else {
        raise SqlError("no such savepoint: \{name}")
      }
      self.savepoints.truncate(i)
      if i == 0 && self.txn_by_savepoint {
        self.end_txn()
      }
    }
    _ => ()
  }
}

///|
/// Executes one statement atomically: on error its effects are undone
/// (unless a FAIL conflict asked to keep them; a ROLLBACK conflict undoes
/// the whole transaction).
pub fn Database::execute_atomic(
  self : Database,
  st : Stmt,
) -> Array[Array[Value]] raise SqlError {
  match st {
    BeginStmt
    | CommitStmt
    | RollbackStmt(_)
    | SavepointStmt(_)
    | ReleaseStmt(_) => {
      self.txn_control(st)
      return []
    }
    _ => ()
  }
  if !(st is SelectStmt(_)) {
    self.dirty = true
  }
  let snap = self.snapshot()
  self.keep_on_error = false
  self.rollback_txn = false
  errdefer (if self.rollback_txn && self.in_txn {
    if self.txn_snap is Some(s) {
      self.restore(s)
    }
    self.end_txn()
  } else if !self.keep_on_error {
    self.restore(snap)
  })
  self.execute(st)
}
