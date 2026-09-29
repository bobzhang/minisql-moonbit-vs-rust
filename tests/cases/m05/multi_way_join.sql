-- Joins of three and four tables, mixing join kinds and conditions that
-- reference several earlier tables.
CREATE TABLE students(sid INTEGER PRIMARY KEY, sname TEXT);
CREATE TABLE courses(cid INTEGER PRIMARY KEY, title TEXT, teacher_id INTEGER);
CREATE TABLE teachers(tid INTEGER PRIMARY KEY, tname TEXT);
CREATE TABLE enroll(sid INTEGER, cid INTEGER, grade INTEGER);
INSERT INTO students VALUES (1, 'amy'), (2, 'ben'), (3, 'cal'), (4, 'dia');
INSERT INTO teachers VALUES (10, 'prof x'), (11, 'prof y'), (12, 'prof z');
INSERT INTO courses VALUES (100, 'math', 10), (101, 'art', 11), (102, 'bio', 10), (103, 'law', NULL);
INSERT INTO enroll VALUES (1, 100, 90), (1, 101, 85), (2, 100, 70), (3, 102, 88), (3, 103, 60), (2, 104, 50);

-- Three-way inner join.
SELECT sname, title, grade FROM students s JOIN enroll e ON e.sid = s.sid JOIN courses c ON c.cid = e.cid ORDER BY sname, title;
-- Four-way inner join: the course without a teacher and the dangling enrollment vanish.
SELECT sname, title, tname FROM students s JOIN enroll e ON e.sid = s.sid
  JOIN courses c ON c.cid = e.cid JOIN teachers t ON t.tid = c.teacher_id ORDER BY sname, title;
-- The same using comma syntax and WHERE.
SELECT sname, title, tname FROM students s, enroll e, courses c, teachers t
  WHERE e.sid = s.sid AND c.cid = e.cid AND t.tid = c.teacher_id ORDER BY sname, title;
-- Left joins all the way down keep every student.
SELECT sname, title, tname FROM students s LEFT JOIN enroll e ON e.sid = s.sid
  LEFT JOIN courses c ON c.cid = e.cid LEFT JOIN teachers t ON t.tid = c.teacher_id ORDER BY sname, title;
-- Inner join after a left join removes the NULL-extended rows again.
SELECT sname, title FROM students s LEFT JOIN enroll e ON e.sid = s.sid JOIN courses c ON c.cid = e.cid ORDER BY sname, title;
-- Teachers' student counts, including teachers with no students.
SELECT tname, count(DISTINCT e.sid) FROM teachers t LEFT JOIN courses c ON c.teacher_id = t.tid
  LEFT JOIN enroll e ON e.cid = c.cid GROUP BY t.tid ORDER BY t.tid;
-- An ON clause that references a table two steps back.
SELECT sname, title FROM students s JOIN enroll e ON e.sid = s.sid JOIN courses c ON c.cid = e.cid AND s.sid <> 1 ORDER BY sname, title;
-- Join order does not change inner-join results.
SELECT sname, title FROM courses c JOIN enroll e ON c.cid = e.cid JOIN students s ON e.sid = s.sid ORDER BY sname, title;
-- Averages per teacher through three joins.
SELECT tname, avg(grade) FROM teachers t JOIN courses c ON c.teacher_id = t.tid JOIN enroll e ON e.cid = c.cid GROUP BY tname ORDER BY tname;
-- Four-way with a table used twice.
SELECT s1.sname, s2.sname, c.title FROM enroll e1 JOIN enroll e2 ON e1.cid = e2.cid AND e1.sid < e2.sid
  JOIN students s1 ON s1.sid = e1.sid JOIN students s2 ON s2.sid = e2.sid JOIN courses c ON c.cid = e1.cid ORDER BY 1, 2;
-- Students with the best grade in each course (join against an aggregate subquery).
SELECT c.title, s.sname, e.grade FROM enroll e JOIN (SELECT cid, max(grade) AS g FROM enroll GROUP BY cid) b
  ON b.cid = e.cid AND b.g = e.grade JOIN students s ON s.sid = e.sid JOIN courses c ON c.cid = e.cid ORDER BY c.title;
