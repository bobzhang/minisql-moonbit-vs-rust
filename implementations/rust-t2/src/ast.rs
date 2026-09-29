// Abstract syntax tree.

use crate::value::Value;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum UnOp {
    Neg,
    Pos,
    Not,
    BitNot,
}

#[derive(Debug, Clone, Copy, PartialEq)]
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

impl BinOp {
    pub fn is_comparison(self) -> bool {
        matches!(
            self,
            BinOp::Eq
                | BinOp::Ne
                | BinOp::Lt
                | BinOp::Le
                | BinOp::Gt
                | BinOp::Ge
                | BinOp::Is
                | BinOp::IsNot
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum LikeOp {
    Like,
    Glob,
    Regexp,
    Match,
}

#[derive(Debug, Clone)]
pub enum Expr {
    Lit(Value),
    /// Column reference; `dq` marks a double-quoted bare name that may fall
    /// back to a string literal.
    Column {
        table: Option<String>,
        name: String,
        dq: bool,
    },
    Unary(UnOp, Box<Expr>),
    Binary(BinOp, Box<Expr>, Box<Expr>),
    IsNull(Box<Expr>),
    NotNull(Box<Expr>),
    Between {
        expr: Box<Expr>,
        lo: Box<Expr>,
        hi: Box<Expr>,
        not: bool,
    },
    InList {
        expr: Box<Expr>,
        list: Vec<Expr>,
        not: bool,
    },
    Like {
        op: LikeOp,
        expr: Box<Expr>,
        pattern: Box<Expr>,
        escape: Option<Box<Expr>>,
        not: bool,
    },
    Case {
        operand: Option<Box<Expr>>,
        whens: Vec<(Expr, Expr)>,
        else_: Option<Box<Expr>>,
    },
    Cast(Box<Expr>, String),
    Collate(Box<Expr>, String),
    Func {
        name: String,
        args: Vec<Expr>,
        distinct: bool,
        star: bool,
        filter: Option<Box<Expr>>,
        order_by: Vec<OrderTerm>,
        over: Option<Box<WindowSpec>>,
    },
    /// Scalar subquery `(SELECT ...)`.
    Subquery(Box<Select>),
    Exists(Box<Select>),
    InSelect {
        expr: Box<Expr>,
        query: Box<Select>,
        not: bool,
    },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ConflictAction {
    Rollback,
    Abort,
    Fail,
    Ignore,
    Replace,
}

/// A CHECK constraint with the text used in its error message (the
/// constraint name, or the expression's source text).
#[derive(Debug, Clone)]
pub struct CheckDef {
    pub expr: Expr,
    pub name: String,
}

#[derive(Debug, Clone)]
pub struct ColumnDef {
    pub name: String,
    pub type_name: String,
    pub primary_key: bool,
    pub pk_desc: bool,
    pub pk_conflict: Option<ConflictAction>,
    pub autoincrement: bool,
    pub not_null: bool,
    pub not_null_conflict: Option<ConflictAction>,
    pub unique: bool,
    pub unique_conflict: Option<ConflictAction>,
    pub checks: Vec<CheckDef>,
    pub default: Option<Expr>,
    pub collate: Option<String>,
    /// Source text of the definition (ALTER TABLE ADD COLUMN).
    pub text: String,
}

#[derive(Debug, Clone)]
pub enum TableConstraint {
    PrimaryKey(Vec<IndexedColumn>, Option<ConflictAction>, bool),
    Unique(Vec<IndexedColumn>, Option<ConflictAction>),
    Check(CheckDef),
    ForeignKey,
}

#[derive(Debug, Clone)]
pub struct IndexedColumn {
    pub expr: Expr,
    pub collate: Option<String>,
    pub desc: bool,
}

#[derive(Debug, Clone)]
pub struct CreateTable {
    pub name: String,
    pub sql: String,
    pub if_not_exists: bool,
    pub columns: Vec<ColumnDef>,
    pub constraints: Vec<TableConstraint>,
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
    Update {
        sets: Vec<(String, Expr)>,
        where_: Option<Expr>,
    },
}

#[derive(Debug, Clone)]
pub struct Upsert {
    pub target: Option<Vec<IndexedColumn>>,
    pub action: UpsertAction,
}

#[derive(Debug, Clone)]
pub struct Insert {
    pub with: Option<Box<With>>,
    pub table: String,
    pub alias: Option<String>,
    pub or_action: Option<ConflictAction>,
    pub columns: Option<Vec<String>>,
    pub source: InsertSource,
    pub upsert: Vec<Upsert>,
    pub returning: Option<Vec<ResultCol>>,
}

#[derive(Debug, Clone)]
pub struct Update {
    pub with: Option<Box<With>>,
    pub table: String,
    pub alias: Option<String>,
    pub or_action: Option<ConflictAction>,
    pub sets: Vec<(String, Expr)>,
    pub where_: Option<Expr>,
    pub returning: Option<Vec<ResultCol>>,
}

#[derive(Debug, Clone)]
pub struct Delete {
    pub with: Option<Box<With>>,
    pub table: String,
    pub alias: Option<String>,
    pub where_: Option<Expr>,
    pub returning: Option<Vec<ResultCol>>,
}

#[derive(Debug, Clone)]
pub enum ResultCol {
    Star,
    TableStar(String),
    /// Expression, optional alias, and the expression's source text.
    Expr(Expr, Option<String>, String),
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum JoinKind {
    Inner,
    Left,
    Right,
    Full,
}

#[derive(Debug, Clone)]
pub enum TableRef {
    Table {
        name: String,
        alias: Option<String>,
    },
    Subquery {
        query: Box<Select>,
        alias: Option<String>,
    },
}

/// One FROM item with the join operator that attaches it to the items
/// before it (the first item's join fields are unused).
#[derive(Debug, Clone)]
pub struct JoinTerm {
    pub source: TableRef,
    pub kind: JoinKind,
    pub natural: bool,
    pub on: Option<Expr>,
    pub using: Option<Vec<String>>,
}

#[derive(Debug, Clone)]
pub struct OrderTerm {
    pub expr: Expr,
    pub desc: bool,
    /// Some(true) = NULLS FIRST, Some(false) = NULLS LAST.
    pub nulls_first: Option<bool>,
}

#[derive(Debug, Clone)]
pub struct SelectCore {
    pub distinct: bool,
    pub columns: Vec<ResultCol>,
    pub from: Vec<JoinTerm>,
    pub where_: Option<Expr>,
    pub group_by: Vec<Expr>,
    pub having: Option<Expr>,
    /// Named window definitions (WINDOW clause).
    pub windows: Vec<(String, WindowSpec)>,
}

/// A window definition: `OVER name` (bare) or `OVER ([base] PARTITION BY
/// ... ORDER BY ... frame)`.
#[derive(Debug, Clone, Default)]
pub struct WindowSpec {
    pub base: Option<String>,
    pub bare: bool,
    pub partition: Vec<Expr>,
    pub order: Vec<OrderTerm>,
    pub frame: Option<FrameSpec>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum FrameUnit {
    Rows,
    Range,
    Groups,
}

#[derive(Debug, Clone)]
pub enum FrameBound {
    UnboundedPreceding,
    Preceding(Expr),
    CurrentRow,
    Following(Expr),
    UnboundedFollowing,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum FrameExclude {
    NoOthers,
    CurrentRow,
    Group,
    Ties,
}

#[derive(Debug, Clone)]
pub struct FrameSpec {
    pub unit: FrameUnit,
    pub start: FrameBound,
    pub end: FrameBound,
    pub exclude: FrameExclude,
}

/// One common table expression of a WITH clause.
#[derive(Debug, Clone)]
pub struct Cte {
    pub name: String,
    pub columns: Option<Vec<String>>,
    pub query: Select,
}

#[derive(Debug, Clone)]
pub struct With {
    pub ctes: Vec<Cte>,
}

#[derive(Debug, Clone)]
pub enum Core {
    Select(SelectCore),
    Values(Vec<Vec<Expr>>),
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SetOp {
    Union,
    UnionAll,
    Intersect,
    Except,
}

/// A full query: one or more cores joined by compound operators, with
/// ORDER BY / LIMIT applying to the whole.
#[derive(Debug, Clone)]
pub struct Select {
    pub with: Option<Box<With>>,
    pub cores: Vec<Core>,
    pub ops: Vec<SetOp>,
    pub order_by: Vec<OrderTerm>,
    pub limit: Option<Expr>,
    pub offset: Option<Expr>,
}

#[derive(Debug, Clone)]
pub enum Stmt {
    CreateTable(CreateTable),
    DropTable {
        name: String,
        if_exists: bool,
    },
    Insert(Insert),
    Update(Update),
    Delete(Delete),
    Select(Select),
    CreateIndex(CreateIndex),
    DropIndex {
        name: String,
        if_exists: bool,
    },
    CreateView(CreateView),
    DropView {
        name: String,
        if_exists: bool,
    },
    AlterTable {
        table: String,
        action: AlterAction,
    },
    Begin,
    Commit,
    /// ROLLBACK, or ROLLBACK TO a savepoint.
    Rollback(Option<String>),
    Savepoint(String),
    Release(String),
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
    pub columns: Option<Vec<String>>,
    pub query: Select,
    pub sql: String,
}

#[derive(Debug, Clone)]
pub enum AlterAction {
    RenameTable(String),
    RenameColumn(String, String),
    AddColumn(ColumnDef),
    DropColumn(String),
}
