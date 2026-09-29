-- lower(X) and upper(X) change the case of ASCII letters only.

SELECT lower('HELLO'), upper('hello'), lower('MiXeD 123!'), upper('MiXeD 123!');
SELECT lower(''), upper(''), lower(NULL), upper(NULL);
-- Non-ASCII letters are unchanged.
SELECT lower('ÀÉÎÕÜ'), upper('àéîõü'), upper('straße'), lower('ΑΒΓ'), upper('ω');
SELECT upper('café'), lower('CAFÉ');
-- Numbers become text.
SELECT upper(123), typeof(upper(123)), lower(1.5), typeof(lower(1.5));
-- Blobs are treated as text.
SELECT lower(x'414243'), typeof(lower(x'414243'));
-- Idempotent.
SELECT lower(lower('ABC')), upper(lower('AbC'));
-- Case-insensitive comparisons with lower().
CREATE TABLE t(id INTEGER, name TEXT);
INSERT INTO t VALUES (1, 'Alice'), (2, 'ALICE'), (3, 'alice'), (4, 'Álice'), (5, 'Bob'), (6, NULL);
SELECT id FROM t WHERE lower(name) = 'alice' ORDER BY id;
SELECT id, upper(name), lower(name) FROM t ORDER BY id;
SELECT id FROM t ORDER BY lower(name), id;
-- Wrong number of arguments.
SELECT lower();
SELECT upper('a', 'b');
