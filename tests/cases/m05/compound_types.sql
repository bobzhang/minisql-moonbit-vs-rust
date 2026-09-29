-- Values of different storage classes in compound queries. No affinity is
-- applied between the sides, so the integer 1 and the text '1' are distinct
-- rows; integer 1 and real 1.0 are equal values.
CREATE TABLE i(n INTEGER);
CREATE TABLE s(t TEXT);
CREATE TABLE r(x REAL);
INSERT INTO i VALUES (1), (2), (3);
INSERT INTO s VALUES ('1'), ('2'), ('abc');
INSERT INTO r VALUES (1.0), (2.5);

SELECT n, typeof(n) FROM i UNION SELECT t, typeof(t) FROM s ORDER BY 2, 1;
SELECT count(*) FROM (SELECT n FROM i UNION SELECT t FROM s);
SELECT n FROM i INTERSECT SELECT t FROM s;
SELECT n FROM i EXCEPT SELECT t FROM s ORDER BY n;
-- Integer vs real: 1 and 1.0 are the same value for UNION/INTERSECT/EXCEPT.
SELECT count(*) FROM (SELECT n FROM i UNION SELECT x FROM r);
SELECT count(*) FROM (SELECT 1 UNION SELECT 1.0);
SELECT count(*) FROM (SELECT n FROM i INTERSECT SELECT x FROM r);
SELECT n FROM i EXCEPT SELECT x FROM r ORDER BY n;
SELECT x FROM r EXCEPT SELECT n FROM i;
-- Mixed classes sort in the cross-class order NULL < numbers < text < blob.
SELECT v FROM (SELECT x'01' AS v UNION SELECT 'b' UNION SELECT 2 UNION SELECT NULL UNION SELECT 1.5 UNION SELECT 'a') ORDER BY v;
SELECT v FROM (SELECT x'01' AS v UNION SELECT 'b' UNION SELECT 2 UNION SELECT NULL UNION SELECT 1.5 UNION SELECT 'a') ORDER BY v DESC;
-- Blobs compare by bytes.
SELECT count(*) FROM (SELECT x'00' UNION SELECT x'0000' UNION SELECT x'00');
-- Text that looks like a number stays text through the compound.
SELECT typeof(v) FROM (SELECT '10' AS v UNION ALL SELECT 10) ORDER BY 1;
-- Inserting a compound result into a typed column applies that column's affinity afterwards.
CREATE TABLE dest(n INTEGER);
INSERT INTO dest SELECT t FROM s WHERE t <> 'abc' UNION ALL SELECT n FROM i;
SELECT n, typeof(n) FROM dest ORDER BY n;
SELECT count(DISTINCT n) FROM dest;
