-- quote(X): an SQL literal for X. Text is single-quoted with quotes
-- doubled; blobs become X'..'; numbers print as numbers; NULL is NULL.

SELECT quote('abc'), quote('it''s'), quote(''), quote('''');
SELECT quote(1), quote(-5), quote(0), quote(9223372036854775807);
SELECT quote(1.5), quote(-0.25), quote(100.0), quote(0.1);
SELECT quote(NULL), typeof(quote(NULL));
SELECT quote(x'00ff'), quote(x''), quote(x'414243');
-- The result is always TEXT.
SELECT typeof(quote(1)), typeof(quote(x'01')), typeof(quote('a'));
-- Non-ASCII passes through.
SELECT quote('café'), quote('日本');
-- Double quotes are not escaped.
SELECT quote('say "hi"');
-- Quoting values of every type from a table.
CREATE TABLE t(id INTEGER, v);
INSERT INTO t VALUES (1, 'O''Reilly'), (2, 42), (3, 2.5), (4, NULL), (5, x'CAFE'), (6, '');
SELECT id, quote(v) FROM t ORDER BY id;
-- Building a statement text.
SELECT 'INSERT INTO t VALUES(' || quote(id) || ', ' || quote(v) || ');' FROM t ORDER BY id;
-- quote() of a column with affinity shows the stored type.
CREATE TABLE u(i INTEGER, s TEXT);
INSERT INTO u VALUES ('7', 7);
SELECT quote(i), quote(s) FROM u;
-- Wrong number of arguments.
SELECT quote();
SELECT quote(1, 2);
