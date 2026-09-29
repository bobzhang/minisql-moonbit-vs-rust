# M4 coverage: aggregation and date/time

Maps each bullet of SPEC.md §4 M4 to the test files that exercise it.

## Aggregates

| Feature | Files |
|---|---|
| `count(*)`, `count(x)` | count_star_and_column, aggregate_null_handling, aggregate_empty_input |
| `count(DISTINCT x)` (incl. collations, int/real equality) | count_distinct, aggregate_distinct |
| `sum` integer results, exactness beyond 2^53, NULL on empty | sum_integer_results |
| `sum` REAL results for mixed / non-numeric input | sum_real_and_mixed |
| Integer overflow in `sum` raises an error; `total`/`avg` never do | sum_overflow, total_function, avg_function |
| `total` (always REAL, 0.0 on empty) | total_function, aggregate_empty_input |
| `avg` (always REAL, NULL on empty) | avg_function |
| Compensated summation of REALs in sum/total/avg | sum_precision_kbn |
| `min` / `max` aggregates, scalar vs. aggregate form | min_max_aggregate |
| `min` / `max` across storage classes and affinities | min_max_mixed_types |
| `min` / `max` with column collations / COLLATE | min_max_collation |
| `group_concat(x)` | group_concat_basic |
| `group_concat(x, sep)` (NULL, empty, multi-char separators) | group_concat_separator |
| `string_agg(x, sep)` | string_agg |
| `DISTINCT` inside aggregates | aggregate_distinct, count_distinct, aggregate_order_by_clause |
| `FILTER (WHERE ...)` | aggregate_filter, having_complex, group_by_order_limit |
| `ORDER BY` inside aggregate arguments | aggregate_order_by_clause, group_concat_basic, group_concat_separator, string_agg |
| NULL handling, empty input | aggregate_null_handling, aggregate_empty_input |
| Aggregates in expressions / scalar functions over aggregates | aggregate_in_expressions |
| Misuse errors (WHERE, nesting, GROUP BY, arg counts, UPDATE/DELETE) | aggregate_errors, group_by_alias_ordinal, having_complex |
| Aggregates as INSERT ... SELECT source / after DML | aggregate_insert_select |

## GROUP BY / HAVING

| Feature | Files |
|---|---|
| Aggregates without GROUP BY (always one row) | aggregate_without_group_by, aggregate_empty_input |
| `GROUP BY` column | group_by_basic, group_by_multiple_columns |
| `GROUP BY` expressions | group_by_expressions |
| `GROUP BY` aliases and ordinals (incl. errors) | group_by_alias_ordinal |
| NULL groups | group_by_nulls |
| Mixed storage classes / affinity in group keys | group_by_mixed_types |
| Collation of group keys | group_by_collation |
| `HAVING` (incl. without GROUP BY, alias, errors) | having_basic, having_complex |
| ORDER BY / LIMIT / DISTINCT over grouped results | group_by_order_limit |
| Bare-column rule for min()/max() | bare_column_min_max, bare_column_min_max_group, datetime_with_aggregates |

## Date and time

| Feature | Files |
|---|---|
| `date` | date_function_basic |
| `time` | time_function_basic |
| `datetime` and ISO-8601 input variants, Julian day input, range limits | datetime_input_formats |
| Time zone suffix (`Z`, `±HH:MM`) in the input | datetime_timezone_suffix |
| `julianday` | julianday_function |
| `unixepoch` | unixepoch_function |
| `strftime` (%Y %m %d %H %M %S %f %e %k %l %I %p %P %j %s %J %F %T %R %%) | strftime_basic_formats |
| `strftime` weekday and week numbers (%w %u %W %U %V %G %g) | strftime_week_formats |
| `timediff` | timediff_function |
| Modifiers `±N days/hours/minutes/seconds` | modifiers_days_hours_minutes |
| Modifiers `±N months/years` (normalization) | modifiers_months_years |
| `start of month/year/day` | modifiers_start_of |
| `weekday N` | modifier_weekday |
| `±HH:MM[:SS]` | modifier_time_offset |
| `unixepoch`, `julianday`, `auto` modifiers | modifiers_unixepoch_julianday_auto, datetime_input_formats |
| `subsec` / `subsecond`, `ceiling`, `floor` | modifiers_subsec_floor_ceiling |
| Invalid inputs / modifiers give NULL | datetime_invalid_inputs, date_function_basic, time_function_basic |
| Date/time with GROUP BY and aggregates | datetime_with_aggregates, strftime_basic_formats, modifiers_start_of |
