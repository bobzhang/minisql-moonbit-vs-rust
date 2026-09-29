-- '+N months' and '+N years' change the month/year field and then
-- normalize: a day that does not exist in the new month rolls over into
-- the next month (so 2024-01-31 +1 month = 2024-03-02).
SELECT date('2024-03-15', '+1 month'), date('2024-03-15', '-1 month'), date('2024-03-15', '+12 months');
SELECT date('2024-12-15', '+1 month'), date('2024-01-15', '-1 month'), date('2024-03-15', '+13 months'), date('2024-03-15', '-25 months');
-- Month-end overflow.
SELECT date('2024-01-31', '+1 month'), date('2023-01-31', '+1 month'), date('2024-03-31', '+1 month'), date('2024-05-31', '-1 month');
SELECT date('2024-08-31', '+1 month'), date('2024-10-31', '+1 month'), date('2024-12-31', '-1 month');
-- Years.
SELECT date('2024-03-15', '+1 year'), date('2024-03-15', '-10 years'), date('2024-03-15', '+100 years');
-- Feb 29 plus a year.
SELECT date('2024-02-29', '+1 year'), date('2024-02-29', '+4 years'), date('2024-02-29', '-1 year'), date('2024-02-29', '-12 months');
-- Time of day is kept.
SELECT datetime('2024-01-31 18:30:00', '+1 month'), datetime('2024-06-15 01:02:03', '+2 years');
-- Chained.
SELECT date('2024-01-31', '+1 month', '+1 month'), date('2024-01-31', '+2 months');
SELECT date('2024-03-15', '+1 year', '-1 month', '+1 day');
-- Singular/plural and case.
SELECT date('2024-03-15', '+1 months'), date('2024-03-15', '+2 month'), date('2024-03-15', '+1 YEAR'), date('2024-03-15', '+3 years');

-- The last day of each month via start of month.
CREATE TABLE m(n INTEGER);
INSERT INTO m VALUES (1), (2), (3), (4), (5), (6), (7), (8), (9), (10), (11), (12);
SELECT n, date('2024-01-01', '+' || (n - 1) || ' months', '+1 month', '-1 day') FROM m ORDER BY n;
SELECT n, date('2023-01-31', '+' || n || ' months') FROM m WHERE n <= 4 ORDER BY n;
