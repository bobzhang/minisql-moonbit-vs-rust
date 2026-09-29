-- FULL [OUTER] JOIN keeps unmatched rows from both sides, NULL-extending the
-- missing half.
CREATE TABLE l(id INTEGER, lv TEXT);
CREATE TABLE r(id INTEGER, rv TEXT);
INSERT INTO l VALUES (1, 'l1'), (2, 'l2'), (4, 'l4');
INSERT INTO r VALUES (2, 'r2'), (3, 'r3'), (4, 'r4a'), (4, 'r4b');

SELECT l.id, lv, r.id, rv FROM l FULL JOIN r ON l.id = r.id ORDER BY coalesce(l.id, r.id), rv;
SELECT l.id, lv, r.id, rv FROM l FULL OUTER JOIN r ON l.id = r.id ORDER BY coalesce(l.id, r.id), rv;
SELECT * FROM l FULL JOIN r ON l.id = r.id ORDER BY coalesce(l.id, r.id), rv;
SELECT count(*) FROM l FULL JOIN r ON l.id = r.id;
-- Only the unmatched rows from either side.
SELECT lv, rv FROM l FULL JOIN r ON l.id = r.id WHERE l.id IS NULL OR r.id IS NULL ORDER BY lv, rv;
-- ON condition that is never true: every row of both sides, each NULL-extended.
SELECT lv, rv FROM l FULL JOIN r ON 0 ORDER BY lv, rv;
SELECT count(*) FROM l FULL JOIN r ON 0;
-- ON condition that is always true: plain cross product.
SELECT count(*) FROM l FULL JOIN r ON 1;
-- Filter inside ON versus WHERE.
SELECT lv, rv FROM l FULL JOIN r ON l.id = r.id AND rv <> 'r4a' ORDER BY lv, rv;
SELECT lv, rv FROM l FULL JOIN r ON l.id = r.id WHERE rv <> 'r4a' ORDER BY lv, rv;
-- Empty sides.
CREATE TABLE e(id INTEGER, ev TEXT);
SELECT lv, ev FROM l FULL JOIN e ON l.id = e.id ORDER BY lv;
SELECT ev, rv FROM e FULL JOIN r ON e.id = r.id ORDER BY rv;
SELECT count(*) FROM e FULL JOIN e AS e2 ON e.id = e2.id;
-- Aggregates across a full join.
SELECT count(lv), count(rv), count(*) FROM l FULL JOIN r ON l.id = r.id;
SELECT coalesce(l.id, r.id) AS k, count(*) FROM l FULL JOIN r ON l.id = r.id GROUP BY k ORDER BY k;
