// Provided by the benchmark harness. Do not modify.
// All process I/O must go through this package.

///|
extern "c" fn read_stdin_ffi() -> Bytes = "minisql_io_read_stdin"

///|
#borrow(data)
extern "c" fn write_stdout_ffi(data : Bytes) -> Unit = "minisql_io_write_stdout"

///|
extern "c" fn flush_stdout_ffi() -> Unit = "minisql_io_flush_stdout"

///|
#borrow(path)
extern "c" fn file_exists_ffi(path : Bytes) -> Int = "minisql_io_file_exists"

///|
#borrow(path)
extern "c" fn read_file_ffi(path : Bytes) -> Bytes = "minisql_io_read_file"

///|
#borrow(path, data)
extern "c" fn write_file_ffi(path : Bytes, data : Bytes) -> Int = "minisql_io_write_file"

///|
/// Reads all of standard input and decodes it as UTF-8
/// (invalid sequences become U+FFFD).
pub fn read_stdin() -> String {
  @utf8.decode_lossy(read_stdin_ffi())
}

///|
/// Writes `s` to standard output as UTF-8. Output is buffered;
/// `main` calls `flush_stdout` before exiting.
pub fn write_stdout(s : String) -> Unit {
  write_stdout_ffi(@utf8.encode(s))
}

///|
pub fn flush_stdout() -> Unit {
  flush_stdout_ffi()
}

///|
/// Command-line arguments, excluding the program name.
pub fn args() -> Array[String] {
  let all = @env.args()
  if all.length() <= 1 {
    []
  } else {
    all[1:].to_owned()
  }
}

///|
/// Reads a whole file. Returns `None` if it cannot be opened.
pub fn read_file(path : String) -> Bytes? {
  let p = @utf8.encode(path)
  if file_exists_ffi(p) == 0 {
    None
  } else {
    Some(read_file_ffi(p))
  }
}

///|
/// Creates or replaces a whole file. Returns `false` on failure.
pub fn write_file(path : String, data : Bytes) -> Bool {
  write_file_ffi(@utf8.encode(path), data) != 0
}
