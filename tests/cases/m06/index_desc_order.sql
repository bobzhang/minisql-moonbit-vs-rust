-- DESC index columns and ORDER BY: whatever index exists, ORDER BY must
-- produce the requested order, including NULL placement and mixed directions.
CREATE TABLE ev(id INTEGER PRIMARY KEY, grp TEXT, ts INTEGER, score REAL);
INSERT INTO ev VALUES
  (1, 'a', 30, 1.5), (2, 'b', 10, NULL), (3, 'a', 20, 3.5), (4, 'b', NULL, 2.0),
  (5, 'a', 50, 0.5), (6, 'c', 40, 3.5), (7, 'b', 25, 1.0);
CREATE INDEX ev_ts_desc ON ev(ts DESC);
CREATE INDEX ev_grp_ts ON ev(grp ASC, ts DESC);

SELECT id FROM ev ORDER BY ts;
SELECT id FROM ev ORDER BY ts DESC;
SELECT id FROM ev ORDER BY ts DESC NULLS FIRST;
SELECT id FROM ev ORDER BY ts NULLS LAST;
SELECT id FROM ev WHERE ts > 20 ORDER BY ts DESC;
SELECT id FROM ev WHERE ts BETWEEN 10 AND 30 ORDER BY ts;
-- Mixed directions matching and not matching the index.
SELECT id FROM ev ORDER BY grp, ts DESC;
SELECT id FROM ev ORDER BY grp DESC, ts;
SELECT id FROM ev ORDER BY grp, ts;
SELECT id FROM ev WHERE grp = 'a' ORDER BY ts DESC;
SELECT id FROM ev WHERE grp = 'b' ORDER BY ts;
-- LIMIT on top of a DESC index order.
SELECT id FROM ev ORDER BY ts DESC LIMIT 3;
SELECT id FROM ev WHERE ts IS NOT NULL ORDER BY ts LIMIT 2 OFFSET 1;
-- min/max over a DESC-indexed column.
SELECT min(ts), max(ts) FROM ev;
SELECT grp, max(ts) FROM ev GROUP BY grp ORDER BY grp;
-- DESC unique index still enforces uniqueness.
CREATE TABLE u(v INTEGER);
CREATE UNIQUE INDEX u_v ON u(v DESC);
INSERT INTO u VALUES (3), (1), (2);
INSERT INTO u VALUES (2);
SELECT v FROM u ORDER BY v DESC;
SELECT v FROM u WHERE v < 3 ORDER BY v;
