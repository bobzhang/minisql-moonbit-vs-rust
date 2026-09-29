// Recursive-descent SQL parser.

use std::rc::Rc;

use crate::ast::*;
use crate::lexer::{tokenize, Tok, Token};
use crate::value::Value;

/// Keywords that cannot be used as bare identifiers or implicit aliases.
const RESERVED: &[&str] = &[
    "ADD", "ALL", "ALTER", "AND", "AS", "AUTOINCREMENT", "BETWEEN", "CASE", "CHECK", "COLLATE",
    "COMMIT", "CONSTRAINT", "CREATE", "CROSS", "DEFAULT", "DEFERRABLE", "DELETE", "DISTINCT",
    "DROP", "ELSE", "ESCAPE", "EXCEPT", "EXISTS", "FILTER", "FOREIGN", "FROM", "FULL", "GLOB",
    "GROUP", "HAVING", "IN", "INDEX", "INNER", "INSERT", "INTERSECT", "INTO", "IS", "ISNULL",
    "JOIN", "LEFT", "LIKE", "LIMIT", "NATURAL", "NOT", "NOTHING", "NOTNULL", "NULL", "ON", "OR",
    "ORDER", "OUTER", "OVER", "PRIMARY", "REFERENCES", "REGEXP", "RETURNING", "RIGHT", "ROLLBACK",
    "SELECT", "SET", "TABLE", "THEN", "TO", "TRANSACTION", "UNION", "UNIQUE", "UPDATE", "USING",
    "VALUES", "WHEN", "WHERE", "WINDOW", "MATCH",
];

fn is_reserved(s: &str) -> bool {
    RESERVED.iter().any(|k| k.eq_ignore_ascii_case(s))
}

// Binary operator precedence levels.
const P_OR: u8 = 1;
const P_AND: u8 = 2;
const P_NOT: u8 = 3;
const P_EQ: u8 = 4;
const P_CMP: u8 = 5;
const P_BIT: u8 = 7;
const P_ADD: u8 = 8;
const P_MUL: u8 = 9;
const P_CONCAT: u8 = 10;
const P_COLLATE: u8 = 11;

const LIKE_OPS: [&str; 4] = ["LIKE", "GLOB", "REGEXP", "MATCH"];

pub struct Parser<'a> {
    src: &'a str,
    toks: Vec<Token>,
    pos: usize,
    /// CREATE TEMP ...
    temp: bool,
}

pub type PResult<T> = Result<T, String>;

pub fn parse_statement(src: &str) -> PResult<Stmt> {
    let toks = tokenize(src)?;
    let mut p = Parser { src, toks, pos: 0, temp: false };
    let stmt = p.statement()?;
    if !p.at_eof() {
        return Err(p.err_near());
    }
    Ok(stmt)
}

impl<'a> Parser<'a> {
    fn peek(&self) -> &Tok {
        &self.toks[self.pos].tok
    }

    fn peek_at(&self, k: usize) -> &Tok {
        let i = (self.pos + k).min(self.toks.len() - 1);
        &self.toks[i].tok
    }

    fn advance(&mut self) -> Tok {
        let t = self.toks[self.pos].tok.clone();
        if self.pos < self.toks.len() - 1 {
            self.pos += 1;
        }
        t
    }

    fn at_eof(&self) -> bool {
        matches!(self.peek(), Tok::Eof)
    }

    fn err_near(&self) -> String {
        if self.at_eof() {
            return "incomplete input".to_string();
        }
        let t = &self.toks[self.pos];
        format!("near \"{}\": syntax error", &self.src[t.start..t.end])
    }

    fn is_kw(&self, kw: &str) -> bool {
        matches!(self.peek(), Tok::Id(s) if s.eq_ignore_ascii_case(kw))
    }

    fn is_kw_at(&self, k: usize, kw: &str) -> bool {
        matches!(self.peek_at(k), Tok::Id(s) if s.eq_ignore_ascii_case(kw))
    }

    fn eat_kw(&mut self, kw: &str) -> bool {
        if self.is_kw(kw) {
            self.advance();
            true
        } else {
            false
        }
    }

    fn expect_kw(&mut self, kw: &str) -> PResult<()> {
        if self.eat_kw(kw) {
            Ok(())
        } else {
            Err(self.err_near())
        }
    }

    fn is_op(&self, op: &str) -> bool {
        matches!(self.peek(), Tok::Op(o) if *o == op)
    }

    fn eat_op(&mut self, op: &str) -> bool {
        if self.is_op(op) {
            self.advance();
            true
        } else {
            false
        }
    }

    fn expect_op(&mut self, op: &str) -> PResult<()> {
        if self.eat_op(op) {
            Ok(())
        } else {
            Err(self.err_near())
        }
    }

    /// An identifier (table, column, alias, ...).
    fn name(&mut self) -> PResult<String> {
        match self.peek().clone() {
            Tok::Id(s) if !is_reserved(&s) => {
                self.advance();
                Ok(s)
            }
            Tok::QId(s) | Tok::DqId(s) | Tok::Str(s) => {
                self.advance();
                Ok(s)
            }
            _ => Err(self.err_near()),
        }
    }

    /// A possibly schema-qualified object name; the schema is ignored.
    fn qualified_name(&mut self) -> PResult<String> {
        Ok(self.qualified_name_at()?.0)
    }

    /// A possibly schema-qualified name and the source offset where the
    /// (unqualified) name starts.
    fn qualified_name_at(&mut self) -> PResult<(String, usize)> {
        let mut start = self.toks[self.pos].start;
        let n = self.name()?;
        if self.eat_op(".") {
            start = self.toks[self.pos].start;
            return Ok((self.name()?, start));
        }
        Ok((n, start))
    }

    /// Schema text of a CREATE statement: SQLite keeps the text from the
    /// object name on, after a normalized "CREATE <kind>".
    fn schema_sql(&self, kind: &str, name_start: usize) -> String {
        let end = self.toks[self.pos.saturating_sub(1)].end.max(name_start);
        format!("CREATE {} {}", kind, &self.src[name_start..end])
    }

    fn statement(&mut self) -> PResult<Stmt> {
        if self.is_kw("WITH") {
            let with = self.with_clause()?;
            if self.is_kw("INSERT") || self.is_kw("REPLACE") {
                let Stmt::Insert(mut ins) = self.insert()? else { unreachable!() };
                ins.with = with;
                return Ok(Stmt::Insert(ins));
            }
            if self.eat_kw("UPDATE") {
                let Stmt::Update(mut upd) = self.update()? else { unreachable!() };
                upd.with = with;
                return Ok(Stmt::Update(upd));
            }
            if self.eat_kw("DELETE") {
                let Stmt::Delete(mut del) = self.delete()? else { unreachable!() };
                del.with = with;
                return Ok(Stmt::Delete(del));
            }
            let mut q = self.select_body()?;
            q.with = with;
            return Ok(Stmt::Select(q));
        }
        if self.is_query_start() {
            return Ok(Stmt::Select(self.select()?));
        }
        if self.eat_kw("CREATE") {
            if self.eat_kw("TEMP") || self.eat_kw("TEMPORARY") {
                self.temp = true;
                if !self.is_kw("TABLE") && !self.is_kw("VIEW") {
                    return Err(self.err_near());
                }
            }
            if self.is_kw("TABLE") {
                return self.create_table();
            }
            if self.is_kw("UNIQUE") || self.is_kw("INDEX") {
                return self.create_index();
            }
            if self.is_kw("VIEW") {
                return self.create_view();
            }
            return Err(self.err_near());
        }
        if self.eat_kw("DROP") {
            let kind = if self.eat_kw("TABLE") {
                0
            } else if self.eat_kw("INDEX") {
                1
            } else if self.eat_kw("VIEW") {
                2
            } else {
                return Err(self.err_near());
            };
            let mut if_exists = false;
            if self.eat_kw("IF") {
                self.expect_kw("EXISTS")?;
                if_exists = true;
            }
            let name = self.qualified_name()?;
            return Ok(match kind {
                0 => Stmt::DropTable { name, if_exists },
                1 => Stmt::DropIndex { name, if_exists },
                _ => Stmt::DropView { name, if_exists },
            });
        }
        if self.eat_kw("ALTER") {
            return self.alter_table();
        }
        if self.eat_kw("BEGIN") {
            let _ = self.eat_kw("DEFERRED") || self.eat_kw("IMMEDIATE") || self.eat_kw("EXCLUSIVE");
            self.eat_kw("TRANSACTION");
            return Ok(Stmt::Begin);
        }
        if self.eat_kw("COMMIT") || self.eat_kw("END") {
            self.eat_kw("TRANSACTION");
            return Ok(Stmt::Commit);
        }
        if self.eat_kw("ROLLBACK") {
            self.eat_kw("TRANSACTION");
            if self.eat_kw("TO") {
                self.eat_kw("SAVEPOINT");
                return Ok(Stmt::Rollback(Some(self.name()?)));
            }
            return Ok(Stmt::Rollback(None));
        }
        if self.eat_kw("SAVEPOINT") {
            return Ok(Stmt::Savepoint(self.name()?));
        }
        if self.eat_kw("RELEASE") {
            self.eat_kw("SAVEPOINT");
            return Ok(Stmt::Release(self.name()?));
        }
        if self.is_kw("INSERT") || self.is_kw("REPLACE") {
            return self.insert();
        }
        if self.eat_kw("UPDATE") {
            return self.update();
        }
        if self.eat_kw("DELETE") {
            return self.delete();
        }
        Err(self.err_near())
    }

    // ---------- CREATE TABLE ----------

    fn create_table(&mut self) -> PResult<Stmt> {
        self.expect_kw("TABLE")?;
        let mut if_not_exists = false;
        if self.eat_kw("IF") {
            self.expect_kw("NOT")?;
            self.expect_kw("EXISTS")?;
            if_not_exists = true;
        }
        let (name, name_start) = self.qualified_name_at()?;
        self.expect_op("(")?;
        let mut columns = Vec::new();
        let mut constraints = Vec::new();
        loop {
            if self.is_table_constraint_start() {
                break;
            }
            columns.push(self.column_def()?);
            if self.eat_op(",") {
                continue;
            }
            break;
        }
        if !self.is_op(")") {
            // table constraints, optionally separated by commas
            loop {
                constraints.push(self.table_constraint()?);
                if self.eat_op(",") {
                    continue;
                }
                if self.is_op(")") {
                    break;
                }
                if !self.is_table_constraint_start() {
                    return Err(self.err_near());
                }
            }
        }
        self.expect_op(")")?;
        // table options
        loop {
            if self.eat_kw("WITHOUT") {
                self.name()?;
            } else if self.eat_kw("STRICT") {
            } else {
                break;
            }
            if !self.eat_op(",") {
                break;
            }
        }
        Ok(Stmt::CreateTable(CreateTable {
            name,
            if_not_exists,
            temp: self.temp,
            columns,
            constraints,
            sql: self.schema_sql("TABLE", name_start),
        }))
    }

    // ---------- CREATE INDEX / VIEW, ALTER TABLE ----------

    fn create_index(&mut self) -> PResult<Stmt> {
        let unique = self.eat_kw("UNIQUE");
        self.expect_kw("INDEX")?;
        let mut if_not_exists = false;
        if self.eat_kw("IF") {
            self.expect_kw("NOT")?;
            self.expect_kw("EXISTS")?;
            if_not_exists = true;
        }
        let (name, name_start) = self.qualified_name_at()?;
        self.expect_kw("ON")?;
        let table = self.name()?;
        let columns = self.indexed_columns()?;
        let where_ = if self.eat_kw("WHERE") { Some(self.expr()?) } else { None };
        Ok(Stmt::CreateIndex(CreateIndex {
            name,
            table,
            unique,
            if_not_exists,
            columns,
            where_,
            sql: self.schema_sql(if unique { "UNIQUE INDEX" } else { "INDEX" }, name_start),
        }))
    }

    fn create_view(&mut self) -> PResult<Stmt> {
        self.expect_kw("VIEW")?;
        let mut if_not_exists = false;
        if self.eat_kw("IF") {
            self.expect_kw("NOT")?;
            self.expect_kw("EXISTS")?;
            if_not_exists = true;
        }
        let (name, name_start) = self.qualified_name_at()?;
        let mut columns = None;
        if self.eat_op("(") {
            let mut cols = Vec::new();
            loop {
                cols.push(self.name()?);
                if !self.eat_op(",") {
                    break;
                }
            }
            self.expect_op(")")?;
            columns = Some(cols);
        }
        self.expect_kw("AS")?;
        let select = self.select()?;
        Ok(Stmt::CreateView(CreateView {
            name,
            if_not_exists,
            temp: self.temp,
            columns,
            select,
            sql: self.schema_sql("VIEW", name_start),
        }))
    }

    fn alter_table(&mut self) -> PResult<Stmt> {
        self.expect_kw("TABLE")?;
        let table = self.qualified_name()?;
        let action = if self.eat_kw("RENAME") {
            if self.eat_kw("TO") {
                AlterAction::RenameTable(self.name()?)
            } else {
                self.eat_kw("COLUMN");
                let old = self.name()?;
                self.expect_kw("TO")?;
                AlterAction::RenameColumn(old, self.name()?)
            }
        } else if self.eat_kw("ADD") {
            self.eat_kw("COLUMN");
            let start = self.toks[self.pos].start;
            let def = self.column_def()?;
            let end = self.toks[self.pos.saturating_sub(1)].end.max(start);
            AlterAction::AddColumn(def, self.src[start..end].to_string())
        } else if self.eat_kw("DROP") {
            self.eat_kw("COLUMN");
            AlterAction::DropColumn(self.name()?)
        } else {
            return Err(self.err_near());
        };
        Ok(Stmt::AlterTable { table, action })
    }

    fn is_table_constraint_start(&self) -> bool {
        ["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"].iter().any(|k| self.is_kw(k))
    }

    fn is_column_constraint_start(&self) -> bool {
        [
            "CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT", "COLLATE",
            "REFERENCES", "GENERATED", "AS",
        ]
        .iter()
        .any(|k| self.is_kw(k))
    }

    fn column_def(&mut self) -> PResult<ColumnDef> {
        let name = self.name()?;
        let type_name = self.type_name()?;
        let mut constraints = Vec::new();
        loop {
            let mut cname = None;
            if self.eat_kw("CONSTRAINT") {
                cname = Some(self.name()?);
            }
            if self.eat_kw("PRIMARY") {
                self.expect_kw("KEY")?;
                let mut desc = false;
                if self.eat_kw("DESC") {
                    desc = true;
                } else {
                    self.eat_kw("ASC");
                }
                let conflict = self.conflict_clause()?;
                let autoincrement = self.eat_kw("AUTOINCREMENT");
                constraints.push(ColumnConstraint::PrimaryKey { desc, conflict, autoincrement });
            } else if self.eat_kw("NOT") {
                self.expect_kw("NULL")?;
                let c = self.conflict_clause()?;
                constraints.push(ColumnConstraint::NotNull(c));
            } else if self.eat_kw("NULL") {
                self.conflict_clause()?;
            } else if self.eat_kw("UNIQUE") {
                let c = self.conflict_clause()?;
                constraints.push(ColumnConstraint::Unique(c));
            } else if self.eat_kw("CHECK") {
                let (e, text) = self.paren_expr_text()?;
                constraints.push(ColumnConstraint::Check(e, cname.unwrap_or(text)));
            } else if self.eat_kw("DEFAULT") {
                let e = if self.eat_op("(") {
                    let e = self.expr()?;
                    self.expect_op(")")?;
                    e
                } else if self.is_op("-") || self.is_op("+") {
                    let neg = self.is_op("-");
                    self.advance();
                    let e = self.literal_value()?;
                    if neg {
                        negate_literal(e)
                    } else {
                        e
                    }
                } else if let Tok::Id(s) = self.peek().clone() {
                    // bare identifiers like TRUE, CURRENT_TIMESTAMP or a word used as text
                    self.advance();
                    if s.eq_ignore_ascii_case("true") {
                        Expr::Literal(Value::Integer(1))
                    } else if s.eq_ignore_ascii_case("false") {
                        Expr::Literal(Value::Integer(0))
                    } else if s.eq_ignore_ascii_case("null") {
                        Expr::Literal(Value::Null)
                    } else {
                        Expr::Column { table: None, name: s, dq: true }
                    }
                } else {
                    self.literal_value()?
                };
                constraints.push(ColumnConstraint::Default(e));
            } else if self.eat_kw("COLLATE") {
                let c = self.name()?;
                constraints.push(ColumnConstraint::Collate(c));
            } else if self.is_kw("REFERENCES") {
                let fk = self.foreign_key_clause()?;
                constraints.push(ColumnConstraint::References(fk));
            } else if self.is_kw("GENERATED") || self.is_kw("AS") {
                if self.eat_kw("GENERATED") {
                    self.expect_kw("ALWAYS")?;
                }
                self.expect_kw("AS")?;
                self.expect_op("(")?;
                let expr = self.expr()?;
                self.expect_op(")")?;
                let stored = if self.eat_kw("STORED") {
                    true
                } else {
                    self.eat_kw("VIRTUAL");
                    false
                };
                constraints.push(ColumnConstraint::Generated { expr, stored });
            } else {
                break;
            }
        }
        Ok(ColumnDef { name, type_name, constraints })
    }

    /// An optional type name: words, optionally followed by `(n)` or `(n, m)`.
    fn type_name(&mut self) -> PResult<Option<String>> {
        let mut words: Vec<String> = Vec::new();
        loop {
            match self.peek().clone() {
                Tok::Id(s) if !self.is_column_constraint_start() => {
                    self.advance();
                    words.push(s);
                }
                Tok::QId(s) | Tok::DqId(s) | Tok::Str(s) => {
                    self.advance();
                    words.push(s);
                }
                _ => break,
            }
        }
        let mut type_name = if words.is_empty() { None } else { Some(words.join(" ")) };
        if type_name.is_some() && self.is_op("(") {
            let start = self.toks[self.pos].start;
            self.advance();
            self.signed_number()?;
            if self.eat_op(",") {
                self.signed_number()?;
            }
            let end = self.toks[self.pos].end;
            self.expect_op(")")?;
            let args = &self.src[start..end];
            let args: String = args.split_whitespace().collect::<Vec<_>>().join(" ");
            type_name = Some(format!("{}{}", type_name.unwrap(), args));
        }
        Ok(type_name)
    }

    fn signed_number(&mut self) -> PResult<()> {
        if self.is_op("+") || self.is_op("-") {
            self.advance();
        }
        match self.peek() {
            Tok::Int(_) | Tok::Float(_) => {
                self.advance();
                Ok(())
            }
            _ => Err(self.err_near()),
        }
    }

    fn literal_value(&mut self) -> PResult<Expr> {
        let t = self.toks[self.pos].clone();
        let v = match &t.tok {
            Tok::Int(Some(i)) => Value::Integer(*i),
            Tok::Int(None) => Value::Real(self.src[t.start..t.end].parse::<f64>().unwrap_or(0.0)),
            Tok::Float(f) => Value::Real(*f),
            Tok::Str(s) => Value::Text(s.clone()),
            Tok::Blob(b) => Value::Blob(b.clone()),
            Tok::Id(s) if s.eq_ignore_ascii_case("NULL") => Value::Null,
            _ => return Err(self.err_near()),
        };
        self.advance();
        Ok(Expr::Literal(v))
    }

    fn conflict_clause(&mut self) -> PResult<Option<Conflict>> {
        if !(self.is_kw("ON") && self.is_kw_at(1, "CONFLICT")) {
            return Ok(None);
        }
        self.advance();
        self.advance();
        let c = if self.eat_kw("ROLLBACK") {
            Conflict::Rollback
        } else if self.eat_kw("ABORT") {
            Conflict::Abort
        } else if self.eat_kw("FAIL") {
            Conflict::Fail
        } else if self.eat_kw("IGNORE") {
            Conflict::Ignore
        } else if self.eat_kw("REPLACE") {
            Conflict::Replace
        } else {
            return Err(self.err_near());
        };
        Ok(Some(c))
    }

    fn foreign_key_clause(&mut self) -> PResult<ForeignKey> {
        self.expect_kw("REFERENCES")?;
        let table = self.name()?;
        let mut columns = Vec::new();
        if self.eat_op("(") {
            loop {
                columns.push(self.name()?);
                if !self.eat_op(",") {
                    break;
                }
            }
            self.expect_op(")")?;
        }
        loop {
            if self.eat_kw("ON") {
                if !(self.eat_kw("DELETE") || self.eat_kw("UPDATE")) {
                    return Err(self.err_near());
                }
                if self.eat_kw("SET") {
                    if !(self.eat_kw("NULL") || self.eat_kw("DEFAULT")) {
                        return Err(self.err_near());
                    }
                } else if self.eat_kw("CASCADE") || self.eat_kw("RESTRICT") {
                } else if self.eat_kw("NO") {
                    self.expect_kw("ACTION")?;
                } else {
                    return Err(self.err_near());
                }
            } else if self.eat_kw("MATCH") {
                self.name()?;
            } else if self.is_kw("DEFERRABLE") || (self.is_kw("NOT") && self.is_kw_at(1, "DEFERRABLE")) {
                self.eat_kw("NOT");
                self.advance();
                if self.eat_kw("INITIALLY") {
                    if !(self.eat_kw("DEFERRED") || self.eat_kw("IMMEDIATE")) {
                        return Err(self.err_near());
                    }
                }
            } else {
                break;
            }
        }
        Ok(ForeignKey { table, columns })
    }

    /// `( expr )`, returning the expression and its source text.
    fn paren_expr_text(&mut self) -> PResult<(Expr, String)> {
        self.expect_op("(")?;
        let start = self.toks[self.pos].start;
        let e = self.expr()?;
        let end = self.toks[self.pos - 1].end;
        self.expect_op(")")?;
        Ok((e, self.src[start..end.max(start)].to_string()))
    }

    fn indexed_columns(&mut self) -> PResult<Vec<IndexedColumn>> {
        Ok(self.indexed_columns_autoinc(false)?.0)
    }

    fn indexed_columns_autoinc(&mut self, allow_autoinc: bool) -> PResult<(Vec<IndexedColumn>, bool)> {
        self.expect_op("(")?;
        let mut cols = Vec::new();
        let mut autoinc = false;
        loop {
            let mut expr = self.expr()?;
            let mut collate = None;
            if let Expr::Collate(inner, c) = expr {
                collate = Some(c);
                expr = *inner;
            }
            if self.eat_kw("COLLATE") {
                collate = Some(self.name()?);
            }
            let mut desc = false;
            if self.eat_kw("DESC") {
                desc = true;
            } else {
                self.eat_kw("ASC");
            }
            cols.push(IndexedColumn { expr, collate, desc });
            if allow_autoinc && self.eat_kw("AUTOINCREMENT") {
                autoinc = true;
            }
            if !self.eat_op(",") {
                break;
            }
        }
        self.expect_op(")")?;
        Ok((cols, autoinc))
    }

    fn table_constraint(&mut self) -> PResult<TableConstraint> {
        let mut cname = None;
        if self.eat_kw("CONSTRAINT") {
            cname = Some(self.name()?);
        }
        if self.eat_kw("PRIMARY") {
            self.expect_kw("KEY")?;
            let (columns, autoincrement) = self.indexed_columns_autoinc(true)?;
            let conflict = self.conflict_clause()?;
            Ok(TableConstraint::PrimaryKey { columns, conflict, autoincrement })
        } else if self.eat_kw("UNIQUE") {
            let columns = self.indexed_columns()?;
            let conflict = self.conflict_clause()?;
            Ok(TableConstraint::Unique { columns, conflict })
        } else if self.eat_kw("CHECK") {
            let (e, text) = self.paren_expr_text()?;
            Ok(TableConstraint::Check(e, cname.unwrap_or(text)))
        } else if self.eat_kw("FOREIGN") {
            self.expect_kw("KEY")?;
            self.expect_op("(")?;
            let mut columns = Vec::new();
            loop {
                columns.push(self.name()?);
                if !self.eat_op(",") {
                    break;
                }
            }
            self.expect_op(")")?;
            let fk = self.foreign_key_clause()?;
            Ok(TableConstraint::ForeignKey { columns, fk })
        } else {
            Err(self.err_near())
        }
    }

    // ---------- INSERT ----------

    fn or_conflict(&mut self) -> PResult<Option<Conflict>> {
        if !self.eat_kw("OR") {
            return Ok(None);
        }
        let c = if self.eat_kw("ROLLBACK") {
            Conflict::Rollback
        } else if self.eat_kw("ABORT") {
            Conflict::Abort
        } else if self.eat_kw("FAIL") {
            Conflict::Fail
        } else if self.eat_kw("IGNORE") {
            Conflict::Ignore
        } else if self.eat_kw("REPLACE") {
            Conflict::Replace
        } else {
            return Err(self.err_near());
        };
        Ok(Some(c))
    }

    fn insert(&mut self) -> PResult<Stmt> {
        let or = if self.eat_kw("REPLACE") {
            Some(Conflict::Replace)
        } else {
            self.expect_kw("INSERT")?;
            self.or_conflict()?
        };
        self.expect_kw("INTO")?;
        let table = self.qualified_name()?;
        let alias = if self.eat_kw("AS") { Some(self.name()?) } else { None };
        let mut columns = None;
        if self.eat_op("(") {
            let mut cols = Vec::new();
            loop {
                cols.push(self.name()?);
                if !self.eat_op(",") {
                    break;
                }
            }
            self.expect_op(")")?;
            columns = Some(cols);
        }
        let source = if self.eat_kw("DEFAULT") {
            self.expect_kw("VALUES")?;
            InsertSource::Default
        } else {
            let q = self.select()?;
            let plain_values = q.cores.len() == 1
                && q.order_by.is_empty()
                && q.limit.is_none()
                && matches!(q.cores[0], SelectCore::Values(_));
            if plain_values {
                match q.cores.into_iter().next() {
                    Some(SelectCore::Values(rows)) => InsertSource::Values(rows),
                    _ => unreachable!(),
                }
            } else {
                InsertSource::Select(Box::new(q))
            }
        };
        let mut upserts = Vec::new();
        if !matches!(source, InsertSource::Default) {
            while self.is_kw("ON") && self.is_kw_at(1, "CONFLICT") {
                self.advance();
                self.advance();
                upserts.push(self.upsert()?);
            }
        }
        let returning = self.returning()?;
        Ok(Stmt::Insert(Insert { with: None, or, table, alias, columns, source, upserts, returning }))
    }

    fn values_rows(&mut self) -> PResult<Vec<Vec<Expr>>> {
        let mut rows: Vec<Vec<Expr>> = Vec::new();
        loop {
            self.expect_op("(")?;
            let mut row = Vec::new();
            loop {
                row.push(self.expr()?);
                if !self.eat_op(",") {
                    break;
                }
            }
            self.expect_op(")")?;
            if let Some(first) = rows.first() {
                if first.len() != row.len() {
                    return Err("all VALUES must have the same number of terms".to_string());
                }
            }
            rows.push(row);
            if !self.eat_op(",") {
                break;
            }
        }
        Ok(rows)
    }

    fn upsert(&mut self) -> PResult<Upsert> {
        let mut target = None;
        if self.is_op("(") {
            target = Some(self.indexed_columns()?);
            if self.eat_kw("WHERE") {
                self.expr()?;
            }
        }
        self.expect_kw("DO")?;
        let action = if self.eat_kw("NOTHING") {
            UpsertAction::Nothing
        } else {
            self.expect_kw("UPDATE")?;
            self.expect_kw("SET")?;
            let sets = self.assignments()?;
            let where_ = if self.eat_kw("WHERE") { Some(self.expr()?) } else { None };
            UpsertAction::Update { sets, where_ }
        };
        Ok(Upsert { target, action })
    }

    /// `col = expr, (a, b) = (x, y), ...`
    fn assignments(&mut self) -> PResult<Vec<(String, Expr)>> {
        let mut sets = Vec::new();
        loop {
            if self.eat_op("(") {
                let mut names = Vec::new();
                loop {
                    names.push(self.name()?);
                    if !self.eat_op(",") {
                        break;
                    }
                }
                self.expect_op(")")?;
                self.expect_op("=")?;
                self.expect_op("(")?;
                let mut exprs = Vec::new();
                loop {
                    exprs.push(self.expr()?);
                    if !self.eat_op(",") {
                        break;
                    }
                }
                self.expect_op(")")?;
                if names.len() != exprs.len() {
                    return Err(format!("{} columns assigned {} values", names.len(), exprs.len()));
                }
                sets.extend(names.into_iter().zip(exprs));
            } else {
                let n = self.name()?;
                self.expect_op("=")?;
                sets.push((n, self.expr()?));
            }
            if !self.eat_op(",") {
                break;
            }
        }
        Ok(sets)
    }

    fn returning(&mut self) -> PResult<Vec<ResultColumn>> {
        let mut cols = Vec::new();
        if self.eat_kw("RETURNING") {
            loop {
                cols.push(self.result_column()?);
                if !self.eat_op(",") {
                    break;
                }
            }
        }
        Ok(cols)
    }

    fn update(&mut self) -> PResult<Stmt> {
        let or = self.or_conflict()?;
        let table = self.qualified_name()?;
        let alias = self.opt_alias()?;
        self.expect_kw("SET")?;
        let sets = self.assignments()?;
        let where_ = if self.eat_kw("WHERE") { Some(self.expr()?) } else { None };
        let returning = self.returning()?;
        Ok(Stmt::Update(Update { with: None, or, table, alias, sets, where_, returning }))
    }

    fn delete(&mut self) -> PResult<Stmt> {
        self.expect_kw("FROM")?;
        let table = self.qualified_name()?;
        let alias = self.opt_alias()?;
        let where_ = if self.eat_kw("WHERE") { Some(self.expr()?) } else { None };
        let returning = self.returning()?;
        Ok(Stmt::Delete(Delete { with: None, table, alias, where_, returning }))
    }

    // ---------- SELECT ----------

    fn is_query_start(&self) -> bool {
        self.is_kw("SELECT") || self.is_kw("VALUES") || self.is_kw("WITH")
    }

    /// `WITH [RECURSIVE] name [(cols)] AS [NOT] [MATERIALIZED] (select), ...`
    fn with_clause(&mut self) -> PResult<Option<Rc<With>>> {
        if !self.eat_kw("WITH") {
            return Ok(None);
        }
        self.eat_kw("RECURSIVE");
        let mut ctes = Vec::new();
        loop {
            let name = self.name()?;
            let mut columns = None;
            if self.eat_op("(") {
                let mut cols = Vec::new();
                loop {
                    cols.push(self.name()?);
                    if !self.eat_op(",") {
                        break;
                    }
                }
                self.expect_op(")")?;
                columns = Some(cols);
            }
            self.expect_kw("AS")?;
            if self.eat_kw("NOT") {
                self.expect_kw("MATERIALIZED")?;
            } else {
                self.eat_kw("MATERIALIZED");
            }
            self.expect_op("(")?;
            let select = self.select()?;
            self.expect_op(")")?;
            ctes.push(Cte { name, columns, select });
            if !self.eat_op(",") {
                break;
            }
        }
        Ok(Some(Rc::new(With { ctes })))
    }

    /// A full query, with an optional WITH clause.
    fn select(&mut self) -> PResult<Select> {
        let with = self.with_clause()?;
        let mut q = self.select_body()?;
        q.with = with;
        Ok(q)
    }

    /// A query without WITH: compound of cores, then ORDER BY / LIMIT.
    fn select_body(&mut self) -> PResult<Select> {
        let mut cores = vec![self.select_core()?];
        let mut ops = Vec::new();
        loop {
            let op = if self.eat_kw("UNION") {
                if self.eat_kw("ALL") {
                    CompoundOp::UnionAll
                } else {
                    CompoundOp::Union
                }
            } else if self.eat_kw("INTERSECT") {
                CompoundOp::Intersect
            } else if self.eat_kw("EXCEPT") {
                CompoundOp::Except
            } else {
                break;
            };
            ops.push(op);
            cores.push(self.select_core()?);
        }
        // a trailing VALUES cannot take ORDER BY or LIMIT
        if matches!(cores.last(), Some(SelectCore::Values(_))) && (self.is_kw("ORDER") || self.is_kw("LIMIT")) {
            return Err(self.err_near());
        }
        let mut order_by = Vec::new();
        if self.eat_kw("ORDER") {
            self.expect_kw("BY")?;
            order_by = self.order_terms()?;
        }
        let mut limit = None;
        let mut offset = None;
        if self.eat_kw("LIMIT") {
            let first = self.expr()?;
            if self.eat_kw("OFFSET") {
                limit = Some(first);
                offset = Some(self.expr()?);
            } else if self.eat_op(",") {
                offset = Some(first);
                limit = Some(self.expr()?);
            } else {
                limit = Some(first);
            }
        }
        Ok(Select { with: None, cores, ops, order_by, limit, offset })
    }

    fn select_core(&mut self) -> PResult<SelectCore> {
        if self.eat_kw("VALUES") {
            return Ok(SelectCore::Values(self.values_rows()?));
        }
        self.expect_kw("SELECT")?;
        let distinct = self.eat_kw("DISTINCT");
        if !distinct {
            self.eat_kw("ALL");
        }
        let mut columns = Vec::new();
        loop {
            columns.push(self.result_column()?);
            if !self.eat_op(",") {
                break;
            }
        }
        let mut from = None;
        if self.eat_kw("FROM") {
            from = Some(self.from_clause()?);
        }
        let mut where_ = None;
        if self.eat_kw("WHERE") {
            where_ = Some(self.expr()?);
        }
        let mut group_by = Vec::new();
        let mut having = None;
        if self.eat_kw("GROUP") {
            self.expect_kw("BY")?;
            loop {
                group_by.push(self.expr()?);
                if !self.eat_op(",") {
                    break;
                }
            }
        }
        if self.eat_kw("HAVING") {
            having = Some(self.expr()?);
        }
        let mut windows = Vec::new();
        if self.eat_kw("WINDOW") {
            loop {
                let name = self.name()?;
                self.expect_kw("AS")?;
                self.expect_op("(")?;
                let spec = self.window_spec()?;
                windows.push((name, spec));
                if !self.eat_op(",") {
                    break;
                }
            }
        }
        Ok(SelectCore::Select(SelectBody { distinct, columns, from, where_, group_by, having, windows }))
    }

    /// A FROM item, or a parenthesized join group (flattened).
    fn table_item(&mut self) -> PResult<From> {
        if self.is_op("(") && !matches!(self.peek_at(1), Tok::Id(s) if s.eq_ignore_ascii_case("SELECT") || s.eq_ignore_ascii_case("VALUES") || s.eq_ignore_ascii_case("WITH")) {
            self.advance();
            let group = self.from_clause()?;
            self.expect_op(")")?;
            return Ok(group);
        }
        Ok(From { first: self.single_table_item()?, joins: Vec::new() })
    }

    fn single_table_item(&mut self) -> PResult<TableItem> {
        if self.eat_op("(") {
            if !self.is_query_start() {
                return Err(self.err_near());
            }
            let query = self.select()?;
            self.expect_op(")")?;
            let alias = self.opt_alias()?;
            return Ok(TableItem::Subquery { query: Box::new(query), alias });
        }
        let name = self.qualified_name()?;
        let alias = self.opt_alias()?;
        Ok(TableItem::Table { name, alias })
    }

    fn from_clause(&mut self) -> PResult<From> {
        let From { first, mut joins } = self.table_item()?;
        loop {
            let mut cross = false;
            let (kind, natural) = if self.eat_op(",") {
                (JoinKind::Inner, false)
            } else {
                let natural = self.eat_kw("NATURAL");
                let kind = if self.eat_kw("LEFT") {
                    self.eat_kw("OUTER");
                    JoinKind::Left
                } else if self.eat_kw("RIGHT") {
                    self.eat_kw("OUTER");
                    JoinKind::Right
                } else if self.eat_kw("FULL") {
                    self.eat_kw("OUTER");
                    JoinKind::Full
                } else if self.eat_kw("INNER") {
                    JoinKind::Inner
                } else if self.eat_kw("CROSS") {
                    cross = true;
                    JoinKind::Inner
                } else if natural || self.is_kw("JOIN") {
                    JoinKind::Inner
                } else {
                    break;
                };
                self.expect_kw("JOIN")?;
                (kind, natural)
            };
            let item = self.table_item()?;
            let mut on = None;
            let mut using = None;
            if self.eat_kw("ON") {
                on = Some(self.expr()?);
            } else if self.eat_kw("USING") {
                self.expect_op("(")?;
                let mut cols = Vec::new();
                loop {
                    cols.push(self.name()?);
                    if !self.eat_op(",") {
                        break;
                    }
                }
                self.expect_op(")")?;
                using = Some(cols);
            }
            if natural && (on.is_some() || using.is_some()) {
                return Err("a NATURAL join may not have an ON or USING clause".to_string());
            }
            if item.joins.is_empty() {
                joins.push(Join { kind, cross, natural, item: item.first, on, using });
            } else {
                // a join group: its condition applies once the group is joined
                if natural || using.is_some() {
                    return Err("USING or NATURAL with a parenthesized join is not supported".to_string());
                }
                joins.push(Join { kind, cross, natural: false, item: item.first, on: None, using: None });
                joins.extend(item.joins);
                if let Some(on) = on {
                    let last = joins.last_mut().unwrap();
                    last.on = Some(match last.on.take() {
                        Some(c) => Expr::Binary(BinOp::And, Box::new(c), Box::new(on)),
                        None => on,
                    });
                }
            }
        }
        Ok(From { first, joins })
    }

    fn order_terms(&mut self) -> PResult<Vec<OrderTerm>> {
        let mut order_by = Vec::new();
        loop {
            let expr = self.expr()?;
            let mut desc = false;
            if self.eat_kw("DESC") {
                desc = true;
            } else {
                self.eat_kw("ASC");
            }
            let mut nulls_first = None;
            if self.eat_kw("NULLS") {
                if self.eat_kw("FIRST") {
                    nulls_first = Some(true);
                } else {
                    self.expect_kw("LAST")?;
                    nulls_first = Some(false);
                }
            }
            order_by.push(OrderTerm { expr, desc, nulls_first });
            if !self.eat_op(",") {
                break;
            }
        }
        Ok(order_by)
    }

    fn opt_alias(&mut self) -> PResult<Option<String>> {
        if self.eat_kw("AS") {
            return Ok(Some(self.name()?));
        }
        match self.peek().clone() {
            Tok::Id(s) if !is_reserved(&s) => {
                self.advance();
                Ok(Some(s))
            }
            Tok::QId(s) | Tok::DqId(s) | Tok::Str(s) => {
                self.advance();
                Ok(Some(s))
            }
            _ => Ok(None),
        }
    }

    fn result_column(&mut self) -> PResult<ResultColumn> {
        if self.eat_op("*") {
            return Ok(ResultColumn::Star);
        }
        let is_name = match self.peek() {
            Tok::Id(s) => !is_reserved(s),
            Tok::QId(_) | Tok::DqId(_) => true,
            _ => false,
        };
        if is_name && matches!(self.peek_at(1), Tok::Op(".")) && matches!(self.peek_at(2), Tok::Op("*")) {
            let t = self.name()?;
            self.advance();
            self.advance();
            return Ok(ResultColumn::TableStar(t));
        }
        let start = self.toks[self.pos].start;
        let e = self.expr()?;
        let end = self.toks[self.pos.saturating_sub(1)].end.max(start);
        let text = self.src[start..end].to_string();
        let alias = self.opt_alias()?;
        Ok(ResultColumn::Expr(e, alias, text))
    }

    // ---------- Expressions ----------

    pub fn expr(&mut self) -> PResult<Expr> {
        self.expr_prec(P_OR)
    }

    fn expr_prec(&mut self, min: u8) -> PResult<Expr> {
        let mut lhs = self.unary()?;
        loop {
            let (prec, op) = match self.peek() {
                Tok::Id(s) => {
                    let u = s.to_ascii_uppercase();
                    match u.as_str() {
                        "OR" => (P_OR, Some(BinOp::Or)),
                        "AND" => (P_AND, Some(BinOp::And)),
                        "IS" | "ISNULL" | "NOTNULL" | "IN" | "BETWEEN" => (P_EQ, None),
                        "LIKE" | "GLOB" | "REGEXP" | "MATCH" => (P_EQ, None),
                        "NOT"
                            if ["NULL", "IN", "BETWEEN", "LIKE", "GLOB", "REGEXP", "MATCH"]
                                .iter()
                                .any(|k| self.is_kw_at(1, k)) =>
                        {
                            (P_EQ, None)
                        }
                        "COLLATE" => (P_COLLATE, None),
                        _ => break,
                    }
                }
                Tok::Op(o) => match *o {
                    "=" | "==" => (P_EQ, Some(BinOp::Eq)),
                    "!=" | "<>" => (P_EQ, Some(BinOp::Ne)),
                    "<" => (P_CMP, Some(BinOp::Lt)),
                    "<=" => (P_CMP, Some(BinOp::Le)),
                    ">" => (P_CMP, Some(BinOp::Gt)),
                    ">=" => (P_CMP, Some(BinOp::Ge)),
                    "+" => (P_ADD, Some(BinOp::Add)),
                    "-" => (P_ADD, Some(BinOp::Sub)),
                    "*" => (P_MUL, Some(BinOp::Mul)),
                    "/" => (P_MUL, Some(BinOp::Div)),
                    "%" => (P_MUL, Some(BinOp::Rem)),
                    "||" => (P_CONCAT, Some(BinOp::Concat)),
                    "&" => (P_BIT, Some(BinOp::BitAnd)),
                    "|" => (P_BIT, Some(BinOp::BitOr)),
                    "<<" => (P_BIT, Some(BinOp::Shl)),
                    ">>" => (P_BIT, Some(BinOp::Shr)),
                    _ => break,
                },
                _ => break,
            };
            if prec < min {
                break;
            }
            match op {
                Some(op) => {
                    self.advance();
                    let rhs = self.expr_prec(prec + 1)?;
                    lhs = Expr::Binary(op, Box::new(lhs), Box::new(rhs));
                }
                None => {
                    // postfix operators and IS [NOT], IN, BETWEEN, LIKE ...
                    if self.eat_kw("COLLATE") {
                        let c = self.name()?;
                        lhs = Expr::Collate(Box::new(lhs), c);
                        continue;
                    }
                    let not = self.is_kw("NOT") && !self.is_kw_at(1, "NULL");
                    if not {
                        self.advance();
                    }
                    if self.eat_kw("IN") {
                        if !self.is_op("(") {
                            // `x IN table`
                            let name = self.qualified_name()?;
                            let q = Select {
                                with: None,
                                cores: vec![SelectCore::Select(SelectBody {
                                    distinct: false,
                                    columns: vec![ResultColumn::Star],
                                    from: Some(From { first: TableItem::Table { name, alias: None }, joins: Vec::new() }),
                                    where_: None,
                                    group_by: Vec::new(),
                                    having: None,
                                    windows: Vec::new(),
                                })],
                                ops: Vec::new(),
                                order_by: Vec::new(),
                                limit: None,
                                offset: None,
                            };
                            lhs = Expr::InSelect { e: Box::new(lhs), query: Box::new(q), not };
                            continue;
                        }
                        self.expect_op("(")?;
                        if self.is_query_start() {
                            let q = self.select()?;
                            self.expect_op(")")?;
                            lhs = Expr::InSelect { e: Box::new(lhs), query: Box::new(q), not };
                            continue;
                        }
                        let mut list = Vec::new();
                        if !self.is_op(")") {
                            loop {
                                list.push(self.expr()?);
                                if !self.eat_op(",") {
                                    break;
                                }
                            }
                        }
                        self.expect_op(")")?;
                        lhs = Expr::InList { e: Box::new(lhs), list, not };
                    } else if self.eat_kw("BETWEEN") {
                        let lo = self.expr_prec(P_EQ + 1)?;
                        self.expect_kw("AND")?;
                        let hi = self.expr_prec(P_EQ + 1)?;
                        lhs = Expr::Between { e: Box::new(lhs), lo: Box::new(lo), hi: Box::new(hi), not };
                    } else if let Some(op) = LIKE_OPS.iter().find(|k| self.is_kw(k)) {
                        let op = op.to_ascii_lowercase();
                        self.advance();
                        let pattern = self.expr_prec(P_EQ + 1)?;
                        let escape = if self.eat_kw("ESCAPE") {
                            Some(Box::new(self.expr_prec(P_EQ + 1)?))
                        } else {
                            None
                        };
                        lhs = Expr::Like { op, e: Box::new(lhs), pattern: Box::new(pattern), escape, not };
                    } else if not {
                        return Err(self.err_near());
                    } else if self.eat_kw("ISNULL") {
                        lhs = Expr::IsNull(Box::new(lhs), false);
                    } else if self.eat_kw("NOTNULL") {
                        lhs = Expr::IsNull(Box::new(lhs), true);
                    } else if self.eat_kw("NOT") {
                        self.expect_kw("NULL")?;
                        lhs = Expr::IsNull(Box::new(lhs), true);
                    } else {
                        self.expect_kw("IS")?;
                        let mut neg = self.eat_kw("NOT");
                        if self.is_kw("DISTINCT") && self.is_kw_at(1, "FROM") {
                            self.advance();
                            self.advance();
                            neg = !neg;
                        }
                        let rhs = self.expr_prec(P_EQ + 1)?;
                        let op = if neg { BinOp::IsNot } else { BinOp::Is };
                        lhs = Expr::Binary(op, Box::new(lhs), Box::new(rhs));
                    }
                }
            }
        }
        Ok(lhs)
    }

    fn unary(&mut self) -> PResult<Expr> {
        if self.eat_kw("NOT") {
            let e = self.expr_prec(P_NOT)?;
            return Ok(Expr::Unary(UnOp::Not, Box::new(e)));
        }
        if self.is_op("-") {
            self.advance();
            // -(((9223372036854775808))) is the smallest integer
            let mut k = 0;
            while matches!(self.peek_at(k), Tok::Op("(")) {
                k += 1;
            }
            if k > 0 && matches!(self.peek_at(k), Tok::Int(None)) && (1..=k).all(|j| matches!(self.peek_at(k + j), Tok::Op(")"))) {
                let t = &self.toks[self.pos + k];
                if self.src[t.start..t.end].trim_start_matches('0') == "9223372036854775808" {
                    self.pos += 2 * k + 1;
                    return Ok(Expr::Literal(Value::Integer(i64::MIN)));
                }
            }
            if matches!(self.peek(), Tok::Int(_) | Tok::Float(_)) {
                let lit = self.literal_value()?;
                let t = &self.toks[self.pos - 1];
                let text = &self.src[t.start..t.end];
                if matches!(t.tok, Tok::Int(None)) && text.trim_start_matches('0') == "9223372036854775808" {
                    return Ok(Expr::Literal(Value::Integer(i64::MIN)));
                }
                if matches!(t.tok, Tok::Int(Some(i64::MIN))) {
                    return Err(format!("hex literal too big: -{}", text));
                }
                return Ok(negate_literal(lit));
            }
            let e = self.unary()?;
            return Ok(Expr::Unary(UnOp::Neg, Box::new(e)));
        }
        if self.eat_op("+") {
            let e = self.unary()?;
            return Ok(Expr::Unary(UnOp::Pos, Box::new(e)));
        }
        if self.eat_op("~") {
            let e = self.unary()?;
            return Ok(Expr::Unary(UnOp::BitNot, Box::new(e)));
        }
        self.primary()
    }

    fn primary(&mut self) -> PResult<Expr> {
        match self.peek().clone() {
            Tok::Int(_) | Tok::Float(_) | Tok::Str(_) | Tok::Blob(_) => self.literal_value(),
            Tok::Op("(") => {
                self.advance();
                if self.is_query_start() {
                    let q = self.select()?;
                    self.expect_op(")")?;
                    return Ok(Expr::Subquery(Box::new(q)));
                }
                let e = self.expr()?;
                self.expect_op(")")?;
                Ok(e)
            }
            Tok::Id(s) => {
                if s.eq_ignore_ascii_case("NULL") {
                    self.advance();
                    return Ok(Expr::Literal(Value::Null));
                }
                if s.eq_ignore_ascii_case("EXISTS") && matches!(self.peek_at(1), Tok::Op("(")) {
                    self.advance();
                    self.advance();
                    let q = self.select()?;
                    self.expect_op(")")?;
                    return Ok(Expr::Exists(Box::new(q)));
                }
                if s.eq_ignore_ascii_case("CASE") {
                    self.advance();
                    return self.case_expr();
                }
                if s.eq_ignore_ascii_case("CAST") && matches!(self.peek_at(1), Tok::Op("(")) {
                    self.advance();
                    self.advance();
                    let e = self.expr()?;
                    self.expect_kw("AS")?;
                    let t = self.type_name()?.unwrap_or_default();
                    self.expect_op(")")?;
                    return Ok(Expr::Cast(Box::new(e), t));
                }
                let kw_func = LIKE_OPS.iter().any(|k| k.eq_ignore_ascii_case(&s))
                    && matches!(self.peek_at(1), Tok::Op("("));
                if is_reserved(&s) && !kw_func {
                    return Err(self.err_near());
                }
                self.advance();
                if self.is_op("(") {
                    return self.function_call(s);
                }
                self.column_ref(s, false)
            }
            Tok::QId(s) => {
                self.advance();
                self.column_ref(s, false)
            }
            Tok::DqId(s) => {
                self.advance();
                self.column_ref(s, true)
            }
            _ => Err(self.err_near()),
        }
    }

    fn case_expr(&mut self) -> PResult<Expr> {
        let base = if self.is_kw("WHEN") { None } else { Some(Box::new(self.expr()?)) };
        let mut whens = Vec::new();
        while self.eat_kw("WHEN") {
            let w = self.expr()?;
            self.expect_kw("THEN")?;
            let t = self.expr()?;
            whens.push((w, t));
        }
        if whens.is_empty() {
            return Err(self.err_near());
        }
        let else_ = if self.eat_kw("ELSE") { Some(Box::new(self.expr()?)) } else { None };
        self.expect_kw("END")?;
        Ok(Expr::Case { base, whens, else_ })
    }

    fn column_ref(&mut self, first: String, dq: bool) -> PResult<Expr> {
        if self.eat_op(".") {
            let col = self.name()?;
            return Ok(Expr::Column { table: Some(first), name: col, dq: false });
        }
        Ok(Expr::Column { table: None, name: first, dq })
    }

    fn function_call(&mut self, name: String) -> PResult<Expr> {
        self.expect_op("(")?;
        let mut args = Vec::new();
        let mut star = false;
        let mut distinct = false;
        let mut order_by = Vec::new();
        if self.eat_op("*") {
            star = true;
        } else if !self.is_op(")") {
            if self.eat_kw("DISTINCT") {
                distinct = true;
            } else {
                self.eat_kw("ALL");
            }
            loop {
                args.push(self.expr()?);
                if !self.eat_op(",") {
                    break;
                }
            }
            if self.eat_kw("ORDER") {
                self.expect_kw("BY")?;
                order_by = self.order_terms()?;
            }
        }
        self.expect_op(")")?;
        let mut filter = None;
        if self.is_kw("FILTER") && matches!(self.peek_at(1), Tok::Op("(")) {
            self.advance();
            self.expect_op("(")?;
            self.expect_kw("WHERE")?;
            filter = Some(self.expr()?);
            self.expect_op(")")?;
        }
        let mut over = None;
        if self.eat_kw("OVER") {
            if self.eat_op("(") {
                over = Some(Box::new(self.window_spec()?));
            } else {
                let base = self.name()?;
                over = Some(Box::new(WindowSpec { base: Some(base), ..Default::default() }));
            }
        }
        Ok(Expr::Function(Box::new(FuncCall { name, args, star, distinct, order_by, filter, over })))
    }

    /// The inside of a window definition, through the closing parenthesis.
    fn window_spec(&mut self) -> PResult<WindowSpec> {
        let mut spec = WindowSpec { paren: true, ..Default::default() };
        let is_clause_kw = |p: &Self| {
            ["PARTITION", "ORDER", "ROWS", "RANGE", "GROUPS"].iter().any(|k| p.is_kw(k))
        };
        if !self.is_op(")") && !is_clause_kw(self) {
            spec.base = Some(self.name()?);
        }
        if self.eat_kw("PARTITION") {
            self.expect_kw("BY")?;
            loop {
                spec.partition.push(self.expr()?);
                if !self.eat_op(",") {
                    break;
                }
            }
        }
        if self.eat_kw("ORDER") {
            self.expect_kw("BY")?;
            spec.order = self.order_terms()?;
        }
        let unit = if self.eat_kw("ROWS") {
            Some(FrameUnit::Rows)
        } else if self.eat_kw("RANGE") {
            Some(FrameUnit::Range)
        } else if self.eat_kw("GROUPS") {
            Some(FrameUnit::Groups)
        } else {
            None
        };
        if let Some(unit) = unit {
            let (start, end) = if self.eat_kw("BETWEEN") {
                let start = self.frame_bound(true)?;
                self.expect_kw("AND")?;
                let end = self.frame_bound(false)?;
                (start, end)
            } else {
                (self.frame_bound(true)?, FrameBound::CurrentRow)
            };
            let mut exclude = Exclude::NoOthers;
            if self.eat_kw("EXCLUDE") {
                exclude = if self.eat_kw("NO") {
                    self.expect_kw("OTHERS")?;
                    Exclude::NoOthers
                } else if self.eat_kw("CURRENT") {
                    self.expect_kw("ROW")?;
                    Exclude::CurrentRow
                } else if self.eat_kw("GROUP") {
                    Exclude::Group
                } else {
                    self.expect_kw("TIES")?;
                    Exclude::Ties
                };
            }
            let rank = |b: &FrameBound| match b {
                FrameBound::UnboundedPreceding => 0,
                FrameBound::Preceding(_) => 1,
                FrameBound::CurrentRow => 2,
                FrameBound::Following(_) => 3,
                FrameBound::UnboundedFollowing => 4,
            };
            let (rs, re) = (rank(&start), rank(&end));
            if (rs == 2 && re == 1) || (rs == 3 && (re == 1 || re == 2)) {
                return Err("unsupported frame specification".to_string());
            }
            spec.frame = Some(Frame { unit, start, end, exclude });
        }
        self.expect_op(")")?;
        Ok(spec)
    }

    fn frame_bound(&mut self, is_start: bool) -> PResult<FrameBound> {
        if self.eat_kw("UNBOUNDED") {
            if is_start {
                self.expect_kw("PRECEDING")?;
                return Ok(FrameBound::UnboundedPreceding);
            }
            self.expect_kw("FOLLOWING")?;
            return Ok(FrameBound::UnboundedFollowing);
        }
        if self.is_kw("CURRENT") && self.is_kw_at(1, "ROW") {
            self.advance();
            self.advance();
            return Ok(FrameBound::CurrentRow);
        }
        let e = self.expr()?;
        if self.eat_kw("PRECEDING") {
            Ok(FrameBound::Preceding(Box::new(e)))
        } else {
            self.expect_kw("FOLLOWING")?;
            Ok(FrameBound::Following(Box::new(e)))
        }
    }
}

fn negate_literal(e: Expr) -> Expr {
    match e {
        Expr::Literal(Value::Integer(i)) if i != i64::MIN => Expr::Literal(Value::Integer(-i)),
        Expr::Literal(Value::Real(r)) => Expr::Literal(Value::Real(-r)),
        other => Expr::Unary(UnOp::Neg, Box::new(other)),
    }
}
