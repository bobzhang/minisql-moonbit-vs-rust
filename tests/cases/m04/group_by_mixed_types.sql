-- Grouping compares values like "=" with the column's affinity/collation:
-- integer 1 and real 1.0 fall in one group; text '1' is a different group.
-- To stay independent of which value represents a merged group, the tests
-- show aggregates or typeof counts rather than the key itself.
CREATE TABLE t(k, v INTEGER);
INSERT INTO t VALUES (1, 10), (1.0, 20), ('1', 30), ('1.0', 40), (2, 50), (x'01', 60), (x'01', 70), ('a', 80);
SELECT count(*), sum(v) FROM t GROUP BY k ORDER BY sum(v), count(*);
SELECT typeof(k), count(*) FROM t GROUP BY typeof(k) ORDER BY 1;

-- Groups are ordered by key with the usual cross-class order when the key
-- is unambiguous.
SELECT k, sum(v) FROM t WHERE typeof(k) <> 'real' AND v <> 10 GROUP BY k ORDER BY k;

-- With INTEGER affinity, '1' is stored as 1, so it joins the numeric group.
CREATE TABLE i(k INTEGER, v INTEGER);
INSERT INTO i VALUES (1, 10), ('1', 20), (1.0, 30), ('01', 40), ('x', 50);
SELECT k, typeof(k), count(*), sum(v) FROM i GROUP BY k ORDER BY k;

-- With TEXT affinity, 1 becomes '1' and 1.0 becomes '1.0'.
CREATE TABLE s(k TEXT, v INTEGER);
INSERT INTO s VALUES (1, 10), ('1', 20), (1.0, 30), ('1.0', 40);
SELECT k, typeof(k), count(*), sum(v) FROM s GROUP BY k ORDER BY k;

-- Grouping by an expression with mixed result types.
SELECT typeof(k + 0), count(*) FROM t GROUP BY typeof(k + 0) ORDER BY 1;
SELECT CAST(k AS INTEGER), count(*) FROM i GROUP BY 1 ORDER BY 1;
