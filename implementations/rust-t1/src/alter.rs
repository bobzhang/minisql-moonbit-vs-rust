// Rewriting stored SQL (views, CHECK constraints, index expressions) for
// ALTER TABLE renames, and finding references to a column.

use crate::agg::for_each_child_mut;
use crate::ast::*;
use crate::db::{key, Database};

/// A FROM item as seen by name resolution in stored SQL.
struct Src {
    visible: String,
    is_target: bool,
    /// Known column names (None = unknown).
    cols: Option<Vec<String>>,
}

/// Finds (and optionally renames) the references to column `col` of the
/// table with key `target`.
pub struct ColRefs<'a> {
    pub db: &'a Database,
    pub target: String,
    /// Column names of the target (before any rename).
    pub target_cols: Vec<String>,
    pub col: String,
    pub new_name: Option<String>,
    pub hits: usize,
}

impl ColRefs<'_> {
    fn resolves(&self, table: &Option<String>, name: &str, scopes: &[Vec<Src>]) -> bool {
        match table {
            Some(q) => {
                for scope in scopes.iter().rev() {
                    if let Some(s) = scope.iter().find(|s| s.visible.eq_ignore_ascii_case(q)) {
                        return s.is_target && name.eq_ignore_ascii_case(&self.col);
                    }
                }
                false
            }
            None => {
                for scope in scopes.iter().rev() {
                    for s in scope {
                        let has = match &s.cols {
                            Some(c) => c.iter().any(|c| c.eq_ignore_ascii_case(name)),
                            None => false,
                        };
                        if has {
                            return s.is_target && name.eq_ignore_ascii_case(&self.col);
                        }
                    }
                }
                false
            }
        }
    }

    fn expr(&mut self, e: &mut Expr, scopes: &mut Vec<Vec<Src>>) {
        match e {
            Expr::Column { table, name, .. } => {
                if self.resolves(table, name, scopes) {
                    self.hits += 1;
                    if let Some(n) = &self.new_name {
                        *name = n.clone();
                    }
                }
            }
            Expr::Subquery(q) | Expr::Exists(q) => self.select(q, scopes),
            Expr::InSelect { e, query, .. } => {
                self.expr(e, scopes);
                self.select(query, scopes);
            }
            _ => for_each_child_mut(e, &mut |c| self.expr(c, scopes)),
        }
    }

    /// Visit an expression over the target table alone (CHECK, index).
    pub fn table_expr(&mut self, e: &mut Expr, table_name: &str) {
        let mut scopes = vec![vec![Src {
            visible: table_name.to_string(),
            is_target: true,
            cols: Some(self.target_cols.clone()),
        }]];
        self.expr(e, &mut scopes);
    }

    fn select(&mut self, sel: &mut Select, scopes: &mut Vec<Vec<Src>>) {
        if let Some(w) = &mut sel.with {
            for c in w.ctes.iter_mut() {
                self.select(&mut c.select, scopes);
            }
        }
        let single = sel.rest.is_empty();
        let mut cores: Vec<&mut Core> = vec![&mut sel.first];
        for (_, c) in sel.rest.iter_mut() {
            cores.push(c);
        }
        let n = cores.len();
        for (ci, core) in cores.into_iter().enumerate() {
            match core {
                Core::Values(rows) => {
                    for r in rows {
                        for e in r {
                            self.expr(e, scopes);
                        }
                    }
                }
                Core::Select(sc) => {
                    let mut srcs = Vec::new();
                    for term in sc.from.iter_mut() {
                        match &mut term.source {
                            TableSource::Table { name, alias } => {
                                let k = key(name);
                                let is_target = k == self.target;
                                let cols = if is_target {
                                    Some(self.target_cols.clone())
                                } else {
                                    self.db.tables.get(&k).map(|t| t.columns.iter().map(|c| c.name.clone()).collect())
                                };
                                srcs.push(Src { visible: alias.clone().unwrap_or_else(|| name.clone()), is_target, cols });
                            }
                            TableSource::Subquery { query, alias } => {
                                self.select(query, scopes);
                                srcs.push(Src { visible: alias.clone().unwrap_or_default(), is_target: false, cols: None });
                            }
                        }
                    }
                    scopes.push(srcs);
                    for rc in sc.columns.iter_mut() {
                        if let ResultCol::Expr { expr, .. } = rc {
                            self.expr(expr, scopes);
                        }
                    }
                    for term in sc.from.iter_mut() {
                        if let Some(on) = &mut term.on {
                            self.expr(on, scopes);
                        }
                    }
                    if let Some(w) = &mut sc.where_ {
                        self.expr(w, scopes);
                    }
                    for g in sc.group_by.iter_mut() {
                        self.expr(g, scopes);
                    }
                    if let Some(h) = &mut sc.having {
                        self.expr(h, scopes);
                    }
                    if single && ci + 1 == n {
                        for t in sel.order_by.iter_mut() {
                            self.expr(&mut t.expr, scopes);
                        }
                    }
                    scopes.pop();
                }
            }
        }
        if let Some(l) = &mut sel.limit {
            self.expr(l, scopes);
        }
        if let Some(o) = &mut sel.offset {
            self.expr(o, scopes);
        }
    }

    pub fn view(&mut self, sel: &mut Select) {
        let mut scopes = Vec::new();
        self.select(sel, &mut scopes);
    }
}

/// Apply `f` to every SELECT core in a query, including nested ones.
pub fn walk_cores(sel: &mut Select, f: &mut dyn FnMut(&mut SelectCore)) {
    if let Some(w) = &mut sel.with {
        for c in w.ctes.iter_mut() {
            walk_cores(&mut c.select, f);
        }
    }
    let mut cores: Vec<&mut Core> = vec![&mut sel.first];
    for (_, c) in sel.rest.iter_mut() {
        cores.push(c);
    }
    for core in cores {
        match core {
            Core::Values(rows) => {
                for r in rows {
                    for e in r {
                        walk_expr_selects(e, f);
                    }
                }
            }
            Core::Select(sc) => {
                f(sc);
                for term in sc.from.iter_mut() {
                    if let TableSource::Subquery { query, .. } = &mut term.source {
                        walk_cores(query, f);
                    }
                    if let Some(on) = &mut term.on {
                        walk_expr_selects(on, f);
                    }
                }
                for rc in sc.columns.iter_mut() {
                    if let ResultCol::Expr { expr, .. } = rc {
                        walk_expr_selects(expr, f);
                    }
                }
                if let Some(w) = &mut sc.where_ {
                    walk_expr_selects(w, f);
                }
                for g in sc.group_by.iter_mut() {
                    walk_expr_selects(g, f);
                }
                if let Some(h) = &mut sc.having {
                    walk_expr_selects(h, f);
                }
            }
        }
    }
    for t in sel.order_by.iter_mut() {
        walk_expr_selects(&mut t.expr, f);
    }
}

fn walk_expr_selects(e: &mut Expr, f: &mut dyn FnMut(&mut SelectCore)) {
    match e {
        Expr::Subquery(q) | Expr::Exists(q) => walk_cores(q, f),
        Expr::InSelect { e, query, .. } => {
            walk_expr_selects(e, f);
            walk_cores(query, f);
        }
        _ => for_each_child_mut(e, &mut |c| walk_expr_selects(c, f)),
    }
}

/// Point FROM references to table `old` at `new` (keeping `old` as the
/// visible name when there was no alias).
pub fn rename_table_in_select(sel: &mut Select, old: &str, new: &str) {
    walk_cores(sel, &mut |sc| {
        for term in sc.from.iter_mut() {
            if let TableSource::Table { name, alias } = &mut term.source {
                if name.eq_ignore_ascii_case(old) {
                    if alias.is_none() {
                        *alias = Some(name.clone());
                    }
                    *name = new.to_string();
                }
            }
        }
    });
}

/// Rename the qualifier `old.` to `new.` in a single-table expression.
pub fn rename_qualifier(e: &mut Expr, old: &str, new: &str) {
    if let Expr::Column { table: Some(t), .. } = e {
        if t.eq_ignore_ascii_case(old) {
            *t = new.to_string();
        }
        return;
    }
    for_each_child_mut(e, &mut |c| rename_qualifier(c, old, new));
}
