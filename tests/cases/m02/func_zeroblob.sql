-- zeroblob(N): a blob of N zero bytes (0 bytes if N <= 0).

SELECT zeroblob(0), zeroblob(1), zeroblob(4), typeof(zeroblob(2));
SELECT length(zeroblob(100)), hex(zeroblob(3)), zeroblob(-5);
-- The argument is converted to an integer.
SELECT zeroblob('3'), zeroblob(2.9), length(zeroblob('10'));
-- Blob comparisons with zeroblob.
SELECT zeroblob(2) = x'0000', zeroblob(2) < x'0001', zeroblob(0) = x'';
-- zeroblob results in blob functions.
SELECT hex(substr(zeroblob(4), 2, 2)), instr(x'01' || zeroblob(2), x'00'), quote(zeroblob(2));
-- Storing zeroblobs.
CREATE TABLE t(id INTEGER, b BLOB);
INSERT INTO t VALUES (1, zeroblob(2)), (2, zeroblob(0)), (3, zeroblob(5));
SELECT id, b, length(b), typeof(b) FROM t ORDER BY id;
SELECT id FROM t WHERE b = zeroblob(2);
SELECT id FROM t ORDER BY b DESC;
-- Wrong number of arguments.
SELECT zeroblob();
