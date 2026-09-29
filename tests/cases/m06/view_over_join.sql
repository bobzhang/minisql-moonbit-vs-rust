-- Views defined over joins (inner, outer, USING, NATURAL, self-joins).
CREATE TABLE dept(did INTEGER PRIMARY KEY, dname TEXT);
CREATE TABLE emp(eid INTEGER PRIMARY KEY, ename TEXT, did INTEGER, boss INTEGER);
INSERT INTO dept VALUES (1, 'eng'), (2, 'ops'), (3, 'hr');
INSERT INTO emp VALUES (1, 'ann', 1, NULL), (2, 'bob', 1, 1), (3, 'cy', 2, 1), (4, 'di', NULL, 3);

CREATE VIEW staff AS SELECT e.eid, e.ename, d.dname FROM emp e JOIN dept d ON d.did = e.did;
SELECT * FROM staff ORDER BY eid;
SELECT dname, count(*) FROM staff GROUP BY dname ORDER BY dname;
-- Outer join view keeps NULL-extended rows.
CREATE VIEW all_staff AS SELECT e.ename, d.dname FROM emp e LEFT JOIN dept d ON d.did = e.did;
SELECT ename, dname FROM all_staff ORDER BY ename;
SELECT ename FROM all_staff WHERE dname IS NULL;
CREATE VIEW dept_people AS SELECT d.dname, e.ename FROM emp e RIGHT JOIN dept d ON d.did = e.did;
SELECT dname, ename FROM dept_people ORDER BY dname, ename;
-- USING / NATURAL inside a view: * expands with the shared column once.
CREATE VIEW nat AS SELECT * FROM emp NATURAL JOIN dept;
SELECT * FROM nat ORDER BY eid;
CREATE VIEW usingv AS SELECT * FROM emp JOIN dept USING (did);
SELECT did, ename, dname FROM usingv ORDER BY eid;
-- Self-join view.
CREATE VIEW reports AS SELECT e.ename AS worker, m.ename AS manager FROM emp e JOIN emp m ON m.eid = e.boss;
SELECT worker, manager FROM reports ORDER BY worker;
-- Joining a view to a table and to another view.
SELECT r.worker, s.dname FROM reports r JOIN staff s ON s.ename = r.worker ORDER BY r.worker;
SELECT a.ename, r.manager FROM all_staff a LEFT JOIN reports r ON r.worker = a.ename ORDER BY a.ename;
-- Changes to either base table show through.
INSERT INTO dept VALUES (4, 'law');
UPDATE emp SET did = 4 WHERE eid = 4;
SELECT * FROM staff ORDER BY eid;
SELECT dname, ename FROM dept_people WHERE ename IS NULL ORDER BY dname;
