-- Joins on INTEGER PRIMARY KEY / rowid columns, and joins where one side's
-- key is a rowid alias and the other side stores text or real keys.
CREATE TABLE parent(id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE child(cid INTEGER PRIMARY KEY, parent_id, note TEXT);
INSERT INTO parent VALUES (1, 'one'), (2, 'two'), (5, 'five');
INSERT INTO child VALUES (10, 1, 'a'), (11, '2', 'b'), (12, 2.0, 'c'), (13, 7, 'd'), (14, NULL, 'e');

-- The IPK column has INTEGER affinity, so '2' and 2.0 match id 2.
SELECT note, name FROM child JOIN parent ON parent.id = child.parent_id ORDER BY cid;
SELECT note, name FROM child JOIN parent ON child.parent_id = parent.id ORDER BY cid;
-- rowid, oid and _rowid_ all name the same key.
SELECT note, name FROM child JOIN parent ON parent.rowid = child.parent_id ORDER BY cid;
SELECT count(*) FROM child JOIN parent ON parent.oid = child.parent_id;
SELECT count(*) FROM child JOIN parent ON parent._rowid_ = child.parent_id;
-- LEFT JOIN on the rowid.
SELECT note, name FROM child LEFT JOIN parent ON parent.id = child.parent_id ORDER BY cid;
-- Joining rowid to rowid.
SELECT p.name, c.note FROM parent p JOIN child c ON c.rowid - 9 = p.rowid ORDER BY p.id;
-- A table without an explicit IPK still has a rowid for joins.
CREATE TABLE tags(label TEXT);
INSERT INTO tags VALUES ('red'), ('green'), ('blue');
SELECT t.rowid, t.label, p.name FROM tags t JOIN parent p ON p.id = t.rowid ORDER BY t.rowid;
SELECT t.label, p.name FROM tags t LEFT JOIN parent p ON p.id = t.rowid ORDER BY t.label;
-- Range joins on the key.
SELECT p.name, count(c.cid) FROM parent p LEFT JOIN child c ON c.cid > p.id + 10 GROUP BY p.id ORDER BY p.id;
-- After updates to the key, joins see the new values.
UPDATE parent SET id = 7 WHERE id = 5;
SELECT note, name FROM child JOIN parent ON parent.id = child.parent_id ORDER BY cid;
DELETE FROM parent WHERE id = 1;
SELECT note, name FROM child LEFT JOIN parent ON parent.id = child.parent_id ORDER BY cid;
