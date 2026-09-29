// Provided by the benchmark harness. Do not modify.
// All process I/O must go through this module.
#![allow(dead_code)]

use std::cell::RefCell;
use std::io::{Read, Write};

thread_local! {
    static OUT: RefCell<std::io::BufWriter<std::io::Stdout>> =
        RefCell::new(std::io::BufWriter::with_capacity(1 << 16, std::io::stdout()));
}

/// Reads all of standard input and decodes it as UTF-8
/// (invalid sequences become U+FFFD).
pub fn read_stdin() -> String {
    let mut buf = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut buf);
    String::from_utf8_lossy(&buf).into_owned()
}

/// Writes `s` to standard output as UTF-8. Output is buffered;
/// `main` calls `flush_stdout` before exiting.
pub fn write_stdout(s: &str) {
    OUT.with(|o| {
        let _ = o.borrow_mut().write_all(s.as_bytes());
    });
}

pub fn flush_stdout() {
    OUT.with(|o| {
        let _ = o.borrow_mut().flush();
    });
}

/// Command-line arguments, excluding the program name.
pub fn args() -> Vec<String> {
    std::env::args().skip(1).collect()
}

/// Reads a whole file. Returns `None` if it cannot be opened.
pub fn read_file(path: &str) -> Option<Vec<u8>> {
    std::fs::read(path).ok()
}

/// Creates or replaces a whole file. Returns `false` on failure.
pub fn write_file(path: &str, data: &[u8]) -> bool {
    std::fs::write(path, data).is_ok()
}
