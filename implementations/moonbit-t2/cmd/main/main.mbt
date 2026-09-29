///|
fn main {
  let input = @io.read_stdin()
  let db = @engine.Database::new()
  let args = @io.args()
  let mut existed = false
  if args.length() > 0 {
    if @io.read_file(args[0]) is Some(data) {
      existed = true
      db.load_file(data) catch {
        @engine.SqlError(msg) => {
          db.load_failed = true
          @io.write_stdout("Error: \{msg}\n")
        }
      }
    }
  }
  @engine.run_script(db, input)
  if args.length() > 0 {
    db.finish_file(args[0], existed)
  }
  @io.flush_stdout()
}
