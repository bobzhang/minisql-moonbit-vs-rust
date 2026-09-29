// Recursive-descent SQL parser.

use crate::ast::*;
use crate::error::{err, Error, Result};
use crate::lexer::{tokenize, Tok, Token};
use crate::value::{affinity_of_type, Collation, Value};

/// Keywords that can never be used as bare identifiers or implicit aliases.
const RESERVED: &[&str] = &[
    "ALL", "ALTER", "AND", "AS", "AUTOINCREMENT", "BETWEEN", "CASE", "CHECK", "COLLATE", "COMMIT",
    "CONSTRAINT", "CREATE", "CROSS", "DEFAULT", "DEFERRABLE", "DELETE", "DISTINCT", "DROP", "ELSE",
    "ESCAPE", "EXCEPT", "EXISTS", "FOREIGN", "FROM", "FULL", "GROUP", "HAVING", "IN",
    "INDEX", "INNER", "INSERT", "INTERSECT", "INTO", "IS", "ISNULL", "JOIN", "LEFT", "LIMIT",
    "NATURAL", "NOT", "NOTHING", "NOTNULL", "NULL", "ON", "OR", "ORDER", "OUTER",
    "PRIMARY", "REFERENCES", "RETURNING", "RIGHT", "SELECT", "SET", "TABLE", "THEN",
    "TO", "TRANSACTION", "UNION", "UNIQUE", "UPDATE", "USING", "VALUES", "WHEN", "WHERE",
];

pub fn is_reserved(s: &str) -> bool {
    RESERVED.iter().any(|k| k.eq_ignore_ascii_case(s))
}

/// Join keywords are reserved but still usable as explicit names.
fn is_join_kw(s: &str) -> bool {
    ["CROSS", "FULL", "INNER", "LEFT", "NATURAL", "OUTER", "RIGHT"].iter().any(|k| k.eq_ignore_ascii_case(s))
}

pub struct Parser<'a> {
    src: &'a str,
    toks: Vec<Token>,
    pos: usize,
}

pub fn parse_statement(src: &str) -> Result<Stmt> {
    let toks = tokenize(src)?;
    let mut p = Parser { src, toks, pos: 0 };
    let stmt = p.statement()?;
    while p.eat_op(";") {}
    if !p.at_eof() {
        return Err(p.syntax_error());
    }
    Ok(stmt)
}

impl<'a> Parser<'a> {
    // ---- token helpers ----

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

    fn syntax_error(&self) -> Error {
        let t = &self.toks[self.pos];
        if matches!(t.tok, Tok::Eof) {
            Error::new("incomplete input")
        } else {
            Error::new(format!("near \"{}\": syntax error", &self.src[t.pos..t.end]))
        }
    }

    fn is_kw_at(&self, k: usize, kw: &str) -> bool {
        matches!(self.peek_at(k), Tok::Id(s) if s.eq_ignore_ascii_case(kw))
    }

    fn is_kw(&self, kw: &str) -> bool {
        self.is_kw_at(0, kw)
    }

    fn eat_kw(&mut self, kw: &str) -> bool {
        if self.is_kw(kw) {
            self.advance();
            true
        } else {
            false
        }
    }

    fn expect_kw(&mut self, kw: &str) -> Result<()> {
        if self.eat_kw(kw) {
            Ok(())
        } else {
            Err(self.syntax_error())
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

    fn expect_op(&mut self, op: &str) -> Result<()> {
        if self.eat_op(op) {
            Ok(())
        } else {
            Err(self.syntax_error())
        }
    }

    /// Is the current token usable as a name (identifier)?
    fn at_name(&self) -> bool {
        match self.peek() {
            Tok::Id(s) => !is_reserved(s),
            Tok::DqId(_) | Tok::QId(_) | Tok::Str(_) => true,
            _ => false,
        }
    }

    /// Is the current token usable as an implicit alias?
    fn at_alias(&self) -> bool {
        self.at_name() && !self.is_kw("WINDOW")
    }

    fn name(&mut self) -> Result<String> {
        match self.peek().clone() {
            Tok::Id(s) if !is_reserved(&s) || is_join_kw(&s) => {
                self.advance();
                Ok(s)
            }
            Tok::DqId(s) | Tok::QId(s) | Tok::Str(s) => {
                self.advance();
                Ok(s)
            }
            _ => Err(self.syntax_error()),
        }
    }

    // ---- statements ----

    fn statement(&mut self) -> Result<Stmt> {
        if self.is_kw("SELECT") || self.is_kw("VALUES") {
            return Ok(Stmt::Select(Box::new(self.select()?)));
        }
        if self.is_kw("WITH") {
            let with = self.with_clause()?;
            if self.is_kw("SELECT") || self.is_kw("VALUES") {
                let mut sel = self.select()?;
                sel.with = Some(Box::new(with));
                return Ok(Stmt::Select(Box::new(sel)));
            }
            let mut stmt = if self.is_kw("INSERT") || self.is_kw("REPLACE") {
                self.insert()?
            } else if self.eat_kw("UPDATE") {
                self.update()?
            } else if self.eat_kw("DELETE") {
                self.delete()?
            } else {
                return Err(self.syntax_error());
            };
            match &mut stmt {
                Stmt::Insert(i) => i.with = Some(Box::new(with)),
                Stmt::Update(u) => u.with = Some(Box::new(with)),
                Stmt::Delete(d) => d.with = Some(Box::new(with)),
                _ => {}
            }
            return Ok(stmt);
        }
        if self.eat_kw("CREATE") {
            if self.eat_kw("TEMP") || self.eat_kw("TEMPORARY") {}
            if self.eat_kw("TABLE") {
                return self.create_table();
            }
            if self.eat_kw("VIEW") {
                return self.create_view();
            }
            let unique = self.eat_kw("UNIQUE");
            if self.eat_kw("INDEX") {
                return self.create_index(unique);
            }
            return Err(self.syntax_error());
        }
        if self.eat_kw("DROP") {
            let kind = if self.eat_kw("TABLE") {
                0
            } else if self.eat_kw("INDEX") {
                1
            } else if self.eat_kw("VIEW") {
                2
            } else {
                return Err(self.syntax_error());
            };
            let if_exists = self.if_exists()?;
            let name = self.qualified_name()?;
            return Ok(match kind {
                0 => Stmt::DropTable { name, if_exists },
                1 => Stmt::DropIndex { name, if_exists },
                _ => Stmt::DropView { name, if_exists },
            });
        }
        if self.eat_kw("ALTER") {
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
                AlterAction::AddColumn(self.column_def()?)
            } else if self.eat_kw("DROP") {
                self.eat_kw("COLUMN");
                AlterAction::DropColumn(self.name()?)
            } else {
                return Err(self.syntax_error());
            };
            return Ok(Stmt::Alter { table, action });
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
                return Ok(Stmt::RollbackTo(self.name()?));
            }
            return Ok(Stmt::Rollback);
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
        Err(self.syntax_error())
    }

    fn delete(&mut self) -> Result<Stmt> {
        self.expect_kw("FROM")?;
        let table = self.qualified_name()?;
        let alias = self.table_alias()?;
        let where_ = if self.eat_kw("WHERE") { Some(self.expr()?) } else { None };
        let returning = self.returning()?;
        Ok(Stmt::Delete(Delete { with: None, table, alias, where_, returning }))
    }

    /// `WITH [RECURSIVE] name [(cols)] AS [NOT] [MATERIALIZED] (select), ...`
    fn with_clause(&mut self) -> Result<With> {
        self.expect_kw("WITH")?;
        let recursive = self.eat_kw("RECURSIVE");
        let mut ctes = Vec::new();
        loop {
            let name = self.name()?;
            let mut cols = None;
            if self.eat_op("(") {
                let mut v = Vec::new();
                loop {
                    v.push(self.name()?);
                    if !self.eat_op(",") {
                        break;
                    }
                }
                self.expect_op(")")?;
                cols = Some(v);
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
            ctes.push(Cte { name, cols, select: Box::new(select) });
            if !self.eat_op(",") {
                break;
            }
        }
        Ok(With { recursive, ctes })
    }
    fn if_exists(&mut self) -> Result<bool> {
        if self.eat_kw("IF") {
            self.expect_kw("EXISTS")?;
            return Ok(true);
        }
        Ok(false)
    }

    /// `[schema.]name` — the schema part is ignored.
    fn qualified_name(&mut self) -> Result<String> {
        let mut n = self.name()?;
        if self.eat_op(".") {
            n = self.name()?;
        }
        Ok(n)
    }

    fn conflict_clause(&mut self) -> Result<Option<Conflict>> {
        if self.is_kw("ON") && self.is_kw_at(1, "CONFLICT") {
            self.advance();
            self.advance();
            return Ok(Some(self.conflict_action()?));
        }
        Ok(None)
    }

    fn conflict_action(&mut self) -> Result<Conflict> {
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
            return Err(self.syntax_error());
        };
        Ok(c)
    }

    fn create_table(&mut self) -> Result<Stmt> {
        let mut if_not_exists = false;
        if self.eat_kw("IF") {
            self.expect_kw("NOT")?;
            self.expect_kw("EXISTS")?;
            if_not_exists = true;
        }
        let name = self.qualified_name()?;
        self.expect_op("(")?;
        let mut columns = Vec::new();
        let mut constraints = Vec::new();
        loop {
            if self.is_kw("CONSTRAINT")
                || self.is_kw("PRIMARY")
                || self.is_kw("UNIQUE")
                || self.is_kw("CHECK")
                || self.is_kw("FOREIGN")
            {
                if columns.is_empty() {
                    return Err(self.syntax_error());
                }
                constraints.push(self.table_constraint()?);
                // table constraints may be separated by commas or not
                while !self.is_op(")") {
                    self.eat_op(",");
                    constraints.push(self.table_constraint()?);
                }
                break;
            }
            columns.push(self.column_def()?);
            if !self.eat_op(",") {
                break;
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
        Ok(Stmt::CreateTable(CreateTable { name, if_not_exists, columns, constraints }))
    }

    fn if_not_exists(&mut self) -> Result<bool> {
        if self.eat_kw("IF") {
            self.expect_kw("NOT")?;
            self.expect_kw("EXISTS")?;
            return Ok(true);
        }
        Ok(false)
    }

    fn create_index(&mut self, unique: bool) -> Result<Stmt> {
        let if_not_exists = self.if_not_exists()?;
        let name = self.qualified_name()?;
        self.expect_kw("ON")?;
        let table = self.name()?;
        let cols = self.indexed_cols()?;
        let where_ = if self.eat_kw("WHERE") { Some(self.expr()?) } else { None };
        Ok(Stmt::CreateIndex(CreateIndex { name, table, unique, if_not_exists, cols, where_ }))
    }

    fn create_view(&mut self) -> Result<Stmt> {
        let if_not_exists = self.if_not_exists()?;
        let name = self.qualified_name()?;
        let mut cols = None;
        if self.eat_op("(") {
            let mut v = Vec::new();
            loop {
                v.push(self.name()?);
                if !self.eat_op(",") {
                    break;
                }
            }
            self.expect_op(")")?;
            cols = Some(v);
        }
        self.expect_kw("AS")?;
        let select = self.select()?;
        Ok(Stmt::CreateView(CreateView { name, if_not_exists, cols, select }))
    }

    fn is_column_constraint_start(&self) -> bool {
        ["CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT", "COLLATE", "REFERENCES", "GENERATED", "AS"]
            .iter()
            .any(|k| self.is_kw(k))
    }

    fn type_name(&mut self) -> Result<String> {
        let mut parts: Vec<String> = Vec::new();
        loop {
            if self.is_column_constraint_start() {
                break;
            }
            match self.peek().clone() {
                Tok::Id(s) => {
                    self.advance();
                    parts.push(s);
                }
                Tok::DqId(s) | Tok::QId(s) => {
                    self.advance();
                    parts.push(s);
                }
                _ => break,
            }
        }
        let mut t = parts.join(" ");
        if !parts.is_empty() && self.eat_op("(") {
            t.push('(');
            t.push_str(&self.signed_number_text()?);
            if self.eat_op(",") {
                t.push(',');
                t.push_str(&self.signed_number_text()?);
            }
            self.expect_op(")")?;
            t.push(')');
        }
        Ok(t)
    }

    fn signed_number_text(&mut self) -> Result<String> {
        let mut s = String::new();
        if self.eat_op("-") {
            s.push('-');
        } else if self.eat_op("+") {
            s.push('+');
        }
        let t = &self.toks[self.pos];
        match &t.tok {
            Tok::Int(..) | Tok::Real(_) => {
                s.push_str(&self.src[t.pos..t.end]);
                self.advance();
                Ok(s)
            }
            _ => Err(self.syntax_error()),
        }
    }

    fn column_def(&mut self) -> Result<ColumnDef> {
        let name = self.name()?;
        let type_name = self.type_name()?;
        let mut constraints = Vec::new();
        loop {
            if self.eat_kw("CONSTRAINT") {
                self.name()?;
            }
            if self.eat_kw("PRIMARY") {
                self.expect_kw("KEY")?;
                let desc = if self.eat_kw("DESC") {
                    true
                } else {
                    self.eat_kw("ASC");
                    false
                };
                let conflict = self.conflict_clause()?;
                let autoincrement = self.eat_kw("AUTOINCREMENT");
                constraints.push(ColumnConstraint::PrimaryKey { desc, conflict, autoincrement });
            } else if self.eat_kw("NOT") {
                self.expect_kw("NULL")?;
                let conflict = self.conflict_clause()?;
                constraints.push(ColumnConstraint::NotNull { conflict });
            } else if self.eat_kw("NULL") {
                self.conflict_clause()?;
                constraints.push(ColumnConstraint::Null);
            } else if self.eat_kw("UNIQUE") {
                let conflict = self.conflict_clause()?;
                constraints.push(ColumnConstraint::Unique { conflict });
            } else if self.eat_kw("CHECK") {
                self.expect_op("(")?;
                let e = self.expr()?;
                self.expect_op(")")?;
                constraints.push(ColumnConstraint::Check(e));
            } else if self.eat_kw("DEFAULT") {
                let e = self.default_value()?;
                constraints.push(ColumnConstraint::Default(e));
            } else if self.eat_kw("COLLATE") {
                let c = self.name()?;
                constraints.push(ColumnConstraint::Collate(c));
            } else if self.eat_kw("REFERENCES") {
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

    fn default_value(&mut self) -> Result<Expr> {
        if self.eat_op("(") {
            let e = self.expr()?;
            self.expect_op(")")?;
            return Ok(e);
        }
        if self.eat_op("-") {
            let e = self.literal_value()?;
            return Ok(negate_literal(e));
        }
        if self.eat_op("+") {
            return self.literal_value();
        }
        if let Tok::Id(s) = self.peek().clone() {
            if !is_reserved(&s) || s.eq_ignore_ascii_case("NULL") {
                let u = s.to_ascii_uppercase();
                if u == "NULL" || u == "TRUE" || u == "FALSE" || u.starts_with("CURRENT_") {
                    return self.literal_value();
                }
                self.advance();
                return Ok(Expr::Lit(Value::Text(s)));
            }
        }
        self.literal_value()
    }

    fn literal_value(&mut self) -> Result<Expr> {
        let e = match self.peek().clone() {
            Tok::Int(Some(v), _) => Expr::Lit(Value::Int(v)),
            Tok::Int(None, text) => Expr::Lit(Value::Real(text.parse::<f64>().unwrap_or(0.0))),
            Tok::Real(f) => Expr::Lit(Value::Real(f)),
            Tok::Str(s) => Expr::Lit(Value::Text(s)),
            Tok::DqId(s) => Expr::Lit(Value::Text(s)),
            Tok::Blob(b) => Expr::Lit(Value::Blob(b)),
            Tok::Id(s) if s.eq_ignore_ascii_case("NULL") => Expr::Lit(Value::Null),
            Tok::Id(s) if s.eq_ignore_ascii_case("TRUE") => Expr::Lit(Value::Int(1)),
            Tok::Id(s) if s.eq_ignore_ascii_case("FALSE") => Expr::Lit(Value::Int(0)),
            Tok::Id(s) if s.to_ascii_uppercase().starts_with("CURRENT_") => {
                Expr::Func { name: s.to_ascii_lowercase(), args: vec![], star: false, distinct: false, coll: Collation::Binary, filter: None, order_by: vec![] }
            }
            _ => return Err(self.syntax_error()),
        };
        self.advance();
        Ok(e)
    }

    fn foreign_key_clause(&mut self) -> Result<ForeignKey> {
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
                    return Err(self.syntax_error());
                }
                if self.eat_kw("SET") {
                    if !(self.eat_kw("NULL") || self.eat_kw("DEFAULT")) {
                        return Err(self.syntax_error());
                    }
                } else if self.eat_kw("CASCADE") || self.eat_kw("RESTRICT") {
                } else if self.eat_kw("NO") {
                    self.expect_kw("ACTION")?;
                } else {
                    return Err(self.syntax_error());
                }
            } else if self.eat_kw("MATCH") {
                self.name()?;
            } else if self.is_kw("DEFERRABLE") || (self.is_kw("NOT") && self.is_kw_at(1, "DEFERRABLE")) {
                self.eat_kw("NOT");
                self.advance();
                if self.eat_kw("INITIALLY") {
                    if !(self.eat_kw("DEFERRED") || self.eat_kw("IMMEDIATE")) {
                        return Err(self.syntax_error());
                    }
                }
            } else {
                break;
            }
        }
        Ok(ForeignKey { table, columns })
    }

    fn indexed_cols(&mut self) -> Result<Vec<IndexedCol>> {
        self.expect_op("(")?;
        let mut cols = Vec::new();
        loop {
            let expr = self.expr()?;
            let (expr, collate) = match expr {
                Expr::Collate(e, c) => (*e, Some(c)),
                e => (e, None),
            };
            let desc = if self.eat_kw("DESC") {
                true
            } else {
                self.eat_kw("ASC");
                false
            };
            cols.push(IndexedCol { expr, collate, desc });
            if !self.eat_op(",") {
                break;
            }
        }
        self.expect_op(")")?;
        Ok(cols)
    }

    fn table_constraint(&mut self) -> Result<TableConstraint> {
        if self.eat_kw("CONSTRAINT") {
            self.name()?;
        }
        if self.eat_kw("PRIMARY") {
            self.expect_kw("KEY")?;
            let cols = self.indexed_cols()?;
            let autoincrement = self.eat_kw("AUTOINCREMENT");
            let conflict = self.conflict_clause()?;
            Ok(TableConstraint::PrimaryKey { cols, conflict, autoincrement })
        } else if self.eat_kw("UNIQUE") {
            let cols = self.indexed_cols()?;
            let conflict = self.conflict_clause()?;
            Ok(TableConstraint::Unique { cols, conflict })
        } else if self.eat_kw("CHECK") {
            self.expect_op("(")?;
            let e = self.expr()?;
            self.expect_op(")")?;
            Ok(TableConstraint::Check(e))
        } else if self.eat_kw("FOREIGN") {
            self.expect_kw("KEY")?;
            self.expect_op("(")?;
            let mut cols = Vec::new();
            loop {
                cols.push(self.name()?);
                if !self.eat_op(",") {
                    break;
                }
            }
            self.expect_op(")")?;
            self.expect_kw("REFERENCES")?;
            let fk = self.foreign_key_clause()?;
            Ok(TableConstraint::ForeignKey { cols, fk })
        } else {
            Err(self.syntax_error())
        }
    }

    fn insert(&mut self) -> Result<Stmt> {
        let mut or = None;
        if self.eat_kw("REPLACE") {
            or = Some(Conflict::Replace);
        } else {
            self.expect_kw("INSERT")?;
            if self.eat_kw("OR") {
                or = Some(self.conflict_action()?);
            }
        }
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
        let source = if self.is_kw("DEFAULT") {
            self.advance();
            self.expect_kw("VALUES")?;
            InsertSource::Default
        } else if self.is_kw("VALUES") {
            self.advance();
            let mut rows = Vec::new();
            loop {
                rows.push(self.paren_expr_list()?);
                if !self.eat_op(",") {
                    break;
                }
            }
            InsertSource::Values(rows)
        } else if self.is_kw("SELECT") || self.is_kw("WITH") {
            InsertSource::Select(Box::new(self.select()?))
        } else {
            return Err(self.syntax_error());
        };
        let mut upserts: Vec<Upsert> = Vec::new();
        while self.is_kw("ON") && self.is_kw_at(1, "CONFLICT") {
            if matches!(source, InsertSource::Default) {
                return Err(self.syntax_error());
            }
            if upserts.last().is_some_and(|u| u.target.is_none()) {
                return Err(self.syntax_error());
            }
            self.advance();
            self.advance();
            let mut target = None;
            let mut target_where = None;
            if self.is_op("(") {
                target = Some(self.indexed_cols()?);
                if self.eat_kw("WHERE") {
                    target_where = Some(self.expr()?);
                }
            }
            self.expect_kw("DO")?;
            let action = if self.eat_kw("NOTHING") {
                UpsertAction::Nothing
            } else {
                self.expect_kw("UPDATE")?;
                self.expect_kw("SET")?;
                let sets = self.set_list()?;
                let where_ = if self.eat_kw("WHERE") { Some(self.expr()?) } else { None };
                UpsertAction::Update { sets, where_ }
            };
            upserts.push(Upsert { target, target_where, action });
        }
        let returning = self.returning()?;
        Ok(Stmt::Insert(Insert { with: None, or, table, alias, columns, source, upserts, returning }))
    }

    fn table_alias(&mut self) -> Result<Option<String>> {
        if self.eat_kw("AS") {
            return Ok(Some(self.name()?));
        }
        if self.at_alias() && !matches!(self.peek(), Tok::Str(_)) && !self.is_kw("INDEXED") {
            return Ok(Some(self.name()?));
        }
        Ok(None)
    }

    fn returning(&mut self) -> Result<Option<Vec<ResultCol>>> {
        if !self.eat_kw("RETURNING") {
            return Ok(None);
        }
        let mut cols = Vec::new();
        loop {
            cols.push(self.result_col()?);
            if !self.eat_op(",") {
                break;
            }
        }
        Ok(Some(cols))
    }

    /// `col = expr, (a, b) = (x, y), ...`
    fn set_list(&mut self) -> Result<Vec<(String, Expr)>> {
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
                let vals = self.paren_expr_list()?;
                if vals.len() != names.len() {
                    return err!("{} columns assigned {} values", names.len(), vals.len());
                }
                sets.extend(names.into_iter().zip(vals));
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

    fn update(&mut self) -> Result<Stmt> {
        let or = if self.eat_kw("OR") { Some(self.conflict_action()?) } else { None };
        let table = self.qualified_name()?;
        let alias = self.table_alias()?;
        self.expect_kw("SET")?;
        let sets = self.set_list()?;
        let where_ = if self.eat_kw("WHERE") { Some(self.expr()?) } else { None };
        let returning = self.returning()?;
        Ok(Stmt::Update(Update { with: None, or, table, alias, sets, where_, returning }))
    }

    fn paren_expr_list(&mut self) -> Result<Vec<Expr>> {
        self.expect_op("(")?;
        let mut v = Vec::new();
        loop {
            v.push(self.expr()?);
            if !self.eat_op(",") {
                break;
            }
        }
        self.expect_op(")")?;
        Ok(v)
    }

    // ---- SELECT ----

    pub fn select(&mut self) -> Result<Select> {
        let with = if self.is_kw("WITH") { Some(Box::new(self.with_clause()?)) } else { None };
        let first = self.select_core()?;
        let mut rest = Vec::new();
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
            rest.push((op, self.select_core()?));
        }
        let mut sel = Select { with, first, rest, order_by: vec![], limit: None, offset: None };
        if self.is_kw("ORDER") {
            sel.order_by = self.order_by_clause()?;
        }
        if self.eat_kw("LIMIT") {
            let a = self.expr()?;
            if self.eat_kw("OFFSET") {
                sel.limit = Some(a);
                sel.offset = Some(self.expr()?);
            } else if self.eat_op(",") {
                sel.offset = Some(a);
                sel.limit = Some(self.expr()?);
            } else {
                sel.limit = Some(a);
            }
        }
        Ok(sel)
    }

    /// Is the parser at the start of a query (inside parentheses)?
    fn at_query(&self) -> bool {
        self.is_kw("SELECT") || self.is_kw("VALUES") || self.is_kw("WITH")
    }

    fn select_core(&mut self) -> Result<Core> {
        if self.eat_kw("VALUES") {
            let mut rows = Vec::new();
            loop {
                rows.push(self.paren_expr_list()?);
                if !self.eat_op(",") {
                    break;
                }
            }
            return Ok(Core::Values(rows));
        }
        self.expect_kw("SELECT")?;
        let distinct = if self.eat_kw("DISTINCT") {
            true
        } else {
            self.eat_kw("ALL");
            false
        };
        let mut columns = Vec::new();
        loop {
            columns.push(self.result_col()?);
            if !self.eat_op(",") {
                break;
            }
        }
        let from = if self.eat_kw("FROM") { self.from_clause()? } else { vec![] };
        let where_ = if self.eat_kw("WHERE") { Some(self.expr()?) } else { None };
        let mut group_by = Vec::new();
        if self.is_kw("GROUP") {
            self.advance();
            self.expect_kw("BY")?;
            loop {
                group_by.push(self.expr()?);
                if !self.eat_op(",") {
                    break;
                }
            }
        }
        let having = if self.eat_kw("HAVING") { Some(self.expr()?) } else { None };
        let mut windows = Vec::new();
        if self.eat_kw("WINDOW") {
            loop {
                let name = self.name()?;
                self.expect_kw("AS")?;
                let def = self.window_def()?;
                windows.push((name, def));
                if !self.eat_op(",") {
                    break;
                }
            }
        }
        Ok(Core::Select(SelectCore { distinct, columns, from, where_, group_by, having, windows }))
    }

    /// `( [base] [PARTITION BY ...] [ORDER BY ...] [frame] )`
    fn window_def(&mut self) -> Result<WindowDef> {
        self.expect_op("(")?;
        let mut def = WindowDef::default();
        let at_clause = |p: &Self| {
            ["PARTITION", "ORDER", "RANGE", "ROWS", "GROUPS"].iter().any(|k| p.is_kw(k))
        };
        if !self.is_op(")") && !at_clause(self) {
            def.base = Some(self.name()?);
        }
        if self.is_kw("PARTITION") {
            self.advance();
            self.expect_kw("BY")?;
            loop {
                def.partition.push(self.expr()?);
                if !self.eat_op(",") {
                    break;
                }
            }
        }
        if self.is_kw("ORDER") {
            def.order = self.order_by_clause()?;
        }
        let unit = if self.eat_kw("RANGE") {
            Some(FrameUnit::Range)
        } else if self.eat_kw("ROWS") {
            Some(FrameUnit::Rows)
        } else if self.eat_kw("GROUPS") {
            Some(FrameUnit::Groups)
        } else {
            None
        };
        if let Some(unit) = unit {
            let (start, end) = if self.eat_kw("BETWEEN") {
                let s = self.frame_bound(true)?;
                self.expect_kw("AND")?;
                let e = self.frame_bound(false)?;
                (s, e)
            } else {
                (self.frame_bound(true)?, FrameBound::CurrentRow)
            };
            let bad = matches!(
                (&start, &end),
                (FrameBound::CurrentRow, FrameBound::Preceding(_))
                    | (FrameBound::Following(_), FrameBound::Preceding(_) | FrameBound::CurrentRow)
            );
            if bad {
                return err!("unsupported frame specification");
            }
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
                } else if self.eat_kw("TIES") {
                    Exclude::Ties
                } else {
                    return Err(self.syntax_error());
                };
            }
            def.frame = Some(Frame { unit, start, end, exclude });
        }
        self.expect_op(")")?;
        Ok(def)
    }

    fn frame_bound(&mut self, is_start: bool) -> Result<FrameBound> {
        if self.is_kw("UNBOUNDED") {
            self.advance();
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
        let e = Box::new(self.expr()?);
        if self.eat_kw("PRECEDING") {
            Ok(FrameBound::Preceding(e))
        } else if self.eat_kw("FOLLOWING") {
            Ok(FrameBound::Following(e))
        } else {
            Err(self.syntax_error())
        }
    }

    fn from_clause(&mut self) -> Result<Vec<FromTerm>> {
        let mut terms = Vec::new();
        let source = self.table_source()?;
        terms.push(FromTerm { source, join: JoinKind::Inner, natural: false, on: None, using: None });
        loop {
            let mut natural = false;
            let join;
            if self.eat_op(",") {
                join = JoinKind::Inner;
            } else {
                if self.eat_kw("NATURAL") {
                    natural = true;
                }
                if self.eat_kw("LEFT") {
                    self.eat_kw("OUTER");
                    join = JoinKind::Left;
                } else if self.eat_kw("RIGHT") {
                    self.eat_kw("OUTER");
                    join = JoinKind::Right;
                } else if self.eat_kw("FULL") {
                    self.eat_kw("OUTER");
                    join = JoinKind::Full;
                } else if self.eat_kw("INNER") || self.eat_kw("CROSS") {
                    join = JoinKind::Inner;
                } else if self.is_kw("JOIN") {
                    join = JoinKind::Inner;
                } else if natural {
                    return Err(self.syntax_error());
                } else {
                    break;
                }
                self.expect_kw("JOIN")?;
            }
            let source = self.table_source()?;
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
                return err!("a NATURAL join may not have an ON or USING clause");
            }
            terms.push(FromTerm { source, join, natural, on, using });
        }
        Ok(terms)
    }

    fn table_source(&mut self) -> Result<TableSource> {
        if self.is_op("(") && (self.is_kw_at(1, "SELECT") || self.is_kw_at(1, "VALUES") || self.is_kw_at(1, "WITH")) {
            self.advance();
            let query = self.select()?;
            self.expect_op(")")?;
            let alias = self.table_alias()?;
            return Ok(TableSource::Subquery { query: Box::new(query), alias });
        }
        let name = self.qualified_name()?;
        let alias = self.table_alias()?;
        if self.eat_kw("INDEXED") {
            self.expect_kw("BY")?;
            self.name()?;
        } else if self.is_kw("NOT") && self.is_kw_at(1, "INDEXED") {
            self.advance();
            self.advance();
        }
        Ok(TableSource::Table { name, alias })
    }

    /// `ORDER BY term, ...` (the current token is ORDER).
    fn order_by_clause(&mut self) -> Result<Vec<OrderTerm>> {
        self.advance();
        self.expect_kw("BY")?;
        let mut out = Vec::new();
        loop {
            let expr = self.expr()?;
            let desc = if self.eat_kw("DESC") {
                true
            } else {
                self.eat_kw("ASC");
                false
            };
            let mut nulls_first = None;
            if self.eat_kw("NULLS") {
                if self.eat_kw("FIRST") {
                    nulls_first = Some(true);
                } else if self.eat_kw("LAST") {
                    nulls_first = Some(false);
                } else {
                    return Err(self.syntax_error());
                }
            }
            out.push(OrderTerm { expr, desc, nulls_first });
            if !self.eat_op(",") {
                break;
            }
        }
        Ok(out)
    }

    fn result_col(&mut self) -> Result<ResultCol> {
        if self.eat_op("*") {
            return Ok(ResultCol::Star);
        }
        let is_name_tok = matches!(self.peek(), Tok::Id(_) | Tok::DqId(_) | Tok::QId(_));
        if is_name_tok
            && matches!(self.peek_at(1), Tok::Op("."))
            && matches!(self.peek_at(2), Tok::Op("*"))
        {
            let name = self.name()?;
            self.advance();
            self.advance();
            return Ok(ResultCol::TableStar(name));
        }
        let start = self.toks[self.pos].pos;
        let expr = self.expr()?;
        let end = if self.pos > 0 { self.toks[self.pos - 1].end } else { start };
        let span = self.src[start..end.max(start)].to_string();
        let mut alias = None;
        if self.eat_kw("AS") {
            alias = Some(self.name()?);
        } else if self.at_alias() {
            alias = Some(self.name()?);
        }
        Ok(ResultCol::Expr { expr, alias, span })
    }

    // ---- expressions ----

    pub fn expr(&mut self) -> Result<Expr> {
        self.or_expr()
    }

    fn or_expr(&mut self) -> Result<Expr> {
        let mut l = self.and_expr()?;
        while self.eat_kw("OR") {
            let r = self.and_expr()?;
            l = Expr::Binary(BinOp::Or, Box::new(l), Box::new(r));
        }
        Ok(l)
    }

    fn and_expr(&mut self) -> Result<Expr> {
        let mut l = self.not_expr()?;
        while self.eat_kw("AND") {
            let r = self.not_expr()?;
            l = Expr::Binary(BinOp::And, Box::new(l), Box::new(r));
        }
        Ok(l)
    }

    fn not_expr(&mut self) -> Result<Expr> {
        if self.eat_kw("NOT") {
            let e = self.not_expr()?;
            return Ok(Expr::Unary(UnOp::Not, Box::new(e)));
        }
        self.equality()
    }

    fn equality(&mut self) -> Result<Expr> {
        let mut l = self.comparison()?;
        loop {
            let op = match self.peek() {
                Tok::Op("=") | Tok::Op("==") => Some(BinOp::Eq),
                Tok::Op("!=") | Tok::Op("<>") => Some(BinOp::Ne),
                _ => None,
            };
            if let Some(op) = op {
                self.advance();
                let r = self.comparison()?;
                l = Expr::Binary(op, Box::new(l), Box::new(r));
                continue;
            }
            if self.eat_kw("ISNULL") {
                l = Expr::IsNull(Box::new(l), false);
                continue;
            }
            if self.eat_kw("NOTNULL") {
                l = Expr::IsNull(Box::new(l), true);
                continue;
            }
            if self.is_kw("NOT") && self.is_kw_at(1, "NULL") {
                self.advance();
                self.advance();
                l = Expr::IsNull(Box::new(l), true);
                continue;
            }
            if self.is_kw("IS") {
                self.advance();
                let mut negated = self.eat_kw("NOT");
                if self.eat_kw("DISTINCT") {
                    self.expect_kw("FROM")?;
                    negated = !negated;
                }
                let r = self.comparison()?;
                l = match r {
                    Expr::Lit(Value::Null) => Expr::IsNull(Box::new(l), negated),
                    r => Expr::Binary(if negated { BinOp::IsNot } else { BinOp::Is }, Box::new(l), Box::new(r)),
                };
                continue;
            }
            let neg = self.is_kw("NOT")
                && ["BETWEEN", "IN", "LIKE", "GLOB", "REGEXP", "MATCH"].iter().any(|k| self.is_kw_at(1, k));
            if neg {
                self.advance();
            }
            if self.eat_kw("BETWEEN") {
                let lo = self.comparison()?;
                self.expect_kw("AND")?;
                let hi = self.comparison()?;
                l = Expr::Between {
                    e: Box::new(l),
                    lo: Box::new(lo),
                    hi: Box::new(hi),
                    neg,
                    info_lo: CmpInfo::default(),
                    info_hi: CmpInfo::default(),
                };
                continue;
            }
            if self.eat_kw("IN") {
                if !self.is_op("(") {
                    // `x IN table`: shorthand for `x IN (SELECT * FROM table)`.
                    let name = self.qualified_name()?;
                    let core = SelectCore {
                        distinct: false,
                        columns: vec![ResultCol::Star],
                        from: vec![FromTerm {
                            source: TableSource::Table { name, alias: None },
                            join: JoinKind::Inner,
                            natural: false,
                            on: None,
                            using: None,
                        }],
                        where_: None,
                        group_by: vec![],
                        having: None,
                        windows: vec![],
                    };
                    let query =
                        Select { with: None, first: Core::Select(core), rest: vec![], order_by: vec![], limit: None, offset: None };
                    l = Expr::InSelect { e: Box::new(l), query: Box::new(query), neg };
                    continue;
                }
                self.expect_op("(")?;
                if self.at_query() {
                    let query = self.select()?;
                    self.expect_op(")")?;
                    l = Expr::InSelect { e: Box::new(l), query: Box::new(query), neg };
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
                l = Expr::InList { e: Box::new(l), list, neg, info: CmpInfo::default() };
                continue;
            }
            if self.is_kw("LIKE") || self.is_kw("GLOB") {
                let glob = self.is_kw("GLOB");
                self.advance();
                let pat = self.comparison()?;
                let esc = if !glob && self.eat_kw("ESCAPE") { Some(Box::new(self.bitwise()?)) } else { None };
                l = Expr::Like { e: Box::new(l), pat: Box::new(pat), esc, neg, glob };
                continue;
            }
            if self.is_kw("REGEXP") || self.is_kw("MATCH") {
                let name = match self.advance() {
                    Tok::Id(s) => s.to_ascii_lowercase(),
                    _ => unreachable!(),
                };
                let r = self.comparison()?;
                let f = Expr::Func { name, args: vec![r, l], star: false, distinct: false, coll: Collation::Binary, filter: None, order_by: vec![] };
                l = if neg { Expr::Unary(UnOp::Not, Box::new(f)) } else { f };
                continue;
            }
            if neg {
                return Err(self.syntax_error());
            }
            break;
        }
        Ok(l)
    }

    fn comparison(&mut self) -> Result<Expr> {
        let mut l = self.bitwise()?;
        loop {
            let op = match self.peek() {
                Tok::Op("<") => BinOp::Lt,
                Tok::Op("<=") => BinOp::Le,
                Tok::Op(">") => BinOp::Gt,
                Tok::Op(">=") => BinOp::Ge,
                _ => break,
            };
            self.advance();
            let r = self.bitwise()?;
            l = Expr::Binary(op, Box::new(l), Box::new(r));
        }
        Ok(l)
    }

    fn bitwise(&mut self) -> Result<Expr> {
        let mut l = self.additive()?;
        loop {
            let op = match self.peek() {
                Tok::Op("&") => BinOp::BitAnd,
                Tok::Op("|") => BinOp::BitOr,
                Tok::Op("<<") => BinOp::Shl,
                Tok::Op(">>") => BinOp::Shr,
                _ => break,
            };
            self.advance();
            let r = self.additive()?;
            l = Expr::Binary(op, Box::new(l), Box::new(r));
        }
        Ok(l)
    }

    fn additive(&mut self) -> Result<Expr> {
        let mut l = self.multiplicative()?;
        loop {
            let op = match self.peek() {
                Tok::Op("+") => BinOp::Add,
                Tok::Op("-") => BinOp::Sub,
                _ => break,
            };
            self.advance();
            let r = self.multiplicative()?;
            l = Expr::Binary(op, Box::new(l), Box::new(r));
        }
        Ok(l)
    }

    fn multiplicative(&mut self) -> Result<Expr> {
        let mut l = self.concat()?;
        loop {
            let op = match self.peek() {
                Tok::Op("*") => BinOp::Mul,
                Tok::Op("/") => BinOp::Div,
                Tok::Op("%") => BinOp::Rem,
                _ => break,
            };
            self.advance();
            let r = self.concat()?;
            l = Expr::Binary(op, Box::new(l), Box::new(r));
        }
        Ok(l)
    }

    fn concat(&mut self) -> Result<Expr> {
        let mut l = self.collate()?;
        while self.eat_op("||") {
            let r = self.collate()?;
            l = Expr::Binary(BinOp::Concat, Box::new(l), Box::new(r));
        }
        Ok(l)
    }

    fn collate(&mut self) -> Result<Expr> {
        let mut e = self.unary()?;
        while self.eat_kw("COLLATE") {
            let c = self.name()?;
            e = Expr::Collate(Box::new(e), c);
        }
        Ok(e)
    }

    fn unary(&mut self) -> Result<Expr> {
        if self.eat_op("-") {
            // -9223372036854775808 is an integer literal
            if let Tok::Int(None, text) = self.peek().clone() {
                if is_min_int_magnitude(&text) {
                    self.advance();
                    return Ok(Expr::Lit(Value::Int(i64::MIN)));
                }
            }
            if self.is_op("(") {
                // -(9223372036854775808) as well
                if let (Tok::Int(None, text), Tok::Op(")")) = (self.peek_at(1).clone(), self.peek_at(2).clone()) {
                    if is_min_int_magnitude(&text) {
                        self.advance();
                        self.advance();
                        self.advance();
                        return Ok(Expr::Lit(Value::Int(i64::MIN)));
                    }
                }
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

    fn primary(&mut self) -> Result<Expr> {
        match self.peek().clone() {
            Tok::Int(..) | Tok::Real(_) | Tok::Str(_) | Tok::Blob(_) => self.literal_value(),
            Tok::Op("(") => {
                self.advance();
                if self.at_query() {
                    let q = self.select()?;
                    self.expect_op(")")?;
                    return Ok(Expr::Subquery(Box::new(q)));
                }
                let e = self.expr()?;
                self.expect_op(")")?;
                Ok(e)
            }
            Tok::Id(s) => {
                let u = s.to_ascii_uppercase();
                match u.as_str() {
                    "NULL" | "TRUE" | "FALSE" => return self.literal_value(),
                    "CURRENT_TIME" | "CURRENT_DATE" | "CURRENT_TIMESTAMP" => return self.literal_value(),
                    "CASE" => return self.case_expr(),
                    "EXISTS" if matches!(self.peek_at(1), Tok::Op("(")) => {
                        self.advance();
                        self.advance();
                        let q = self.select()?;
                        self.expect_op(")")?;
                        return Ok(Expr::Exists(Box::new(q)));
                    }
                    "CAST" if matches!(self.peek_at(1), Tok::Op("(")) => {
                        self.advance();
                        self.advance();
                        let e = self.expr()?;
                        self.expect_kw("AS")?;
                        let t = self.type_name()?;
                        self.expect_op(")")?;
                        return Ok(Expr::Cast(Box::new(e), affinity_of_type(&t)));
                    }
                    _ => {}
                }
                if matches!(self.peek_at(1), Tok::Op("(")) && !is_reserved(&s) {
                    return self.function_call();
                }
                if is_reserved(&s) && !is_join_kw(&s) {
                    return Err(self.syntax_error());
                }
                self.column_ref()
            }
            Tok::DqId(_) | Tok::QId(_) => self.column_ref(),
            _ => Err(self.syntax_error()),
        }
    }

    fn case_expr(&mut self) -> Result<Expr> {
        self.expect_kw("CASE")?;
        let base = if self.is_kw("WHEN") { None } else { Some(Box::new(self.expr()?)) };
        let mut whens = Vec::new();
        while self.eat_kw("WHEN") {
            let w = self.expr()?;
            self.expect_kw("THEN")?;
            let t = self.expr()?;
            whens.push((w, t));
        }
        if whens.is_empty() {
            return Err(self.syntax_error());
        }
        let else_ = if self.eat_kw("ELSE") { Some(Box::new(self.expr()?)) } else { None };
        self.expect_kw("END")?;
        Ok(Expr::Case { base, whens, else_, infos: vec![] })
    }

    fn function_call(&mut self) -> Result<Expr> {
        let name = match self.advance() {
            Tok::Id(s) => s.to_ascii_lowercase(),
            _ => unreachable!(),
        };
        self.expect_op("(")?;
        let mut args = Vec::new();
        let mut star = false;
        let mut distinct = false;
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
        }
        let mut order_by = Vec::new();
        if self.is_kw("ORDER") {
            order_by = self.order_by_clause()?;
        }
        self.expect_op(")")?;
        let mut filter = None;
        if self.is_kw("FILTER") && matches!(self.peek_at(1), Tok::Op("(")) {
            self.advance();
            self.advance();
            self.expect_kw("WHERE")?;
            filter = Some(Box::new(self.expr()?));
            self.expect_op(")")?;
        }
        let f = Expr::Func { name, args, star, distinct, coll: Collation::Binary, filter, order_by };
        if self.eat_kw("OVER") {
            let over = if self.is_op("(") { Over::Spec(self.window_def()?) } else { Over::Named(self.name()?) };
            return Ok(Expr::Window { func: Box::new(f), over: Box::new(over) });
        }
        Ok(f)
    }

    fn column_ref(&mut self) -> Result<Expr> {
        let first_dq = matches!(self.peek(), Tok::DqId(_));
        let first = self.name()?;
        if self.eat_op(".") {
            let second = self.name()?;
            if self.eat_op(".") {
                let third = self.name()?;
                return Ok(Expr::Column { table: Some(second), name: third, dq: false });
            }
            return Ok(Expr::Column { table: Some(first), name: second, dq: false });
        }
        Ok(Expr::Column { table: None, name: first, dq: first_dq })
    }
}

fn is_min_int_magnitude(text: &str) -> bool {
    text.trim_start_matches('0') == "9223372036854775808"
}

fn negate_literal(e: Expr) -> Expr {
    match e {
        Expr::Lit(Value::Int(i)) => Expr::Lit(match i.checked_neg() {
            Some(v) => Value::Int(v),
            None => Value::Real(-(i as f64)),
        }),
        Expr::Lit(Value::Real(f)) => Expr::Lit(Value::Real(-f)),
        e => Expr::Unary(UnOp::Neg, Box::new(e)),
    }
}
