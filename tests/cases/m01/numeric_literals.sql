-- Lexing of numeric literals: integers, decimals, exponents, leading and
-- trailing dots, hex integers.

SELECT 0, 123, 0123;
SELECT 1.5, .5, 5., 0.;
SELECT typeof(.5), typeof(5.), typeof(0.);
SELECT 1e3, 1E3, 1e+3, 1e-3, 1.5e2, .5e1, 5.e1;
SELECT typeof(1e3), typeof(1e-3);
-- Hex integer literals.
SELECT 0x0, 0x1F, 0X1f, 0xff, 0xABCDEF;
SELECT typeof(0x1F);
SELECT 0x7FFFFFFFFFFFFFFF;
-- Hex literals are 64-bit two's complement.
SELECT 0xFFFFFFFFFFFFFFFF, 0x8000000000000000;
-- A decimal integer literal too large for 64 bits becomes REAL.
SELECT 9223372036854775808, typeof(9223372036854775808);
SELECT 99999999999999999999;
-- Negative literals are unary minus applied to a literal.
SELECT -1.5, -.5, -1e3, -0x10;
-- Operators need no whitespace around literals.
SELECT 1+2, 3-1, 2*3, 7/2, 1.5+1, 1e2+1;
-- A hex literal wider than 64 bits is an error.
SELECT 0x10000000000000000;
-- A malformed number is an error.
SELECT 1e;
SELECT 0x;
SELECT 12abc;
