# M1 coverage

Maps each M1 bullet in `spec/SPEC.md` §4 to the test files that exercise it.

| Spec bullet | Files |
|---|---|
| Program interface, statement splitting (§2.2) | `statement_splitting`, `comments`, `string_literals` (unterminated string at end of script), `identifiers_quoted` (`[...]` containing `;`), `syntax_errors` (script continues after errors) |
| Output protocol: rows joined by `\|`, no rows on error (§2.3) | every file; `output_text_blob` (text containing `\|`), `insert_errors`, `name_resolution_errors` (failing statements print only `Error:`) |
| Output: INTEGER formatting | `output_integers`, `arithmetic_integer`, `numeric_literals` |
| Output: REAL formatting (fixed vs scientific, `-0.0`, `Inf`, NaN→NULL) | `output_reals`, `select_literals`, `arithmetic_real`, `arithmetic_overflow` |
| Output: TEXT / BLOB formatting | `output_text_blob`, `blob_literals`, `string_literals` |
| Lexer: numeric literals (decimals, exponents, `.5`, `5.`, hex) | `numeric_literals`, `lexer_tokens`, `select_literals` |
| Lexer: strings, blobs, quoted identifiers, comments, operators | `string_literals`, `blob_literals`, `identifiers_quoted`, `double_quoted_strings`, `comments`, `lexer_tokens` |
| `CREATE TABLE [IF NOT EXISTS]`, declared types (`VARCHAR(20)`, `DECIMAL(10, 2)`, multi-word) | `create_table_basic`, `create_table_types`, `create_table_if_not_exists`, `affinity_type_name_rules` |
| Constraint clauses parse (not enforced) | `create_table_constraints_parse` |
| `DROP TABLE [IF EXISTS]` | `drop_table` |
| `INSERT INTO t [(cols)] VALUES (...), (...)` | `insert_basic`, `insert_errors`, `insert_affinity_mix` |
| Type affinity on storage | `affinity_integer_column`, `affinity_real_column`, `affinity_numeric_column`, `affinity_text_column`, `affinity_blob_column`, `affinity_type_name_rules`, `insert_affinity_mix`, `create_table_types` |
| `SELECT [ALL]`, `*`, `table.*`, aliases, `FROM t [AS] x`, no `FROM` | `select_star`, `select_aliases`, `select_without_from`, `identifiers_case` |
| `WHERE` | `where_basic`, `logic_three_valued`, `logic_truthiness`, `is_null_operators` |
| `ORDER BY expr [ASC\|DESC], ...` (NULLs first, cross-class order, BINARY) | `order_by_basic`, `order_by_mixed_types`, `order_by_multiple_keys`, `order_by_expressions`, `blob_literals`, `comparison_int_real` |
| Literals incl. `TRUE`/`FALSE`, NULL | `select_literals`, `null_and_booleans` |
| Column references `col`, `table.col` | `select_star`, `select_aliases`, `identifiers_case`, `identifiers_quoted`, `where_basic` |
| Unary `-`/`+` | `unary_operators`, `text_to_number`, `arithmetic_overflow` |
| `+ - * / %` (integer division, remainder sign, division by zero, overflow to REAL) | `arithmetic_integer`, `arithmetic_real`, `arithmetic_overflow`, `division_by_zero`, `text_to_number` |
| `\|\|` | `concat_operator`, `operator_precedence` |
| `= == != <> < <= > >=` | `comparison_operators`, `comparison_cross_class`, `comparison_int_real` |
| `AND OR NOT` (three-valued logic) | `logic_three_valued`, `logic_truthiness` |
| `IS NULL`, `IS NOT NULL`, `ISNULL`, `NOTNULL`, `NOT NULL` | `is_null_operators` |
| Parentheses, operator precedence | `operator_precedence`, `concat_operator`, `unary_operators` |
| `typeof(x)` | `typeof_function` (and most other files) |
| Error: syntax errors | `syntax_errors`, `create_table_basic`, `numeric_literals`, `blob_literals`, `lexer_tokens`, `select_aliases` |
| Error: no such table | `name_resolution_errors`, `drop_table`, `insert_errors`, `select_star`, `identifiers_case` |
| Error: no such column | `name_resolution_errors`, `where_basic`, `order_by_basic`, `select_without_from`, `select_aliases`, `double_quoted_strings` |
| Error: table already exists | `create_table_if_not_exists` |
| Error: wrong number of values in INSERT | `insert_errors` |
| Error: ambiguous column name | not testable in M1 (needs two tables in `FROM`, which is M5); `name_resolution_errors` covers duplicate column names in `CREATE TABLE` instead |
