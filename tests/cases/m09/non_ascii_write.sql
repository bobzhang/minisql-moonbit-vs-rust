-- @db file
-- UTF-8 text written by the engine (accents, CJK, emoji, combining marks),
-- in data, in an index (ordered by bytes) and in table and column names.
-- @phase engine
CREATE TABLE "café"(id INTEGER PRIMARY KEY, "naïve" TEXT, note TEXT);
CREATE INDEX "café_idx" ON "café"("naïve");
INSERT INTO "café" VALUES
  (1, 'résumé', 'latin'), (2, '中文字符', 'cjk'), (3, '😀🎉', 'emoji'),
  (4, 'e' || char(769), 'combining'), (5, 'Ωmega', 'greek'), (6, 'zebra', 'ascii'),
  (7, 'Ärger', 'umlaut'), (8, '', 'empty'), (9, printf('%.*c', 3000, 'é'), 'long');
CREATE TABLE 表(键 INTEGER PRIMARY KEY, 值 TEXT UNIQUE);
INSERT INTO 表 VALUES (1, '一'), (2, '二'), (3, '三');
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT id, "naïve", length("naïve"), hex("naïve") FROM "café" WHERE id < 9 ORDER BY id;
SELECT id FROM "café" INDEXED BY "café_idx" ORDER BY "naïve", id;
SELECT length("naïve"), octet_length("naïve") FROM "café" WHERE id = 9;
SELECT 键 FROM 表 INDEXED BY sqlite_autoindex_表_1 WHERE 值 = '二';
INSERT INTO 表 VALUES (4, '四');
-- @phase engine
SELECT group_concat(值, '' ORDER BY 键) FROM 表;
SELECT id FROM "café" WHERE "naïve" = '😀🎉';
