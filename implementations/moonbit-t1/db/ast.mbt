///|
priv enum BinOp {
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
} derive(Eq)

///|
priv enum UnOp {
  Neg
  Pos
  Not
  BitNot
} derive(Eq)

///|
priv enum Expr {
  Lit(Value)
  /// Integer literal 9223372036854775808 (becomes MIN when negated).
  BigIntLit
  /// Unresolved column reference. `dq` marks a lone double-quoted name.
  Column(tbl~ : String?, name~ : String, dq~ : Bool)
  /// Resolved column: slot in the flat row, with its affinity.
  Slot(Int, Affinity, Coll)
  Unary(UnOp, Expr)
  Binary(BinOp, Expr, Expr)
  /// Bound comparison (Eq..IsNot) with its affinity and collation.
  Cmp(BinOp, Expr, Expr, CmpInfo)
  IsNull(Expr, Bool) // (expr, negated)
  Collate(Expr, Coll)
  Cast(Expr, Affinity)
  /// x [NOT] BETWEEN lo AND hi; infos for (x, lo) and (x, hi).
  Between(Expr, Expr, Expr, Bool, CmpInfo, CmpInfo)
  /// x [NOT] IN (list)
  InList(Expr, Array[Expr], Bool, CmpInfo)
  Like(glob~ : Bool, lhs~ : Expr, pat~ : Expr, esc~ : Expr?, neg~ : Bool)
  Case(
    base~ : Expr?,
    whens~ : Array[(Expr, Expr)],
    else_~ : Expr?,
    infos~ : Array[CmpInfo]
  )
  Func(
    name~ : String,
    args~ : Array[Expr],
    star~ : Bool,
    distinct~ : Bool,
    coll~ : Coll,
    filter~ : Expr?,
    order~ : Array[OrderTerm]
  )
  /// Result of an aggregate, stored at this slot of the group row.
  AggRef(Int)
  /// Unbound subqueries: scalar, EXISTS, x [NOT] IN (query).
  SubQ(Query)
  ExistsQ(Query)
  InQ(Expr, Query, Bool)
  /// Reference into the row of an enclosing query, `depth` levels up.
  Outer(Int, Expr)
  /// Bound subqueries.
  SubScalar(SubPlan)
  SubExists(SubPlan)
  SubIn(Expr, SubPlan, Bool, CmpInfo)
  /// Unbound window function call.
  WinCall(WinAst)
  /// Result of window function `i`, stored at slot `base + i`.
  WinRef(Int, Ref[Int])
}

///|
priv enum FrameUnit {
  FRows
  FRange
  FGroups
} derive(Eq)

///|
priv enum FrameBound {
  UnbPre
  Pre(Expr)
  CurRow
  Fol(Expr)
  UnbFol
}

///|
priv enum Exclude {
  ExNone
  ExCurrent
  ExGroup
  ExTies
} derive(Eq)

///|
priv struct Frame {
  unit : FrameUnit
  start : FrameBound
  end : FrameBound
  exclude : Exclude
}

///|
/// A window definition: `[base] [PARTITION BY ...] [ORDER BY ...] [frame]`.
priv struct WinDef {
  base : String?
  partition : Array[Expr]
  order : Array[OrderTerm]
  frame : Frame?
}

///|
priv enum Over {
  OverName(String)
  OverDef(WinDef)
}

///|
priv struct WinAst {
  name : String
  args : Array[Expr]
  star : Bool
  distinct : Bool
  filter : Expr?
  order : Array[OrderTerm]
  over : Over
}

///|
/// One common table expression of a WITH clause.
priv struct CteDef {
  name : String
  cols : Array[String]?
  query : Query
}

///|
priv enum Coll {
  CBinary
  CNoCase
  CRTrim
} derive(Eq)

///|
/// How a comparison converts and orders its operands.
priv struct CmpInfo {
  aff : Affinity?
  coll : Coll
}

///|
let default_info : CmpInfo = { aff: None, coll: CBinary, }

///|
priv enum ResultCol {
  Star
  TableStar(String)
  /// expression, AS name, source text
  ExprCol(Expr, String?, String)
}

///|
priv struct OrderTerm {
  expr : Expr
  desc : Bool
  nulls_first : Bool? // explicit NULLS FIRST / NULLS LAST
  text : String // source text of the expression
}

///|
priv enum JoinKind {
  JInner
  JLeft
  JRight
  JFull
} derive(Eq)

///|
priv enum FromSrc {
  FTable(String)
  FSub(Query)
}

///|
priv struct FromItem {
  src : FromSrc
  as_name : String?
  join : JoinKind // how this item joins the items to its left
  natural : Bool
  on : Expr?
  using_ : Array[String]?
}

///|
priv enum CompoundOp {
  UnionAll
  Union
  Intersect
  Except
} derive(Eq)

///|
priv enum Query {
  QSelect(Select)
  QValues(Array[Array[Expr]])
  /// Members carry no ORDER BY / LIMIT of their own.
  QCompound(
    first~ : Query,
    rest~ : Array[(CompoundOp, Query)],
    order_by~ : Array[OrderTerm],
    limit~ : Expr?,
    offset~ : Expr?
  )
  QWith(ctes~ : Array[CteDef], body~ : Query)
}

///|
priv struct Select {
  distinct : Bool
  cols : Array[ResultCol]
  from : Array[FromItem]
  where_ : Expr?
  group_by : Array[Expr]
  having : Expr?
  order_by : Array[OrderTerm]
  limit : Expr?
  offset : Expr?
  windows : Array[(String, WinDef)]
}

///|
priv enum Conflict {
  CRollback
  CAbort
  CFail
  CIgnore
  CReplace
} derive(Eq)

///|
priv struct ColumnDef {
  name : String
  type_name : String
  affinity : Affinity
  mut not_null : Bool
  mut primary_key : Bool
  mut pk_desc : Bool
  mut autoincrement : Bool
  mut unique : Bool
  mut default_ : Expr?
  mut collate : String?
  checks : Array[Expr]
  mut pk_conflict : Conflict?
  mut nn_conflict : Conflict?
  mut unique_conflict : Conflict?
}

///|
priv enum TableConstraint {
  TPrimaryKey(Array[String], Conflict?)
  TUnique(Array[String], Conflict?)
  TCheck(Expr)
  TForeignKey
}

///|
priv enum InsertSource {
  Values(Array[Array[Expr]])
  SelectSrc(Query)
  DefaultValues
}

///|
/// ON CONFLICT [(target)] DO NOTHING | DO UPDATE SET ... [WHERE ...]
priv struct Upsert {
  target : Array[String]?
  sets : Array[(String, Expr)]? // None = DO NOTHING
  where_ : Expr?
}

///|
priv enum Stmt {
  CreateTable(
    name~ : String,
    if_not_exists~ : Bool,
    cols~ : Array[ColumnDef],
    constraints~ : Array[TableConstraint],
    sql~ : String
  )
  DropTable(name~ : String, if_exists~ : Bool)
  Insert(
    table~ : String,
    as_name~ : String?,
    cols~ : Array[String]?,
    src~ : InsertSource,
    or_~ : Conflict?,
    upserts~ : Array[Upsert],
    returning~ : Array[ResultCol]?
  )
  Update(
    table~ : String,
    as_name~ : String?,
    or_~ : Conflict?,
    sets~ : Array[(String, Expr)],
    where_~ : Expr?,
    returning~ : Array[ResultCol]?
  )
  Delete(
    table~ : String,
    as_name~ : String?,
    where_~ : Expr?,
    returning~ : Array[ResultCol]?
  )
  SelectStmt(Query)
  CreateIndex(
    name~ : String,
    table~ : String,
    unique~ : Bool,
    if_not_exists~ : Bool,
    cols~ : Array[IndexCol],
    where_~ : Expr?,
    sql~ : String
  )
  DropIndex(name~ : String, if_exists~ : Bool)
  CreateView(
    name~ : String,
    if_not_exists~ : Bool,
    cols~ : Array[String]?,
    query~ : Query,
    sql~ : String
  )
  DropView(name~ : String, if_exists~ : Bool)
  AlterRename(table~ : String, new_name~ : String)
  AlterRenameCol(table~ : String, old~ : String, new_name~ : String)
  AlterAdd(table~ : String, col~ : ColumnDef, sql~ : String)
  AlterDrop(table~ : String, col~ : String)
  Begin
  Commit
  Rollback(String?)
  Savepoint(String)
  Release(String)
  WithDml(Array[CteDef], Stmt)
}

///|
/// One key part of CREATE INDEX: expression (COLLATE stripped), collation, order.
priv struct IndexCol {
  expr : Expr
  coll : Coll?
  desc : Bool
}
