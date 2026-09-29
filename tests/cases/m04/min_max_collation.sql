-- Aggregate min()/max() compare using the collation of their argument: the
-- declared column collation, or an explicit COLLATE.
CREATE TABLE t(nc TEXT COLLATE NOCASE, b TEXT, rt TEXT COLLATE RTRIM);
INSERT INTO t VALUES ('b', 'b', 'a'), ('A', 'A', 'b'), ('C', 'C', 'c'), ('d', 'd', 'b  ');
SELECT min(nc), max(nc) FROM t;
SELECT min(b), max(b) FROM t;
SELECT min(b COLLATE NOCASE), max(b COLLATE NOCASE) FROM t;
SELECT min(nc COLLATE BINARY), max(nc COLLATE BINARY) FROM t;
-- An expression built from the column loses its collation.
SELECT max(nc || ''), min(nc || '') FROM t;

-- RTRIM: 'c' is the max either way; values are otherwise distinct.
SELECT max(rt), min(rt) FROM t;

-- Grouped, with NOCASE.
CREATE TABLE g(k TEXT, s TEXT COLLATE NOCASE);
INSERT INTO g VALUES ('p', 'x'), ('p', 'Y'), ('p', 'z'), ('q', 'B'), ('q', 'a');
SELECT k, min(s), max(s) FROM g GROUP BY k ORDER BY k;
SELECT k, min(s COLLATE BINARY), max(s COLLATE BINARY) FROM g GROUP BY k ORDER BY k;

-- Scalar (2-argument) max uses the collation too.
SELECT nc, max(nc, 'bb'), min(nc, 'bb') FROM t ORDER BY b;
