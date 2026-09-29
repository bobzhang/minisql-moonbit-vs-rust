-- NULL join keys never match with = (NULL = NULL is NULL, not true), but IS
-- treats two NULLs as equal.
CREATE TABLE l(k, lv TEXT);
CREATE TABLE r(k, rv TEXT);
INSERT INTO l VALUES (1, 'l1'), (NULL, 'lnull'), (2, 'l2'), (NULL, 'lnull2');
INSERT INTO r VALUES (1, 'r1'), (NULL, 'rnull'), (3, 'r3');

SELECT lv, rv FROM l JOIN r ON l.k = r.k ORDER BY lv, rv;
SELECT count(*) FROM l JOIN r ON l.k = r.k;
-- IS matches NULL with NULL: 2 left NULLs x 1 right NULL.
SELECT lv, rv FROM l JOIN r ON l.k IS r.k ORDER BY lv, rv;
SELECT count(*) FROM l JOIN r ON l.k IS r.k;
-- IS NOT DISTINCT FROM is the same as IS.
SELECT count(*) FROM l JOIN r ON l.k IS NOT DISTINCT FROM r.k;
-- <> with NULLs is also never true.
SELECT lv, rv FROM l JOIN r ON l.k <> r.k ORDER BY lv, rv;
-- IS NOT pairs everything except the equal non-NULL pairs and NULL/NULL pairs.
SELECT count(*) FROM l JOIN r ON l.k IS NOT r.k;
-- coalesce() in the join condition maps NULLs to a sentinel.
SELECT lv, rv FROM l JOIN r ON coalesce(l.k, -1) = coalesce(r.k, -1) ORDER BY lv, rv;
-- Join conditions that are NULL filter out the pair.
SELECT count(*) FROM l JOIN r ON l.k = r.k OR NULL;
SELECT count(*) FROM l JOIN r ON l.k = r.k OR l.k IS NULL;
-- NULL keys in USING also never match.
SELECT k, lv, rv FROM l JOIN r USING (k) ORDER BY lv;
-- WHERE on the NULL side.
SELECT lv, rv FROM l, r WHERE l.k IS NULL AND r.k IS NULL ORDER BY lv;
