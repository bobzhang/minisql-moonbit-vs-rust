///|
fn main {
  let input = @io.read_stdin()
  let db = @sql.Database::new()
  let args = @io.args()
  let mut old : Bytes? = None
  let mut writable = false
  if args.length() > 0 {
    old = @io.read_file(args[0])
    writable = true
    match old {
      Some(data) =>
        db.load_file(data) catch {
          @sql.SqlError(msg) => {
            @io.write_stdout("Error: " + msg + "\n")
            writable = false
          }
        }
      None => ()
    }
  }
  let before = db.state_fingerprint()
  @sql.run_script(db, input, s => @io.write_stdout(s))
  @io.flush_stdout()
  if writable {
    db.rollback_open_txn()
    let fresh = match old {
      Some(d) => d.length() == 0
      None => true
    }
    if fresh || db.state_fingerprint() != before {
      let old_image = if fresh { None } else { old }
      @io.write_file(args[0], db.file_image(old_image)) |> ignore
    }
  }
}
