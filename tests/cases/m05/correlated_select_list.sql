-- Correlated scalar subqueries in the select list are evaluated once per
-- outer row, seeing that row's columns.
CREATE TABLE teams(tid INTEGER PRIMARY KEY, tname TEXT);
CREATE TABLE players(pid INTEGER PRIMARY KEY, tid INTEGER, pname TEXT, pts INTEGER);
INSERT INTO teams VALUES (1, 'reds'), (2, 'blues'), (3, 'greens');
INSERT INTO players VALUES (1, 1, 'ann', 10), (2, 1, 'bob', 25), (3, 2, 'cat', 7), (4, 2, 'dan', 7), (5, 2, 'eve', 30);

-- Counts and sums per outer row; teams with no players get 0 / NULL.
SELECT tname, (SELECT count(*) FROM players p WHERE p.tid = t.tid), (SELECT sum(pts) FROM players p WHERE p.tid = t.tid) FROM teams t ORDER BY tid;
-- Top scorer's name per team: first row of an ordered subquery.
SELECT tname, (SELECT pname FROM players p WHERE p.tid = t.tid ORDER BY pts DESC, pname) FROM teams t ORDER BY tid;
-- Lowest scorer with a tie broken by name.
SELECT tname, (SELECT pname FROM players p WHERE p.tid = t.tid ORDER BY pts, pname LIMIT 1) FROM teams t ORDER BY tid;
-- Per-player comparison with the team average.
SELECT pname, pts - (SELECT avg(pts) FROM players q WHERE q.tid = p.tid) FROM players p ORDER BY pid;
-- Rank within team by counting better teammates.
SELECT pname, 1 + (SELECT count(*) FROM players q WHERE q.tid = p.tid AND q.pts > p.pts) AS rnk FROM players p ORDER BY tid, rnk, pname;
-- Running total by pid.
SELECT pid, (SELECT sum(pts) FROM players q WHERE q.pid <= p.pid) FROM players p ORDER BY pid;
-- The outer column may be referenced unqualified when the inner tables do not have it.
SELECT tname, (SELECT count(*) FROM players WHERE players.tid = tid) FROM teams ORDER BY tid;
SELECT tname, (SELECT group_concat(pname, '+') FROM (SELECT pname FROM players WHERE players.tid = teams.tid ORDER BY pname)) FROM teams ORDER BY tid;
-- Correlated subquery used inside an expression and a function.
SELECT tname, coalesce((SELECT max(pts) FROM players p WHERE p.tid = t.tid), 0) * 2 FROM teams t ORDER BY tid;
SELECT upper(tname) || ':' || (SELECT count(*) FROM players p WHERE p.tid = t.tid) FROM teams t ORDER BY tid;
-- Two correlated subqueries in the same row.
SELECT tname, (SELECT min(pts) FROM players p WHERE p.tid = t.tid), (SELECT max(pts) FROM players p WHERE p.tid = t.tid) FROM teams t ORDER BY tid;
-- Correlated subquery referring to a joined outer row.
SELECT p.pname, t.tname, (SELECT count(*) FROM players q WHERE q.tid = t.tid AND q.pid <> p.pid) FROM players p JOIN teams t ON t.tid = p.tid ORDER BY p.pid;
-- Correlated subquery on a LEFT JOIN's NULL-extended side.
SELECT t.tname, p.pname, (SELECT count(*) FROM players q WHERE q.pts > p.pts) FROM teams t LEFT JOIN players p ON p.tid = t.tid AND p.pts > 20 ORDER BY t.tid;
