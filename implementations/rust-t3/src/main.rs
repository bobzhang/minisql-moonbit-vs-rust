mod access;
mod agg;
mod ast;
mod cte;
mod datetime;
mod db;
mod ddl;
mod eval;
mod exec;
mod flatten;
mod functions;
mod io;
mod lexer;
mod parser;
mod printf;
mod query;
mod split;
mod sqlfile;
mod sqlwrite;
mod value;
mod window;

use std::panic::{catch_unwind, AssertUnwindSafe};

fn run_statement(db: &mut db::Database, sql: &str) -> Result<String, String> {
    let stmt = parser::parse_statement(sql)?;
    let rows = exec::execute(db, &stmt)?;
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
    Ok(out)
}

fn main() {
    let input = io::read_stdin();
    let mut db = db::Database::new();
    let path = io::args().first().cloned();
    let mut old_file = None;
    if let Some(path) = &path {
        if let Some(data) = io::read_file(path) {
            match catch_unwind(AssertUnwindSafe(|| sqlfile::load(&mut db, &data))) {
                Ok(Ok(())) => {}
                Ok(Err(e)) => io::write_stdout(&format!("Error: {}\n", e)),
                Err(_) => io::write_stdout("Error: database disk image is malformed\n"),
            }
            old_file = Some(data);
        }
    }
    db.dirty = false;
    db.schema_dirty = false;
    for sql in split::split(&input) {
        let mark = db.mark();
        let res = catch_unwind(AssertUnwindSafe(|| run_statement(&mut db, &sql)));
        match res {
            Ok(Ok(out)) => io::write_stdout(&out),
            Ok(Err(msg)) => io::write_stdout(&format!("Error: {}\n", msg.replace(['\n', '\r'], " "))),
            Err(_) => {
                // undo whatever the failed statement changed
                db.rollback_to(mark);
                db.end_statement();
                io::write_stdout("Error: internal error\n")
            }
        }
    }
    // an explicit transaction still open at the end is rolled back
    db.abort_txn();
    if let Some(path) = &path {
        if db.dirty {
            let saved = catch_unwind(AssertUnwindSafe(|| sqlwrite::save(&db, old_file.as_deref(), db.schema_dirty)));
            match saved {
                Ok(Ok(bytes)) => {
                    if !io::write_file(path, &bytes) {
                        io::write_stdout("Error: unable to write database file\n");
                    }
                }
                Ok(Err(e)) => io::write_stdout(&format!("Error: {}\n", e)),
                Err(_) => io::write_stdout("Error: internal error while writing the database\n"),
            }
        }
    }
    io::flush_stdout();
}
