-- @db file
-- Rowids of every varint length, including 9-byte varints (>= 2^56),
-- the maximum and minimum 64-bit values, negative rowids, and big gaps.
-- Rows sort by rowid in the table b-tree, so negative keys come first.
-- @phase sqlite
PRAGMA page_size = 512;
CREATE TABLE r(id INTEGER PRIMARY KEY, label TEXT);
INSERT INTO r VALUES
  (-9223372036854775808, 'min'), (-9223372036854775807, 'min+1'),
  (-72057594037927936, '-2^56'), (-1, 'minus one'), (0, 'zero'), (1, 'one'),
  (127, '2^7-1'), (128, '2^7'), (16383, '2^14-1'), (16384, '2^14'),
  (2097151, '2^21-1'), (2097152, '2^21'), (268435455, '2^28-1'), (268435456, '2^28'),
  (34359738367, '2^35-1'), (34359738368, '2^35'), (4398046511103, '2^42-1'), (4398046511104, '2^42'),
  (562949953421311, '2^49-1'), (562949953421312, '2^49'),
  (72057594037927935, '2^56-1'), (72057594037927936, '2^56'),
  (9223372036854775806, 'max-1'), (9223372036854775807, 'max');
-- Many rows with huge, widely spaced keys so the tree has interior pages
-- whose separator keys are 9-byte varints.
CREATE TABLE sparse(k INTEGER PRIMARY KEY, v INTEGER);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 3000)
INSERT INTO sparse SELECT i * 3000000000000000 - 4611686018427387904, i FROM c;
-- A table without an explicit key, with explicit rowids.
CREATE TABLE plain(x);
INSERT INTO plain(rowid, x) VALUES (1000000, 'a'), (-3, 'b'), (7, 'c');
-- @phase engine
SELECT id, label FROM r ORDER BY id;
SELECT label FROM r WHERE id = 9223372036854775807;
SELECT label FROM r WHERE id = -9223372036854775808;
SELECT count(*) FROM r WHERE id < 0;
SELECT label FROM r WHERE id > 72057594037927935 ORDER BY id;
SELECT min(id), max(id) FROM r;
SELECT count(*), sum(v), min(k), max(k) FROM sparse;
SELECT k, v FROM sparse WHERE v IN (1, 1537, 3000) ORDER BY k;
SELECT v FROM sparse WHERE k = 1500 * 3000000000000000 - 4611686018427387904;
SELECT count(*) FROM sparse WHERE k > 0;
SELECT rowid, x FROM plain ORDER BY rowid;
SELECT x FROM plain WHERE rowid = 1000000;
