-- concat(X, ...) joins the text forms of its arguments, skipping NULLs.
-- concat_ws(SEP, X, ...) does the same with a separator between the
-- non-NULL arguments; a NULL separator gives NULL.

SELECT concat('a', 'b', 'c'), concat('a'), concat('x', 1, 2.5, -3);
-- NULL arguments are skipped (unlike ||).
SELECT concat('a', NULL, 'b'), 'a' || NULL || 'b', concat(NULL), concat(NULL, NULL);
SELECT typeof(concat(NULL)), length(concat(NULL, NULL));
-- Blobs are taken as text.
SELECT concat('A', x'4243');
-- Non-ASCII.
SELECT concat('日本', '語', '!'), concat('é', 'è');
-- concat_ws.
SELECT concat_ws(',', 'a', 'b', 'c'), concat_ws(', ', 1, 2, 3), concat_ws('', 'x', 'y');
SELECT concat_ws(',', 'a', NULL, 'b'), concat_ws(',', NULL, NULL), concat_ws(',', 'only');
-- Empty strings are not skipped.
SELECT concat_ws('-', 'a', '', 'b'), concat_ws('-', '', '');
-- A NULL separator gives NULL.
SELECT concat_ws(NULL, 'a', 'b'), typeof(concat_ws(NULL, 'a'));
-- A numeric separator is converted to text.
SELECT concat_ws(0, 'a', 'b'), concat_ws(1.5, 1, 2);
-- Result type is always TEXT (or NULL for a NULL separator).
SELECT typeof(concat(1, 2)), typeof(concat_ws(',', 1));
-- Joining table columns.
CREATE TABLE p(id INTEGER, first TEXT, middle TEXT, last TEXT);
INSERT INTO p VALUES (1, 'Ada', NULL, 'Lovelace'), (2, 'John', 'Ronald', 'Tolkien'), (3, NULL, NULL, NULL), (4, 'Cher', '', NULL);
SELECT id, concat(first, middle, last), concat_ws(' ', first, middle, last) FROM p ORDER BY id;
SELECT id FROM p WHERE concat_ws('', first, last) = 'AdaLovelace';
-- Wrong number of arguments.
SELECT concat();
SELECT concat_ws(',');
