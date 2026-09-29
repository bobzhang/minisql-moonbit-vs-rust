-- Multi-column UNIQUE indexes: only the combination must be unique.
CREATE TABLE seats(hall TEXT, rownum INTEGER, seat INTEGER, holder TEXT);
CREATE UNIQUE INDEX seats_pos ON seats(hall, rownum, seat);
INSERT INTO seats VALUES ('A', 1, 1, 'ann'), ('A', 1, 2, 'bob'), ('A', 2, 1, 'cy'), ('B', 1, 1, 'di');

-- Full duplicate combination fails.
INSERT INTO seats VALUES ('A', 1, 2, 'eve');
-- Any differing column is fine.
INSERT INTO seats VALUES ('A', 1, 3, 'eve'), ('B', 1, 2, 'fay'), ('C', 1, 2, 'gus');
SELECT hall, rownum, seat, holder FROM seats ORDER BY hall, rownum, seat;
-- Updates that create a duplicate combination fail.
UPDATE seats SET seat = 1 WHERE holder = 'bob';
UPDATE seats SET hall = 'A' WHERE holder = 'di';
-- Updates that keep combinations unique succeed.
UPDATE seats SET rownum = 5 WHERE hall = 'A' AND rownum = 1;
SELECT hall, rownum, seat FROM seats WHERE hall = 'A' ORDER BY rownum, seat;
-- Lookups on a prefix of the index columns.
SELECT holder FROM seats WHERE hall = 'B' ORDER BY seat;
SELECT holder FROM seats WHERE hall = 'A' AND rownum = 5 ORDER BY seat DESC;
-- Lookups on a non-prefix column still work.
SELECT holder FROM seats WHERE seat = 2 ORDER BY holder;
-- Column order in the index definition does not affect what is unique.
CREATE TABLE pairs(x INTEGER, y INTEGER);
CREATE UNIQUE INDEX pairs_yx ON pairs(y, x);
INSERT INTO pairs VALUES (1, 2), (2, 1);
INSERT INTO pairs VALUES (1, 2);
SELECT x, y FROM pairs ORDER BY x;
-- Table-level UNIQUE (a, b) behaves the same as a unique index.
CREATE TABLE tl(a INTEGER, b INTEGER, UNIQUE (a, b));
INSERT INTO tl VALUES (1, 1), (1, 2), (2, 1);
INSERT INTO tl VALUES (1, 2);
SELECT count(*) FROM tl;
-- Upsert targeting the multi-column unique index.
INSERT INTO seats VALUES ('C', 1, 2, 'hal') ON CONFLICT (hall, rownum, seat) DO UPDATE SET holder = excluded.holder;
SELECT holder FROM seats WHERE hall = 'C';
