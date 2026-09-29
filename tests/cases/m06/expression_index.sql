-- Indexes on expressions. They are used for lookups on the same expression,
-- are kept up to date by DML, and a UNIQUE expression index enforces
-- uniqueness of the expression's value.
CREATE TABLE people(id INTEGER PRIMARY KEY, first TEXT, last TEXT, born INTEGER);
INSERT INTO people VALUES (1, 'Ann', 'Lee', 1990), (2, 'bob', 'LEE', 1985), (3, 'Cy', 'Park', 2001), (4, 'di', NULL, 1990);
CREATE INDEX people_lower_last ON people(lower(last));
CREATE INDEX people_decade ON people(born / 10 * 10, first);

SELECT id FROM people WHERE lower(last) = 'lee' ORDER BY id;
SELECT id FROM people WHERE lower(last) IS NULL;
SELECT id FROM people WHERE born / 10 * 10 = 1990 ORDER BY first;
SELECT born / 10 * 10 AS decade, count(*) FROM people GROUP BY decade ORDER BY decade;
-- The plain column is still queryable normally.
SELECT id FROM people WHERE last = 'Lee';
-- DML keeps the expression index current.
UPDATE people SET last = 'lee' WHERE id = 3;
SELECT id FROM people WHERE lower(last) = 'lee' ORDER BY id;
DELETE FROM people WHERE id = 1;
INSERT INTO people VALUES (5, 'Eve', 'LeE', 1979);
SELECT id FROM people WHERE lower(last) = 'lee' ORDER BY id;
SELECT id FROM people WHERE born / 10 * 10 = 1970;
-- UNIQUE on an expression.
CREATE TABLE emails(addr TEXT);
CREATE UNIQUE INDEX emails_ci ON emails(lower(addr));
INSERT INTO emails VALUES ('A@EXAMPLE.COM');
INSERT INTO emails VALUES ('a@example.com');
INSERT OR IGNORE INTO emails VALUES ('a@Example.com'), ('b@example.com');
SELECT addr FROM emails ORDER BY addr;
-- Multi-part expression index with uniqueness.
CREATE TABLE pts(x INTEGER, y INTEGER);
CREATE UNIQUE INDEX pts_sum ON pts(x + y);
INSERT INTO pts VALUES (1, 2), (2, 2);
INSERT INTO pts VALUES (3, 0);
UPDATE pts SET y = 1 WHERE x = 2;
SELECT x, y FROM pts ORDER BY x;
-- Expression index plus a partial predicate.
CREATE INDEX people_first_len ON people(length(first)) WHERE last IS NOT NULL;
SELECT id FROM people WHERE length(first) = 2 AND last IS NOT NULL ORDER BY id;
SELECT id FROM people WHERE length(first) = 2 ORDER BY id;
-- Errors: aggregate or subquery in an index expression.
CREATE INDEX bad1 ON people(max(born));
CREATE INDEX bad2 ON people((SELECT 1));
