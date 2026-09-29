-- NOCASE collation in detail: only the 26 ASCII letters are folded.

SELECT 'A' = 'a' COLLATE NOCASE, 'Z' = 'z' COLLATE NOCASE, '@' = '`' COLLATE NOCASE, '[' = '{' COLLATE NOCASE;
-- Ordering puts letters in folded order, but non-letters keep byte order.
SELECT 'B' < 'a' COLLATE NOCASE, '_' < 'a' COLLATE NOCASE, '_' < 'A' COLLATE NOCASE;
SELECT 'Z' < '[' COLLATE NOCASE, 'z' < '[' COLLATE NOCASE;
-- Prefixes are smaller.
SELECT 'ab' < 'ABC' COLLATE NOCASE, 'ABC' > 'ab' COLLATE NOCASE;
-- Non-ASCII is compared by bytes.
SELECT 'Ä' = 'ä' COLLATE NOCASE, 'É' < 'é' COLLATE NOCASE, 'ÿ' > 'z' COLLATE NOCASE;
-- Mixed strings.
SELECT 'Hello World' = 'hello world' COLLATE NOCASE, 'Hello World' = 'hello  world' COLLATE NOCASE;
SELECT 'ItEm1' = 'item1' COLLATE NOCASE, 'item1' = 'item2' COLLATE NOCASE;
-- Trailing spaces still count in NOCASE.
SELECT 'a' = 'A ' COLLATE NOCASE;
-- NOCASE with numbers in text.
SELECT 'ABC10' < 'abc9' COLLATE NOCASE;
-- A table of names compared with NOCASE.
CREATE TABLE n(id INTEGER, name TEXT);
INSERT INTO n VALUES (1, 'alice'), (2, 'ALICE'), (3, 'Alice'), (4, 'bob'), (5, 'Álice'), (6, 'alicE ');
SELECT id FROM n WHERE name = 'ALICE' COLLATE NOCASE ORDER BY id;
SELECT id FROM n WHERE name > 'alice' COLLATE NOCASE ORDER BY id;
SELECT id FROM n WHERE name COLLATE NOCASE BETWEEN 'a' AND 'b' ORDER BY id;
SELECT id FROM n WHERE name COLLATE NOCASE IN ('BOB', 'ALICE') ORDER BY id;
SELECT id, name = 'Alice' COLLATE NOCASE, name = 'Alice' FROM n ORDER BY id;
-- LIKE is already case-insensitive for ASCII; COLLATE does not change that.
SELECT id FROM n WHERE name LIKE 'ALICE' ORDER BY id;
