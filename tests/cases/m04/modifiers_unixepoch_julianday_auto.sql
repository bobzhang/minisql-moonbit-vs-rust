-- 'unixepoch', 'julianday' and 'auto' decide how a numeric time value is
-- interpreted. They must come first among the modifiers.
SELECT datetime(0, 'unixepoch'), datetime(1710460800, 'unixepoch'), datetime(-86400, 'unixepoch');
SELECT datetime(1710460800.75, 'unixepoch'), datetime('1710460800', 'unixepoch');
SELECT date(2460384.5, 'julianday'), datetime(2460384.75, 'julianday'), datetime('2460384.5', 'julianday');

-- 'auto': values in 0.0 .. 5373484.499999 are Julian day numbers; other
-- values in the unix timestamp range are unix timestamps.
SELECT datetime(2460384.5, 'auto'), datetime(1710460800, 'auto'), datetime(0, 'auto');
SELECT datetime(5373484, 'auto'), datetime(5373485, 'auto'), datetime(-1, 'auto');
SELECT datetime(253402300799, 'auto'), datetime(253402300800, 'auto');

-- 'unixepoch' with a non-numeric time value gives NULL; so does
-- 'julianday' with a non-numeric value.
SELECT datetime('2024-03-15', 'unixepoch'), datetime('2024-03-15', 'julianday'), datetime('abc', 'unixepoch');
-- These modifiers may not follow another modifier.
SELECT datetime(0, '+1 day', 'unixepoch');

-- Followed by other modifiers.
SELECT datetime(1710460800, 'unixepoch', '+1 day', 'start of month');
SELECT date(1710460800, 'unixepoch', 'weekday 0');
SELECT unixepoch(2460384.5, 'julianday'), julianday(1710460800, 'unixepoch');

-- Converting stored epoch seconds.
CREATE TABLE ev(id INTEGER, t INTEGER);
INSERT INTO ev VALUES (1, 0), (2, 951782400), (3, 1709251199), (4, 1709251200);
SELECT id, datetime(t, 'unixepoch'), date(t, 'unixepoch', 'start of month') FROM ev ORDER BY id;
SELECT date(t, 'unixepoch', 'start of year') AS y, count(*) FROM ev GROUP BY y ORDER BY y;
