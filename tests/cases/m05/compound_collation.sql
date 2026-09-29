-- Collations in compound queries. When comparing rows, each result column
-- uses the collation of the leftmost SELECT's column if it has one (a
-- declared column collation, BINARY for a plain column, or an explicit
-- COLLATE); a literal has none, so the next SELECT's column decides.
CREATE TABLE ci(w TEXT COLLATE NOCASE);
CREATE TABLE bin(w TEXT);
INSERT INTO ci VALUES ('A'), ('b'), ('c ');
INSERT INTO bin VALUES ('a'), ('B'), ('d'), ('c');

-- NOCASE on the left: 'A'='a' and 'b'='B' collapse, 5 distinct rows.
SELECT count(*) FROM (SELECT w FROM ci UNION SELECT w FROM bin);
-- BINARY on the left: nothing collapses.
SELECT count(*) FROM (SELECT w FROM bin UNION SELECT w FROM ci);
-- INTERSECT and EXCEPT return the left side's rows.
SELECT w FROM ci INTERSECT SELECT w FROM bin ORDER BY 1 COLLATE BINARY;
SELECT w FROM bin INTERSECT SELECT w FROM ci ORDER BY 1 COLLATE BINARY;
SELECT w FROM ci EXCEPT SELECT w FROM bin ORDER BY 1 COLLATE BINARY;
SELECT w FROM bin EXCEPT SELECT w FROM ci ORDER BY 1 COLLATE BINARY;
-- An explicit COLLATE in the left SELECT overrides the declared collation.
SELECT count(*) FROM (SELECT w COLLATE BINARY FROM ci UNION SELECT w FROM bin);
SELECT w COLLATE BINARY FROM ci INTERSECT SELECT w FROM bin;
SELECT count(*) FROM (SELECT w COLLATE NOCASE FROM bin UNION SELECT w FROM ci);
-- RTRIM ignores trailing spaces: 'c ' matches 'c'.
SELECT w COLLATE RTRIM FROM ci INTERSECT SELECT w FROM bin;
SELECT count(*) FROM (SELECT w COLLATE RTRIM FROM bin UNION SELECT w FROM ci);
-- A literal on the left has no collation, so the right column's NOCASE applies.
SELECT count(*) FROM (SELECT 'a' UNION SELECT w FROM ci);
SELECT count(*) FROM (SELECT 'a' UNION SELECT w FROM bin);
-- ORDER BY on a compound sorts with the same column collation unless overridden;
-- here all values are distinct under NOCASE, so the order is fully determined.
SELECT w FROM ci UNION ALL SELECT 'D' ORDER BY 1;
SELECT w FROM ci UNION ALL SELECT 'D' ORDER BY 1 COLLATE BINARY;
SELECT w FROM bin UNION ALL SELECT 'e' ORDER BY 1 COLLATE NOCASE;
