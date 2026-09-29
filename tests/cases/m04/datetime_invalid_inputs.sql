-- Date/time functions return NULL (not an error) for invalid time values or
-- modifiers, and for NULL arguments.
SELECT date('2024-00-10'), date('2024-13-10'), date('2024-01-00'), date('2024-01-32');
SELECT time('25:00'), time('10:61'), time('10:00:61'), datetime('2024-03-15 10:00:00.');
SELECT date('abc'), date(''), date('2024-03'), date('2024-03-15 junk');
SELECT date(NULL), time(NULL), datetime(NULL), julianday(NULL), unixepoch(NULL), strftime('%Y', NULL);
SELECT date('2024-03-15', 'bogus'), date('2024-03-15', '+1 day', 'bogus'), date('2024-03-15', '+1 day', NULL);
-- Julian day numbers out of range.
SELECT date(-1), date(5373484.5), datetime(1e10);
-- Unix timestamps out of range.
SELECT datetime(1e15, 'unixepoch');
-- Results out of range after modifiers.
SELECT date('9999-12-31', '+1 day'), datetime('9999-12-31 23:59:59', '+1 second');

-- NULL results in queries.
CREATE TABLE t(id INTEGER, s TEXT);
INSERT INTO t VALUES (1, '2024-03-15'), (2, 'oops'), (3, NULL), (4, '2024-02-29'), (5, '2023-02-29x');
SELECT id, date(s), date(s) IS NULL FROM t ORDER BY id;
SELECT count(date(s)), count(*) FROM t;
SELECT id FROM t WHERE julianday(s) IS NULL ORDER BY id;

-- Wrong number of arguments is an error.
SELECT timediff('2024-01-01', '2024-01-02', '2024-01-03');
