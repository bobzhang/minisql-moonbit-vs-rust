// Recursive-descent SQL parser.

use crate::ast::*;
use crate::lexer::{tokenize, Tok, Token};
use crate::value::Value;

/// Words that can never be used as bare identifiers or implicit aliases.
const RESERVED: &[&str] = &[
    "ALL",
    "ALTER",
    "AND",
    "AS",
    "BETWEEN",
    "BY",
    "CASE",
    "CHECK",
    "COLLATE",
    "CONSTRAINT",
    "CREATE",
    "CROSS",
    "DEFAULT",
    "DELETE",
    "DISTINCT",
    "DROP",
    "ELSE",
    "ESCAPE",
    "EXCEPT",
    "EXISTS",
    "FOREIGN",
    "FROM",
    "FULL",
    "GLOB",
    "GROUP",
    "HAVING",
    "IN",
    "INDEX",
    "INNER",
    "INSERT",
    "INTERSECT",
    "INTO",
    "IS",
    "ISNULL",
    "JOIN",
    "LEFT",
    "LIKE",
    "LIMIT",
    "MATCH",
    "NATURAL",
    "NOT",
    "NOTNULL",
    "NULL",
    "OFFSET",
    "ON",
    "OR",
    "ORDER",
    "OUTER",
    "PRIMARY",
    "REFERENCES",
    "REGEXP",
    "RETURNING",
    "RIGHT",
    "SELECT",
    "SET",
    "TABLE",
    "THEN",
    "TO",
    "UNION",
    "UNIQUE",
    "UPDATE",
    "USING",
    "VALUES",
    "WHEN",
    "WHERE",
    "WINDOW",
];

fn is_reserved(w: &str) -> bool {
    RESERVED.iter().any(|k| k.eq_ignore_ascii_case(w))
}

pub struct Parser {
    toks: Vec<Token>,
    pos: usize,
    src: String,
    /// Byte offset of the object name in a CREATE statement.
    name_start: usize,
}

type PResult<T> = Result<T, String>;

pub fn parse_statement(sql: &str) -> PResult<Stmt> {
    let toks = tokenize(sql)?;
    let mut p = Parser {
        toks,
        pos: 0,
        src: sql.to_string(),
        name_start: 0,
    };
    let mut stmt = p.parse_stmt()?;
    let end = p.toks[p.pos].start.min(sql.len());
    p.eat_op(";");
    if !matches!(p.peek(), Tok::Eof) {
        return Err(p.err());
    }
    // The schema keeps "CREATE <kind> " followed by the text from the name.
    let rest = sql[p.name_start.min(end)..end].trim_end();
    match &mut stmt {
        Stmt::CreateTable(c) => c.sql = format!("CREATE TABLE {}", rest),
        Stmt::CreateIndex(c) => {
            c.sql = format!(
                "CREATE {}INDEX {}",
                if c.unique { "UNIQUE " } else { "" },
                rest
            )
        }
        Stmt::CreateView(c) => c.sql = format!("CREATE VIEW {}", rest),
        _ => {}
    }
    Ok(stmt)
}

impl Parser {
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

    fn err(&self) -> String {
        match self.peek() {
            Tok::Eof => "incomplete input".to_string(),
            _ => format!("near \"{}\": syntax error", self.toks[self.pos].text),
        }
    }

    fn is_kw(&self, kw: &str) -> bool {
        matches!(self.peek(), Tok::Word(w) if w.eq_ignore_ascii_case(kw))
    }

    fn is_kw_at(&self, k: usize, kw: &str) -> bool {
        matches!(self.peek_at(k), Tok::Word(w) if w.eq_ignore_ascii_case(kw))
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
            Err(self.err())
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
            Err(self.err())
        }
    }

    /// An identifier (table, column, alias name).
    fn parse_name(&mut self) -> PResult<String> {
        match self.peek().clone() {
            Tok::Word(w) if !is_reserved(&w) => {
                self.advance();
                Ok(w)
            }
            Tok::QIdent(s, _) => {
                self.advance();
                Ok(s)
            }
            Tok::Str(s) => {
                self.advance();
                Ok(s)
            }
            _ => Err(self.err()),
        }
    }

    fn parse_stmt(&mut self) -> PResult<Stmt> {
        if self.is_kw("WITH") {
            let save = self.pos;
            let with = self.parse_with()?;
            if self.is_kw("SELECT") || self.is_kw("VALUES") {
                self.pos = save;
                return Ok(Stmt::Select(self.parse_select()?));
            }
            let mut stmt = if self.is_kw("INSERT") || self.is_kw("REPLACE") {
                self.parse_insert()?
            } else if self.is_kw("UPDATE") {
                self.parse_update()?
            } else if self.is_kw("DELETE") {
                self.parse_delete()?
            } else {
                return Err(self.err());
            };
            match &mut stmt {
                Stmt::Insert(i) => i.with = Some(Box::new(with)),
                Stmt::Update(u) => u.with = Some(Box::new(with)),
                Stmt::Delete(d) => d.with = Some(Box::new(with)),
                _ => {}
            }
            return Ok(stmt);
        }
        if self.is_kw("CREATE") {
            self.parse_create()
        } else if self.is_kw("DROP") {
            self.parse_drop()
        } else if self.is_kw("INSERT") {
            self.parse_insert()
        } else if self.is_kw("REPLACE") {
            self.parse_insert()
        } else if self.is_kw("UPDATE") {
            self.parse_update()
        } else if self.is_kw("DELETE") {
            self.parse_delete()
        } else if self.is_kw("SELECT") || self.is_kw("VALUES") {
            Ok(Stmt::Select(self.parse_select()?))
        } else if self.is_kw("ALTER") {
            self.parse_alter()
        } else if self.eat_kw("BEGIN") {
            if !self.eat_kw("DEFERRED") && !self.eat_kw("IMMEDIATE") {
                self.eat_kw("EXCLUSIVE");
            }
            self.eat_kw("TRANSACTION");
            Ok(Stmt::Begin)
        } else if self.eat_kw("COMMIT") || self.eat_kw("END") {
            self.eat_kw("TRANSACTION");
            Ok(Stmt::Commit)
        } else if self.eat_kw("ROLLBACK") {
            self.eat_kw("TRANSACTION");
            if self.eat_kw("TO") {
                self.eat_kw("SAVEPOINT");
                return Ok(Stmt::Rollback(Some(self.parse_name()?)));
            }
            Ok(Stmt::Rollback(None))
        } else if self.eat_kw("SAVEPOINT") {
            Ok(Stmt::Savepoint(self.parse_name()?))
        } else if self.eat_kw("RELEASE") {
            self.eat_kw("SAVEPOINT");
            Ok(Stmt::Release(self.parse_name()?))
        } else {
            Err(self.err())
        }
    }

    fn parse_alter(&mut self) -> PResult<Stmt> {
        self.expect_kw("ALTER")?;
        self.expect_kw("TABLE")?;
        let table = self.parse_qualified_name()?;
        let action = if self.eat_kw("RENAME") {
            if self.eat_kw("TO") {
                AlterAction::RenameTable(self.parse_name()?)
            } else {
                self.eat_kw("COLUMN");
                let old = self.parse_name()?;
                self.expect_kw("TO")?;
                AlterAction::RenameColumn(old, self.parse_name()?)
            }
        } else if self.eat_kw("ADD") {
            self.eat_kw("COLUMN");
            let start = self.toks[self.pos].start;
            let mut cd = self.parse_column_def()?;
            let end = self.toks[self.pos].start;
            cd.text = self.src[start..end].trim_end().to_string();
            AlterAction::AddColumn(cd)
        } else if self.eat_kw("DROP") {
            self.eat_kw("COLUMN");
            AlterAction::DropColumn(self.parse_name()?)
        } else {
            return Err(self.err());
        };
        Ok(Stmt::AlterTable { table, action })
    }

    fn parse_if_not_exists(&mut self) -> PResult<bool> {
        if self.is_kw("IF") {
            self.advance();
            self.expect_kw("NOT")?;
            self.expect_kw("EXISTS")?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    fn parse_if_exists(&mut self) -> PResult<bool> {
        if self.is_kw("IF") {
            self.advance();
            self.expect_kw("EXISTS")?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    /// Optional `schema.` prefix followed by a name.
    fn parse_qualified_name(&mut self) -> PResult<String> {
        let n = self.parse_name()?;
        if self.eat_op(".") {
            return self.parse_name();
        }
        Ok(n)
    }

    fn parse_create(&mut self) -> PResult<Stmt> {
        self.expect_kw("CREATE")?;
        if self.eat_kw("TEMP") || self.eat_kw("TEMPORARY") {}
        if self.eat_kw("TABLE") {
            return self.parse_create_table();
        }
        if self.eat_kw("VIEW") {
            let if_not_exists = self.parse_if_not_exists()?;
            self.name_start = self.toks[self.pos].start;
            let name = self.parse_qualified_name()?;
            let mut columns = None;
            if self.eat_op("(") {
                let mut cols = Vec::new();
                loop {
                    cols.push(self.parse_name()?);
                    if !self.eat_op(",") {
                        break;
                    }
                }
                self.expect_op(")")?;
                columns = Some(cols);
            }
            self.expect_kw("AS")?;
            let query = self.parse_select()?;
            return Ok(Stmt::CreateView(CreateView {
                name,
                if_not_exists,
                columns,
                query,
                sql: String::new(),
            }));
        }
        let unique = self.eat_kw("UNIQUE");
        if self.eat_kw("INDEX") {
            let if_not_exists = self.parse_if_not_exists()?;
            self.name_start = self.toks[self.pos].start;
            let name = self.parse_qualified_name()?;
            self.expect_kw("ON")?;
            let table = self.parse_name()?;
            let columns = self.parse_indexed_columns()?;
            let where_ = if self.eat_kw("WHERE") {
                Some(self.parse_expr()?)
            } else {
                None
            };
            return Ok(Stmt::CreateIndex(CreateIndex {
                name,
                table,
                unique,
                if_not_exists,
                columns,
                where_,
                sql: String::new(),
            }));
        }
        Err(self.err())
    }

    fn parse_create_table(&mut self) -> PResult<Stmt> {
        let if_not_exists = self.parse_if_not_exists()?;
        self.name_start = self.toks[self.pos].start;
        let name = self.parse_qualified_name()?;
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
                break;
            }
            columns.push(self.parse_column_def()?);
            if !self.eat_op(",") {
                break;
            }
        }
        if !self.is_op(")") {
            loop {
                constraints.push(self.parse_table_constraint()?);
                if self.eat_op(",") {
                    continue;
                }
                if self.is_op(")") {
                    break;
                }
                // constraints may also be separated by whitespace only
                if self.is_kw("CONSTRAINT")
                    || self.is_kw("PRIMARY")
                    || self.is_kw("UNIQUE")
                    || self.is_kw("CHECK")
                    || self.is_kw("FOREIGN")
                {
                    continue;
                }
                return Err(self.err());
            }
        }
        self.expect_op(")")?;
        // table options
        loop {
            if self.eat_kw("WITHOUT") {
                self.parse_name()?;
            } else if self.eat_kw("STRICT") {
            } else {
                break;
            }
            if !self.eat_op(",") {
                break;
            }
        }
        if columns.is_empty() {
            return Err(self.err());
        }
        Ok(Stmt::CreateTable(CreateTable {
            name,
            sql: String::new(),
            if_not_exists,
            columns,
            constraints,
        }))
    }

    fn is_constraint_start(&self) -> bool {
        [
            "CONSTRAINT",
            "PRIMARY",
            "NOT",
            "NULL",
            "UNIQUE",
            "CHECK",
            "DEFAULT",
            "COLLATE",
            "REFERENCES",
            "GENERATED",
            "AS",
        ]
        .iter()
        .any(|k| self.is_kw(k))
    }

    fn parse_signed_number_text(&mut self) -> PResult<String> {
        let mut s = String::new();
        if self.is_op("+") || self.is_op("-") {
            s.push_str(&self.toks[self.pos].text);
            self.advance();
        }
        match self.peek() {
            Tok::Int(_) | Tok::Float(_) => {
                s.push_str(&self.toks[self.pos].text);
                self.advance();
                Ok(s)
            }
            _ => Err(self.err()),
        }
    }

    fn parse_column_def(&mut self) -> PResult<ColumnDef> {
        let name = self.parse_name()?;
        let mut words: Vec<String> = Vec::new();
        loop {
            if self.is_constraint_start() {
                break;
            }
            match self.peek().clone() {
                Tok::Word(w) => {
                    self.advance();
                    words.push(w);
                }
                Tok::QIdent(s, _) | Tok::Str(s) => {
                    self.advance();
                    words.push(s);
                }
                _ => break,
            }
        }
        let mut type_name = words.join(" ");
        if !words.is_empty() && self.eat_op("(") {
            let a = self.parse_signed_number_text()?;
            type_name.push('(');
            type_name.push_str(&a);
            if self.eat_op(",") {
                let b = self.parse_signed_number_text()?;
                type_name.push_str(", ");
                type_name.push_str(&b);
            }
            self.expect_op(")")?;
            type_name.push(')');
        }
        let mut col = ColumnDef {
            name,
            type_name,
            primary_key: false,
            pk_desc: false,
            pk_conflict: None,
            autoincrement: false,
            not_null: false,
            not_null_conflict: None,
            unique: false,
            unique_conflict: None,
            checks: Vec::new(),
            default: None,
            collate: None,
            text: String::new(),
        };
        let mut cname: Option<String> = None;
        loop {
            if self.eat_kw("CONSTRAINT") {
                cname = Some(self.parse_name()?);
                continue;
            }
            if self.eat_kw("PRIMARY") {
                self.expect_kw("KEY")?;
                col.primary_key = true;
                if self.eat_kw("DESC") {
                    col.pk_desc = true;
                } else {
                    self.eat_kw("ASC");
                }
                col.pk_conflict = self.parse_conflict_clause()?;
                if self.eat_kw("AUTOINCREMENT") {
                    col.autoincrement = true;
                }
            } else if self.eat_kw("NOT") {
                self.expect_kw("NULL")?;
                col.not_null = true;
                col.not_null_conflict = self.parse_conflict_clause()?;
            } else if self.eat_kw("NULL") {
                self.parse_conflict_clause()?;
            } else if self.eat_kw("UNIQUE") {
                col.unique = true;
                col.unique_conflict = self.parse_conflict_clause()?;
            } else if self.eat_kw("CHECK") {
                col.checks.push(self.parse_check_body(cname.take())?);
            } else if self.eat_kw("DEFAULT") {
                let e = if self.eat_op("(") {
                    let e = self.parse_expr()?;
                    self.expect_op(")")?;
                    e
                } else if self.is_op("+") || self.is_op("-") {
                    let neg = self.is_op("-");
                    self.advance();
                    let lit = self.parse_literal()?;
                    if neg {
                        negate_literal(lit)
                    } else {
                        lit
                    }
                } else if let Tok::Word(w) = self.peek().clone() {
                    if w.eq_ignore_ascii_case("NULL")
                        || w.eq_ignore_ascii_case("TRUE")
                        || w.eq_ignore_ascii_case("FALSE")
                        || w.to_ascii_uppercase().starts_with("CURRENT_")
                    {
                        self.parse_primary()?
                    } else {
                        self.advance();
                        Expr::Lit(Value::Text(w))
                    }
                } else {
                    self.parse_literal()?
                };
                col.default = Some(e);
            } else if self.eat_kw("COLLATE") {
                col.collate = Some(self.parse_name()?);
            } else if self.is_kw("REFERENCES") {
                self.parse_references()?;
            } else if self.is_kw("GENERATED") || self.is_kw("AS") {
                if self.eat_kw("GENERATED") {
                    self.expect_kw("ALWAYS")?;
                }
                self.expect_kw("AS")?;
                self.expect_op("(")?;
                self.parse_expr()?;
                self.expect_op(")")?;
                if !self.eat_kw("STORED") {
                    self.eat_kw("VIRTUAL");
                }
            } else {
                break;
            }
            cname = None;
        }
        Ok(col)
    }

    /// `( expr )` of a CHECK constraint; the name defaults to the source text.
    fn parse_check_body(&mut self, name: Option<String>) -> PResult<CheckDef> {
        self.expect_op("(")?;
        let start = self.toks[self.pos].start;
        let expr = self.parse_expr()?;
        let end = self.toks[self.pos].start;
        self.expect_op(")")?;
        let name = name.unwrap_or_else(|| self.src[start..end].trim().to_string());
        Ok(CheckDef { expr, name })
    }

    fn parse_literal(&mut self) -> PResult<Expr> {
        match self.peek() {
            Tok::Int(_) | Tok::Float(_) | Tok::Str(_) | Tok::Blob(_) => self.parse_primary(),
            _ => Err(self.err()),
        }
    }

    fn parse_conflict_clause(&mut self) -> PResult<Option<ConflictAction>> {
        if self.is_kw("ON") && self.is_kw_at(1, "CONFLICT") {
            self.advance();
            self.advance();
            return Ok(Some(self.parse_conflict_action()?));
        }
        Ok(None)
    }

    fn parse_conflict_action(&mut self) -> PResult<ConflictAction> {
        let a = if self.eat_kw("ROLLBACK") {
            ConflictAction::Rollback
        } else if self.eat_kw("ABORT") {
            ConflictAction::Abort
        } else if self.eat_kw("FAIL") {
            ConflictAction::Fail
        } else if self.eat_kw("IGNORE") {
            ConflictAction::Ignore
        } else if self.eat_kw("REPLACE") {
            ConflictAction::Replace
        } else {
            return Err(self.err());
        };
        Ok(a)
    }

    fn parse_references(&mut self) -> PResult<()> {
        self.expect_kw("REFERENCES")?;
        self.parse_name()?;
        if self.eat_op("(") {
            loop {
                self.parse_name()?;
                if !self.eat_op(",") {
                    break;
                }
            }
            self.expect_op(")")?;
        }
        loop {
            if self.is_kw("ON") && !self.is_kw_at(1, "CONFLICT") {
                self.advance();
                if !self.eat_kw("DELETE") {
                    self.expect_kw("UPDATE")?;
                }
                if self.eat_kw("SET") {
                    if !self.eat_kw("NULL") {
                        self.expect_kw("DEFAULT")?;
                    }
                } else if self.eat_kw("CASCADE") || self.eat_kw("RESTRICT") {
                } else if self.eat_kw("NO") {
                    self.expect_kw("ACTION")?;
                } else {
                    return Err(self.err());
                }
            } else if self.eat_kw("MATCH") {
                self.parse_name()?;
            } else if self.is_kw("DEFERRABLE")
                || (self.is_kw("NOT") && self.is_kw_at(1, "DEFERRABLE"))
            {
                self.eat_kw("NOT");
                self.advance();
                if self.eat_kw("INITIALLY") {
                    if !self.eat_kw("DEFERRED") {
                        self.expect_kw("IMMEDIATE")?;
                    }
                }
            } else {
                break;
            }
        }
        Ok(())
    }

    fn parse_indexed_columns(&mut self) -> PResult<Vec<IndexedColumn>> {
        let (cols, autoinc) = self.parse_pk_columns()?;
        if autoinc {
            return Err("near \"AUTOINCREMENT\": syntax error".into());
        }
        Ok(cols)
    }

    /// Indexed column list; AUTOINCREMENT is accepted after a column (only
    /// meaningful for a table-level PRIMARY KEY).
    fn parse_pk_columns(&mut self) -> PResult<(Vec<IndexedColumn>, bool)> {
        self.expect_op("(")?;
        let mut cols = Vec::new();
        let mut autoinc = false;
        loop {
            let e = self.parse_expr()?;
            let (expr, collate) = match e {
                Expr::Collate(inner, c) => (*inner, Some(c)),
                other => (other, None),
            };
            let desc = if self.eat_kw("DESC") {
                true
            } else {
                self.eat_kw("ASC");
                false
            };
            cols.push(IndexedColumn {
                expr,
                collate,
                desc,
            });
            if self.eat_kw("AUTOINCREMENT") {
                autoinc = true;
            }
            if !self.eat_op(",") {
                break;
            }
        }
        self.expect_op(")")?;
        Ok((cols, autoinc))
    }

    fn parse_table_constraint(&mut self) -> PResult<TableConstraint> {
        let mut cname = None;
        if self.eat_kw("CONSTRAINT") {
            cname = Some(self.parse_name()?);
        }
        if self.eat_kw("PRIMARY") {
            self.expect_kw("KEY")?;
            self.expect_op("(")?;
            self.pos -= 1;
            let (cols, autoinc) = self.parse_pk_columns()?;
            let conflict = self.parse_conflict_clause()?;
            Ok(TableConstraint::PrimaryKey(cols, conflict, autoinc))
        } else if self.eat_kw("UNIQUE") {
            let cols = self.parse_indexed_columns()?;
            let conflict = self.parse_conflict_clause()?;
            Ok(TableConstraint::Unique(cols, conflict))
        } else if self.eat_kw("CHECK") {
            Ok(TableConstraint::Check(self.parse_check_body(cname)?))
        } else if self.eat_kw("FOREIGN") {
            self.expect_kw("KEY")?;
            self.expect_op("(")?;
            loop {
                self.parse_name()?;
                if !self.eat_op(",") {
                    break;
                }
            }
            self.expect_op(")")?;
            self.parse_references()?;
            Ok(TableConstraint::ForeignKey)
        } else {
            Err(self.err())
        }
    }

    fn parse_drop(&mut self) -> PResult<Stmt> {
        self.expect_kw("DROP")?;
        let kind = if self.eat_kw("TABLE") {
            0
        } else if self.eat_kw("INDEX") {
            1
        } else {
            self.expect_kw("VIEW")?;
            2
        };
        let if_exists = self.parse_if_exists()?;
        let name = self.parse_qualified_name()?;
        Ok(match kind {
            0 => Stmt::DropTable { name, if_exists },
            1 => Stmt::DropIndex { name, if_exists },
            _ => Stmt::DropView { name, if_exists },
        })
    }

    fn parse_insert(&mut self) -> PResult<Stmt> {
        let mut or_action = None;
        if self.eat_kw("REPLACE") {
            or_action = Some(ConflictAction::Replace);
        } else {
            self.expect_kw("INSERT")?;
            if self.eat_kw("OR") {
                or_action = Some(self.parse_conflict_action()?);
            }
        }
        self.expect_kw("INTO")?;
        let table = self.parse_qualified_name()?;
        let alias = if self.eat_kw("AS") {
            Some(self.parse_name()?)
        } else {
            None
        };
        let mut columns = None;
        if self.eat_op("(") {
            let mut cols = Vec::new();
            loop {
                cols.push(self.parse_name()?);
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
        } else if self.is_kw("VALUES") && !self.values_is_compound() {
            self.advance();
            InsertSource::Values(self.parse_values_rows()?)
        } else if self.is_kw("SELECT") || self.is_kw("VALUES") || self.is_kw("WITH") {
            InsertSource::Select(Box::new(self.parse_select()?))
        } else {
            return Err(self.err());
        };
        let mut upsert = Vec::new();
        if !matches!(source, InsertSource::Default) {
            while self.is_kw("ON") && self.is_kw_at(1, "CONFLICT") {
                self.advance();
                self.advance();
                let target = if self.is_op("(") {
                    let t = self.parse_indexed_columns()?;
                    if self.eat_kw("WHERE") {
                        self.parse_expr()?;
                    }
                    Some(t)
                } else {
                    None
                };
                self.expect_kw("DO")?;
                let action = if self.eat_kw("NOTHING") {
                    UpsertAction::Nothing
                } else {
                    self.expect_kw("UPDATE")?;
                    self.expect_kw("SET")?;
                    let sets = self.parse_set_list()?;
                    let where_ = if self.eat_kw("WHERE") {
                        Some(self.parse_expr()?)
                    } else {
                        None
                    };
                    UpsertAction::Update { sets, where_ }
                };
                let last_untargeted = upsert.last().is_some_and(|u: &Upsert| u.target.is_none());
                if last_untargeted {
                    return Err(
                        "ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint"
                            .into(),
                    );
                }
                upsert.push(Upsert { target, action });
            }
        }
        let returning = self.parse_returning()?;
        Ok(Stmt::Insert(Insert {
            with: None,
            table,
            alias,
            or_action,
            columns,
            source,
            upsert,
            returning,
        }))
    }

    fn parse_set_list(&mut self) -> PResult<Vec<(String, Expr)>> {
        let mut sets = Vec::new();
        loop {
            if self.eat_op("(") {
                let mut names = Vec::new();
                loop {
                    names.push(self.parse_name()?);
                    if !self.eat_op(",") {
                        break;
                    }
                }
                self.expect_op(")")?;
                self.expect_op("=")?;
                self.expect_op("(")?;
                let mut exprs = Vec::new();
                loop {
                    exprs.push(self.parse_expr()?);
                    if !self.eat_op(",") {
                        break;
                    }
                }
                self.expect_op(")")?;
                if names.len() != exprs.len() {
                    return Err(format!(
                        "{} columns assigned {} values",
                        names.len(),
                        exprs.len()
                    ));
                }
                sets.extend(names.into_iter().zip(exprs));
            } else {
                let name = self.parse_name()?;
                self.expect_op("=")?;
                sets.push((name, self.parse_expr()?));
            }
            if !self.eat_op(",") {
                break;
            }
        }
        Ok(sets)
    }

    fn parse_returning(&mut self) -> PResult<Option<Vec<ResultCol>>> {
        if !self.eat_kw("RETURNING") {
            return Ok(None);
        }
        let mut cols = Vec::new();
        loop {
            cols.push(self.parse_result_col()?);
            if !self.eat_op(",") {
                break;
            }
        }
        Ok(Some(cols))
    }

    fn parse_update(&mut self) -> PResult<Stmt> {
        self.expect_kw("UPDATE")?;
        let or_action = if self.eat_kw("OR") {
            Some(self.parse_conflict_action()?)
        } else {
            None
        };
        let table = self.parse_qualified_name()?;
        let alias = self.parse_alias()?;
        self.expect_kw("SET")?;
        let sets = self.parse_set_list()?;
        let where_ = if self.eat_kw("WHERE") {
            Some(self.parse_expr()?)
        } else {
            None
        };
        let returning = self.parse_returning()?;
        Ok(Stmt::Update(Update {
            with: None,
            table,
            alias,
            or_action,
            sets,
            where_,
            returning,
        }))
    }

    fn parse_delete(&mut self) -> PResult<Stmt> {
        self.expect_kw("DELETE")?;
        self.expect_kw("FROM")?;
        let table = self.parse_qualified_name()?;
        let alias = self.parse_alias()?;
        let where_ = if self.eat_kw("WHERE") {
            Some(self.parse_expr()?)
        } else {
            None
        };
        let returning = self.parse_returning()?;
        Ok(Stmt::Delete(Delete {
            with: None,
            table,
            alias,
            where_,
            returning,
        }))
    }

    /// Rows of a VALUES clause (after the VALUES keyword).
    fn parse_values_rows(&mut self) -> PResult<Vec<Vec<Expr>>> {
        let mut rows: Vec<Vec<Expr>> = Vec::new();
        loop {
            self.expect_op("(")?;
            let mut row = Vec::new();
            loop {
                row.push(self.parse_expr()?);
                if !self.eat_op(",") {
                    break;
                }
            }
            self.expect_op(")")?;
            if let Some(first) = rows.first() {
                if first.len() != row.len() {
                    return Err("all VALUES must have the same number of terms".into());
                }
            }
            rows.push(row);
            if !self.eat_op(",") {
                break;
            }
        }
        Ok(rows)
    }

    /// Whether the VALUES clause at the current position is followed by a
    /// compound operator, ORDER BY or LIMIT (so it must be parsed as a query).
    fn values_is_compound(&self) -> bool {
        let mut depth = 0i32;
        let mut k = 1;
        loop {
            match self.peek_at(k) {
                Tok::Eof => return false,
                Tok::Op("(") => depth += 1,
                Tok::Op(")") => depth -= 1,
                Tok::Word(w) if depth == 0 => {
                    let u = w.to_ascii_uppercase();
                    return matches!(
                        u.as_str(),
                        "UNION" | "INTERSECT" | "EXCEPT" | "ORDER" | "LIMIT"
                    );
                }
                Tok::Op(";") if depth == 0 => return false,
                _ => {}
            }
            k += 1;
        }
    }

    fn is_query_start(&self, k: usize) -> bool {
        self.is_kw_at(k, "SELECT") || self.is_kw_at(k, "VALUES") || self.is_kw_at(k, "WITH")
    }

    /// WITH [RECURSIVE] name [(cols)] AS [NOT] [MATERIALIZED] (select), ...
    fn parse_with(&mut self) -> PResult<With> {
        self.expect_kw("WITH")?;
        self.eat_kw("RECURSIVE");
        let mut ctes = Vec::new();
        loop {
            let name = self.parse_name()?;
            let mut columns = None;
            if self.eat_op("(") {
                let mut cols = Vec::new();
                loop {
                    cols.push(self.parse_name()?);
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
            let query = self.parse_select()?;
            self.expect_op(")")?;
            if ctes
                .iter()
                .any(|c: &Cte| c.name.eq_ignore_ascii_case(&name))
            {
                return Err(format!("duplicate WITH table name: {}", name));
            }
            ctes.push(Cte {
                name,
                columns,
                query,
            });
            if !self.eat_op(",") {
                break;
            }
        }
        Ok(With { ctes })
    }

    /// The inside of a window definition, after its opening parenthesis.
    fn parse_window_spec(&mut self) -> PResult<WindowSpec> {
        let mut spec = WindowSpec::default();
        let is_clause = |p: &Self| {
            ["PARTITION", "ORDER", "ROWS", "RANGE", "GROUPS"]
                .iter()
                .any(|k| p.is_kw(k))
        };
        if !self.is_op(")") && !is_clause(self) {
            spec.base = Some(self.parse_name()?);
        }
        if self.eat_kw("PARTITION") {
            self.expect_kw("BY")?;
            loop {
                spec.partition.push(self.parse_expr()?);
                if !self.eat_op(",") {
                    break;
                }
            }
        }
        if self.eat_kw("ORDER") {
            self.expect_kw("BY")?;
            spec.order = self.parse_order_terms()?;
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
                let s = self.parse_frame_bound(true)?;
                self.expect_kw("AND")?;
                (s, self.parse_frame_bound(false)?)
            } else {
                (self.parse_frame_bound(true)?, FrameBound::CurrentRow)
            };
            let mut exclude = FrameExclude::NoOthers;
            if self.eat_kw("EXCLUDE") {
                exclude = if self.eat_kw("NO") {
                    self.expect_kw("OTHERS")?;
                    FrameExclude::NoOthers
                } else if self.eat_kw("CURRENT") {
                    self.expect_kw("ROW")?;
                    FrameExclude::CurrentRow
                } else if self.eat_kw("GROUP") {
                    FrameExclude::Group
                } else {
                    self.expect_kw("TIES")?;
                    FrameExclude::Ties
                };
            }
            spec.frame = Some(FrameSpec {
                unit,
                start,
                end,
                exclude,
            });
        }
        self.expect_op(")")?;
        Ok(spec)
    }

    fn parse_frame_bound(&mut self, start: bool) -> PResult<FrameBound> {
        if self.is_kw("UNBOUNDED") {
            self.advance();
            if start {
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
        let e = self.parse_expr()?;
        if self.eat_kw("PRECEDING") {
            Ok(FrameBound::Preceding(e))
        } else {
            self.expect_kw("FOLLOWING")?;
            Ok(FrameBound::Following(e))
        }
    }

    pub fn parse_select(&mut self) -> PResult<Select> {
        let with = if self.is_kw("WITH") {
            Some(Box::new(self.parse_with()?))
        } else {
            None
        };
        let mut cores = vec![self.parse_core()?];
        let mut ops = Vec::new();
        loop {
            let op = if self.eat_kw("UNION") {
                if self.eat_kw("ALL") {
                    SetOp::UnionAll
                } else {
                    SetOp::Union
                }
            } else if self.eat_kw("INTERSECT") {
                SetOp::Intersect
            } else if self.eat_kw("EXCEPT") {
                SetOp::Except
            } else {
                break;
            };
            ops.push(op);
            cores.push(self.parse_core()?);
        }
        // ORDER BY / LIMIT attach to a trailing SELECT, never to VALUES.
        if matches!(cores.last(), Some(Core::Values(_)))
            && (self.is_kw("ORDER") || self.is_kw("LIMIT"))
        {
            return Err(self.err());
        }
        let mut order_by = Vec::new();
        if self.eat_kw("ORDER") {
            self.expect_kw("BY")?;
            order_by = self.parse_order_terms()?;
        }
        let mut limit = None;
        let mut offset = None;
        if self.eat_kw("LIMIT") {
            let a = self.parse_expr()?;
            if self.eat_kw("OFFSET") {
                offset = Some(self.parse_expr()?);
                limit = Some(a);
            } else if self.eat_op(",") {
                limit = Some(self.parse_expr()?);
                offset = Some(a);
            } else {
                limit = Some(a);
            }
        }
        Ok(Select {
            with,
            cores,
            ops,
            order_by,
            limit,
            offset,
        })
    }

    fn parse_core(&mut self) -> PResult<Core> {
        if self.eat_kw("VALUES") {
            return Ok(Core::Values(self.parse_values_rows()?));
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
            columns.push(self.parse_result_col()?);
            if !self.eat_op(",") {
                break;
            }
        }
        let mut from = Vec::new();
        if self.eat_kw("FROM") {
            from = self.parse_from()?;
        }
        let mut where_ = None;
        if self.eat_kw("WHERE") {
            where_ = Some(self.parse_expr()?);
        }
        let mut group_by = Vec::new();
        if self.eat_kw("GROUP") {
            self.expect_kw("BY")?;
            loop {
                group_by.push(self.parse_expr()?);
                if !self.eat_op(",") {
                    break;
                }
            }
        }
        let having = if self.eat_kw("HAVING") {
            Some(self.parse_expr()?)
        } else {
            None
        };
        let mut windows = Vec::new();
        if self.eat_kw("WINDOW") {
            loop {
                let name = self.parse_name()?;
                self.expect_kw("AS")?;
                self.expect_op("(")?;
                windows.push((name, self.parse_window_spec()?));
                if !self.eat_op(",") {
                    break;
                }
            }
        }
        Ok(Core::Select(SelectCore {
            distinct,
            columns,
            from,
            where_,
            group_by,
            having,
            windows,
        }))
    }

    fn parse_from(&mut self) -> PResult<Vec<JoinTerm>> {
        let first = self.parse_table_ref()?;
        let mut terms = vec![JoinTerm {
            source: first,
            kind: JoinKind::Inner,
            natural: false,
            on: None,
            using: None,
        }];
        loop {
            let (kind, natural) = if self.eat_op(",") {
                (JoinKind::Inner, false)
            } else {
                let save = self.pos;
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
                } else {
                    if !self.eat_kw("INNER") {
                        self.eat_kw("CROSS");
                    }
                    JoinKind::Inner
                };
                if !self.eat_kw("JOIN") {
                    if self.pos != save {
                        return Err(self.err());
                    }
                    break;
                }
                (kind, natural)
            };
            let source = self.parse_table_ref()?;
            let mut on = None;
            let mut using = None;
            if self.eat_kw("ON") {
                on = Some(self.parse_expr()?);
            } else if self.eat_kw("USING") {
                self.expect_op("(")?;
                let mut names = Vec::new();
                loop {
                    names.push(self.parse_name()?);
                    if !self.eat_op(",") {
                        break;
                    }
                }
                self.expect_op(")")?;
                using = Some(names);
            }
            if natural && (on.is_some() || using.is_some()) {
                return Err("a NATURAL join may not have an ON or USING clause".into());
            }
            terms.push(JoinTerm {
                source,
                kind,
                natural,
                on,
                using,
            });
        }
        Ok(terms)
    }

    fn parse_table_ref(&mut self) -> PResult<TableRef> {
        if self.is_op("(") && self.is_query_start(1) {
            self.advance();
            let query = self.parse_select()?;
            self.expect_op(")")?;
            let alias = self.parse_alias()?;
            return Ok(TableRef::Subquery {
                query: Box::new(query),
                alias,
            });
        }
        let name = self.parse_qualified_name()?;
        let alias = self.parse_alias()?;
        Ok(TableRef::Table { name, alias })
    }

    fn parse_order_terms(&mut self) -> PResult<Vec<OrderTerm>> {
        let mut order_by = Vec::new();
        loop {
            let expr = self.parse_expr()?;
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
                } else {
                    self.expect_kw("LAST")?;
                    nulls_first = Some(false);
                }
            }
            order_by.push(OrderTerm {
                expr,
                desc,
                nulls_first,
            });
            if !self.eat_op(",") {
                break;
            }
        }
        Ok(order_by)
    }

    fn parse_alias(&mut self) -> PResult<Option<String>> {
        if self.eat_kw("AS") {
            return Ok(Some(self.parse_name()?));
        }
        match self.peek() {
            Tok::Word(w) if !is_reserved(w) => Ok(Some(self.parse_name()?)),
            Tok::QIdent(..) | Tok::Str(_) => Ok(Some(self.parse_name()?)),
            _ => Ok(None),
        }
    }

    fn parse_result_col(&mut self) -> PResult<ResultCol> {
        if self.eat_op("*") {
            return Ok(ResultCol::Star);
        }
        // name.*
        let is_name = matches!(self.peek(), Tok::Word(w) if !is_reserved(w))
            || matches!(self.peek(), Tok::QIdent(..));
        if is_name
            && matches!(self.peek_at(1), Tok::Op("."))
            && matches!(self.peek_at(2), Tok::Op("*"))
        {
            let n = self.parse_name()?;
            self.advance();
            self.advance();
            return Ok(ResultCol::TableStar(n));
        }
        let start = self.toks[self.pos].start;
        let e = self.parse_expr()?;
        let last = &self.toks[self.pos.saturating_sub(1)];
        let text = self.src[start..(last.start + last.text.len()).max(start)].to_string();
        let alias = self.parse_alias()?;
        Ok(ResultCol::Expr(e, alias, text))
    }

    // ---------------------------------------------------------------
    // Expressions
    // ---------------------------------------------------------------

    pub fn parse_expr(&mut self) -> PResult<Expr> {
        self.parse_or()
    }

    fn parse_or(&mut self) -> PResult<Expr> {
        let mut l = self.parse_and()?;
        while self.eat_kw("OR") {
            let r = self.parse_and()?;
            l = Expr::Binary(BinOp::Or, Box::new(l), Box::new(r));
        }
        Ok(l)
    }

    fn parse_and(&mut self) -> PResult<Expr> {
        let mut l = self.parse_not()?;
        while self.eat_kw("AND") {
            let r = self.parse_not()?;
            l = Expr::Binary(BinOp::And, Box::new(l), Box::new(r));
        }
        Ok(l)
    }

    fn parse_not(&mut self) -> PResult<Expr> {
        if self.eat_kw("NOT") {
            let e = self.parse_not()?;
            return Ok(Expr::Unary(UnOp::Not, Box::new(e)));
        }
        self.parse_equality()
    }

    fn parse_equality(&mut self) -> PResult<Expr> {
        let mut l = self.parse_comparison()?;
        loop {
            if self.eat_op("=") || self.eat_op("==") {
                let r = self.parse_comparison()?;
                l = Expr::Binary(BinOp::Eq, Box::new(l), Box::new(r));
            } else if self.eat_op("!=") || self.eat_op("<>") {
                let r = self.parse_comparison()?;
                l = Expr::Binary(BinOp::Ne, Box::new(l), Box::new(r));
            } else if self.eat_kw("IS") {
                let not = self.eat_kw("NOT");
                if self.eat_kw("DISTINCT") {
                    self.expect_kw("FROM")?;
                    let r = self.parse_comparison()?;
                    let op = if not { BinOp::Is } else { BinOp::IsNot };
                    l = Expr::Binary(op, Box::new(l), Box::new(r));
                } else {
                    let r = self.parse_comparison()?;
                    let op = if not { BinOp::IsNot } else { BinOp::Is };
                    l = Expr::Binary(op, Box::new(l), Box::new(r));
                }
            } else if self.eat_kw("ISNULL") {
                l = Expr::IsNull(Box::new(l));
            } else if self.eat_kw("NOTNULL") {
                l = Expr::NotNull(Box::new(l));
            } else if self.is_kw("NOT") && self.is_kw_at(1, "NULL") {
                self.advance();
                self.advance();
                l = Expr::NotNull(Box::new(l));
            } else {
                let save = self.pos;
                let not = self.eat_kw("NOT");
                if self.eat_kw("BETWEEN") {
                    let lo = self.parse_comparison()?;
                    self.expect_kw("AND")?;
                    let hi = self.parse_comparison()?;
                    l = Expr::Between {
                        expr: Box::new(l),
                        lo: Box::new(lo),
                        hi: Box::new(hi),
                        not,
                    };
                } else if self.eat_kw("IN") {
                    if !self.is_op("(") {
                        // x IN table: shorthand for x IN (SELECT * FROM table).
                        let name = self.parse_qualified_name()?;
                        let core = SelectCore {
                            distinct: false,
                            columns: vec![ResultCol::Star],
                            from: vec![JoinTerm {
                                source: TableRef::Table { name, alias: None },
                                kind: JoinKind::Inner,
                                natural: false,
                                on: None,
                                using: None,
                            }],
                            where_: None,
                            group_by: vec![],
                            having: None,
                            windows: vec![],
                        };
                        let query = Select {
                            with: None,
                            cores: vec![Core::Select(core)],
                            ops: vec![],
                            order_by: vec![],
                            limit: None,
                            offset: None,
                        };
                        l = Expr::InSelect {
                            expr: Box::new(l),
                            query: Box::new(query),
                            not,
                        };
                        continue;
                    }
                    self.expect_op("(")?;
                    if self.is_query_start(0) {
                        let query = self.parse_select()?;
                        self.expect_op(")")?;
                        l = Expr::InSelect {
                            expr: Box::new(l),
                            query: Box::new(query),
                            not,
                        };
                        continue;
                    }
                    let mut list = Vec::new();
                    if !self.is_op(")") {
                        loop {
                            list.push(self.parse_expr()?);
                            if !self.eat_op(",") {
                                break;
                            }
                        }
                    }
                    self.expect_op(")")?;
                    l = Expr::InList {
                        expr: Box::new(l),
                        list,
                        not,
                    };
                } else if let Some(op) = self.like_op() {
                    self.advance();
                    let pattern = self.parse_comparison()?;
                    let escape = if self.eat_kw("ESCAPE") {
                        Some(Box::new(self.parse_comparison()?))
                    } else {
                        None
                    };
                    l = Expr::Like {
                        op,
                        expr: Box::new(l),
                        pattern: Box::new(pattern),
                        escape,
                        not,
                    };
                } else {
                    self.pos = save;
                    break;
                }
            }
        }
        Ok(l)
    }

    fn like_op(&self) -> Option<LikeOp> {
        if self.is_kw("LIKE") {
            Some(LikeOp::Like)
        } else if self.is_kw("GLOB") {
            Some(LikeOp::Glob)
        } else if self.is_kw("REGEXP") {
            Some(LikeOp::Regexp)
        } else if self.is_kw("MATCH") {
            Some(LikeOp::Match)
        } else {
            None
        }
    }

    fn parse_comparison(&mut self) -> PResult<Expr> {
        let mut l = self.parse_bitwise()?;
        loop {
            let op = if self.eat_op("<") {
                BinOp::Lt
            } else if self.eat_op("<=") {
                BinOp::Le
            } else if self.eat_op(">") {
                BinOp::Gt
            } else if self.eat_op(">=") {
                BinOp::Ge
            } else {
                break;
            };
            let r = self.parse_bitwise()?;
            l = Expr::Binary(op, Box::new(l), Box::new(r));
        }
        Ok(l)
    }

    fn parse_bitwise(&mut self) -> PResult<Expr> {
        let mut l = self.parse_additive()?;
        loop {
            let op = if self.eat_op("&") {
                BinOp::BitAnd
            } else if self.eat_op("|") {
                BinOp::BitOr
            } else if self.eat_op("<<") {
                BinOp::Shl
            } else if self.eat_op(">>") {
                BinOp::Shr
            } else {
                break;
            };
            let r = self.parse_additive()?;
            l = Expr::Binary(op, Box::new(l), Box::new(r));
        }
        Ok(l)
    }

    fn parse_additive(&mut self) -> PResult<Expr> {
        let mut l = self.parse_multiplicative()?;
        loop {
            let op = if self.eat_op("+") {
                BinOp::Add
            } else if self.eat_op("-") {
                BinOp::Sub
            } else {
                break;
            };
            let r = self.parse_multiplicative()?;
            l = Expr::Binary(op, Box::new(l), Box::new(r));
        }
        Ok(l)
    }

    fn parse_multiplicative(&mut self) -> PResult<Expr> {
        let mut l = self.parse_concat()?;
        loop {
            let op = if self.eat_op("*") {
                BinOp::Mul
            } else if self.eat_op("/") {
                BinOp::Div
            } else if self.eat_op("%") {
                BinOp::Rem
            } else {
                break;
            };
            let r = self.parse_concat()?;
            l = Expr::Binary(op, Box::new(l), Box::new(r));
        }
        Ok(l)
    }

    fn parse_concat(&mut self) -> PResult<Expr> {
        let mut l = self.parse_unary()?;
        while self.eat_op("||") {
            let r = self.parse_unary()?;
            l = Expr::Binary(BinOp::Concat, Box::new(l), Box::new(r));
        }
        Ok(l)
    }

    fn parse_unary(&mut self) -> PResult<Expr> {
        if self.eat_op("-") {
            // -9223372036854775808 is the minimum integer literal
            if let Tok::Int(t) = self.peek().clone() {
                if t.trim_start_matches('0') == "9223372036854775808" {
                    self.advance();
                    return self.parse_postfix(Expr::Lit(Value::Integer(i64::MIN)));
                }
            }
            let e = self.parse_unary()?;
            return Ok(Expr::Unary(UnOp::Neg, Box::new(e)));
        }
        if self.eat_op("+") {
            let e = self.parse_unary()?;
            return Ok(Expr::Unary(UnOp::Pos, Box::new(e)));
        }
        if self.eat_op("~") {
            let e = self.parse_unary()?;
            return Ok(Expr::Unary(UnOp::BitNot, Box::new(e)));
        }
        if self.is_kw("NOT") {
            // NOT inside a higher-precedence context, e.g. `1 = NOT 0`
            self.advance();
            let e = self.parse_equality()?;
            return Ok(Expr::Unary(UnOp::Not, Box::new(e)));
        }
        let p = self.parse_primary()?;
        self.parse_postfix(p)
    }

    fn parse_postfix(&mut self, mut e: Expr) -> PResult<Expr> {
        while self.eat_kw("COLLATE") {
            let c = self.parse_name()?;
            e = Expr::Collate(Box::new(e), c);
        }
        Ok(e)
    }

    fn parse_primary(&mut self) -> PResult<Expr> {
        let tok = self.peek().clone();
        match tok {
            Tok::Int(t) => {
                self.advance();
                Ok(Expr::Lit(parse_int_literal(&t)?))
            }
            Tok::Float(t) => {
                self.advance();
                Ok(Expr::Lit(Value::Real(parse_float_literal(&t))))
            }
            Tok::Str(s) => {
                self.advance();
                Ok(Expr::Lit(Value::Text(s)))
            }
            Tok::Blob(b) => {
                self.advance();
                Ok(Expr::Lit(Value::Blob(b)))
            }
            Tok::Op("(") => {
                self.advance();
                if self.is_query_start(0) {
                    let q = self.parse_select()?;
                    self.expect_op(")")?;
                    return Ok(Expr::Subquery(Box::new(q)));
                }
                let e = self.parse_expr()?;
                self.expect_op(")")?;
                Ok(e)
            }
            Tok::QIdent(name, dq) => {
                self.advance();
                if self.is_op(".") {
                    self.advance();
                    let col = self.parse_name()?;
                    return Ok(Expr::Column {
                        table: Some(name),
                        name: col,
                        dq: false,
                    });
                }
                Ok(Expr::Column {
                    table: None,
                    name,
                    dq,
                })
            }
            Tok::Word(w) => {
                let up = w.to_ascii_uppercase();
                match up.as_str() {
                    "NULL" => {
                        self.advance();
                        return Ok(Expr::Lit(Value::Null));
                    }
                    "TRUE" => {
                        self.advance();
                        return Ok(Expr::Lit(Value::Integer(1)));
                    }
                    "FALSE" => {
                        self.advance();
                        return Ok(Expr::Lit(Value::Integer(0)));
                    }
                    "CASE" => return self.parse_case(),
                    "EXISTS" if matches!(self.peek_at(1), Tok::Op("(")) => {
                        self.advance();
                        self.advance();
                        let q = self.parse_select()?;
                        self.expect_op(")")?;
                        return Ok(Expr::Exists(Box::new(q)));
                    }
                    "CAST" => {
                        self.advance();
                        self.expect_op("(")?;
                        let e = self.parse_expr()?;
                        self.expect_kw("AS")?;
                        let mut words = Vec::new();
                        while let Tok::Word(w) = self.peek().clone() {
                            self.advance();
                            words.push(w);
                        }
                        let mut t = words.join(" ");
                        if self.eat_op("(") {
                            let a = self.parse_signed_number_text()?;
                            t.push('(');
                            t.push_str(&a);
                            if self.eat_op(",") {
                                let b = self.parse_signed_number_text()?;
                                t.push_str(", ");
                                t.push_str(&b);
                            }
                            self.expect_op(")")?;
                            t.push(')');
                        }
                        self.expect_op(")")?;
                        return Ok(Expr::Cast(Box::new(e), t));
                    }
                    _ => {}
                }
                let like_fn = ["LIKE", "GLOB", "REGEXP", "MATCH"].contains(&up.as_str());
                if is_reserved(&w) && !(like_fn && matches!(self.peek_at(1), Tok::Op("("))) {
                    return Err(self.err());
                }
                self.advance();
                if self.is_op("(") {
                    return self.parse_function(w);
                }
                if self.is_op(".") {
                    self.advance();
                    let col = self.parse_name()?;
                    return Ok(Expr::Column {
                        table: Some(w),
                        name: col,
                        dq: false,
                    });
                }
                Ok(Expr::Column {
                    table: None,
                    name: w,
                    dq: false,
                })
            }
            _ => Err(self.err()),
        }
    }

    fn parse_function(&mut self, name: String) -> PResult<Expr> {
        self.expect_op("(")?;
        let mut args = Vec::new();
        let mut distinct = false;
        let mut star = false;
        if self.eat_op("*") {
            star = true;
        } else if !self.is_op(")") {
            if self.eat_kw("DISTINCT") {
                distinct = true;
            } else {
                self.eat_kw("ALL");
            }
            loop {
                args.push(self.parse_expr()?);
                if !self.eat_op(",") {
                    break;
                }
            }
        }
        let mut order_by = Vec::new();
        if !star && self.eat_kw("ORDER") {
            self.expect_kw("BY")?;
            order_by = self.parse_order_terms()?;
        }
        self.expect_op(")")?;
        let mut filter = None;
        if self.is_kw("FILTER") && matches!(self.peek_at(1), Tok::Op("(")) {
            self.advance();
            self.advance();
            self.expect_kw("WHERE")?;
            filter = Some(Box::new(self.parse_expr()?));
            self.expect_op(")")?;
        }
        let mut over = None;
        if self.eat_kw("OVER") {
            if self.eat_op("(") {
                over = Some(Box::new(self.parse_window_spec()?));
            } else {
                let base = self.parse_name()?;
                over = Some(Box::new(WindowSpec {
                    base: Some(base),
                    bare: true,
                    ..Default::default()
                }));
            }
        }
        Ok(Expr::Func {
            name,
            args,
            distinct,
            star,
            filter,
            order_by,
            over,
        })
    }

    fn parse_case(&mut self) -> PResult<Expr> {
        self.expect_kw("CASE")?;
        let operand = if self.is_kw("WHEN") {
            None
        } else {
            Some(Box::new(self.parse_expr()?))
        };
        let mut whens = Vec::new();
        while self.eat_kw("WHEN") {
            let w = self.parse_expr()?;
            self.expect_kw("THEN")?;
            let t = self.parse_expr()?;
            whens.push((w, t));
        }
        if whens.is_empty() {
            return Err(self.err());
        }
        let else_ = if self.eat_kw("ELSE") {
            Some(Box::new(self.parse_expr()?))
        } else {
            None
        };
        self.expect_kw("END")?;
        Ok(Expr::Case {
            operand,
            whens,
            else_,
        })
    }
}

fn negate_literal(e: Expr) -> Expr {
    match e {
        Expr::Lit(Value::Integer(i)) => match i.checked_neg() {
            Some(n) => Expr::Lit(Value::Integer(n)),
            None => Expr::Lit(Value::Real(-(i as f64))),
        },
        Expr::Lit(Value::Real(r)) => Expr::Lit(Value::Real(-r)),
        other => Expr::Unary(UnOp::Neg, Box::new(other)),
    }
}

fn parse_int_literal(t: &str) -> PResult<Value> {
    if t.len() > 2 && (t.starts_with("0x") || t.starts_with("0X")) {
        let h = t[2..].trim_start_matches('0');
        if h.len() > 16 {
            return Err(format!("hex literal too big: {}", t));
        }
        let v = if h.is_empty() {
            0
        } else {
            u64::from_str_radix(h, 16).map_err(|e| e.to_string())?
        };
        return Ok(Value::Integer(v as i64));
    }
    match t.parse::<i64>() {
        Ok(v) => Ok(Value::Integer(v)),
        Err(_) => Ok(Value::Real(parse_float_literal(t))),
    }
}

fn parse_float_literal(t: &str) -> f64 {
    crate::value::atof(t.as_bytes()).1
}
