///|
pub(all) enum UnOp {
  Neg
  Pos
  Not
  BitNot
} derive(Debug, Eq)

///|
pub(all) enum BinOp {
  Add
  Sub
  Mul
  Div
  Mod
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
  Is
  IsNot
} derive(Debug, Eq)

///|
pub(all) enum Expr {
  Lit(Value)
  /// Column reference: optional table qualifier, column name, and whether
  /// the name was a bare double-quoted token (may fall back to a string).
  Column(String?, String, Bool)
  Unary(UnOp, Expr)
  Binary(BinOp, Expr, Expr)
  /// IS NULL (false) / NOT NULL (true)
  IsNull(Expr, Bool)
  Between(Expr, Expr, Expr, Bool)
  InList(Expr, Array[Expr], Bool)
  InSelect(Expr, Select, Bool)
  /// op name ("LIKE", "GLOB", ...), lhs, pattern, escape, negated
  Like(String, Expr, Expr, Expr?, Bool)
  Case(Expr?, Array[(Expr, Expr)], Expr?)
  Cast(Expr, String)
  Collate(Expr, String)
  Func(FuncCall)
  Exists(Select, Bool)
  Subquery(Select)
  Param(String)
  /// Placeholder for the k-th aggregate call of an aggregate query.
  AggSlot(Int)
} derive(Debug)

///|
pub(all) struct FuncCall {
  name : String
  args : Array[Expr]
  distinct : Bool
  star : Bool
  filter : Expr?
  order_by : Array[OrderTerm]
  over : WindowSpec?
} derive(Debug)

///|
pub(all) struct WindowSpec {
  base : String?
  partition_by : Array[Expr]
  order_by : Array[OrderTerm]
  frame : FrameSpec?
} derive(Debug)

///|
pub(all) enum FrameBound {
  UnboundedPreceding
  Preceding(Expr)
  CurrentRow
  Following(Expr)
  UnboundedFollowing
} derive(Debug)

///|
pub(all) struct FrameSpec {
  unit : String // ROWS | RANGE | GROUPS
  start : FrameBound
  end : FrameBound
  exclude : String // NO OTHERS | CURRENT ROW | GROUP | TIES
} derive(Debug)

///|
pub(all) struct OrderTerm {
  expr : Expr
  desc : Bool
  nulls_first : Bool? // None = default
} derive(Debug)

///|
pub(all) enum ResultCol {
  Star
  TableStar(String)
  ExprCol(Expr, String?)
} derive(Debug)

///|
pub(all) enum JoinKind {
  Inner
  Left
  Right
  Full
  Cross
} derive(Debug, Eq)

///|
pub(all) enum FromItem {
  TableRef(String, String?)
  SubqueryRef(Select, String?)
  Join(FromItem, FromItem, JoinKind, Bool, Expr?, Array[String]?) // natural, on, using
} derive(Debug)

///|
pub(all) struct SimpleSelect {
  distinct : Bool
  columns : Array[ResultCol]
  from : FromItem?
  where_ : Expr?
  group_by : Array[Expr]
  having : Expr?
  windows : Array[(String, WindowSpec)]
} derive(Debug)

///|
pub(all) enum SelectCore {
  Simple(SimpleSelect)
  Values(Array[Array[Expr]])
} derive(Debug)

///|
pub(all) enum CompoundOp {
  Union
  UnionAll
  Intersect
  Except
} derive(Debug, Eq)

///|
pub(all) struct Cte {
  name : String
  columns : Array[String]
  select : Select
  materialized : Bool?
} derive(Debug)

///|
pub(all) struct Select {
  with_ : Array[Cte]
  recursive : Bool
  first : SelectCore
  rest : Array[(CompoundOp, SelectCore)]
  order_by : Array[OrderTerm]
  limit : Expr?
  offset : Expr?
} derive(Debug)

///|
pub(all) struct ColumnDef {
  name : String
  type_name : String
  mut primary_key : Bool
  mut pk_desc : Bool
  mut autoincrement : Bool
  mut not_null : Bool
  mut unique : Bool
  mut default : Expr?
  checks : Array[Expr]
  mut collate : String?
  mut pk_conflict : String?
  mut nn_conflict : String?
  mut unique_conflict : String?
} derive(Debug)

///|
pub(all) enum TableConstraint {
  PrimaryKey(Array[(String, String?, Bool)], String?) // (column, collate, desc), conflict
  Unique(Array[(String, String?, Bool)], String?)
  Check(Expr)
  ForeignKey(Array[String], String, Array[String])
} derive(Debug)

///|
pub(all) struct CreateTable {
  name : String
  if_not_exists : Bool
  /// CREATE TEMP TABLE (not listed in sqlite_schema).
  temp : Bool
  columns : Array[ColumnDef]
  constraints : Array[TableConstraint]
} derive(Debug)

///|
pub(all) enum InsertSource {
  InsValues(Array[Array[Expr]])
  InsSelect(Select)
  InsDefault
} derive(Debug)

///|
pub(all) enum UpsertAction {
  DoNothing
  DoUpdate(Array[(String, Expr)], Expr?)
} derive(Debug)

///|
pub(all) struct Upsert {
  target : Array[String]? // None = any uniqueness constraint
  target_where : Expr?
  action : UpsertAction
} derive(Debug)

///|
pub(all) struct Insert {
  table : String
  alias : String?
  columns : Array[String]?
  source : InsertSource
  or_action : String? // REPLACE, IGNORE, ABORT, FAIL, ROLLBACK
  upserts : Array[Upsert]
  returning : Array[ResultCol]
} derive(Debug)

///|
pub(all) struct Update {
  table : String
  alias : String?
  or_action : String?
  sets : Array[(String, Expr)]
  where_ : Expr?
  returning : Array[ResultCol]
} derive(Debug)

///|
pub(all) struct Delete {
  table : String
  alias : String?
  where_ : Expr?
  returning : Array[ResultCol]
} derive(Debug)

///|
/// One key of CREATE INDEX: expression, explicit collation, descending.
pub(all) struct IndexedCol {
  expr : Expr
  collate : String?
  desc : Bool
} derive(Debug)

///|
pub(all) struct CreateIndex {
  name : String
  table : String
  unique : Bool
  if_not_exists : Bool
  cols : Array[IndexedCol]
  where_ : Expr?
} derive(Debug)

///|
pub(all) struct CreateView {
  name : String
  if_not_exists : Bool
  temp : Bool
  columns : Array[String]
  select : Select
} derive(Debug)

///|
pub(all) enum AlterAction {
  RenameTable(String)
  RenameColumn(String, String)
  AddColumn(ColumnDef)
  DropColumn(String)
} derive(Debug)

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
  /// ROLLBACK [TO savepoint]
  RollbackStmt(String?)
  SavepointStmt(String)
  ReleaseStmt(String)
  InsertStmt(Insert)
  UpdateStmt(Update)
  DeleteStmt(Delete)
  SelectStmt(Select)
  /// WITH clause in front of INSERT, UPDATE or DELETE.
  WithStmt(Array[Cte], Stmt)
} derive(Debug)
