# M2 coverage

Maps each M2 bullet in `spec/SPEC.md` §4 to the test files that exercise it.

## Operators and expressions

| Spec item | Files |
|---|---|
| `CASE` (searched and simple forms) | `case_searched`, `case_simple`, `case_result_types`, `collation_precedence` (collation inside simple CASE) |
| `CAST(x AS type)` | `cast_to_integer`, `cast_to_real`, `cast_to_text_blob`, `cast_to_numeric`, `cast_type_affinity`, `affinity_expressions` |
| `IS [NOT]` | `is_operator`, `collate_operator`, `collation_declared_column` |
| `IS [NOT] DISTINCT FROM` | `is_distinct_from`, `operator_precedence_m2` |
| `[NOT] BETWEEN` | `between_basic`, `between_affinity_collation` |
| `[NOT] IN (list)` | `in_list_basic`, `in_list_nulls`, `in_list_affinity` |
| `[NOT] LIKE ... [ESCAPE ...]` | `like_basic`, `like_escape`, `like_unicode_types`, `func_like_glob` |
| `[NOT] GLOB` | `glob_basic`, `glob_character_classes`, `func_like_glob` |
| Bitwise `& \| ~ << >>` | `bitwise_operators`, `bitwise_shifts` |
| `COLLATE` operator | `collate_operator`, `collation_precedence`, `collation_functions` |
| Precedence of the M2 operators | `operator_precedence_m2`, `between_basic`, `bitwise_operators`, `bitwise_shifts` |

## Collations and comparison affinity

| Spec item | Files |
|---|---|
| `BINARY` | `collate_operator`, `collation_precedence` |
| `NOCASE` | `collation_nocase`, `collate_operator`, `collation_declared_column` |
| `RTRIM` | `collation_rtrim`, `collate_operator`, `collation_declared_column` |
| Declared column collations | `collation_declared_column`, `collation_precedence`, `between_affinity_collation`, `in_list_affinity`, `collation_functions` |
| Rules for which collation a comparison uses (explicit left > explicit right > left column > right column > BINARY; `+col`/`CAST` keep column collation; IN uses the left operand's; BETWEEN per comparison; max/min leftmost) | `collation_precedence`, `collation_declared_column`, `between_affinity_collation`, `in_list_affinity`, `collation_functions` |
| Comparison affinity: numeric column vs text | `affinity_numeric_vs_text`, `in_list_affinity`, `between_affinity_collation`, `case_simple`, `is_operator`, `func_nullif` |
| Comparison affinity: text column vs number | `affinity_text_vs_numeric`, `in_list_affinity`, `between_affinity_collation` |
| Comparison affinity: column vs column | `affinity_column_pairs` |
| Comparison affinity: expressions (`+col`, `(col)`, `CAST`, arithmetic, function results) | `affinity_expressions`, `cast_type_affinity` |

## Scalar functions

| Function | Files |
|---|---|
| `abs` | `func_abs` |
| `char` | `func_char_unicode` |
| `coalesce`, `ifnull` | `func_coalesce_ifnull` |
| `concat`, `concat_ws` | `func_concat` |
| `format` / `printf` — `%d %i %u` | `printf_integers` |
| `printf` — `%f` | `printf_float_f` |
| `printf` — `%e %E %g %G` | `printf_float_e_g` |
| `printf` — `%s` (width/precision in bytes, `!` flag) and `%%` | `printf_strings` |
| `printf` — `%q %Q %w` | `printf_quoting` |
| `printf` — `%x %X %o %c` | `printf_hex_octal_char` |
| `printf` — flags `- + space 0 # , !`, width, precision, `*`, missing/extra args, NULL format | `printf_integers`, `printf_float_f`, `printf_float_e_g`, `printf_strings`, `printf_hex_octal_char`, `printf_arguments` |
| `glob`, `like` (function forms) | `func_like_glob` |
| `hex` | `func_hex` |
| `unhex` | `func_unhex` |
| `iif` / `if` | `func_iif` |
| `instr` | `func_instr` |
| `length`, `octet_length` | `func_length` |
| `likelihood`, `likely`, `unlikely` | `func_likely_likelihood` |
| `lower`, `upper` | `func_lower_upper` |
| `trim`, `ltrim`, `rtrim` | `func_trim` |
| `max` / `min` (scalar) | `func_max_min_scalar`, `collation_functions` |
| `nullif` | `func_nullif`, `collation_functions` |
| `quote` | `func_quote` |
| `replace` | `func_replace` |
| `round` | `func_round` |
| `sign` | `func_sign` |
| `substr` / `substring` | `func_substr` |
| `unicode` | `func_char_unicode` |
| `zeroblob` | `func_zeroblob` |

## Math functions

| Function | Files |
|---|---|
| `sin cos tan asin acos atan atan2` | `math_trig` |
| `sinh cosh tanh asinh acosh atanh` | `math_hyperbolic` |
| `exp ln log log10 log2` (incl. two-argument `log`) | `math_exp_log` |
| `ceil ceiling floor trunc` | `math_rounding` |
| `pow power sqrt mod` | `math_pow_sqrt_mod` |
| `pi degrees radians` | `math_pi_degrees`, `math_trig` |

Inexact transcendental results are wrapped in `round(x, 10..12)` so that the
tests do not depend on the last bit of the platform math library.

## Errors

| Spec item | Files |
|---|---|
| Wrong number of arguments | `function_errors` and the end of almost every `func_*` / `math_*` file |
| No such function | `function_errors`, `printf_arguments` |
| Other runtime errors (integer overflow in `abs`, bad `ESCAPE`, bad `likelihood` probability, unknown collation) | `func_abs`, `case_result_types`, `func_iif`, `func_coalesce_ifnull`, `like_escape`, `func_like_glob`, `func_likely_likelihood`, `collate_operator` |
