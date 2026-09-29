-- instr(X, Y): 1-based position of the first occurrence of Y in X, 0 if not
-- found, NULL if either argument is NULL. Positions count characters for
-- text and bytes for blobs.

SELECT instr('hello', 'l'), instr('hello', 'lo'), instr('hello', 'h'), instr('hello', 'z');
SELECT instr('hello', 'hello'), instr('hello', 'hello!'), instr('aaa', 'aa');
-- An empty needle is found at position 1, even in an empty string.
SELECT instr('hello', ''), instr('', ''), instr('', 'a');
-- Case-sensitive.
SELECT instr('Hello', 'h'), instr('Hello', 'H');
-- NULL.
SELECT instr(NULL, 'a'), instr('a', NULL), instr(NULL, NULL);
-- Characters, not bytes, for text.
SELECT instr('日本語', '語'), instr('héllo', 'l'), instr('😀a', 'a');
-- Numbers are converted to text.
SELECT instr(12345, 34), instr(1.5, '.'), instr('abc10', 10);
-- Blobs: byte positions.
SELECT instr(x'0102030405', x'0304'), instr(x'0102', x'03'), instr(x'C3A9C3A9', x'A9');
-- Mixed blob/text: both are treated as blobs.
SELECT instr('abc', x'63'), instr(x'616263', 'c');
-- In a table.
CREATE TABLE t(id INTEGER, email TEXT);
INSERT INTO t VALUES (1, 'ann@example.com'), (2, 'bob.at.example'), (3, '@start'), (4, NULL), (5, 'zoé@café.fr');
SELECT id, instr(email, '@') FROM t ORDER BY id;
SELECT id FROM t WHERE instr(email, '@') > 0 ORDER BY id;
SELECT id, substr(email, 1, instr(email, '@') - 1) FROM t WHERE instr(email, '@') > 1 ORDER BY id;
-- Wrong number of arguments.
SELECT instr('a');
SELECT instr('a', 'b', 'c');
