///|
fn main {
  let input = @io.read_stdin()
  let db = @db.Database::new()
  let args = @io.args()
  let mut prefix = ""
  let mut existed = false
  let mut loaded = true
  if args.length() > 0 {
    match @io.read_file(args[0]) {
      Some(data) => {
        existed = true
        db.load_file(data) catch {
          @db.SqlError(msg) => {
            prefix = "Error: \{msg}\n"
            loaded = false
          }
        }
      }
      None => ()
    }
  }
  @io.write_stdout(prefix + @db.run_script(db, input))
  @io.flush_stdout()
  if args.length() > 0 && loaded {
    if db.image_to_save(existed) is Some(image) {
      ignore(@io.write_file(args[0], image))
    }
  }
}
