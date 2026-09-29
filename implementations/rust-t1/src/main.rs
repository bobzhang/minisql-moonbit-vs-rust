#![allow(dead_code)]
mod access;
mod agg;
mod ast;
mod datetime;
mod db;
mod ddl;
mod alter;
mod error;
mod eval;
mod exec;
mod file;
mod func;
mod io;
mod lexer;
mod parser;
mod printf;
mod query;
mod sqltext;
mod write;
mod value;
mod window;

/// Split a script into statements on `;` outside quotes and comments
/// (SPEC §2.2). Pieces holding only whitespace and comments are dropped.
fn split_statements(script: &str) -> Vec<&str> {
    let b = script.as_bytes();
    let n = b.len();
    let mut out = Vec::new();
    let mut start = 0;
    let mut has_content = false;
    let mut i = 0;
    while i < n {
        let c = b[i];
        match c {
            b'\'' | b'"' | b'`' => {
                has_content = true;
                let mut j = i + 1;
                while j < n {
                    if b[j] == c {
                        if j + 1 < n && b[j + 1] == c {
                            j += 2;
                            continue;
                        }
                        break;
                    }
                    j += 1;
                }
                i = (j + 1).min(n);
            }
            b'[' => {
                has_content = true;
                let mut j = i + 1;
                while j < n && b[j] != b']' {
                    j += 1;
                }
                i = (j + 1).min(n);
            }
            b'-' if i + 1 < n && b[i + 1] == b'-' => {
                while i < n && b[i] != b'\n' {
                    i += 1;
                }
            }
            b'/' if i + 1 < n && b[i + 1] == b'*' => {
                let mut j = i + 2;
                while j + 1 < n && !(b[j] == b'*' && b[j + 1] == b'/') {
                    j += 1;
                }
                i = (j + 2).min(n);
            }
            b';' => {
                if has_content {
                    out.push(&script[start..i]);
                }
                has_content = false;
                i += 1;
                start = i;
            }
            _ => {
                if !c.is_ascii_whitespace() {
                    has_content = true;
                }
                i += 1;
            }
        }
    }
    if has_content {
        out.push(&script[start..]);
    }
    out
}

fn main() {
    // Run on a thread with a large stack: parsing and evaluation recurse.
    let h = std::thread::Builder::new().stack_size(512 << 20).spawn(run_script).unwrap();
    let _ = h.join();
    io::flush_stdout();
}

fn run_script() {
    let input = io::read_stdin();
    let mut engine = exec::Engine::new();
    let path = io::args().first().cloned();
    let mut existed = false;
    if let Some(path) = &path {
        if let Some(data) = io::read_file(path) {
            existed = true;
            let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| engine.load_file(&data)));
            match res {
                Ok(Ok(())) => {}
                Ok(Err(e)) => io::write_stdout(&format!("Error: {}\n", e)),
                Err(_) => io::write_stdout("Error: internal error\n"),
            }
        }
    }
    for stmt in split_statements(&input) {
        let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| engine.execute(stmt)));
        let res = match res {
            Ok(r) => r,
            Err(_) => Err(error::Error::new("internal error")),
        };
        match res {
            Ok(rows) => {
                let mut s = String::new();
                for row in rows {
                    for (i, v) in row.iter().enumerate() {
                        if i > 0 {
                            s.push('|');
                        }
                        s.push_str(&v.render());
                    }
                    s.push('\n');
                }
                io::write_stdout(&s);
            }
            Err(e) => {
                io::write_stdout(&format!("Error: {}\n", e.to_string().replace('\n', " ")));
            }
        }
    }
    io::flush_stdout();
    if let Some(path) = &path {
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| engine.save(path, existed)));
    }
}
