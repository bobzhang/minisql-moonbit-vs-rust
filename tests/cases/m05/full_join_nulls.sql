-- FULL JOIN where the join keys themselves contain NULLs: NULL keys never
-- match, so such rows appear once from each side, NULL-extended.
CREATE TABLE a(k, av TEXT);
CREATE TABLE b(k, bv TEXT);
INSERT INTO a VALUES (1, 'a1'), (NULL, 'an'), (2, 'a2');
INSERT INTO b VALUES (NULL, 'bn'), (2, 'b2'), (3, 'b3'), (NULL, 'bn2');

SELECT av, bv FROM a FULL JOIN b ON a.k = b.k ORDER BY av, bv;
SELECT count(*) FROM a FULL JOIN b ON a.k = b.k;
-- With IS, the NULL keys do match each other.
SELECT av, bv FROM a FULL JOIN b ON a.k IS b.k ORDER BY av, bv;
SELECT count(*) FROM a FULL JOIN b ON a.k IS b.k;
-- Distinguishing "NULL key" from "NULL-extended" rows.
SELECT av, bv, a.k IS NULL AND av IS NOT NULL AS a_null_key, b.k IS NULL AND bv IS NOT NULL AS b_null_key
  FROM a FULL JOIN b ON a.k = b.k ORDER BY av, bv;
-- Both-sides-unmatched count.
SELECT sum(av IS NULL), sum(bv IS NULL) FROM a FULL JOIN b ON a.k = b.k;
-- coalesce over both keys.
SELECT coalesce(a.k, b.k), av, bv FROM a FULL JOIN b ON a.k = b.k ORDER BY 1, 2, 3;
-- A NULL-valued non-key column is different from NULL extension.
INSERT INTO a VALUES (3, NULL);
SELECT a.k, av, b.k, bv FROM a FULL JOIN b ON a.k = b.k WHERE a.k = 3 OR b.k = 3 ORDER BY bv;
SELECT count(*) FROM a FULL JOIN b ON a.k = b.k WHERE av IS NULL;
-- NULL-extended rows and WHERE comparisons.
SELECT count(*) FROM a FULL JOIN b ON a.k = b.k WHERE a.k > 0;
SELECT count(*) FROM a FULL JOIN b ON a.k = b.k WHERE NOT (a.k > 0);
SELECT count(*) FROM a FULL JOIN b ON a.k = b.k WHERE a.k IS NULL;
