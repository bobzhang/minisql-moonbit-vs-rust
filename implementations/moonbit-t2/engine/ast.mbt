///|
pub(all) enum BinOp {
  Add
  Sub
  Mul
  Div
  Rem
  Concat
  Eq
  Ne
  Lt
  Le
  Gt
  Ge
  And
  Or
  BitAnd
  BitOr
  Shl
  Shr
} derive(Eq)

///|
pub(all) enum UnOp {
  Neg
  Pos
  BitNot
  Not
} derive(Eq)

///|
pub(all) enum Expr {
  Lit(Value)
  /// Unresolved column reference; `dq` marks a double-quoted bare name.
  Col(tbl~ : String?, name~ : String, dq~ : Bool)
  /// Resolved column: `depth` scopes up, slot `idx` in that scope's row.
  Slot(depth~ : Int, idx~ : Int, aff~ : Affinity, coll~ : String?)
  Unary(UnOp, Expr)
  Binary(BinOp, Expr, Expr)
  IsNull(Expr, Bool) // negated when true
  Is(Expr, Expr, Bool) // IS / IS NOT
  Between(Expr, Expr, Expr, Bool)
  InList(Expr, Array[Expr], Bool)
  Like(String, Expr, Expr, Expr?, Bool) // op (LIKE/GLOB/...), lhs, pattern, escape, negated
  Func(
    name~ : String,
    args~ : Array[Expr],
    distinct~ : Bool,
    star~ : Bool,
    filter~ : Expr?,
    order~ : Array[OrderTerm]
  )
  /// Result of an aggregate, stored at slot `idx` of the group row; `coll`
  /// is an explicit collation propagated from the arguments.
  AggRef(depth~ : Int, idx~ : Int, coll~ : String?)
  Case(Expr?, Array[(Expr, Expr)], Expr?)
  Cast(Expr, String)
  Collate(Expr, String)
  /// Unbound subqueries: scalar, EXISTS, and `x [NOT] IN (SELECT ...)`.
  Subquery(Select)
  Exists(Select)
  InSelect(Expr, Select, Bool)
  /// Bound subqueries.
  ScalarQ(SubQuery)
  ExistsQ(SubQuery)
  InQ(Expr, SubQuery, Bool)
  /// A window function call: the `Func` and its OVER clause.
  WinFunc(Expr, WindowSpec)
}

///|
/// Frame boundary of a window.
pub(all) enum FrameBound {
  UnboundedPreceding
  Preceding(Expr)
  CurrentRow
  Following(Expr)
  UnboundedFollowing
}

///|
pub(all) enum FrameUnit {
  FRows
  FRange
  FGroups
} derive(Eq)

///|
pub(all) enum FrameExclude {
  ExNoOthers
  ExCurrentRow
  ExGroup
  ExTies
} derive(Eq)

///|
pub(all) struct Frame {
  unit : FrameUnit
  start : FrameBound
  end : FrameBound
  exclude : FrameExclude
}

///|
/// A window definition: an optional base window name, PARTITION BY,
/// ORDER BY and frame.
pub(all) struct WindowSpec {
  base : String?
  partition : Array[Expr]
  order : Array[OrderTerm]
  frame : Frame?
  /// `OVER name` (the named window as is).
  named_only : Bool
}

///|
/// A common table expression of a WITH clause.
pub(all) struct CteDecl {
  name : String
  cols : Array[String]?
  query : Select
}

///|
/// A prepared subquery used inside an expression.
pub(all) struct SubQuery {
  /// Runs the query; the argument is the environment of the enclosing query.
  run : (Env) -> Array[Array[Value]] raise SqlError
  correlated : Bool
  /// Affinity and collation of the first result column.
  aff : Affinity?
  coll : (String, Bool)?
  mut cache : Array[Array[Value]]?
  /// IN lookup set (keys of non-NULL values) and whether a NULL was seen.
  mut in_keys : Set[String]?
  mut in_null : Bool
}

///|
pub(all) enum ResultCol {
  Star
  TableStar(String)
  /// Expression, alias, and source text (the default column name).
  ExprCol(Expr, String?, String)
}

///|
pub(all) struct OrderTerm {
  expr : Expr
  desc : Bool
  nulls : Int // 0 default, 1 first, 2 last
}

///|
pub(all) enum JoinKind {
  JInner
  JLeft
  JRight
  JFull
} derive(Eq)

///|
pub(all) enum FromItem {
  TableRef(name~ : String, as_name~ : String?)
  SubqueryRef(query~ : Select, as_name~ : String?)
  Join(
    left~ : FromItem,
    right~ : FromItem,
    kind~ : JoinKind,
    natural~ : Bool,
    on~ : Expr?,
    using_cols~ : Array[String]?
  )
}

///|
pub(all) enum CompoundOp {
  UnionAll
  Union
  Intersect
  Except
} derive(Eq)

///|
fn CompoundOp::label(self : CompoundOp) -> String {
  match self {
    UnionAll => "UNION ALL"
    Union => "UNION"
    Intersect => "INTERSECT"
    Except => "EXCEPT"
  }
}

///|
pub(all) struct Select {
  distinct : Bool
  columns : Array[ResultCol]
  from : FromItem?
  where_ : Expr?
  group_by : Array[Expr]
  having : Expr?
  /// Rows of a `VALUES` core (the other core fields are then unused).
  values : Array[Array[Expr]]?
  /// Further cores of a compound query, applied left to right.
  compound : Array[(CompoundOp, Select)]
  order_by : Array[OrderTerm]
  limit : Expr?
  offset : Expr?
  /// Common table expressions of a leading WITH clause.
  with_ : Array[CteDecl]
  /// Named windows of the WINDOW clause (of this core).
  windows : Array[(String, WindowSpec)]
}

///|
/// Conflict resolution algorithm.
pub(all) enum Conflict {
  CDefault
  CRollback
  CAbort
  CFail
  CIgnore
  CReplace
} derive(Eq)

///|
pub(all) struct CheckDef {
  expr : Expr
  name : String?
  text : String
}

///|
pub(all) struct ColumnDef {
  name : String
  decl_type : String
  mut primary_key : Bool
  mut pk_desc : Bool
  mut pk_conflict : Conflict
  mut autoincrement : Bool
  mut not_null : Bool
  mut nn_conflict : Conflict
  mut unique : Bool
  mut unique_conflict : Conflict
  mut default : Expr?
  checks : Array[CheckDef]
  mut collate : String?
}

///|
pub(all) enum TableConstraint {
  PrimaryKey(Array[String], Conflict, Bool) // columns, conflict, autoincrement
  Unique(Array[String], Conflict)
  Check(CheckDef)
  ForeignKey
}

///|
pub(all) struct CreateTable {
  name : String
  if_not_exists : Bool
  columns : Array[ColumnDef]
  constraints : Array[TableConstraint]
  sql : String
}

///|
pub(all) enum InsertSource {
  Values(Array[Array[Expr]])
  FromSelect(Select)
  DefaultValues
}

///|
pub(all) enum UpsertAction {
  DoNothing
  DoUpdate(Array[(String, Expr)], Expr?)
}

///|
pub(all) struct Upsert {
  target : Array[String]? // conflict target columns
  target_where : Expr?
  action : UpsertAction
}

///|
pub(all) struct Insert {
  or_conflict : Conflict
  table : String
  as_name : String?
  columns : Array[String]?
  source : InsertSource
  upsert : Array[Upsert]
  returning : Array[ResultCol]
}

///|
pub(all) struct Update {
  or_conflict : Conflict
  table : String
  as_name : String?
  sets : Array[(String, Expr)]
  where_ : Expr?
  returning : Array[ResultCol]
}

///|
pub(all) struct Delete {
  table : String
  as_name : String?
  where_ : Expr?
  returning : Array[ResultCol]
}

///|
/// One key part of an index: a column or expression (unbound), an explicit
/// collation and the sort direction.
pub(all) struct IndexPart {
  expr : Expr
  coll : String?
  desc : Bool
}

///|
pub(all) struct CreateIndex {
  name : String
  table : String
  unique : Bool
  if_not_exists : Bool
  parts : Array[IndexPart]
  where_ : Expr?
  sql : String
}

///|
pub(all) struct CreateView {
  name : String
  if_not_exists : Bool
  cols : Array[String]?
  query : Select
  sql : String
}

///|
pub(all) enum AlterAction {
  RenameTo(String)
  RenameColumn(String, String)
  AddColumn(ColumnDef, String) // definition and its source text
  DropColumn(String)
}

///|
pub(all) enum Stmt {
  CreateTableStmt(CreateTable)
  DropTableStmt(String, Bool)
  CreateIndexStmt(CreateIndex)
  DropIndexStmt(String, Bool)
  CreateViewStmt(CreateView)
  DropViewStmt(String, Bool)
  AlterStmt(String, AlterAction)
  BeginStmt
  CommitStmt
  RollbackStmt(String?) // ROLLBACK [TO savepoint]
  SavepointStmt(String)
  ReleaseStmt(String)
  InsertStmt(Insert)
  UpdateStmt(Update)
  DeleteStmt(Delete)
  SelectStmt(Select)
  /// A data-modifying statement with a leading WITH clause.
  WithStmt(Array[CteDecl], Stmt)
}
