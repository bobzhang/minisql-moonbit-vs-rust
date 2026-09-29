-- @db file
-- UTF-8 text stored by SQLite: accented Latin, CJK, emoji (4-byte UTF-8),
-- combining marks, in data, in an index, and in table/column names.
-- length() counts characters, octet_length() counts bytes; sorting is by
-- bytes (BINARY collation).
-- @phase sqlite
CREATE TABLE "café"(id INTEGER PRIMARY KEY, "naïve" TEXT, note TEXT);
CREATE INDEX café_naïve ON "café"("naïve");
INSERT INTO "café" VALUES
  (1, 'résumé', 'latin-1 range'), (2, '中文字符', 'cjk'), (3, '😀🎉', 'emoji'),
  (4, 'e' || char(769), 'combining acute'), (5, 'Ωmega', 'greek'), (6, 'zebra', 'ascii'),
  (7, 'Ärger', 'umlaut'), (8, '', 'empty'), (9, printf('%.*c', 300, 'é'), 'long accented');
CREATE TABLE 表(键 INTEGER PRIMARY KEY, 值 TEXT);
INSERT INTO 表 VALUES (1, '一'), (2, '二'), (3, '三');
-- @phase engine
SELECT id, "naïve", length("naïve"), octet_length("naïve") FROM "café" WHERE id < 9 ORDER BY id;
SELECT id FROM "café" ORDER BY "naïve", id;
SELECT id, note FROM "café" WHERE "naïve" = '中文字符';
SELECT id FROM "café" WHERE "naïve" > 'z' ORDER BY "naïve";
SELECT length("naïve"), octet_length("naïve"), substr("naïve", 299) FROM "café" WHERE id = 9;
SELECT substr("naïve", 2, 2), unicode("naïve"), hex("naïve") FROM "café" WHERE id IN (2, 3) ORDER BY id;
SELECT upper("naïve"), lower("naïve") FROM "café" WHERE id IN (1, 5, 7) ORDER BY id;
SELECT instr("naïve", '字'), replace("naïve", '中', '英') FROM "café" WHERE id = 2;
SELECT 值 FROM 表 ORDER BY 键 DESC;
SELECT group_concat(值, '・' ORDER BY 键) FROM 表;
SELECT count(*) FROM "café" WHERE "naïve" LIKE '%é%';
