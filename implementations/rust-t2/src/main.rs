mod agg;
mod ast;
mod datetime;
mod engine;
mod func;
mod io;
mod lexer;
mod parser;
mod value;

fn main() {
    let input = io::read_stdin();
    let mut db = engine::Database::default();
    if let Some(path) = io::args().first() {
        if let Some(data) = io::read_file(path) {
            if let Err(msg) = db.load_file(&data) {
                io::write_stdout(&format!("Error: {}\n", msg));
            }
        }
    }
    for sql in lexer::split_statements(&input) {
        let result = parser::parse_statement(&sql).and_then(|stmt| db.execute(&stmt));
        match result {
            Ok(rows) => {
                let mut out = String::new();
                for row in rows {
                    for (i, v) in row.iter().enumerate() {
                        if i > 0 {
                            out.push('|');
                        }
                        out.push_str(&v.to_output());
                    }
                    out.push('\n');
                }
                io::write_stdout(&out);
            }
            Err(msg) => {
                let msg = msg.replace(['\n', '\r'], " ");
                io::write_stdout(&format!("Error: {}\n", msg));
            }
        }
    }
    if let Some(path) = io::args().first() {
        let existed = io::read_file(path).is_some();
        match db.save() {
            Ok(Some(data)) => {
                io::write_file(path, &data);
            }
            Ok(None) if !existed => {
                io::write_file(path, &[]);
            }
            Ok(None) => {}
            Err(msg) => io::write_stdout(&format!("Error: {}\n", msg)),
        }
    }
    io::flush_stdout();
}
