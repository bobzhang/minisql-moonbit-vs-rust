// Query flattening: a simple view or FROM-clause subquery is merged into
// the query that uses it (as SQLite's flattener does), so that its tables
// take part in index selection and join ordering. Only plain cases are
// handled; anything that could change the meaning of a name is left alone.

use crate::agg::{self, map_expr};
use crate::ast::*;
use crate::db::{key, Database};

fn is_rowid_name(n: &str) -> bool {
    n.eq_ignore_ascii_case("rowid") || n.eq_ignore_ascii_case("oid") || n.eq_ignore_ascii_case("_rowid_")
}

/// Column references (qualifier, name) anywhere in a query, including its
/// nested queries.
fn select_refs(q: &Select, out: &mut Vec<(Option<String>, String)>) {
    fn item(it: &TableItem, out: &mut Vec<(Option<String>, String)>) {
        if let TableItem::Subquery { query, .. } = it {
            select_refs(query, out);
        }
    }
    let mut exprs: Vec<&Expr> = Vec::new();
    for core in &q.cores {
        match core {
            SelectCore::Values(rows) => exprs.extend(rows.iter().flatten()),
            SelectCore::Select(b) => {
                for c in &b.columns {
                    match c {
                        ResultColumn::Expr(e, _, _) => exprs.push(e),
                        ResultColumn::TableStar(t) => out.push((Some(t.clone()), "*".to_string())),
                        ResultColumn::Star => {}
                    }
                }
                if let Some(f) = &b.from {
                    item(&f.first, out);
                    for j in &f.joins {
                        item(&j.item, out);
                        exprs.extend(j.on.iter());
                        if let Some(u) = &j.using {
                            out.extend(u.iter().map(|n| (None, n.clone())));
                        }
                    }
                }
                exprs.extend(b.where_.iter());
                exprs.extend(b.group_by.iter());
                exprs.extend(b.having.iter());
            }
        }
    }
    exprs.extend(q.order_by.iter().map(|t| &t.expr));
    exprs.extend(q.limit.iter());
    exprs.extend(q.offset.iter());
    for e in exprs {
        expr_refs(e, out);
    }
}

/// Column references in an expression, including nested queries.
fn expr_refs(e: &Expr, out: &mut Vec<(Option<String>, String)>) {
    let _ = map_expr(e, &mut |x| {
        match x {
            Expr::Column { table, name, .. } => out.push((table.clone(), name.clone())),
            Expr::Subquery(q) | Expr::Exists(q) => select_refs(q, out),
            Expr::InSelect { query, .. } => select_refs(query, out),
            _ => {}
        }
        Ok(None)
    });
}

fn has_subquery(e: &Expr) -> bool {
    let mut found = false;
    let _ = map_expr(e, &mut |x| {
        if matches!(x, Expr::Subquery(_) | Expr::Exists(_) | Expr::InSelect { .. }) {
            found = true;
        }
        Ok(None)
    });
    found
}

/// A FROM item of the subquery being merged: its old name and new alias.
struct Inner {
    name: String,
    alias: String,
    columns: Vec<String>,
}

thread_local! {
    static COUNTER: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

fn fresh_alias(base: &str) -> String {
    let n = COUNTER.with(|c| {
        c.set(c.get() + 1);
        c.get()
    });
    format!("{}\u{1}{}", base, n)
}

/// Flattens the first mergeable FROM item of the query, if any.
pub fn flatten(db: &Database, sel: &SelectBody, order_by: &[OrderTerm]) -> Option<(SelectBody, Vec<OrderTerm>)> {
    let from = sel.from.as_ref()?;
    // window functions see the rows of their own query level
    let outer_windows = !sel.windows.is_empty()
        || order_by.iter().any(|t| agg::contains_window(&t.expr))
        || sel.columns.iter().any(|c| matches!(c, ResultColumn::Expr(e, _, _) if agg::contains_window(e)));
    if outer_windows {
        return None;
    }
    if from.joins.iter().any(|j| j.natural || j.using.is_some() || matches!(j.kind, JoinKind::Right | JoinKind::Full)) {
        return None;
    }
    let n_items = from.joins.len() + 1;
    for p in 0..n_items {
        let item = if p == 0 { &from.first } else { &from.joins[p - 1].item };
        if let Some(r) = try_item(db, sel, order_by, p, item) {
            return Some(r);
        }
    }
    None
}

fn try_item(
    db: &Database,
    sel: &SelectBody,
    order_by: &[OrderTerm],
    p: usize,
    item: &TableItem,
) -> Option<(SelectBody, Vec<OrderTerm>)> {
    let from = sel.from.as_ref().unwrap();
    // the subquery and the name the outer query uses for it
    let (sub, alias, col_names): (&Select, String, Option<Vec<String>>) = match item {
        TableItem::Table { name, alias } => {
            let k = key(name);
            if crate::cte::is_cte(name) || db.tables.contains_key(&k) {
                return None;
            }
            let v = db.views.get(&k)?;
            (&v.select, alias.clone().unwrap_or_else(|| v.name.clone()), v.columns.clone())
        }
        TableItem::Subquery { query, alias } => (query, alias.clone().unwrap_or_else(|| fresh_alias("subquery")), None),
    };
    // the subquery must be a plain SELECT over tables
    if sub.with.is_some() || sub.cores.len() != 1 || !sub.order_by.is_empty() || sub.limit.is_some() || sub.offset.is_some() {
        return None;
    }
    let SelectCore::Select(b) = &sub.cores[0] else { return None };
    if b.distinct || !b.group_by.is_empty() || b.having.is_some() {
        return None;
    }
    let sfrom = b.from.as_ref()?;
    if sfrom.joins.iter().any(|j| j.kind != JoinKind::Inner || j.natural || j.using.is_some()) {
        return None;
    }
    let left = p > 0 && from.joins[p - 1].kind == JoinKind::Left;
    if left && !sfrom.joins.is_empty() {
        return None;
    }
    let mut inners: Vec<Inner> = Vec::new();
    for it in std::iter::once(&sfrom.first).chain(sfrom.joins.iter().map(|j| &j.item)) {
        let TableItem::Table { name, alias: a } = it else { return None };
        if crate::cte::is_cte(name) {
            return None;
        }
        let t = db.tables.get(&key(name))?;
        inners.push(Inner {
            name: a.clone().unwrap_or_else(|| t.name.clone()),
            alias: fresh_alias(&t.name),
            columns: t.columns.iter().map(|c| c.name.clone()).collect(),
        });
    }
    let all_sub_exprs: Vec<&Expr> = b
        .columns
        .iter()
        .filter_map(|c| match c {
            ResultColumn::Expr(e, _, _) => Some(e),
            _ => None,
        })
        .chain(b.where_.iter())
        .chain(sfrom.joins.iter().filter_map(|j| j.on.as_ref()))
        .collect();
    if !b.windows.is_empty()
        || all_sub_exprs.iter().any(|e| has_subquery(e) || agg::contains_agg(e, &|_| true) || agg::contains_window(e))
    {
        return None;
    }

    // qualifies a name of the subquery with its new alias
    let qualify = |e: &Expr| -> Option<Expr> {
        let mut ok = true;
        let r = map_expr(e, &mut |x| {
            if let Expr::Column { table, name, .. } = x {
                let hit: Vec<&Inner> = match table {
                    Some(q) => inners.iter().filter(|i| i.name.eq_ignore_ascii_case(q)).collect(),
                    None => inners
                        .iter()
                        .filter(|i| i.columns.iter().any(|c| c.eq_ignore_ascii_case(name)))
                        .collect(),
                };
                let found = match (table, hit.len()) {
                    (_, 1) => Some(hit[0]),
                    (None, 0) if is_rowid_name(name) && inners.len() == 1 => Some(&inners[0]),
                    _ => None,
                };
                match found {
                    Some(i) if table.is_none() || i.columns.iter().any(|c| c.eq_ignore_ascii_case(name)) || is_rowid_name(name) => {
                        return Ok(Some(Expr::Column { table: Some(i.alias.clone()), name: name.clone(), dq: false }));
                    }
                    _ => {
                        ok = false;
                    }
                }
            }
            Ok(None)
        });
        if ok {
            r.ok()
        } else {
            None
        }
    };

    // the subquery's result columns: (name, qualified expression)
    let mut cols: Vec<(String, Expr)> = Vec::new();
    for rc in &b.columns {
        match rc {
            ResultColumn::Star => {
                for i in &inners {
                    for c in &i.columns {
                        cols.push((c.clone(), Expr::Column { table: Some(i.alias.clone()), name: c.clone(), dq: false }));
                    }
                }
            }
            ResultColumn::TableStar(q) => {
                let i = inners.iter().find(|i| i.name.eq_ignore_ascii_case(q))?;
                for c in &i.columns {
                    cols.push((c.clone(), Expr::Column { table: Some(i.alias.clone()), name: c.clone(), dq: false }));
                }
            }
            ResultColumn::Expr(e, a, text) => {
                let name = match (a, e) {
                    (Some(a), _) => a.clone(),
                    (None, Expr::Column { name, .. }) => name.clone(),
                    _ => text.clone(),
                };
                cols.push((name, qualify(e)?));
            }
        }
    }
    if let Some(names) = &col_names {
        if names.len() != cols.len() {
            return None;
        }
        for (c, n) in cols.iter_mut().zip(names) {
            c.0 = n.clone();
        }
    }
    // unique column names, as SQLite gives a view's columns
    let mut seen: Vec<String> = Vec::new();
    for c in cols.iter_mut() {
        let base = c.0.clone();
        let mut k = 0;
        while seen.iter().any(|s| s.eq_ignore_ascii_case(&c.0)) {
            k += 1;
            c.0 = format!("{}:{}", base, k);
        }
        seen.push(c.0.clone());
    }
    let sub_where = match &b.where_ {
        Some(w) => Some(qualify(w)?),
        None => None,
    };
    // the subquery's inner-join conditions join its WHERE clause (SQLite
    // moves ON terms after the WHERE terms)
    let mut sub_where = sub_where;
    let mut sub_joins: Vec<Join> = Vec::new();
    for (j, i) in sfrom.joins.iter().zip(inners.iter().skip(1)) {
        let TableItem::Table { name, .. } = &j.item else { return None };
        if let Some(e) = &j.on {
            let q = qualify(e)?;
            sub_where = Some(match sub_where {
                Some(w) => Expr::Binary(BinOp::And, Box::new(w), Box::new(q)),
                None => q,
            });
        }
        sub_joins.push(Join {
            kind: JoinKind::Inner,
            cross: j.cross,
            natural: false,
            item: TableItem::Table { name: name.clone(), alias: Some(i.alias.clone()) },
            on: None,
            using: None,
        });
    }
    let TableItem::Table { name: first_name, .. } = &sfrom.first else { return None };
    let first_item = TableItem::Table { name: first_name.clone(), alias: Some(inners[0].alias.clone()) };

    // names the outer query must not use ambiguously
    let hidden: Vec<&String> = inners.iter().flat_map(|i| i.columns.iter()).collect();
    let is_sub_col = |n: &str| cols.iter().any(|(c, _)| c.eq_ignore_ascii_case(n));
    let other_items: Vec<&TableItem> = std::iter::once(&from.first)
        .chain(from.joins.iter().map(|j| &j.item))
        .enumerate()
        .filter(|(k, _)| *k != p)
        .map(|(_, it)| it)
        .collect();
    let item_name = |it: &TableItem| -> Option<String> {
        match it {
            TableItem::Table { name, alias } => Some(alias.clone().unwrap_or_else(|| name.clone())),
            TableItem::Subquery { alias, .. } => alias.clone(),
        }
    };
    // columns of the other outer items (None: unknown)
    let other_cols = |n: &str| -> Option<bool> {
        let mut any = false;
        for it in &other_items {
            match it {
                TableItem::Table { name, .. } => {
                    if let Some(t) = db.tables.get(&key(name)) {
                        if t.columns.iter().any(|c| c.name.eq_ignore_ascii_case(n)) {
                            any = true;
                        }
                    } else {
                        return None;
                    }
                }
                TableItem::Subquery { .. } => return None,
            }
        }
        Some(any)
    };
    if other_items.iter().any(|it| item_name(it).is_some_and(|x| x.eq_ignore_ascii_case(&alias))) {
        return None;
    }

    // rewrites one expression of the outer query
    let rewrite = |e: &Expr| -> Option<Expr> {
        // names inside nested queries are left alone: give up if they
        // could mean the subquery
        let mut nested: Vec<(Option<String>, String)> = Vec::new();
        let _ = map_expr(e, &mut |x| {
            match x {
                Expr::Subquery(q) | Expr::Exists(q) => select_refs(q, &mut nested),
                Expr::InSelect { query, .. } => select_refs(query, &mut nested),
                _ => {}
            }
            Ok(None)
        });
        for (q, n) in &nested {
            let hits = match q {
                Some(q) => q.eq_ignore_ascii_case(&alias),
                None => is_sub_col(n) || hidden.iter().any(|h| h.eq_ignore_ascii_case(n)) || is_rowid_name(n),
            };
            if hits {
                return None;
            }
        }
        let mut ok = true;
        let r = map_expr(e, &mut |x| {
            if let Expr::Column { table, name, dq } = x {
                if is_rowid_name(name) && (table.is_none() || table.as_ref().is_some_and(|t| t.eq_ignore_ascii_case(&alias))) {
                    ok = false;
                    return Ok(None);
                }
                match table {
                    Some(t) if t.eq_ignore_ascii_case(&alias) => match cols.iter().find(|(c, _)| c.eq_ignore_ascii_case(name)) {
                        Some((_, ex)) => return Ok(Some(ex.clone())),
                        None => ok = false,
                    },
                    Some(_) => {}
                    None => {
                        let mine = is_sub_col(name);
                        match other_cols(name) {
                            Some(false) => {}
                            Some(true) => {
                                if mine {
                                    ok = false;
                                }
                                return Ok(None);
                            }
                            None => {
                                ok = false;
                                return Ok(None);
                            }
                        }
                        if mine {
                            let (_, ex) = cols.iter().find(|(c, _)| c.eq_ignore_ascii_case(name)).unwrap();
                            return Ok(Some(ex.clone()));
                        }
                        // an unknown name must not start matching a hidden column
                        if hidden.iter().any(|h| h.eq_ignore_ascii_case(name)) || !*dq {
                            ok = false;
                        }
                    }
                }
            }
            Ok(None)
        });
        if ok {
            r.ok()
        } else {
            None
        }
    };

    // result columns (with * expanded)
    let mut columns: Vec<ResultColumn> = Vec::new();
    for rc in &sel.columns {
        match rc {
            ResultColumn::Star => {
                for (k, it) in std::iter::once(&from.first).chain(from.joins.iter().map(|j| &j.item)).enumerate() {
                    if k == p {
                        for (n, ex) in &cols {
                            columns.push(ResultColumn::Expr(ex.clone(), Some(n.clone()), n.clone()));
                        }
                    } else {
                        columns.push(ResultColumn::TableStar(item_name(it)?));
                    }
                }
            }
            ResultColumn::TableStar(t) if t.eq_ignore_ascii_case(&alias) => {
                for (n, ex) in &cols {
                    columns.push(ResultColumn::Expr(ex.clone(), Some(n.clone()), n.clone()));
                }
            }
            ResultColumn::TableStar(t) => columns.push(ResultColumn::TableStar(t.clone())),
            ResultColumn::Expr(e, a, text) => {
                let a = match (a, e) {
                    (Some(a), _) => Some(a.clone()),
                    (None, Expr::Column { name, .. }) => Some(name.clone()),
                    _ => None,
                };
                columns.push(ResultColumn::Expr(rewrite(e)?, a, text.clone()));
            }
        }
    }
    let mut where_ = match &sel.where_ {
        Some(w) => Some(rewrite(w)?),
        None => None,
    };
    let mut group_by = Vec::new();
    for g in &sel.group_by {
        group_by.push(rewrite(g)?);
    }
    let having = match &sel.having {
        Some(h) => Some(rewrite(h)?),
        None => None,
    };
    let mut new_order = Vec::new();
    for t in order_by {
        // ORDER BY may name a result column
        let e = match &t.expr {
            Expr::Column { table: None, name, .. }
                if sel.columns.iter().any(|rc| matches!(rc, ResultColumn::Expr(_, Some(a), _) if a.eq_ignore_ascii_case(name))) =>
            {
                t.expr.clone()
            }
            e => rewrite(e)?,
        };
        new_order.push(OrderTerm { expr: e, desc: t.desc, nulls_first: t.nulls_first });
    }
    let mut joins: Vec<Join> = Vec::new();
    for (k, j) in from.joins.iter().enumerate() {
        let on = match &j.on {
            Some(e) => Some(rewrite(e)?),
            None => None,
        };
        if k + 1 == p {
            let mut on = on;
            if left {
                if let Some(w) = &sub_where {
                    on = Some(match on {
                        Some(c) => Expr::Binary(BinOp::And, Box::new(c), Box::new(w.clone())),
                        None => w.clone(),
                    });
                }
            }
            // the join's condition may use any of the subquery's tables
            if sub_joins.is_empty() {
                joins.push(Join { kind: j.kind, cross: j.cross, natural: false, item: first_item.clone(), on, using: None });
            } else {
                joins.push(Join { kind: j.kind, cross: j.cross, natural: false, item: first_item.clone(), on: None, using: None });
                let mut sj = sub_joins.clone();
                sj.last_mut().unwrap().on = on;
                joins.extend(sj);
            }
        } else {
            joins.push(Join { kind: j.kind, cross: j.cross, natural: false, item: j.item.clone(), on, using: None });
        }
    }
    let first = if p == 0 {
        joins.splice(0..0, sub_joins.iter().cloned());
        first_item
    } else {
        from.first.clone()
    };
    if !left {
        if let Some(w) = sub_where {
            where_ = Some(match where_ {
                Some(c) => Expr::Binary(BinOp::And, Box::new(w), Box::new(c)),
                None => w,
            });
        }
    }
    let body = SelectBody {
        distinct: sel.distinct,
        columns,
        from: Some(From { first, joins }),
        where_,
        group_by,
        having,
        windows: Vec::new(),
    };
    Some((body, new_order))
}
