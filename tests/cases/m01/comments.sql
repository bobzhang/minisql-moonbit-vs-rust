-- Line and block comments are accepted anywhere whitespace is.

SELECT 1; -- trailing line comment
-- A comment line before a statement
SELECT 2;
/* A block comment before a statement */ SELECT 3;
SELECT /* inside */ 4 /* after */;
SELECT 5/**/+/**/6;
SELECT 7 --comment directly after a value
  + 1;

/* A multi-line
   block comment
   spanning lines */
SELECT 'after multi-line comment';

-- Comment markers inside strings are just text.
SELECT '-- not a comment', '/* not a comment */';
SELECT 'a' || '--' || 'b';

-- A comment between tokens of DDL and DML.
CREATE /* c1 */ TABLE t /* c2 */ ( -- c3
  a INTEGER, -- first column
  b TEXT /* second column */
);
INSERT INTO t /* target */ VALUES /* rows */ (1, 'x'), -- first row
  (2, 'y');
SELECT a, b FROM t -- no filter
ORDER BY /* key */ a DESC;

-- A block comment may contain what looks like a line comment.
SELECT /* -- still inside block */ 9;

-- Minus signs next to each other form a comment, so "1--1" is just 1.
SELECT 1--1
;
SELECT 1 - -1;
