-- Tokenizing without whitespace, multi-character operators and unusual
-- spacing.

SELECT 1+2*3-4/2;
SELECT 1<2, 2<=2, 3>2, 3>=4, 1<>2, 1!=1, 1==1, 1=1;
SELECT 'a'||'b'||'c';
SELECT(1),(2);
SELECT-1,+2,-+-3;
SELECT 1 - -1, 1- -1, 1 -(-1);
SELECT	1	,	2;
SELECT
1
,
2
;
-- Operators adjacent to identifiers and literals.
CREATE TABLE t(a INTEGER,b INTEGER);
INSERT INTO t(a,b)VALUES(1,2),(3,4);
SELECT a+b,a*b,a||b,a<b FROM t ORDER BY a;
SELECT a FROM t WHERE a>=3 AND b<=4;
SELECT a FROM t WHERE(a=1)OR(b=4)ORDER BY a DESC;
SELECT t.a,t.b FROM t ORDER BY t.b;
SELECT"a",[b],`a`FROM"t"ORDER BY"a";
-- Numbers followed by dots and exponents.
SELECT 1.e2, .1e1, 1.5E+2, 1e-1;
-- Keywords in mixed case.
SeLeCt 'mixed' WhErE 1 AnD NoT 0;
-- A lone '!' is not an operator.
SELECT 1 ! 2;
-- '==' vs '=' vs '===' (the last is a syntax error).
SELECT 1 === 1;
