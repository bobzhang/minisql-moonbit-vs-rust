-- @db file
-- An index over an untyped column holding every storage class. Index
-- b-tree order is NULL < numbers (integers and reals compared by value) <
-- text < blob. Range and equality queries must honour that order and
-- numeric equality between 2 and 2.0.
-- @phase sqlite
PRAGMA page_size = 512;
CREATE TABLE m(id INTEGER PRIMARY KEY, v);
CREATE INDEX m_v ON m(v);
INSERT INTO m(v) VALUES (NULL), (2), (2.0), (1.5), (-7), ('2'), ('abc'), ('ABC'), (x'00'), (x''), (''),
  (9223372036854775807), (-9223372036854775808), (1e300), (-1e300), (0), (-0.0), (x'FF'), ('é'), (NULL);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 500)
INSERT INTO m(v) SELECT CASE i % 4 WHEN 0 THEN i WHEN 1 THEN i + 0.5 WHEN 2 THEN 't' || i ELSE unhex(printf('%04X', i)) END FROM c;
-- @phase engine
SELECT id, v, typeof(v) FROM m WHERE id <= 20 ORDER BY v, id;
SELECT id FROM m WHERE v = 2 ORDER BY id;
SELECT id FROM m WHERE v = '2';
SELECT count(*) FROM m WHERE v IS NULL;
SELECT count(*) FROM m WHERE v > 100 AND v < 200;
SELECT count(*) FROM m WHERE v >= 't' AND v < 'u';
SELECT count(*) FROM m WHERE v >= x'00';
SELECT typeof(v), count(*) FROM m GROUP BY typeof(v) ORDER BY 1;
SELECT id, v FROM m WHERE v BETWEEN 't100' AND 't120' ORDER BY v;
SELECT min(v), max(v) FROM m WHERE typeof(v) = 'text';
SELECT id FROM m ORDER BY v DESC, id DESC LIMIT 3;
