-- @db file
-- Records with many columns written by the engine: 150 columns (the record
-- header is longer than 127 bytes, so its size varint takes 2 bytes), then
-- rows with large text in many columns so one record spans overflow pages.
-- SQLite adds a column and copies the table with CREATE TABLE ... AS.
-- @phase engine
CREATE TABLE w(c0 INTEGER, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15, c16, c17, c18, c19, c20, c21, c22, c23, c24, c25, c26, c27, c28, c29, c30, c31, c32, c33, c34, c35, c36, c37, c38, c39, c40, c41, c42, c43, c44, c45, c46, c47, c48, c49, c50, c51, c52, c53, c54, c55, c56, c57, c58, c59, c60, c61, c62, c63, c64, c65, c66, c67, c68, c69, c70, c71, c72, c73, c74, c75, c76, c77, c78, c79, c80, c81, c82, c83, c84, c85, c86, c87, c88, c89, c90, c91, c92, c93, c94, c95, c96, c97, c98, c99, c100, c101, c102, c103, c104, c105, c106, c107, c108, c109, c110, c111, c112, c113, c114, c115, c116, c117, c118, c119, c120, c121, c122, c123, c124, c125, c126, c127, c128, c129, c130, c131, c132, c133, c134, c135, c136, c137, c138, c139, c140, c141, c142, c143, c144, c145, c146, c147, c148, c149 TEXT);
INSERT INTO w(c0, c1, c64, c127, c128, c149) VALUES (1, 'one', 64, 127, 128, 'last');
INSERT INTO w(c0) VALUES (2);
INSERT INTO w(c0, c149) VALUES (3, 'only last');
CREATE INDEX w_149 ON w(c149, c0);
-- @phase sqlite
PRAGMA integrity_check;
SELECT c0, c1, c64, c127, c128, c149, c2 FROM w ORDER BY c0;
SELECT c0 FROM w INDEXED BY w_149 WHERE c149 = 'last';
ALTER TABLE w ADD COLUMN c150 DEFAULT 'added';
CREATE TABLE wide AS SELECT w.*, w.c0 AS d0, w.c1 AS d1 FROM w;
-- @phase engine
SELECT c0, c150, d1 FROM wide ORDER BY c0;
UPDATE w SET c100 = printf('%.*c', 3000, 'x'), c140 = 'forty' WHERE c0 = 1;
INSERT INTO w(c0, c10, c20, c30, c40, c50, c60, c70, c80, c90, c100) VALUES
  (4, printf('%.*c', 1000, 'a'), printf('%.*c', 1000, 'b'), printf('%.*c', 1000, 'c'), printf('%.*c', 1000, 'd'), printf('%.*c', 1000, 'e'),
   printf('%.*c', 1000, 'f'), printf('%.*c', 1000, 'g'), printf('%.*c', 1000, 'h'), printf('%.*c', 1000, 'i'), 'hundred');
-- @phase sqlite
PRAGMA integrity_check;
SELECT c0, length(c100), c140, c149, c150 FROM w ORDER BY c0;
SELECT length(c10) + length(c20) + length(c90), substr(c50, 1, 3), c100 FROM w WHERE c0 = 4;
