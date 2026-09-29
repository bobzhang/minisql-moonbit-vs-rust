// Abstract syntax tree.
#![allow(dead_code)] // constraint details are parsed now and enforced in later milestones

use std::rc::Rc;

use crate::value::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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
    Is,
    IsNot,
    And,
    Or,
    BitAnd,
    BitOr,
    Shl,
    Shr,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnOp {
    Neg,
    Pos,
    Not,
    BitNot,
}

#[derive(Debug, Clone)]
pub enum Expr {
    Literal(Value),
    /// Column reference. `dq` is set for an unqualified "double-quoted" name,
    /// which falls back to a string literal if no column matches.
    Column { table: Option<String>, name: String, dq: bool },
    Unary(UnOp, Box<Expr>),
    Binary(BinOp, Box<Expr>, Box<Expr>),
    /// `expr IS NULL` (negated: `IS NOT NULL`).
    IsNull(Box<Expr>, bool),
    Function(Box<FuncCall>),
    /// Reference to the result of the i-th aggregate of the enclosing query
    /// (produced internally when an aggregate query is planned).
    AggRef(usize),
    Case { base: Option<Box<Expr>>, whens: Vec<(Expr, Expr)>, else_: Option<Box<Expr>> },
    Cast(Box<Expr>, String),
    Collate(Box<Expr>, String),
    Between { e: Box<Expr>, lo: Box<Expr>, hi: Box<Expr>, not: bool },
    InList { e: Box<Expr>, list: Vec<Expr>, not: bool },
    /// `e LIKE/GLOB/REGEXP/MATCH pattern [ESCAPE esc]`; `op` is the function name.
    Like { op: String, e: Box<Expr>, pattern: Box<Expr>, escape: Option<Box<Expr>>, not: bool },
    /// Scalar subquery `(SELECT ...)`.
    Subquery(Box<Select>),
    /// `EXISTS (SELECT ...)`.
    Exists(Box<Select>),
    /// `e [NOT] IN (SELECT ...)`.
    InSelect { e: Box<Expr>, query: Box<Select>, not: bool },
    /// Column `col` of FROM source `src` of the current query, as produced
    /// by `*` expansion (internal).
    SourceCol { src: usize, col: usize },
    /// Reference to the result of the i-th window function of the enclosing
    /// query (internal).
    WinRef(usize),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameUnit {
    Rows,
    Range,
    Groups,
}

#[derive(Debug, Clone)]
pub enum FrameBound {
    UnboundedPreceding,
    Preceding(Box<Expr>),
    CurrentRow,
    Following(Box<Expr>),
    UnboundedFollowing,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Exclude {
    NoOthers,
    CurrentRow,
    Group,
    Ties,
}

#[derive(Debug, Clone)]
pub struct Frame {
    pub unit: FrameUnit,
    pub start: FrameBound,
    pub end: FrameBound,
    pub exclude: Exclude,
}

/// A window definition: `OVER name` or `OVER ([base] PARTITION BY ...
/// ORDER BY ... frame)`.
#[derive(Debug, Clone, Default)]
pub struct WindowSpec {
    pub base: Option<String>,
    /// Written in parentheses (`OVER (w ...)` rather than `OVER w`).
    pub paren: bool,
    pub partition: Vec<Expr>,
    pub order: Vec<OrderTerm>,
    pub frame: Option<Frame>,
}

/// One common table expression of a WITH clause.
#[derive(Debug, Clone)]
pub struct Cte {
    pub name: String,
    pub columns: Option<Vec<String>>,
    pub select: Select,
}

#[derive(Debug, Clone)]
pub struct With {
    pub ctes: Vec<Cte>,
}

#[derive(Debug, Clone)]
pub struct FuncCall {
    pub name: String,
    pub args: Vec<Expr>,
    pub star: bool,
    pub distinct: bool,
    pub order_by: Vec<OrderTerm>,
    pub filter: Option<Expr>,
    pub over: Option<Box<WindowSpec>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Conflict {
    Rollback,
    Abort,
    Fail,
    Ignore,
    Replace,
}

#[derive(Debug, Clone)]
pub struct ForeignKey {
    pub table: String,
    pub columns: Vec<String>,
}

#[derive(Debug, Clone)]
pub enum ColumnConstraint {
    PrimaryKey { desc: bool, conflict: Option<Conflict>, autoincrement: bool },
    NotNull(Option<Conflict>),
    Unique(Option<Conflict>),
    Check(Expr, String),
    Default(Expr),
    Collate(String),
    References(ForeignKey),
    Generated { expr: Expr, stored: bool },
}

#[derive(Debug, Clone)]
pub struct ColumnDef {
    pub name: String,
    pub type_name: Option<String>,
    pub constraints: Vec<ColumnConstraint>,
}

#[derive(Debug, Clone)]
pub struct IndexedColumn {
    pub expr: Expr,
    pub collate: Option<String>,
    pub desc: bool,
}

#[derive(Debug, Clone)]
pub enum TableConstraint {
    PrimaryKey { columns: Vec<IndexedColumn>, conflict: Option<Conflict>, autoincrement: bool },
    Unique { columns: Vec<IndexedColumn>, conflict: Option<Conflict> },
    Check(Expr, String),
    ForeignKey { columns: Vec<String>, fk: ForeignKey },
}

#[derive(Debug, Clone)]
pub struct CreateTable {
    pub name: String,
    pub if_not_exists: bool,
    pub temp: bool,
    pub columns: Vec<ColumnDef>,
    pub constraints: Vec<TableConstraint>,
    pub sql: String,
}

#[derive(Debug, Clone)]
pub enum InsertSource {
    Values(Vec<Vec<Expr>>),
    Select(Box<Select>),
    Default,
}

#[derive(Debug, Clone)]
pub enum UpsertAction {
    Nothing,
    Update { sets: Vec<(String, Expr)>, where_: Option<Expr> },
}

#[derive(Debug, Clone)]
pub struct Upsert {
    pub target: Option<Vec<IndexedColumn>>,
    pub action: UpsertAction,
}

#[derive(Debug, Clone)]
pub struct Insert {
    pub with: Option<Rc<With>>,
    pub or: Option<Conflict>,
    pub table: String,
    pub alias: Option<String>,
    pub columns: Option<Vec<String>>,
    pub source: InsertSource,
    pub upserts: Vec<Upsert>,
    pub returning: Vec<ResultColumn>,
}

#[derive(Debug, Clone)]
pub struct Update {
    pub with: Option<Rc<With>>,
    pub or: Option<Conflict>,
    pub table: String,
    pub alias: Option<String>,
    pub sets: Vec<(String, Expr)>,
    pub where_: Option<Expr>,
    pub returning: Vec<ResultColumn>,
}

#[derive(Debug, Clone)]
pub struct Delete {
    pub with: Option<Rc<With>>,
    pub table: String,
    pub alias: Option<String>,
    pub where_: Option<Expr>,
    pub returning: Vec<ResultColumn>,
}

#[derive(Debug, Clone)]
pub enum ResultColumn {
    Star,
    TableStar(String),
    /// Expression, alias and the expression's source text.
    Expr(Expr, Option<String>, String),
}

#[derive(Debug, Clone)]
pub enum TableItem {
    Table { name: String, alias: Option<String> },
    Subquery { query: Box<Select>, alias: Option<String> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JoinKind {
    Inner,
    Left,
    Right,
    Full,
}

#[derive(Debug, Clone)]
pub struct Join {
    pub kind: JoinKind,
    /// Written as CROSS JOIN (the planner keeps the order).
    pub cross: bool,
    pub natural: bool,
    pub item: TableItem,
    pub on: Option<Expr>,
    pub using: Option<Vec<String>>,
}

#[derive(Debug, Clone)]
pub struct From {
    pub first: TableItem,
    pub joins: Vec<Join>,
}

#[derive(Debug, Clone)]
pub struct OrderTerm {
    pub expr: Expr,
    pub desc: bool,
    /// Explicit NULLS FIRST (true) / NULLS LAST (false).
    pub nulls_first: Option<bool>,
}

#[derive(Debug, Clone)]
pub struct SelectBody {
    pub distinct: bool,
    pub columns: Vec<ResultColumn>,
    pub from: Option<From>,
    pub where_: Option<Expr>,
    pub group_by: Vec<Expr>,
    pub having: Option<Expr>,
    /// Named windows of the WINDOW clause.
    pub windows: Vec<(String, WindowSpec)>,
}

#[derive(Debug, Clone)]
pub enum SelectCore {
    Select(SelectBody),
    Values(Vec<Vec<Expr>>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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

/// A complete query: one or more cores joined by compound operators, with
/// ORDER BY / LIMIT applying to the whole.
#[derive(Debug, Clone)]
pub struct Select {
    pub with: Option<Rc<With>>,
    pub cores: Vec<SelectCore>,
    pub ops: Vec<CompoundOp>,
    pub order_by: Vec<OrderTerm>,
    pub limit: Option<Expr>,
    pub offset: Option<Expr>,
}

#[derive(Debug, Clone)]
pub struct CreateIndex {
    pub name: String,
    pub table: String,
    pub unique: bool,
    pub if_not_exists: bool,
    pub columns: Vec<IndexedColumn>,
    pub where_: Option<Expr>,
    pub sql: String,
}

#[derive(Debug, Clone)]
pub struct CreateView {
    pub name: String,
    pub if_not_exists: bool,
    pub temp: bool,
    pub columns: Option<Vec<String>>,
    pub select: Select,
    pub sql: String,
}

#[derive(Debug, Clone)]
pub enum AlterAction {
    RenameTable(String),
    RenameColumn(String, String),
    /// Column definition and its source text.
    AddColumn(ColumnDef, String),
    DropColumn(String),
}

#[derive(Debug, Clone)]
pub enum Stmt {
    CreateTable(CreateTable),
    DropTable { name: String, if_exists: bool },
    CreateIndex(CreateIndex),
    DropIndex { name: String, if_exists: bool },
    CreateView(CreateView),
    DropView { name: String, if_exists: bool },
    AlterTable { table: String, action: AlterAction },
    Begin,
    Commit,
    /// ROLLBACK, or ROLLBACK TO a savepoint.
    Rollback(Option<String>),
    Savepoint(String),
    Release(String),
    Insert(Insert),
    Update(Update),
    Delete(Delete),
    Select(Select),
}
