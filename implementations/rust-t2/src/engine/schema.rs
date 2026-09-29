// Schema helpers: AST walkers and the rewriting done by ALTER TABLE RENAME.

use crate::ast::*;

use super::fold;

/// Visit an expression and its subexpressions (not descending into
/// subqueries).
pub fn walk_expr(e: &Expr, f: &mut dyn FnMut(&Expr)) {
    f(e);
    match e {
        Expr::Lit(_) | Expr::Column { .. } | Expr::Subquery(_) | Expr::Exists(_) => {}
        Expr::Unary(_, x)
        | Expr::IsNull(x)
        | Expr::NotNull(x)
        | Expr::Cast(x, _)
        | Expr::Collate(x, _) => walk_expr(x, f),
        Expr::InSelect { expr, .. } => walk_expr(expr, f),
        Expr::Binary(_, l, r) => {
            walk_expr(l, f);
            walk_expr(r, f);
        }
        Expr::Between { expr, lo, hi, .. } => {
            walk_expr(expr, f);
            walk_expr(lo, f);
            walk_expr(hi, f);
        }
        Expr::InList { expr, list, .. } => {
            walk_expr(expr, f);
            list.iter().for_each(|x| walk_expr(x, f));
        }
        Expr::Like {
            expr,
            pattern,
            escape,
            ..
        } => {
            walk_expr(expr, f);
            walk_expr(pattern, f);
            if let Some(x) = escape {
                walk_expr(x, f);
            }
        }
        Expr::Case {
            operand,
            whens,
            else_,
        } => {
            if let Some(x) = operand {
                walk_expr(x, f);
            }
            for (w, t) in whens {
                walk_expr(w, f);
                walk_expr(t, f);
            }
            if let Some(x) = else_ {
                walk_expr(x, f);
            }
        }
        Expr::Func {
            args,
            filter,
            order_by,
            over,
            ..
        } => {
            args.iter().for_each(|x| walk_expr(x, f));
            if let Some(x) = filter {
                walk_expr(x, f);
            }
            order_by.iter().for_each(|t| walk_expr(&t.expr, f));
            if let Some(w) = over {
                w.partition.iter().for_each(|x| walk_expr(x, f));
                w.order.iter().for_each(|t| walk_expr(&t.expr, f));
            }
        }
    }
}

/// A rename performed by ALTER TABLE.
pub enum Rename<'a> {
    Table {
        old: &'a str,
        new: &'a str,
    },
    Column {
        table: &'a str,
        old: &'a str,
        new: &'a str,
    },
}

/// Qualifiers in scope that refer to the renamed table.
#[derive(Clone, Default)]
struct Quals {
    names: Vec<String>,
}

impl Quals {
    fn has(&self, q: &str) -> bool {
        self.names.iter().any(|n| *n == fold(q))
    }
}

/// Rewrite an expression of the renamed table itself (CHECK constraints,
/// index expressions): every column reference belongs to the table.
pub fn rename_in_table_expr(e: &mut Expr, r: &Rename, table: &str) {
    let q = Quals {
        names: vec![fold(table)],
    };
    rn_expr(e, r, &q);
}

/// Rewrite a view's query.
pub fn rename_in_select(sel: &mut Select, r: &Rename) {
    rn_select(sel, r, &Quals::default());
}

fn rn_select(sel: &mut Select, r: &Rename, outer: &Quals) {
    if let Some(w) = &mut sel.with {
        for c in &mut w.ctes {
            rn_select(&mut c.query, r, outer);
        }
    }
    let mut last = outer.clone();
    for core in &mut sel.cores {
        match core {
            Core::Select(c) => last = rn_core(c, r, outer),
            Core::Values(rows) => {
                for row in rows {
                    for e in row {
                        rn_expr(e, r, outer);
                    }
                }
            }
        }
    }
    // ORDER BY of a single SELECT sees its FROM clause.
    let q = if sel.cores.len() == 1 {
        last
    } else {
        outer.clone()
    };
    for t in &mut sel.order_by {
        rn_expr(&mut t.expr, r, &q);
    }
    if let Some(e) = &mut sel.limit {
        rn_expr(e, r, outer);
    }
    if let Some(e) = &mut sel.offset {
        rn_expr(e, r, outer);
    }
}

fn rn_core(c: &mut SelectCore, r: &Rename, outer: &Quals) -> Quals {
    let mut q = outer.clone();
    let mut local = false;
    for term in &mut c.from {
        match &mut term.source {
            TableRef::Table { name, alias } => match r {
                Rename::Table { old, new } => {
                    if fold(name) == fold(old) {
                        *name = new.to_string();
                        if alias.is_none() {
                            q.names.push(fold(old));
                        }
                    }
                }
                Rename::Column { table, .. } => {
                    if fold(name) == fold(table) {
                        q.names.push(fold(alias.as_deref().unwrap_or(name)));
                        local = true;
                    }
                }
            },
            TableRef::Subquery { query, .. } => rn_select(query, r, outer),
        }
    }
    for term in &mut c.from {
        if let Some(e) = &mut term.on {
            rn_expr(e, r, &q);
        }
        if let (Some(using), Rename::Column { old, new, .. }) = (&mut term.using, r) {
            if local {
                for u in using.iter_mut() {
                    if fold(u) == fold(old) {
                        *u = new.to_string();
                    }
                }
            }
        }
    }
    for rc in &mut c.columns {
        match rc {
            ResultCol::Expr(e, _, _) => rn_expr(e, r, &q),
            ResultCol::TableStar(t) => {
                if let Rename::Table { new, .. } = r {
                    if q.has(t) {
                        *t = new.to_string();
                    }
                }
            }
            ResultCol::Star => {}
        }
    }
    if let Some(e) = &mut c.where_ {
        rn_expr(e, r, &q);
    }
    for e in &mut c.group_by {
        rn_expr(e, r, &q);
    }
    if let Some(e) = &mut c.having {
        rn_expr(e, r, &q);
    }
    for (_, w) in &mut c.windows {
        rn_window(w, r, &q);
    }
    q
}

fn rn_window(w: &mut WindowSpec, r: &Rename, q: &Quals) {
    w.partition.iter_mut().for_each(|x| rn_expr(x, r, q));
    w.order.iter_mut().for_each(|t| rn_expr(&mut t.expr, r, q));
}

fn rn_expr(e: &mut Expr, r: &Rename, q: &Quals) {
    match e {
        Expr::Lit(_) => {}
        Expr::Column { table, name, .. } => match r {
            Rename::Table { new, .. } => {
                if let Some(t) = table {
                    if q.has(t) {
                        *t = new.to_string();
                    }
                }
            }
            Rename::Column { old, new, .. } => {
                let applies = match table {
                    Some(t) => q.has(t),
                    None => !q.names.is_empty(),
                };
                if applies && fold(name) == fold(old) {
                    *name = new.to_string();
                }
            }
        },
        Expr::Unary(_, x)
        | Expr::IsNull(x)
        | Expr::NotNull(x)
        | Expr::Cast(x, _)
        | Expr::Collate(x, _) => rn_expr(x, r, q),
        Expr::Binary(_, l, rr) => {
            rn_expr(l, r, q);
            rn_expr(rr, r, q);
        }
        Expr::Between { expr, lo, hi, .. } => {
            rn_expr(expr, r, q);
            rn_expr(lo, r, q);
            rn_expr(hi, r, q);
        }
        Expr::InList { expr, list, .. } => {
            rn_expr(expr, r, q);
            list.iter_mut().for_each(|x| rn_expr(x, r, q));
        }
        Expr::Like {
            expr,
            pattern,
            escape,
            ..
        } => {
            rn_expr(expr, r, q);
            rn_expr(pattern, r, q);
            if let Some(x) = escape {
                rn_expr(x, r, q);
            }
        }
        Expr::Case {
            operand,
            whens,
            else_,
        } => {
            if let Some(x) = operand {
                rn_expr(x, r, q);
            }
            for (w, t) in whens {
                rn_expr(w, r, q);
                rn_expr(t, r, q);
            }
            if let Some(x) = else_ {
                rn_expr(x, r, q);
            }
        }
        Expr::Func {
            args,
            filter,
            order_by,
            over,
            ..
        } => {
            args.iter_mut().for_each(|x| rn_expr(x, r, q));
            if let Some(x) = filter {
                rn_expr(x, r, q);
            }
            order_by.iter_mut().for_each(|t| rn_expr(&mut t.expr, r, q));
            if let Some(w) = over {
                rn_window(w, r, q);
            }
        }
        Expr::Subquery(s) | Expr::Exists(s) => rn_select(s, r, q),
        Expr::InSelect { expr, query, .. } => {
            rn_expr(expr, r, q);
            rn_select(query, r, q);
        }
    }
}
