// Schema statements: CREATE/DROP TABLE, INDEX and VIEW, ALTER TABLE.

use std::collections::BTreeSet;

use crate::agg;
use crate::ast::*;
use crate::db::{is_schema_table, key, Database, IdxCol, Index, Table, View, SEQ_TABLE};
use crate::eval::{affinity, bind, check_coll, expr_coll};
use crate::exec::build_table;
use crate::lexer::{tokenize, Tok, Token};
use crate::parser::parse_statement;
use crate::query::{select_reads_table, table_scope};
use crate::value::{apply_affinity, Coll};

pub fn execute(db: &mut Database, stmt: &Stmt) -> Result<(), String> {
    match stmt {
        Stmt::CreateTable(ct) => create_table(db, ct),
        Stmt::DropTable { name, if_exists } => drop_table(db, name, *if_exists),
        Stmt::CreateIndex(ci) => create_index(db, ci),
        Stmt::DropIndex { name, if_exists } => drop_index(db, name, *if_exists),
        Stmt::CreateView(cv) => create_view(db, cv),
        Stmt::DropView { name, if_exists } => drop_view(db, name, *if_exists),
        Stmt::AlterTable { table, action } => alter_table(db, table, action),
        _ => unreachable!("not a schema statement"),
    }
}

fn check_reserved(name: &str) -> Result<(), String> {
    if name.len() >= 7 && name[..7].eq_ignore_ascii_case("sqlite_") {
        return Err(format!("object name reserved for internal use: {}", name));
    }
    Ok(())
}

// ---------- tables ----------

fn create_table(db: &mut Database, ct: &CreateTable) -> Result<(), String> {
    let k = key(&ct.name);
    if db.tables.contains_key(&k) || db.views.contains_key(&k) {
        if ct.if_not_exists {
            return Ok(());
        }
        let kind = if db.views.contains_key(&k) { "view" } else { "table" };
        return Err(format!("{} {} already exists", kind, ct.name));
    }
    if db.find_index(&ct.name).is_some() {
        return Err(format!("there is already an index named {}", ct.name));
    }
    check_reserved(&ct.name)?;
    let mut t = build_table(db, ct)?;
    t.order = db.next_order();
    for idx in &mut t.indexes {
        idx.order = db.next_order();
    }
    let autoinc = t.autoinc;
    db.put_table(t);
    // the first AUTOINCREMENT table brings sqlite_sequence
    if autoinc && !db.tables.contains_key(SEQ_TABLE) {
        let Stmt::CreateTable(ct) = parse_statement("CREATE TABLE sqlite_sequence(name,seq)")? else { unreachable!() };
        let mut st = build_table(db, &ct)?;
        st.order = db.next_order();
        db.put_table(st);
    }
    Ok(())
}

fn drop_table(db: &mut Database, name: &str, if_exists: bool) -> Result<(), String> {
    let k = key(name);
    if is_schema_table(name) {
        return Err("table sqlite_master may not be dropped".to_string());
    }
    if db.views.contains_key(&k) {
        return Err(format!("use DROP VIEW to delete view {}", name));
    }
    if k == SEQ_TABLE {
        return Err("table sqlite_sequence may not be dropped".to_string());
    }
    let Some(t) = db.tables.get(&k) else {
        if if_exists {
            return Ok(());
        }
        return Err(format!("no such table: {}", name));
    };
    let tname = t.name.clone();
    db.remove_table(&k);
    db.drop_seq(&tname);
    Ok(())
}

// ---------- indexes ----------

fn has_subquery(e: &Expr) -> bool {
    let mut found = false;
    let _ = agg::map_expr(e, &mut |x| {
        if matches!(x, Expr::Subquery(_) | Expr::Exists(_) | Expr::InSelect { .. }) {
            found = true;
        }
        Ok(None)
    });
    found
}

/// Builds an (empty) index for table `t` from its definition.
pub fn make_index(db: &Database, t: &Table, ci: &CreateIndex) -> Result<Index, String> {
    let scope = table_scope(t, &t.name);
    let mut cols = Vec::new();
    let mut colls = Vec::new();
    let mut affs = Vec::new();
    let mut desc = Vec::new();
    for ic in &ci.columns {
        let plain = match &ic.expr {
            Expr::Column { table, name, .. } if table.as_deref().is_none_or(|q| q.eq_ignore_ascii_case(&t.name)) => {
                t.column_index(name)
            }
            _ => None,
        };
        let (col, coll, aff) = match plain {
            Some(c) => (IdxCol::Col(c), t.columns[c].coll.unwrap_or(Coll::Binary), t.columns[c].affinity),
            None => {
                if let Expr::Column { table: None, name, dq: false } = &ic.expr {
                    return Err(format!("no such column: {}", name));
                }
                if has_subquery(&ic.expr) {
                    return Err("subqueries prohibited in index expressions".to_string());
                }
                let b = bind(&ic.expr, &scope, db)?;
                let coll = expr_coll(&b).unwrap_or(Coll::Binary);
                let aff = affinity(&b);
                (IdxCol::Expr(b), coll, aff)
            }
        };
        let coll = match &ic.collate {
            Some(c) => Coll::from_name(c)?,
            None => check_coll(coll)?,
        };
        cols.push(col);
        colls.push(coll);
        affs.push(aff);
        desc.push(ic.desc);
    }
    let pred = match &ci.where_ {
        Some(w) => {
            if has_subquery(w) {
                return Err("subqueries prohibited in partial index WHERE clauses".to_string());
            }
            Some(bind(w, &scope, db)?)
        }
        None => None,
    };
    Ok(Index {
        name: ci.name.clone(),
        auto: false,
        def: Some(ci.clone()),
        order: 0,
        cols,
        colls,
        desc,
        affs,
        pred,
        unique: ci.unique,
        conflict: None,
        entries: BTreeSet::new(),
        root: 0,
    })
}

fn create_index(db: &mut Database, ci: &CreateIndex) -> Result<(), String> {
    check_reserved(&ci.name)?;
    if is_schema_table(&ci.table) {
        return Err("table sqlite_master may not be indexed".to_string());
    }
    let tk = key(&ci.table);
    if db.views.contains_key(&tk) {
        return Err("views may not be indexed".to_string());
    }
    let Some(t) = db.tables.get(&tk) else {
        return Err(format!("no such table: main.{}", ci.table));
    };
    if db.find_index(&ci.name).is_some() {
        if ci.if_not_exists {
            return Ok(());
        }
        return Err(format!("index {} already exists", ci.name));
    }
    let nk = key(&ci.name);
    if db.tables.contains_key(&nk) || db.views.contains_key(&nk) {
        return Err(format!("there is already a table named {}", ci.name));
    }
    let mut idx = make_index(db, t, ci)?;
    t.build_index(&mut idx)?;
    idx.order = db.next_order();
    db.add_index(&tk, idx);
    Ok(())
}

fn drop_index(db: &mut Database, name: &str, if_exists: bool) -> Result<(), String> {
    let Some((tk, pos)) = db.find_index(name) else {
        if if_exists {
            return Ok(());
        }
        return Err(format!("no such index: {}", name));
    };
    if db.tables[&tk].indexes[pos].auto {
        return Err("index associated with UNIQUE or PRIMARY KEY constraint cannot be dropped".to_string());
    }
    db.drop_index(&tk, pos);
    Ok(())
}

// ---------- views ----------

fn create_view(db: &mut Database, cv: &CreateView) -> Result<(), String> {
    let k = key(&cv.name);
    if db.tables.contains_key(&k) || db.views.contains_key(&k) {
        if cv.if_not_exists {
            return Ok(());
        }
        let kind = if db.views.contains_key(&k) { "view" } else { "table" };
        return Err(format!("{} {} already exists", kind, cv.name));
    }
    if db.find_index(&cv.name).is_some() {
        return Err(format!("there is already an index named {}", cv.name));
    }
    check_reserved(&cv.name)?;
    let order = db.next_order();
    db.put_view(View {
        name: cv.name.clone(),
        columns: cv.columns.clone(),
        select: cv.select.clone(),
        sql: cv.sql.clone(),
        order,
        temp: cv.temp,
    });
    Ok(())
}

fn drop_view(db: &mut Database, name: &str, if_exists: bool) -> Result<(), String> {
    let k = key(name);
    if db.tables.contains_key(&k) {
        return Err(format!("use DROP TABLE to delete table {}", name));
    }
    if !db.views.contains_key(&k) {
        if if_exists {
            return Ok(());
        }
        return Err(format!("no such view: {}", name));
    }
    db.remove_view(&k);
    Ok(())
}

// ---------- ALTER TABLE ----------

fn alter_table(db: &mut Database, table: &str, action: &AlterAction) -> Result<(), String> {
    let tk = key(table);
    if is_schema_table(table) {
        return Err("table sqlite_master may not be altered".to_string());
    }
    if tk == SEQ_TABLE {
        return Err("table sqlite_sequence may not be altered".to_string());
    }
    if db.views.contains_key(&tk) {
        return Err(match action {
            AlterAction::AddColumn(..) => "Cannot add a column to a view".to_string(),
            AlterAction::DropColumn(_) => "cannot drop column from a view".to_string(),
            _ => format!("view {} may not be altered", table),
        });
    }
    let old = db.table(table)?.clone();
    let explicit: Vec<&Index> = old.indexes.iter().filter(|i| !i.auto).collect();
    match action {
        AlterAction::RenameTable(new) => {
            let nk = key(new);
            if db.tables.contains_key(&nk) || db.views.contains_key(&nk) || db.find_index(new).is_some() {
                return Err(format!("there is already another table or index with this name: {}", new));
            }
            check_reserved(new)?;
            let sql = rename_table_in_create(&old.sql, &old.name, new);
            let idx_sql: Vec<(String, u64)> =
                explicit.iter().map(|i| (rename_table_in_index(&index_sql(i), &old.name, new), i.order)).collect();
            let views = rewrite_views(db, &old.name, |sql, _| rename_table_in_view(sql, &old.name, new))?;
            let t = rebuild_table(db, &old, &sql, &idx_sql, |r| r.clone())?;
            db.remove_table(&tk);
            db.put_table(t);
            for v in views {
                db.put_view(v);
            }
            db.rename_seq(&old.name, new)?;
        }
        AlterAction::RenameColumn(from, to) => {
            let Some(c) = old.column_index(from) else {
                return Err(format!("no such column: \"{}\"", from));
            };
            if old.column_index(to).is_some() {
                return Err(format!("duplicate column name: {}", to));
            }
            let from = old.columns[c].name.clone();
            let sql = rename_column_in_create(&old.sql, &from, to);
            let idx_sql: Vec<(String, u64)> =
                explicit.iter().map(|i| (rename_column_in_index(&index_sql(i), &old.name, &from, to), i.order)).collect();
            let views = rewrite_views(db, &old.name, |sql, aliases| rename_column_in_view(sql, aliases, &from, to))?;
            let t = rebuild_table(db, &old, &sql, &idx_sql, |r| r.clone())?;
            db.remove_table(&tk);
            db.put_table(t);
            for v in views {
                db.put_view(v);
            }
        }
        AlterAction::AddColumn(def, text) => {
            if old.column_index(&def.name).is_some() {
                return Err(format!("duplicate column name: {}", def.name));
            }
            let mut default = None;
            for c in &def.constraints {
                match c {
                    ColumnConstraint::PrimaryKey { .. } => return Err("Cannot add a PRIMARY KEY column".to_string()),
                    ColumnConstraint::Unique(_) => return Err("Cannot add a UNIQUE column".to_string()),
                    ColumnConstraint::Default(e) => default = Some(e.clone()),
                    ColumnConstraint::Generated { stored: true, .. } => {
                        return Err("cannot add a STORED column".to_string())
                    }
                    _ => {}
                }
            }
            let not_null = def.constraints.iter().any(|c| matches!(c, ColumnConstraint::NotNull(_)));
            // the default must be a literal (sqlite3ValueFromExpr)
            fn literal(e: &Expr) -> bool {
                match e {
                    Expr::Literal(_) => true,
                    Expr::Unary(UnOp::Neg | UnOp::Pos, x) => literal(x),
                    Expr::Cast(x, _) => literal(x),
                    Expr::Column { table: None, name, dq: true } => !name.to_ascii_uppercase().starts_with("CURRENT_"),
                    _ => false,
                }
            }
            let dv = match &default {
                Some(e) => {
                    let non_const = || "Cannot add a column with non-constant default".to_string();
                    if !literal(e) {
                        return Err(non_const());
                    }
                    let b = bind(e, &crate::eval::Scope::empty(), db).map_err(|_| non_const())?;
                    crate::eval::eval(&b, &[], &crate::eval::Env::new(db))?
                }
                None => crate::value::Value::Null,
            };
            if not_null && dv.is_null() && !old.rows.is_empty() {
                return Err("Cannot add a NOT NULL column with default value NULL".to_string());
            }
            let sql = add_column_to_create(&old.sql, text);
            let idx_sql: Vec<(String, u64)> = explicit.iter().map(|i| (index_sql(i), i.order)).collect();
            let aff = crate::value::Affinity::from_type(def.type_name.as_deref());
            let dv = apply_affinity(dv, aff);
            let t = rebuild_table(db, &old, &sql, &idx_sql, |r| {
                let mut r = r.clone();
                r.push(dv.clone());
                r
            })?;
            db.remove_table(&tk);
            db.put_table(t);
        }
        AlterAction::DropColumn(name) => {
            let Some(c) = old.column_index(name) else {
                return Err(format!("no such column: \"{}\"", name));
            };
            let name = old.columns[c].name.clone();
            if old.columns.len() == 1 {
                return Err(format!("cannot drop column \"{}\": no other columns exist", name));
            }
            if old.ipk == Some(c) {
                return Err(format!("cannot drop PRIMARY KEY column: \"{}\"", name));
            }
            for idx in old.indexes.iter().filter(|i| i.auto) {
                if idx.cols.iter().any(|x| matches!(x, IdxCol::Col(i) if *i == c)) {
                    let pk = idx_is_pk(&old, idx);
                    return Err(format!(
                        "cannot drop {} column: \"{}\"",
                        if pk { "PRIMARY KEY" } else { "UNIQUE" },
                        name
                    ));
                }
            }
            let sql = drop_column_from_create(&old.sql, &name)
                .ok_or_else(|| format!("cannot drop column \"{}\"", name))?;
            let idx_sql: Vec<(String, u64)> = explicit.iter().map(|i| (index_sql(i), i.order)).collect();
            for (s, _) in &idx_sql {
                if sql_mentions(s, &name) {
                    let iname = explicit.iter().find(|i| index_sql(i) == *s).map(|i| i.name.clone()).unwrap_or_default();
                    return Err(format!("error in index {} after drop column: no such column: {}", iname, name));
                }
            }
            let t = rebuild_table(db, &old, &sql, &idx_sql, |r| {
                let mut r = r.clone();
                r.remove(c);
                r
            })?;
            db.remove_table(&tk);
            db.put_table(t);
        }
    }
    Ok(())
}

/// Whether an automatic index belongs to the PRIMARY KEY.
fn idx_is_pk(t: &Table, idx: &Index) -> bool {
    let Ok(Stmt::CreateTable(ct)) = parse_statement(&t.sql) else { return false };
    let first = match idx.cols.first() {
        Some(IdxCol::Col(c)) => *c,
        _ => return false,
    };
    let name = &t.columns[first].name;
    ct.columns.iter().any(|cd| {
        cd.name.eq_ignore_ascii_case(name)
            && cd.constraints.iter().any(|c| matches!(c, ColumnConstraint::PrimaryKey { .. }))
    }) || ct.constraints.iter().any(|tc| match tc {
        TableConstraint::PrimaryKey { columns, .. } => columns.iter().any(|ic| {
            matches!(&ic.expr, Expr::Column { name: n, .. } if n.eq_ignore_ascii_case(name))
        }),
        _ => false,
    })
}

fn index_sql(i: &Index) -> String {
    i.def.as_ref().map(|d| d.sql.clone()).unwrap_or_default()
}

/// Rebuilds a table from new CREATE TABLE text, carrying over the rows
/// (converted by `map`) and re-creating the explicit indexes.
fn rebuild_table(
    db: &Database,
    old: &Table,
    sql: &str,
    idx_sql: &[(String, u64)],
    map: impl Fn(&Vec<crate::value::Value>) -> Vec<crate::value::Value>,
) -> Result<Table, String> {
    let Stmt::CreateTable(ct) = parse_statement(sql)? else {
        return Err("internal error: bad table definition".to_string());
    };
    let mut t = build_table(db, &ct)?;
    t.order = old.order;
    t.temp = old.temp;
    let old_auto: Vec<u64> = old.indexes.iter().filter(|i| i.auto).map(|i| i.order).collect();
    for (i, idx) in t.indexes.iter_mut().enumerate() {
        idx.order = old_auto.get(i).copied().unwrap_or(old.order);
    }
    for (rowid, row) in &old.rows {
        t.rows.insert(*rowid, map(row));
    }
    for (s, order) in idx_sql {
        let Stmt::CreateIndex(ci) = parse_statement(s)? else {
            return Err("internal error: bad index definition".to_string());
        };
        let mut idx = make_index(db, &t, &ci).map_err(|e| format!("error in index {}: {}", ci.name, e))?;
        idx.order = *order;
        t.indexes.push(idx);
    }
    let mut indexes = std::mem::take(&mut t.indexes);
    for idx in &mut indexes {
        t.build_index(idx)?;
    }
    t.indexes = indexes;
    Ok(t)
}

/// Rewrites the SQL of every view that reads table `tname`; `f` gets the
/// SQL and the aliases under which the view refers to the table.
fn rewrite_views(db: &Database, tname: &str, f: impl Fn(&str, &[String]) -> String) -> Result<Vec<View>, String> {
    let mut out = Vec::new();
    for v in db.views.values() {
        if !select_reads_table(&v.select, tname) {
            continue;
        }
        let mut aliases = vec![tname.to_string()];
        collect_aliases(&v.select, tname, &mut aliases);
        let sql = f(&v.sql, &aliases);
        let Ok(Stmt::CreateView(cv)) = parse_statement(&sql) else { continue };
        out.push(View { name: v.name.clone(), columns: cv.columns, select: cv.select, sql, order: v.order, temp: v.temp });
    }
    Ok(out)
}

fn collect_aliases(q: &Select, tname: &str, out: &mut Vec<String>) {
    fn item(it: &TableItem, tname: &str, out: &mut Vec<String>) {
        match it {
            TableItem::Table { name, alias } => {
                if name.eq_ignore_ascii_case(tname) {
                    if let Some(a) = alias {
                        out.push(a.clone());
                    }
                }
            }
            TableItem::Subquery { query, .. } => collect_aliases(query, tname, out),
        }
    }
    if let Some(w) = &q.with {
        for c in &w.ctes {
            collect_aliases(&c.select, tname, out);
        }
    }
    for core in &q.cores {
        if let SelectCore::Select(b) = core {
            if let Some(f) = &b.from {
                item(&f.first, tname, out);
                for j in &f.joins {
                    item(&j.item, tname, out);
                }
            }
            let mut exprs: Vec<&Expr> = Vec::new();
            for c in &b.columns {
                if let ResultColumn::Expr(e, _, _) = c {
                    exprs.push(e);
                }
            }
            exprs.extend(b.where_.iter());
            exprs.extend(b.having.iter());
            if let Some(f) = &b.from {
                exprs.extend(f.joins.iter().filter_map(|j| j.on.as_ref()));
            }
            for e in exprs {
                let _ = agg::map_expr(e, &mut |x| {
                    match x {
                        Expr::Subquery(q) | Expr::Exists(q) | Expr::InSelect { query: q, .. } => {
                            collect_aliases(q, tname, out)
                        }
                        _ => {}
                    }
                    Ok(None)
                });
            }
        }
    }
}

// ---------- SQL text rewriting ----------

fn ident(t: &Tok) -> Option<&str> {
    match t {
        Tok::Id(s) | Tok::QId(s) | Tok::DqId(s) => Some(s),
        _ => None,
    }
}

fn is_kw(t: &Tok, kw: &str) -> bool {
    matches!(t, Tok::Id(s) if s.eq_ignore_ascii_case(kw))
}

fn is_op(t: &Tok, op: &str) -> bool {
    matches!(t, Tok::Op(o) if *o == op)
}

pub fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

/// Quotes a name only if it is not a plain identifier.
fn maybe_quote(name: &str) -> String {
    let plain = !name.is_empty()
        && name.bytes().enumerate().all(|(i, c)| c == b'_' || c.is_ascii_alphabetic() || (i > 0 && c.is_ascii_digit()))
        && parse_statement(&format!("SELECT {} FROM x", name)).is_ok();
    if plain {
        name.to_string()
    } else {
        quote_ident(name)
    }
}

fn toks(sql: &str) -> Vec<Token> {
    let mut t = tokenize(sql).unwrap_or_default();
    t.retain(|x| !matches!(x.tok, Tok::Eof));
    t
}

/// Applies (start, end, replacement) edits to `sql`.
fn apply_edits(sql: &str, mut edits: Vec<(usize, usize, String)>) -> String {
    edits.sort_by_key(|e| e.0);
    let mut out = String::with_capacity(sql.len() + 16);
    let mut pos = 0;
    for (s, e, r) in edits {
        if s < pos {
            continue;
        }
        out.push_str(&sql[pos..s]);
        out.push_str(&r);
        pos = e;
    }
    out.push_str(&sql[pos..]);
    out
}

/// Index of the first token that is the `op` operator, from `from`.
fn find_op(ts: &[Token], from: usize, op: &str) -> Option<usize> {
    (from..ts.len()).find(|&i| is_op(&ts[i].tok, op))
}

/// Index of the parenthesis matching the one at `open`.
fn matching_paren(ts: &[Token], open: usize) -> Option<usize> {
    let mut depth = 0;
    for (i, t) in ts.iter().enumerate().skip(open) {
        if is_op(&t.tok, "(") {
            depth += 1;
        } else if is_op(&t.tok, ")") {
            depth -= 1;
            if depth == 0 {
                return Some(i);
            }
        }
    }
    None
}

fn eq_name(t: &Tok, name: &str) -> bool {
    ident(t).is_some_and(|s| s.eq_ignore_ascii_case(name))
}

/// Whether the SQL mentions `name` as an identifier.
fn sql_mentions(sql: &str, name: &str) -> bool {
    let ts = toks(sql);
    let start = find_op(&ts, 0, "(").unwrap_or(0);
    ts[start..].iter().any(|t| eq_name(&t.tok, name))
}

fn rename_table_in_create(sql: &str, old: &str, new: &str) -> String {
    let ts = toks(sql);
    let Some(open) = find_op(&ts, 0, "(") else { return sql.to_string() };
    let mut edits = Vec::new();
    // the name is the last identifier before the parenthesis (after any schema)
    let first = if open >= 3 && is_op(&ts[open - 2].tok, ".") { open - 3 } else { open - 1 };
    edits.push((ts[first].start, ts[open - 1].end, quote_ident(new)));
    for i in open..ts.len() {
        if !eq_name(&ts[i].tok, old) {
            continue;
        }
        let qualifier = i + 1 < ts.len() && is_op(&ts[i + 1].tok, ".");
        let referenced = i > 0 && is_kw(&ts[i - 1].tok, "REFERENCES");
        if qualifier || referenced {
            edits.push((ts[i].start, ts[i].end, quote_ident(new)));
        }
    }
    apply_edits(sql, edits)
}

fn rename_table_in_index(sql: &str, old: &str, new: &str) -> String {
    let ts = toks(sql);
    let Some(on) = ts.iter().position(|t| is_kw(&t.tok, "ON")) else { return sql.to_string() };
    let mut edits = Vec::new();
    if on + 1 < ts.len() {
        edits.push((ts[on + 1].start, ts[on + 1].end, quote_ident(new)));
    }
    for i in on + 2..ts.len() {
        if eq_name(&ts[i].tok, old) && i + 1 < ts.len() && is_op(&ts[i + 1].tok, ".") {
            edits.push((ts[i].start, ts[i].end, quote_ident(new)));
        }
    }
    apply_edits(sql, edits)
}

/// Position of the AS that starts a view's query.
fn view_body_start(ts: &[Token]) -> usize {
    let mut depth = 0;
    for (i, t) in ts.iter().enumerate() {
        if is_op(&t.tok, "(") {
            depth += 1;
        } else if is_op(&t.tok, ")") {
            depth -= 1;
        } else if depth == 0 && is_kw(&t.tok, "AS") {
            return i + 1;
        }
    }
    ts.len()
}

fn rename_table_in_view(sql: &str, old: &str, new: &str) -> String {
    let ts = toks(sql);
    let mut edits = Vec::new();
    for i in view_body_start(&ts)..ts.len() {
        if !eq_name(&ts[i].tok, old) {
            continue;
        }
        let after_dot = i > 0 && is_op(&ts[i - 1].tok, ".");
        let call = i + 1 < ts.len() && is_op(&ts[i + 1].tok, "(");
        if !after_dot && !call {
            edits.push((ts[i].start, ts[i].end, quote_ident(new)));
        }
    }
    apply_edits(sql, edits)
}

fn rename_column_in_create(sql: &str, old: &str, new: &str) -> String {
    let ts = toks(sql);
    let Some(open) = find_op(&ts, 0, "(") else { return sql.to_string() };
    let mut edits = Vec::new();
    for i in open..ts.len() {
        if eq_name(&ts[i].tok, old) && !(i + 1 < ts.len() && is_op(&ts[i + 1].tok, "(")) {
            edits.push((ts[i].start, ts[i].end, maybe_quote(new)));
        }
    }
    apply_edits(sql, edits)
}

fn rename_column_in_index(sql: &str, table: &str, old: &str, new: &str) -> String {
    let ts = toks(sql);
    let Some(on) = ts.iter().position(|t| is_kw(&t.tok, "ON")) else { return sql.to_string() };
    let mut edits = Vec::new();
    for i in on + 2..ts.len() {
        if !eq_name(&ts[i].tok, old) {
            continue;
        }
        let call = i + 1 < ts.len() && is_op(&ts[i + 1].tok, "(");
        let ok_qual = i < 2 || !is_op(&ts[i - 1].tok, ".") || eq_name(&ts[i - 2].tok, table);
        if !call && ok_qual {
            edits.push((ts[i].start, ts[i].end, maybe_quote(new)));
        }
    }
    apply_edits(sql, edits)
}

fn rename_column_in_view(sql: &str, aliases: &[String], old: &str, new: &str) -> String {
    let ts = toks(sql);
    let mut edits = Vec::new();
    for i in view_body_start(&ts)..ts.len() {
        if !eq_name(&ts[i].tok, old) {
            continue;
        }
        let call = i + 1 < ts.len() && is_op(&ts[i + 1].tok, "(");
        let qualifier = i + 1 < ts.len() && is_op(&ts[i + 1].tok, ".");
        let alias_def = i > 0 && is_kw(&ts[i - 1].tok, "AS");
        if call || qualifier || alias_def {
            continue;
        }
        if i >= 2 && is_op(&ts[i - 1].tok, ".") {
            let q = ident(&ts[i - 2].tok).unwrap_or("");
            if !aliases.iter().any(|a| a.eq_ignore_ascii_case(q)) {
                continue;
            }
        }
        edits.push((ts[i].start, ts[i].end, maybe_quote(new)));
    }
    apply_edits(sql, edits)
}

fn add_column_to_create(sql: &str, def: &str) -> String {
    let ts = toks(sql);
    let Some(open) = find_op(&ts, 0, "(") else { return sql.to_string() };
    let Some(close) = matching_paren(&ts, open) else { return sql.to_string() };
    // SQLite inserts the new column after the last column definition,
    // before any table constraints
    let mut at = ts[close].start;
    let mut depth = 0;
    let mut prev_end = ts[open].end;
    for t in ts.iter().take(close).skip(open + 1) {
        if is_op(&t.tok, "(") {
            depth += 1;
        } else if is_op(&t.tok, ")") {
            depth -= 1;
        } else if depth == 0 && is_op(&t.tok, ",") {
            prev_end = t.start;
            continue;
        }
        if depth == 0
            && prev_end > 0
            && t.start > prev_end
            && ["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"].iter().any(|k| is_kw(&t.tok, k))
        {
            at = prev_end;
            break;
        }
        prev_end = 0;
    }
    apply_edits(sql, vec![(at, at, format!(", {}", def.trim_end_matches(|c: char| c == ';' || c.is_whitespace())))])
}

fn drop_column_from_create(sql: &str, name: &str) -> Option<String> {
    let ts = toks(sql);
    let open = find_op(&ts, 0, "(")?;
    let close = matching_paren(&ts, open)?;
    // top-level items between the parentheses: (first token, last token)
    let mut items = Vec::new();
    let mut depth = 0;
    let mut start = open + 1;
    for (i, t) in ts.iter().enumerate().take(close).skip(open + 1) {
        if is_op(&t.tok, "(") {
            depth += 1;
        } else if is_op(&t.tok, ")") {
            depth -= 1;
        } else if depth == 0 && is_op(&t.tok, ",") {
            items.push((start, i - 1));
            start = i + 1;
        }
    }
    items.push((start, close - 1));
    let n = items.iter().position(|&(s, _)| eq_name(&ts[s].tok, name))?;
    let (s, e) = items[n];
    let (from, to) = if n > 0 {
        (ts[items[n - 1].1].end, ts[e].end)
    } else if items.len() > 1 {
        (ts[s].start, ts[items[1].0].start)
    } else {
        (ts[s].start, ts[e].end)
    };
    Some(apply_edits(sql, vec![(from, to, String::new())]))
}
