// Schema statements: CREATE/DROP TABLE, INDEX, VIEW and ALTER TABLE.

use std::rc::Rc;

use crate::alter::{rename_qualifier, rename_table_in_select, ColRefs};
use crate::ast::*;
use crate::db::{is_schema_table, key, Check, Column, IdxColKind, Index, IndexCol, Table, View};
use crate::error::{err, Result};
use crate::eval::{bind, contains_subquery, eval, expr_affinity, expr_collation, Cx, Scope};
use crate::exec::{table_source, Engine};
use crate::value::{affinity_of_type, Collation, Value};

fn reserved(name: &str) -> bool {
    name.len() >= 7 && name.as_bytes()[..7].eq_ignore_ascii_case(b"sqlite_")
}

/// Build a column from its definition (constraints other than NOT NULL,
/// DEFAULT and COLLATE are handled by the caller).
fn build_column(cd: &ColumnDef) -> Result<Column> {
    let mut col = Column {
        name: cd.name.clone(),
        decl_type: cd.type_name.clone(),
        affinity: affinity_of_type(&cd.type_name),
        not_null: None,
        default: None,
        collation: None,
    };
    for c in &cd.constraints {
        match c {
            ColumnConstraint::NotNull { conflict } => {
                col.not_null = Some(conflict.unwrap_or(Conflict::Abort));
            }
            ColumnConstraint::Default(e) => {
                if contains_subquery(e) {
                    return err!("default value of column [{}] is not constant", cd.name);
                }
                col.default = Some(e.clone())
            }
            ColumnConstraint::Collate(c) => {
                if Collation::from_name(c).is_none() {
                    return err!("no such collation sequence: {}", c);
                }
                col.collation = Some(c.clone())
            }
            _ => {}
        }
    }
    Ok(col)
}

fn plain_index(cols: Vec<(usize, Collation)>, columns: &[Column], conflict: Option<Conflict>, primary: bool) -> Index {
    Index {
        name: String::new(),
        cols: cols
            .into_iter()
            .map(|(c, coll)| IndexCol {
                kind: IdxColKind::Col(c),
                coll,
                coll_name: None,
                desc: false,
                aff: Some(columns[c].affinity),
            })
            .collect(),
        unique: true,
        auto: true,
        primary,
        conflict,
        where_ast: None,
        where_: None,
        entries: Default::default(),
        seq: 0,
        sql: None,
    }
}

impl Engine {
    // ---- CREATE / DROP TABLE ----

    pub(crate) fn create_table(&mut self, ct: CreateTable, sql: &str) -> Result<()> {
        if self.db.table(&ct.name).is_some() || self.db.view(&ct.name).is_some() {
            if ct.if_not_exists {
                return Ok(());
            }
            return err!("table {} already exists", ct.name);
        }
        if self.db.find_index(&ct.name).is_some() {
            return err!("there is already an index named {}", ct.name);
        }
        if reserved(&ct.name) {
            return err!("object name reserved for internal use: {}", ct.name);
        }
        if ct.columns.is_empty() {
            return err!("near \")\": syntax error");
        }
        let mut columns: Vec<Column> = Vec::new();
        for cd in &ct.columns {
            if columns.iter().any(|c| c.name.eq_ignore_ascii_case(&cd.name)) {
                return err!("duplicate column name: {}", cd.name);
            }
            columns.push(build_column(cd)?);
        }

        // Keys in declaration order.
        let mut has_pk = false;
        let mut rowid_alias = None;
        let mut rowid_conflict = None;
        let mut autoincrement = false;
        let mut indexes: Vec<Index> = Vec::new();
        let mut checks = Vec::new();
        let add_key = |cols: Vec<(usize, Option<Collation>)>,
                       conflict: Option<Conflict>,
                       primary: bool,
                       indexes: &mut Vec<Index>| {
            let cols: Vec<(usize, Collation)> =
                cols.iter().map(|(c, coll)| (*c, coll.unwrap_or_else(|| columns[*c].coll()))).collect();
            // An identical existing key makes this one redundant.
            if let Some(u) = indexes.iter_mut().find(|u| {
                u.cols.len() == cols.len()
                    && u.cols.iter().zip(&cols).all(|(ic, (c, coll))| matches!(ic.kind, IdxColKind::Col(x) if x == *c) && ic.coll == *coll)
            }) {
                u.primary |= primary;
                if u.conflict.is_none() {
                    u.conflict = conflict;
                }
                return;
            }
            indexes.push(plain_index(cols, &columns, conflict, primary));
        };
        for (i, cd) in ct.columns.iter().enumerate() {
            for c in &cd.constraints {
                match c {
                    ColumnConstraint::PrimaryKey { desc, conflict, autoincrement: ai } => {
                        if has_pk {
                            return err!("table \"{}\" has more than one primary key", ct.name);
                        }
                        has_pk = true;
                        if columns[i].decl_type.eq_ignore_ascii_case("INTEGER") && !desc {
                            rowid_alias = Some(i);
                            rowid_conflict = *conflict;
                            autoincrement = *ai;
                        } else if *ai {
                            return err!("AUTOINCREMENT is only allowed on an INTEGER PRIMARY KEY");
                        } else {
                            add_key(vec![(i, None)], *conflict, true, &mut indexes);
                        }
                    }
                    ColumnConstraint::Unique { conflict } => add_key(vec![(i, None)], *conflict, false, &mut indexes),
                    ColumnConstraint::Check(e) => checks.push(Check { expr: e.clone(), col: Some(cd.name.clone()) }),
                    _ => {}
                }
            }
        }
        let find_col = |c: &IndexedCol| -> Result<(usize, Option<Collation>)> {
            let coll = match &c.collate {
                Some(n) => match Collation::from_name(n) {
                    Some(x) => Some(x),
                    None => return err!("no such collation sequence: {}", n),
                },
                None => None,
            };
            match &c.expr {
                Expr::Column { table: None, name, .. } => match columns.iter().position(|c| c.name.eq_ignore_ascii_case(name)) {
                    Some(i) => Ok((i, coll)),
                    None => err!("no such column: {}", name),
                },
                _ => err!("expressions prohibited in PRIMARY KEY and UNIQUE constraints"),
            }
        };
        for tc in &ct.constraints {
            match tc {
                TableConstraint::PrimaryKey { cols, conflict, autoincrement: ai } => {
                    if has_pk {
                        return err!("table \"{}\" has more than one primary key", ct.name);
                    }
                    has_pk = true;
                    let idx = cols.iter().map(find_col).collect::<Result<Vec<_>>>()?;
                    if idx.len() == 1 && columns[idx[0].0].decl_type.eq_ignore_ascii_case("INTEGER") && !cols[0].desc {
                        rowid_alias = Some(idx[0].0);
                        rowid_conflict = *conflict;
                        autoincrement = *ai;
                    } else if *ai {
                        return err!("AUTOINCREMENT is only allowed on an INTEGER PRIMARY KEY");
                    } else {
                        add_key(idx, *conflict, true, &mut indexes);
                    }
                }
                TableConstraint::Unique { cols, conflict } => {
                    let idx = cols.iter().map(find_col).collect::<Result<Vec<_>>>()?;
                    add_key(idx, *conflict, false, &mut indexes);
                }
                TableConstraint::Check(e) => checks.push(Check { expr: e.clone(), col: None }),
                TableConstraint::ForeignKey { .. } => {}
            }
        }
        let schema_seq = self.db.alloc_seq();
        for (n, ix) in indexes.iter_mut().enumerate() {
            ix.name = format!("sqlite_autoindex_{}_{}", ct.name, n + 1);
            ix.seq = self.db.alloc_seq();
        }
        if autoincrement && self.db.sequence_seq.is_none() {
            self.db.sequence_seq = Some(self.db.alloc_seq());
        }
        let table = Table {
            name: ct.name.clone(),
            columns,
            rows: Default::default(),
            rowid_alias,
            rowid_conflict,
            autoincrement,
            seq: 0,
            indexes,
            checks,
            sql: crate::sqltext::normalize_create(sql),
            schema_seq,
            version: 0,
        };
        // Validate CHECK expressions.
        let scope = Scope::with_sources(vec![table_source(&table, None, 0)]);
        for c in &table.checks {
            bind(&c.expr, &scope)?;
        }
        self.db.tables.insert(key(&ct.name), Rc::new(table));
        Ok(())
    }

    pub(crate) fn drop_table(&mut self, name: &str, if_exists: bool) -> Result<()> {
        if self.db.table(name).is_none() {
            if self.db.view(name).is_some() {
                return err!("use DROP VIEW to delete view {}", name);
            }
            if is_schema_table(name) || crate::db::is_sequence_table(name) {
                return err!("table {} may not be dropped", name);
            }
        }
        if self.db.tables.remove(&key(name)).is_none() && !if_exists {
            return err!("no such table: {}", name);
        }
        Ok(())
    }

    // ---- CREATE / DROP INDEX ----

    pub(crate) fn create_index(&mut self, ci: CreateIndex, sql: &str) -> Result<()> {
        if self.db.find_index(&ci.name).is_some() {
            if ci.if_not_exists {
                return Ok(());
            }
            return err!("index {} already exists", ci.name);
        }
        if self.db.table(&ci.name).is_some() || self.db.view(&ci.name).is_some() {
            return err!("there is already a table named {}", ci.name);
        }
        if reserved(&ci.name) {
            return err!("object name reserved for internal use: {}", ci.name);
        }
        let tkey = key(&ci.table);
        let Some(t) = self.db.tables.get(&tkey) else {
            if self.db.view(&ci.table).is_some() {
                return err!("views may not be indexed");
            }
            if is_schema_table(&ci.table) {
                return err!("table {} may not be indexed", ci.table);
            }
            return err!("no such table: main.{}", ci.table);
        };
        let mut cols = Vec::new();
        for c in &ci.cols {
            let (kind, aff, dcoll) = index_col(t, &c.expr)?;
            let coll = match &c.collate {
                Some(n) => match Collation::from_name(n) {
                    Some(x) => x,
                    None => return err!("no such collation sequence: {}", n),
                },
                None => dcoll,
            };
            cols.push(IndexCol { kind, coll, coll_name: c.collate.clone(), desc: c.desc, aff });
        }
        let where_ = match &ci.where_ {
            Some(w) => {
                if contains_subquery(w) {
                    return err!("subqueries prohibited in partial index WHERE clauses");
                }
                Some(bind(w, &Scope::with_sources(vec![table_source(t, None, 0)]))?)
            }
            None => None,
        };
        let seq = self.db.alloc_seq();
        let ix = Index {
            name: ci.name.clone(),
            cols,
            unique: ci.unique,
            auto: false,
            primary: false,
            conflict: None,
            where_ast: ci.where_.clone(),
            where_,
            entries: Default::default(),
            seq,
            sql: Some(crate::sqltext::normalize_create(sql)),
        };
        let t = self.db.table_mut(&tkey).unwrap();
        t.indexes.push(ix);
        let pos = t.indexes.len() - 1;
        t.fill_index(pos);
        if ci.unique {
            check_unique(t, pos)?;
        }
        Ok(())
    }

    pub(crate) fn drop_index(&mut self, name: &str, if_exists: bool) -> Result<()> {
        match self.db.find_index(name) {
            None => {
                if if_exists {
                    Ok(())
                } else {
                    err!("no such index: {}", name)
                }
            }
            Some((tk, pos)) => {
                let t = self.db.table_mut(&tk).unwrap();
                if t.indexes[pos].auto {
                    return err!("index associated with UNIQUE or PRIMARY KEY constraint cannot be dropped");
                }
                t.indexes.remove(pos);
                Ok(())
            }
        }
    }

    // ---- CREATE / DROP VIEW ----

    pub(crate) fn create_view(&mut self, cv: CreateView, sql: &str) -> Result<()> {
        if self.db.view(&cv.name).is_some() {
            if cv.if_not_exists {
                return Ok(());
            }
            return err!("view {} already exists", cv.name);
        }
        if self.db.table(&cv.name).is_some() {
            if cv.if_not_exists {
                return Ok(());
            }
            return err!("table {} already exists", cv.name);
        }
        if self.db.find_index(&cv.name).is_some() {
            return err!("there is already an index named {}", cv.name);
        }
        if reserved(&cv.name) {
            return err!("object name reserved for internal use: {}", cv.name);
        }
        let schema_seq = self.db.alloc_seq();
        let v = View { name: cv.name.clone(), cols: cv.cols, select: cv.select, sql: crate::sqltext::normalize_create(sql), schema_seq };
        self.db.views.insert(key(&cv.name), Rc::new(v));
        Ok(())
    }

    pub(crate) fn drop_view(&mut self, name: &str, if_exists: bool) -> Result<()> {
        if self.db.view(name).is_none() && self.db.table(name).is_some() {
            return err!("use DROP TABLE to delete table {}", name);
        }
        if self.db.views.remove(&key(name)).is_none() && !if_exists {
            return err!("no such view: {}", name);
        }
        Ok(())
    }

    // ---- ALTER TABLE ----

    pub(crate) fn alter(&mut self, name: &str, action: AlterAction, sql: &str) -> Result<()> {
        let tkey = key(name);
        if !self.db.tables.contains_key(&tkey) {
            if self.db.view(name).is_some() {
                return match action {
                    AlterAction::AddColumn(_) => err!("Cannot add a column to a view"),
                    _ => err!("view {} may not be altered", name),
                };
            }
            if is_schema_table(name) {
                return err!("table {} may not be altered", name);
            }
            return err!("no such table: {}", name);
        }
        match action {
            AlterAction::RenameTable(new) => self.rename_table(&tkey, &new)?,
            AlterAction::RenameColumn(old, new) => self.rename_column(&tkey, &old, &new)?,
            AlterAction::AddColumn(cd) => {
                self.add_column(&tkey, &cd)?;
                if let Some(text) = crate::sqltext::added_column_text(sql) {
                    let t = self.db.table_mut(&tkey).unwrap();
                    t.sql = crate::sqltext::add_column(&t.sql, &text);
                }
                return Ok(());
            }
            AlterAction::DropColumn(col) => self.drop_column(&tkey, &col)?,
        }
        // Like SQLite, renames and drops require every view to still work.
        for v in self.db.views.values() {
            let scope = Scope { db: Some(&self.db), ..Default::default() };
            if let Err(e) = crate::query::plan_select(&v.select, &scope) {
                return err!("error in view {}: {}", v.name, e);
            }
        }
        Ok(())
    }

    fn rename_table(&mut self, tkey: &str, new: &str) -> Result<()> {
        if self.db.table(new).is_some() || self.db.view(new).is_some() || self.db.find_index(new).is_some() {
            return err!("there is already another table or index with this name: {}", new);
        }
        if reserved(new) {
            return err!("object name reserved for internal use: {}", new);
        }
        let rc = self.db.tables.remove(tkey).unwrap();
        let mut t = Rc::unwrap_or_clone(rc);
        let old = std::mem::replace(&mut t.name, new.to_string());
        t.sql = crate::sqltext::rename_table(&t.sql, &old, new, true);
        let prefix = format!("sqlite_autoindex_{}_", old);
        for ix in &mut t.indexes {
            if ix.auto && ix.name.starts_with(&prefix) {
                ix.name = format!("sqlite_autoindex_{}_{}", new, &ix.name[prefix.len()..]);
            }
            for c in &mut ix.cols {
                if let IdxColKind::Expr { ast, .. } = &mut c.kind {
                    rename_qualifier(ast, &old, new);
                }
            }
            if let Some(w) = &mut ix.where_ast {
                rename_qualifier(w, &old, new);
            }
            if let Some(s) = &mut ix.sql {
                *s = crate::sqltext::rename_table(s, &old, new, false);
            }
        }
        for c in &mut t.checks {
            rename_qualifier(&mut c.expr, &old, new);
        }
        self.db.tables.insert(key(new), Rc::new(t));
        for v in self.db.views.values_mut() {
            let v = Rc::make_mut(v);
            rename_table_in_select(&mut v.select, &old, new);
            v.sql = crate::sqltext::rename_table(&v.sql, &old, new, false);
        }
        Ok(())
    }

    /// References to column `col` of table `tkey` (renamed to `new_name`
    /// if given) in the table's own expressions and in views.
    fn col_refs(&mut self, tkey: &str, col: &str, new_name: Option<&str>) -> (usize, Vec<String>) {
        let t = self.db.tables.get(tkey).unwrap().clone();
        let target_cols: Vec<String> = t.columns.iter().map(|c| c.name.clone()).collect();
        let mut views = std::mem::take(&mut self.db.views);
        let mut in_views = Vec::new();
        let mut table = (*t).clone();
        let own;
        {
            let mut r = ColRefs {
                db: &self.db,
                target: tkey.to_string(),
                target_cols,
                col: col.to_string(),
                new_name: new_name.map(|s| s.to_string()),
                hits: 0,
            };
            for c in &mut table.checks {
                r.table_expr(&mut c.expr, &t.name);
            }
            for ix in &mut table.indexes {
                for c in &mut ix.cols {
                    if let IdxColKind::Expr { ast, .. } = &mut c.kind {
                        r.table_expr(ast, &t.name);
                    }
                }
                if let Some(w) = &mut ix.where_ast {
                    r.table_expr(w, &t.name);
                }
            }
            own = r.hits;
            for (k, v) in views.iter_mut() {
                let before = r.hits;
                let mut sel = v.select.clone();
                r.view(&mut sel);
                if r.hits > before {
                    in_views.push(k.clone());
                    if new_name.is_some() {
                        Rc::make_mut(v).select = sel;
                    }
                }
            }
        }
        self.db.views = views;
        if new_name.is_some() {
            self.db.tables.insert(tkey.to_string(), Rc::new(table));
        }
        (own, in_views)
    }

    fn rename_column(&mut self, tkey: &str, old: &str, new: &str) -> Result<()> {
        let t = self.db.tables.get(tkey).unwrap();
        let Some(ci) = t.column_index(old) else {
            return err!("no such column: \"{}\"", old);
        };
        if t.column_index(new).is_some_and(|j| j != ci) {
            return err!("duplicate column name: {}", new);
        }
        let old_name = t.columns[ci].name.clone();
        let (_, in_views) = self.col_refs(tkey, &old_name, Some(new));
        for vk in in_views {
            if let Some(v) = self.db.views.get_mut(&vk) {
                let v = Rc::make_mut(v);
                v.sql = crate::sqltext::rename_column_refs(&v.sql, &old_name, new);
            }
        }
        let t = self.db.table_mut(tkey).unwrap();
        t.columns[ci].name = new.to_string();
        t.sql = crate::sqltext::rename_column_in_table(&t.sql, &old_name, new);
        for ix in &mut t.indexes {
            if let Some(s) = &mut ix.sql {
                *s = crate::sqltext::rename_column_refs(s, &old_name, new);
            }
        }
        for c in &mut t.checks {
            if c.col.as_deref().is_some_and(|n| n.eq_ignore_ascii_case(&old_name)) {
                c.col = Some(new.to_string());
            }
        }
        rebind_indexes(t)
    }

    fn add_column(&mut self, tkey: &str, cd: &ColumnDef) -> Result<()> {
        let t = self.db.tables.get(tkey).unwrap();
        if t.column_index(&cd.name).is_some() {
            return err!("duplicate column name: {}", cd.name);
        }
        let col = build_column(cd)?;
        let mut checks = Vec::new();
        for c in &cd.constraints {
            match c {
                ColumnConstraint::PrimaryKey { .. } => return err!("Cannot add a PRIMARY KEY column"),
                ColumnConstraint::Unique { .. } => return err!("Cannot add a UNIQUE column"),
                ColumnConstraint::Check(e) => checks.push(Check { expr: e.clone(), col: Some(cd.name.clone()) }),
                _ => {}
            }
        }
        let default = match &col.default {
            Some(d) if !is_simple_default(d) && !t.rows.is_empty() => {
                return err!("Cannot add a column with non-constant default");
            }
            Some(d) => {
                let b = match bind(d, &Scope::default()) {
                    Ok(b) => b,
                    Err(_) => return err!("Cannot add a column with non-constant default"),
                };
                eval(&b, &[], &Cx::new(&crate::db::Database::default()))?.apply_affinity(col.affinity)
            }
            None => Value::Null,
        };
        if col.not_null.is_some() && default.is_null() && !t.rows.is_empty() {
            return err!("Cannot add a NOT NULL column with default value NULL");
        }
        let t = self.db.table_mut(tkey).unwrap();
        t.columns.push(col);
        t.checks.extend(checks);
        t.version += 1;
        for row in t.rows.values_mut() {
            row.push(default.clone());
        }
        // Validate CHECK expressions against the new layout.
        let scope = Scope::with_sources(vec![table_source(t, None, 0)]);
        for c in &t.checks {
            bind(&c.expr, &scope)?;
        }
        Ok(())
    }

    fn drop_column(&mut self, tkey: &str, col: &str) -> Result<()> {
        let t = self.db.tables.get(tkey).unwrap();
        let Some(ci) = t.column_index(col) else {
            return err!("no such column: \"{}\"", col);
        };
        let cname = t.columns[ci].name.clone();
        if t.rowid_alias == Some(ci) {
            return err!("cannot drop PRIMARY KEY column: \"{}\"", cname);
        }
        for ix in &t.indexes {
            let uses = ix.cols.iter().any(|c| matches!(c.kind, IdxColKind::Col(j) if j == ci));
            if ix.auto && uses {
                if ix.primary {
                    return err!("cannot drop PRIMARY KEY column: \"{}\"", cname);
                }
                return err!("cannot drop UNIQUE column: \"{}\"", cname);
            }
            if uses {
                return err!("error in index {} after drop column: no such column: {}", ix.name, cname);
            }
        }
        if t.columns.len() == 1 {
            return err!("cannot drop column \"{}\": no other columns exist", cname);
        }
        // CHECK constraints declared on the column go with it.
        let t = self.db.table_mut(tkey).unwrap();
        t.checks.retain(|c| !c.col.as_deref().is_some_and(|n| n.eq_ignore_ascii_case(&cname)));
        let (own, views) = self.col_refs(tkey, &cname, None);
        if own > 0 {
            return err!("error in table {} after drop column: no such column: {}", name_of(&self.db, tkey), cname);
        }
        if let Some(v) = views.first() {
            return err!("error in view {} after drop column: no such column: {}", v, cname);
        }
        let t = self.db.table_mut(tkey).unwrap();
        t.columns.remove(ci);
        t.sql = crate::sqltext::drop_column(&t.sql, &cname);
        t.version += 1;
        for row in t.rows.values_mut() {
            row.remove(ci);
        }
        if let Some(a) = t.rowid_alias {
            if a > ci {
                t.rowid_alias = Some(a - 1);
            }
        }
        for ix in &mut t.indexes {
            for c in &mut ix.cols {
                if let IdxColKind::Col(j) = &mut c.kind {
                    if *j > ci {
                        *j -= 1;
                    }
                }
            }
        }
        rebind_indexes(t)?;
        for i in 0..t.indexes.len() {
            t.fill_index(i);
        }
        Ok(())
    }
}

/// A default value SQLite can evaluate without running code: a literal,
/// possibly signed, cast or collated.
fn is_simple_default(e: &Expr) -> bool {
    match e {
        Expr::Lit(_) => true,
        Expr::Unary(UnOp::Neg | UnOp::Pos, x) | Expr::Cast(x, _) | Expr::Collate(x, _) => is_simple_default(x),
        _ => false,
    }
}

fn name_of(db: &crate::db::Database, tkey: &str) -> String {
    db.tables.get(tkey).map(|t| t.name.clone()).unwrap_or_default()
}

/// Kind, affinity and default collation of an index column expression.
fn index_col(t: &Table, e: &Expr) -> Result<(IdxColKind, Option<crate::value::Affinity>, Collation)> {
    if let Expr::Column { table, name, .. } = e {
        if table.as_ref().is_none_or(|q| q.eq_ignore_ascii_case(&t.name)) {
            if let Some(i) = t.column_index(name) {
                return Ok((IdxColKind::Col(i), Some(t.columns[i].affinity), t.columns[i].coll()));
            }
            if !crate::db::is_rowid_name(name) {
                return err!("no such column: {}", name);
            }
        }
    }
    if contains_subquery(e) {
        return err!("subqueries prohibited in index expressions");
    }
    let b = bind(e, &Scope::with_sources(vec![table_source(t, None, 0)]))?;
    let aff = expr_affinity(&b);
    let coll = expr_collation(&b).unwrap_or(Collation::Binary);
    Ok((IdxColKind::Expr { ast: e.clone(), bound: b }, aff, coll))
}

/// Re-bind expression columns and predicates of every index after a
/// change of the table's columns.
fn rebind_indexes(t: &mut Table) -> Result<()> {
    let scope_t = t.clone();
    let scope = Scope::with_sources(vec![table_source(&scope_t, None, 0)]);
    for ix in &mut t.indexes {
        for c in &mut ix.cols {
            if let IdxColKind::Expr { ast, bound } = &mut c.kind {
                *bound = bind(ast, &scope)?;
            }
        }
        if let Some(w) = &ix.where_ast {
            ix.where_ = Some(bind(w, &scope)?);
        }
    }
    Ok(())
}

/// Error if index `pos` has two entries with equal non-NULL keys.
fn check_unique(t: &Table, pos: usize) -> Result<()> {
    let ix = &t.indexes[pos];
    let n = ix.cols.len();
    let mut prev: Option<&[Value]> = None;
    for k in &ix.entries {
        let vals = &k.0[..n];
        if let Some(p) = prev {
            if !vals.iter().any(|v| v.is_null())
                && p.iter().zip(vals).all(|(a, b)| crate::value::compare(a, b) == std::cmp::Ordering::Equal)
            {
                return match ix.plain_cols() {
                    Some(cols) => err!(
                        "UNIQUE constraint failed: {}",
                        cols.iter().map(|&c| format!("{}.{}", t.name, t.columns[c].name)).collect::<Vec<_>>().join(", ")
                    ),
                    None => err!("UNIQUE constraint failed: index '{}'", ix.name),
                };
            }
        }
        prev = Some(vals);
    }
    Ok(())
}
