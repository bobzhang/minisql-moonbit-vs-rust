-- @db file
-- Rows with rowids of every varint length, negative rowids, and the
-- extreme 64-bit values, written by the engine (9-byte varints in cells
-- and in interior-page keys). SQLite checks the table's key order.
-- @phase engine
CREATE TABLE r(id INTEGER PRIMARY KEY, label TEXT);
CREATE INDEX r_label ON r(label);
INSERT INTO r VALUES (-9223372036854775808, 'min'), (-1, 'minus one'), (0, 'zero'), (127, 'a'), (128, 'b'),
  (16383, 'c'), (16384, 'd'), (2097151, 'e'), (2097152, 'f'), (268435455, 'g'), (268435456, 'h'),
  (72057594037927935, 'i'), (72057594037927936, 'j'), (9223372036854775807, 'max');
CREATE TABLE sparse(k INTEGER PRIMARY KEY, v INTEGER);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 5000)
INSERT INTO sparse SELECT i * 1844674407370955 - 4611686018427387904, i FROM c;
CREATE TABLE plain(x);
INSERT INTO plain(rowid, x) VALUES (5, 'five'), (-5, 'minus five');
INSERT INTO plain(x) VALUES ('next');
-- @phase sqlite
PRAGMA integrity_check;
SELECT id, label FROM r ORDER BY id;
SELECT count(*), sum(v), min(k), max(k) FROM sparse;
SELECT v FROM sparse WHERE k = 2500 * 1844674407370955 - 4611686018427387904;
SELECT rowid, x FROM plain ORDER BY rowid;
SELECT id FROM r INDEXED BY r_label WHERE label = 'j';
-- @phase engine
SELECT count(*) FROM r WHERE id < 0;
SELECT label FROM r WHERE id = 9223372036854775807;
DELETE FROM sparse WHERE v % 2 = 0;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), sum(v) FROM sparse;
