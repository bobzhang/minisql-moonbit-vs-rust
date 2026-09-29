// Abstract syntax tree.

use std::cell::RefCell;
use std::rc::Rc;

use crate::query::{QueryPlan, SubResult};
use crate::value::{Affinity, Collation, Value};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnOp {
    Neg,
    Pos,
    Not,
    BitNot,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    Concat,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    And,
    Or,
    BitAnd,
    BitOr,
    Shl,
    Shr,
    /// `IS` / `IS NOT DISTINCT FROM`.
    Is,
    /// `IS NOT` / `IS DISTINCT FROM`.
    IsNot,
}

impl BinOp {
    pub fn is_comparison(self) -> bool {
        matches!(self, BinOp::Eq | BinOp::Ne | BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge | BinOp::Is | BinOp::IsNot)
    }
}

/// How a comparison is performed: the affinity applied to both operands
/// (None = no conversion) and the collating sequence.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CmpInfo {
    pub aff: Option<Affinity>,
    pub coll: Collation,
}

impl Default for CmpInfo {
    fn default() -> Self {
        CmpInfo { aff: None, coll: Collation::Binary }
    }
}

#[derive(Clone, Debug)]
pub enum Expr {
    Lit(Value),
    /// Unresolved column reference. `dq` marks a lone double-quoted
    /// identifier that falls back to a string literal.
    Column {
        table: Option<String>,
        name: String,
        dq: bool,
    },
    /// Resolved column: index into the current row.
    Col {
        idx: usize,
        aff: Affinity,
        coll: Collation,
    },
    Unary(UnOp, Box<Expr>),
    Binary(BinOp, Box<Expr>, Box<Expr>),
    /// Bound comparison (produced by `bind` from a comparison `Binary`).
    Compare {
        op: BinOp,
        l: Box<Expr>,
        r: Box<Expr>,
        info: CmpInfo,
    },
    /// `x IS NULL` (negated: `x IS NOT NULL`).
    IsNull(Box<Expr>, bool),
    /// `x COLLATE name`.
    Collate(Box<Expr>, String),
    Func {
        name: String,
        args: Vec<Expr>,
        star: bool,
        distinct: bool,
        /// Collation for functions that compare their arguments (bound).
        coll: Collation,
        /// Aggregate `FILTER (WHERE ...)`.
        filter: Option<Box<Expr>>,
        /// Aggregate `ORDER BY` inside the argument list.
        order_by: Vec<OrderTerm>,
    },
    /// Result of aggregate number `idx - base` in a post-aggregation row
    /// (read from `row[idx]`), with the aggregate's collation.
    AggRef {
        idx: usize,
        coll: Option<Collation>,
    },
    Cast(Box<Expr>, Affinity),
    Case {
        base: Option<Box<Expr>>,
        whens: Vec<(Expr, Expr)>,
        else_: Option<Box<Expr>>,
        /// Per-WHEN comparison info for the simple form (bound).
        infos: Vec<CmpInfo>,
    },
    Between {
        e: Box<Expr>,
        lo: Box<Expr>,
        hi: Box<Expr>,
        neg: bool,
        info_lo: CmpInfo,
        info_hi: CmpInfo,
    },
    InList {
        e: Box<Expr>,
        list: Vec<Expr>,
        neg: bool,
        info: CmpInfo,
    },
    Like {
        e: Box<Expr>,
        pat: Box<Expr>,
        esc: Option<Box<Expr>>,
        neg: bool,
        glob: bool,
    },
    /// Unbound scalar subquery `(SELECT ...)`.
    Subquery(Box<Select>),
    /// Unbound `EXISTS (SELECT ...)`.
    Exists(Box<Select>),
    /// Unbound `e [NOT] IN (SELECT ...)`.
    InSelect { e: Box<Expr>, query: Box<Select>, neg: bool },
    /// Bound reference into the row of an enclosing query `up` levels out;
    /// `inner` (a `Col` or `AggRef`) is evaluated against that row.
    Outer { up: usize, inner: Box<Expr> },
    /// Bound subquery.
    SubPlan {
        kind: SubKind,
        plan: Rc<QueryPlan>,
        /// References columns of an enclosing query (no caching).
        correlated: bool,
        /// Result of an uncorrelated subquery, computed once.
        cache: Rc<RefCell<Option<SubResult>>>,
    },
    /// Unbound window function call: `func` is an `Expr::Func`.
    Window { func: Box<Expr>, over: Box<Over> },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameUnit {
    Rows,
    Range,
    Groups,
}

#[derive(Clone, Debug)]
pub enum FrameBound {
    UnboundedPreceding,
    Preceding(Box<Expr>),
    CurrentRow,
    Following(Box<Expr>),
    UnboundedFollowing,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Exclude {
    NoOthers,
    CurrentRow,
    Group,
    Ties,
}

#[derive(Clone, Debug)]
pub struct Frame {
    pub unit: FrameUnit,
    pub start: FrameBound,
    pub end: FrameBound,
    pub exclude: Exclude,
}

/// A window definition: `[base] [PARTITION BY ...] [ORDER BY ...] [frame]`.
#[derive(Clone, Debug, Default)]
pub struct WindowDef {
    pub base: Option<String>,
    pub partition: Vec<Expr>,
    pub order: Vec<OrderTerm>,
    pub frame: Option<Frame>,
}

#[derive(Clone, Debug)]
pub enum Over {
    Named(String),
    Spec(WindowDef),
}

#[derive(Clone, Debug)]
pub enum SubKind {
    Scalar,
    Exists,
    In { e: Box<Expr>, neg: bool, info: CmpInfo },
}

#[derive(Clone, Debug)]
pub enum ResultCol {
    Star,
    TableStar(String),
    /// `span` is the expression's source text (the default column name).
    Expr { expr: Expr, alias: Option<String>, span: String },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JoinKind {
    Inner,
    Left,
    Right,
    Full,
}

#[derive(Clone, Debug)]
pub enum TableSource {
    Table { name: String, alias: Option<String> },
    Subquery { query: Box<Select>, alias: Option<String> },
}

/// One FROM-clause item with the join operator that attaches it to the
/// items before it (ignored for the first item).
#[derive(Clone, Debug)]
pub struct FromTerm {
    pub source: TableSource,
    pub join: JoinKind,
    pub natural: bool,
    pub on: Option<Expr>,
    pub using: Option<Vec<String>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CompoundOp {
    Union,
    UnionAll,
    Intersect,
    Except,
}

impl CompoundOp {
    pub fn name(self) -> &'static str {
        match self {
            CompoundOp::Union => "UNION",
            CompoundOp::UnionAll => "UNION ALL",
            CompoundOp::Intersect => "INTERSECT",
            CompoundOp::Except => "EXCEPT",
        }
    }
}

#[derive(Clone, Debug)]
pub struct SelectCore {
    pub distinct: bool,
    pub columns: Vec<ResultCol>,
    pub from: Vec<FromTerm>,
    pub where_: Option<Expr>,
    pub group_by: Vec<Expr>,
    pub having: Option<Expr>,
    /// `WINDOW name AS (...)` definitions.
    pub windows: Vec<(String, WindowDef)>,
}

#[derive(Clone, Debug)]
pub enum Core {
    Select(SelectCore),
    Values(Vec<Vec<Expr>>),
}

#[derive(Clone, Debug)]
pub struct OrderTerm {
    pub expr: Expr,
    pub desc: bool,
    /// Some(true) = NULLS FIRST, Some(false) = NULLS LAST.
    pub nulls_first: Option<bool>,
}

/// A query: one core or a left-associative compound chain, with ORDER BY
/// and LIMIT applying to the whole.
#[derive(Clone, Debug)]
pub struct Select {
    pub with: Option<Box<With>>,
    pub first: Core,
    pub rest: Vec<(CompoundOp, Core)>,
    pub order_by: Vec<OrderTerm>,
    pub limit: Option<Expr>,
    pub offset: Option<Expr>,
}

#[derive(Clone, Debug)]
pub struct Cte {
    pub name: String,
    pub cols: Option<Vec<String>>,
    pub select: Box<Select>,
}

#[derive(Clone, Debug)]
pub struct With {
    pub recursive: bool,
    pub ctes: Vec<Cte>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Conflict {
    Rollback,
    Abort,
    Fail,
    Ignore,
    Replace,
}

#[derive(Clone, Debug)]
pub struct IndexedCol {
    pub expr: Expr,
    pub collate: Option<String>,
    pub desc: bool,
}

#[derive(Clone, Debug)]
pub struct ForeignKey {
    pub table: String,
    pub columns: Vec<String>,
}

#[derive(Clone, Debug)]
pub enum ColumnConstraint {
    PrimaryKey { desc: bool, conflict: Option<Conflict>, autoincrement: bool },
    NotNull { conflict: Option<Conflict> },
    Null,
    Unique { conflict: Option<Conflict> },
    Check(Expr),
    Default(Expr),
    Collate(String),
    References(ForeignKey),
    Generated { expr: Expr, stored: bool },
}

#[derive(Clone, Debug)]
pub struct ColumnDef {
    pub name: String,
    pub type_name: String,
    pub constraints: Vec<ColumnConstraint>,
}

#[derive(Clone, Debug)]
pub enum TableConstraint {
    PrimaryKey { cols: Vec<IndexedCol>, conflict: Option<Conflict>, autoincrement: bool },
    Unique { cols: Vec<IndexedCol>, conflict: Option<Conflict> },
    Check(Expr),
    ForeignKey { cols: Vec<String>, fk: ForeignKey },
}

#[derive(Clone, Debug)]
pub struct CreateTable {
    pub name: String,
    pub if_not_exists: bool,
    pub columns: Vec<ColumnDef>,
    pub constraints: Vec<TableConstraint>,
}

#[derive(Clone, Debug)]
pub enum InsertSource {
    Values(Vec<Vec<Expr>>),
    Select(Box<Select>),
    Default,
}

#[derive(Clone, Debug)]
pub struct Insert {
    pub with: Option<Box<With>>,
    pub or: Option<Conflict>,
    pub table: String,
    pub alias: Option<String>,
    pub columns: Option<Vec<String>>,
    pub source: InsertSource,
    pub upserts: Vec<Upsert>,
    pub returning: Option<Vec<ResultCol>>,
}

#[derive(Clone, Debug)]
pub enum UpsertAction {
    Nothing,
    Update { sets: Vec<(String, Expr)>, where_: Option<Expr> },
}

#[derive(Clone, Debug)]
pub struct Upsert {
    /// Conflict target columns (None = any constraint).
    pub target: Option<Vec<IndexedCol>>,
    pub target_where: Option<Expr>,
    pub action: UpsertAction,
}

#[derive(Clone, Debug)]
pub struct Update {
    pub with: Option<Box<With>>,
    pub or: Option<Conflict>,
    pub table: String,
    pub alias: Option<String>,
    pub sets: Vec<(String, Expr)>,
    pub where_: Option<Expr>,
    pub returning: Option<Vec<ResultCol>>,
}

#[derive(Clone, Debug)]
pub struct Delete {
    pub with: Option<Box<With>>,
    pub table: String,
    pub alias: Option<String>,
    pub where_: Option<Expr>,
    pub returning: Option<Vec<ResultCol>>,
}

#[derive(Clone, Debug)]
pub enum Stmt {
    Select(Box<Select>),
    CreateTable(CreateTable),
    DropTable { name: String, if_exists: bool },
    Insert(Insert),
    Update(Update),
    Delete(Delete),
    CreateIndex(CreateIndex),
    DropIndex { name: String, if_exists: bool },
    CreateView(CreateView),
    DropView { name: String, if_exists: bool },
    Alter { table: String, action: AlterAction },
    Begin,
    Commit,
    Rollback,
    Savepoint(String),
    Release(String),
    RollbackTo(String),
}

#[derive(Clone, Debug)]
pub struct CreateIndex {
    pub name: String,
    pub table: String,
    pub unique: bool,
    pub if_not_exists: bool,
    pub cols: Vec<IndexedCol>,
    pub where_: Option<Expr>,
}

#[derive(Clone, Debug)]
pub struct CreateView {
    pub name: String,
    pub if_not_exists: bool,
    pub cols: Option<Vec<String>>,
    pub select: Select,
}

#[derive(Clone, Debug)]
pub enum AlterAction {
    RenameTable(String),
    RenameColumn(String, String),
    AddColumn(ColumnDef),
    DropColumn(String),
}
