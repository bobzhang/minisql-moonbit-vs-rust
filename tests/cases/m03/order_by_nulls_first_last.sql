-- Default NULL placement: NULLs sort first in ASC and last in DESC.
-- NULLS FIRST / NULLS LAST override it per sort key.
CREATE TABLE t(id INTEGER, v INTEGER, s TEXT);
INSERT INTO t VALUES (1, 30, 'c'), (2, NULL, 'a'), (3, 10, NULL), (4, NULL, NULL), (5, 20, 'b');

SELECT id, v FROM t ORDER BY v, id;
SELECT id, v FROM t ORDER BY v DESC, id;
SELECT id, v FROM t ORDER BY v NULLS LAST, id;
SELECT id, v FROM t ORDER BY v ASC NULLS FIRST, id;
SELECT id, v FROM t ORDER BY v DESC NULLS FIRST, id;
SELECT id, v FROM t ORDER BY v DESC NULLS LAST, id;

-- Different placement on each key.
SELECT id, v, s FROM t ORDER BY s NULLS LAST, v DESC NULLS FIRST, id;
SELECT id, v, s FROM t ORDER BY s DESC NULLS LAST, v NULLS LAST, id DESC;

-- NULLS FIRST/LAST with an ordinal and with an alias.
SELECT s, id FROM t ORDER BY 1 NULLS LAST, 2;
SELECT v AS val, id FROM t ORDER BY val DESC NULLS LAST, id;

-- An expression that yields NULL for some rows.
SELECT id, v / (id - 3) AS q FROM t ORDER BY q NULLS LAST, id;

-- All values NULL: order falls through to the tie-breaker.
CREATE TABLE n(k INTEGER, x);
INSERT INTO n VALUES (2, NULL), (1, NULL), (3, NULL);
SELECT k, x FROM n ORDER BY x NULLS LAST, k DESC;
SELECT k, x FROM n ORDER BY x DESC NULLS FIRST, k;

-- NULL placement together with other storage classes.
CREATE TABLE m(id INTEGER, x);
INSERT INTO m VALUES (1, 'text'), (2, NULL), (3, x'00'), (4, 2.5), (5, 7);
SELECT id, x FROM m ORDER BY x NULLS LAST;
SELECT id, x FROM m ORDER BY x DESC NULLS FIRST;
SELECT id, x FROM m ORDER BY x DESC;
