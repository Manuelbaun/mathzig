# Math.js Feature List

A comprehensive documentation of all mathjs features organized by category. This document serves as a reference for comparing mathjs functionality with the mathzig implementation.

---

## Table of Contents

1. [Data Types](#1-data-types)
2. [Arithmetic Operations](#2-arithmetic-operations)
3. [Trigonometry](#3-trigonometry)
4. [Complex Numbers](#4-complex-numbers)
5. [Matrix Operations](#5-matrix-operations)
6. [Algebra](#6-algebra)
7. [Statistics](#7-statistics)
8. [Probability & Combinatorics](#8-probability--combinatorics)
9. [Set Operations](#9-set-operations)
10. [Units](#10-units)
11. [Expression Parsing & Evaluation](#11-expression-parsing--evaluation)
12. [Relational & Logical Operations](#12-relational--logical-operations)
13. [Bitwise Operations](#13-bitwise-operations)
14. [Geometry](#14-geometry)
15. [Signal Processing](#15-signal-processing)
16. [Numeric Solvers](#16-numeric-solvers)
17. [String/Formatting](#17-stringformatting)
18. [Utility Functions](#18-utility-functions)
19. [Constants](#19-constants)
20. [Core/Configuration](#20-coreconfiguration)

---

## Summary Statistics

| Category | Function Count |
|----------|----------------|
| Data Types | 13 |
| Arithmetic Operations | 35 |
| Trigonometry | 24 |
| Complex Numbers | 4 |
| Matrix Operations | 40+ |
| Algebra | 18+ |
| Statistics | 13 |
| Probability & Combinatorics | 12+ |
| Set Operations | 9 |
| Units | 4 |
| Expression Parsing & Evaluation | 5 |
| Relational & Logical Operations | 13 |
| Bitwise Operations | 7 |
| Geometry | 2 |
| Signal Processing | 3 |
| Numeric Solvers | 1 |
| String/Formatting | 6+ |
| Utility Functions | 18+ |
| Constants | 15+ |
| Core/Configuration | 5+ |
| **Total** | **250+** |

---

## 1. Data Types

Mathjs supports a variety of data types for numerical and symbolic computation.

### 1.1 Numeric Types

| Type | Constructor | Description |
|------|-------------|-------------|
| **Number** | [`math.number()`](libs/mathjs/src/expression/embeddedDocs/construction/number.js) | Standard JavaScript floating-point number (64-bit IEEE 754) |
| **BigNumber** | [`math.bignumber()`](libs/mathjs/src/expression/embeddedDocs/construction/bignumber.js) | Arbitrary precision decimal number |
| **Fraction** | [`math.fraction()`](libs/mathjs/src/expression/embeddedDocs/construction/fraction.js) | Exact rational number representation |
| **Complex** | [`math.complex()`](libs/mathjs/src/expression/embeddedDocs/construction/complex.js) | Complex number with real and imaginary parts |
| **BigInt** | [`math.bigint()`](libs/mathjs/src/expression/embeddedDocs/construction/bigint.js) | JavaScript BigInt for arbitrary precision integers |

### 1.2 Collection Types

| Type | Constructor | Description |
|------|-------------|-------------|
| **Matrix** | [`math.matrix()`](libs/mathjs/src/expression/embeddedDocs/construction/matrix.js) | Mathematical matrix (wrapper for DenseMatrix/SparseMatrix) |
| **DenseMatrix** | `math.matrix({ dense: true })` | Matrix stored as dense 2D array |
| **SparseMatrix** | `math.matrix({ sparse: true })` | Matrix stored in sparse format for memory efficiency |
| **Array** | `[]` or `math.array()` | Standard JavaScript array (1D or 2D) |
| **Range** | `math.range()` | Sequence of numbers with start, step, end |
| **Sparse** | [`math.sparse()`](libs/mathjs/src/expression/embeddedDocs/construction/sparse.js) | Create sparse matrix structure |

### 1.3 Other Types

| Type | Constructor | Description |
|------|-------------|-------------|
| **Unit** | [`math.unit()`](libs/mathjs/src/expression/embeddedDocs/construction/unit.js) | Quantity with associated unit of measurement |
| **String** | [`math.string()`](libs/mathjs/src/expression/embeddedDocs/construction/string.js) | String type for text operations |
| **Boolean** | [`math.boolean()`](libs/mathjs/src/expression/embeddedDocs/construction/boolean.js) | true/false values |
| **Date** | Built-in | JavaScript Date objects |

---

## 2. Arithmetic Operations

### 2.1 Basic Operations

| Function | Description |
|----------|-------------|
| [`add(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/add.js) | Addition: a + b |
| [`subtract(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/subtract.js) | Subtraction: a - b |
| [`multiply(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/multiply.js) | Multiplication: a * b |
| [`divide(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/divide.js) | Division: a / b |
| [`mod(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/mod.js) | Modulo: a % b |

### 2.2 Powers and Roots

| Function | Description |
|----------|-------------|
| [`pow(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/pow.js) | Power: a^b |
| [`sqrt(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/sqrt.js) | Square root: √a |
| [`cbrt(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/cbrt.js) | Cube root: ∛a |
| [`nthRoot(a, n)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/nthRoot.js) | nth root: ⁿ√a |
| [`square(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/square.js) | Square: a² |
| [`cube(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/cube.js) | Cube: a³ |
| [`sqrtm(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/sqrtm.js) | Matrix square root |

### 2.3 Logarithms and Exponentials

| Function | Description |
|----------|-------------|
| [`exp(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/exp.js) | Exponential: e^a |
| [`expm(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/expm.js) | Matrix exponential |
| [`expm1(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/expm1.js) | exp(a) - 1 (for small a) |
| [`log(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/log.js) | Natural logarithm: ln(a) |
| [`log10(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/log10.js) | Base-10 logarithm: log₁₀(a) |
| [`log2(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/log2.js) | Base-2 logarithm: log₂(a) |
| [`log1p(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/log1p.js) | ln(1 + a) (for small a) |

### 2.4 Rounding Functions

| Function | Description |
|----------|-------------|
| [`abs(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/abs.js) | Absolute value: \|a\| |
| [`ceil(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/ceil.js) | Round up to nearest integer |
| [`floor(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/floor.js) | Round down to nearest integer |
| [`fix(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/fix.js) | Round towards zero |
| [`round(a, n)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/round.js) | Round to n decimal places |
| [`sign(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/sign.js) | Sign of number (-1, 0, or 1) |

### 2.5 Number Theory

| Function | Description |
|----------|-------------|
| [`gcd(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/gcd.js) | Greatest common divisor |
| [`lcm(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/lcm.js) | Least common multiple |
| [`xgcd(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/xgcd.js) | Extended GCD (returns [gcd, x, y]) |
| [`factorial(n)`](libs/mathjs/src/expression/embeddedDocs/function/probability/factorial.js) | Factorial n! |
| [`isPrime(n)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isPrime.js) | Check if number is prime |

### 2.6 Unary Operations

| Function | Description |
|----------|-------------|
| [`unaryMinus(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/unaryMinus.js) | Negation: -a |
| [`unaryPlus(a)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/unaryPlus.js) | Unary plus: +a |

### 2.7 Vector/Matrix Operations

| Function | Description |
|----------|-------------|
| [`norm(a, p)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/norm.js) | Vector/matrix norm (p-norm) |
| [`dot(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/dot.js) | Dot product of two vectors |
| [`cross(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/cross.js) | Cross product of two vectors |
| [`hypot(a, b, ...)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/hypot.js) | Hypotenuse: √(a² + b² + ...) |

### 2.8 Element-wise Operations

| Function | Description |
|----------|-------------|
| [`dotMultiply(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/dotMultiply.js) | Element-wise multiplication: a .* b |
| [`dotDivide(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/dotDivide.js) | Element-wise division: a ./ b |
| [`dotPow(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/dotPow.js) | Element-wise power: a .^ b |

### 2.9 Other Arithmetic

| Function | Description |
|----------|-------------|
| [`invmod(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/invmod.js) | Modular inverse |
| [`nthRoots(a, n)`](libs/mathjs/src/expression/embeddedDocs/function/arithmetic/nthRoots.js) | All nth roots of a complex number |

---

## 3. Trigonometry

### 3.1 Standard Trigonometric Functions

| Function | Description |
|----------|-------------|
| [`sin(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/sin.js) | Sine: sin(x) |
| [`cos(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/cos.js) | Cosine: cos(x) |
| [`tan(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/tan.js) | Tangent: tan(x) |

### 3.2 Inverse Trigonometric Functions

| Function | Description |
|----------|-------------|
| [`asin(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/asin.js) | Arc sine: arcsin(x) |
| [`acos(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/acos.js) | Arc cosine: arccos(x) |
| [`atan(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/atan.js) | Arc tangent: arctan(x) |
| [`atan2(y, x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/atan2.js) | Arc tangent of y/x (2-argument) |

### 3.3 Hyperbolic Functions

| Function | Description |
|----------|-------------|
| [`sinh(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/sinh.js) | Hyperbolic sine: sinh(x) |
| [`cosh(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/cosh.js) | Hyperbolic cosine: cosh(x) |
| [`tanh(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/tanh.js) | Hyperbolic tangent: tanh(x) |

### 3.4 Inverse Hyperbolic Functions

| Function | Description |
|----------|-------------|
| [`asinh(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/asinh.js) | Inverse hyperbolic sine: arcsinh(x) |
| [`acosh(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/acosh.js) | Inverse hyperbolic cosine: arccosh(x) |
| [`atanh(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/atanh.js) | Inverse hyperbolic tangent: arctanh(x) |

### 3.3 Reciprocal Trigonometric Functions

| Function | Description |
|----------|-------------|
| [`csc(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/csc.js) | Cosecant: csc(x) = 1/sin(x) |
| [`sec(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/sec.js) | Secant: sec(x) = 1/cos(x) |
| [`cot(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/cot.js) | Cotangent: cot(x) = 1/tan(x) |

### 3.4 Inverse Reciprocal Trigonometric Functions

| Function | Description |
|----------|-------------|
| [`acsc(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/acsc.js) | Inverse cosecant: arccsc(x) |
| [`asec(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/asec.js) | Inverse secant: arcsec(x) |
| [`acot(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/acot.js) | Inverse cotangent: arccot(x) |

### 3.5 Hyperbolic Reciprocal Functions

| Function | Description |
|----------|-------------|
| [`csch(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/csch.js) | Hyperbolic cosecant: csch(x) |
| [`sech(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/sech.js) | Hyperbolic secant: sech(x) |
| [`coth(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/coth.js) | Hyperbolic cotangent: coth(x) |

### 3.6 Inverse Hyperbolic Reciprocal Functions

| Function | Description |
|----------|-------------|
| [`acsch(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/acsch.js) | Inverse hyperbolic cosecant: arccsch(x) |
| [`asech(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/asech.js) | Inverse hyperbolic secant: arcsech(x) |
| [`acoth(x)`](libs/mathjs/src/expression/embeddedDocs/function/trigonometry/acoth.js) | Inverse hyperbolic cotangent: arccoth(x) |

---

## 4. Complex Numbers

| Function | Description |
|----------|-------------|
| [`arg(z)`](libs/mathjs/src/expression/embeddedDocs/function/complex/arg.js) | Argument (phase angle) of complex number |
| [`conj(z)`](libs/mathjs/src/expression/embeddedDocs/function/complex/conj.js) | Complex conjugate |
| [`re(z)`](libs/mathjs/src/expression/embeddedDocs/function/complex/re.js) | Real part of complex number |
| [`im(z)`](libs/mathjs/src/expression/embeddedDocs/function/complex/im.js) | Imaginary part of complex number |

---

## 5. Matrix Operations

### 5.1 Matrix Creation

| Function | Description |
|----------|-------------|
| [`matrix()`](libs/mathjs/src/expression/embeddedDocs/construction/matrix.js) | Create a matrix from array |
| [`ones(m, n)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/ones.js) | Create matrix of all ones |
| [`zeros(m, n)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/zeros.js) | Create matrix of all zeros |
| [`identity(n)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/identity.js) | Create identity matrix |
| [`diag(v)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/diag.js) | Create diagonal matrix |
| [`range(start, end, step)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/range.js) | Create range sequence |
| [`concat(a, b, ...)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/concat.js) | Concatenate matrices/arrays |
| [`matrixFromRows()`](libs/mathjs/src/expression/embeddedDocs/function/matrix/matrixFromRows.js) | Create matrix from row arrays |
| [`matrixFromColumns()`](libs/mathjs/src/expression/embeddedDocs/function/matrix/matrixFromColumns.js) | Create matrix from column arrays |
| [`matrixFromFunction()`](libs/mathjs/src/expression/embeddedDocs/function/matrix/matrixFromFunction.js) | Create matrix from function |
| [`sparse()`](libs/mathjs/src/expression/embeddedDocs/construction/sparse.js) | Create sparse matrix |

### 5.2 Element Access

| Function | Description |
|----------|-------------|
| [`subset(matrix, index)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/subset.js) | Get/set subset of matrix |
| [`get(matrix, path)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/get.js) | Get value at path |
| [`set(matrix, path, value)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/set.js) | Set value at path |
| [`remove(matrix, index)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/remove.js) | Remove element from matrix |
| [`resize(matrix, size)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/resize.js) | Resize matrix |
| [`reshape(matrix, size)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/reshape.js) | Reshape matrix dimensions |

### 5.3 Element-wise Operations

| Function | Description |
|----------|-------------|
| [`map(matrix, fn)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/map.js) | Apply function to each element |
| [`forEach(matrix, fn)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/forEach.js) | Iterate over elements |
| [`filter(matrix, condition)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/filter.js) | Filter elements by condition |
| [`flatten(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/flatten.js) | Flatten to 1D array |
| [`squeeze(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/squeeze.js) | Remove singleton dimensions |
| [`flatten()`](libs/mathjs/src/expression/embeddedDocs/function/matrix/flatten.js) | Flatten multi-dimensional array |

### 5.4 Matrix Manipulation

| Function | Description |
|----------|-------------|
| [`transpose(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/transpose.js) | Transpose matrix |
| [`ctranspose(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/ctranspose.js) | Conjugate transpose (Hermitian) |
| [`flipud(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/flipud.js) | Flip matrix vertically |
| [`fliplr(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/fliplr.js) | Flip matrix horizontally |
| [`rotate(matrix, angle)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/rotate.js) | Rotate matrix |
| [`sort(matrix, compare)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/sort.js) | Sort matrix elements |
| [`row(matrix, index)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/row.js) | Get row as matrix |
| [`column(matrix, index)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/column.js) | Get column as matrix |

### 5.5 Linear Algebra

| Function | Description |
|----------|-------------|
| [`det(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/det.js) | Determinant |
| [`inv(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/inv.js) | Matrix inverse |
| [`pinv(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/pinv.js) | Moore-Penrose pseudoinverse |
| [`trace(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/trace.js) | Trace (sum of diagonal) |
| [`rank(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/rank.js) | Matrix rank |
| [`kron(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/kron.js) | Kronecker product |
| [`eigs(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/eigs.js) | Eigenvalues and eigenvectors |
| [`dot(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/dot.js) | Dot product |
| [`cross(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/cross.js) | Cross product |

### 5.6 Matrix Decomposition

| Function | Description |
|----------|-------------|
| [`lu(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/lu.js) | LU decomposition |
| [`lup(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/lup.js) | LUP decomposition (with pivoting) |
| [`qr(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/qr.js) | QR decomposition |
| [`svd(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/svd.js) | Singular value decomposition |
| [`schur(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/schur.js) | Schur decomposition |
| [`slu(matrix, threshold)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/slu.js) | Sparse LU decomposition |

### 5.7 Matrix Information

| Function | Description |
|----------|-------------|
| [`size(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/size.js) | Get size/dimensions |
| [`count(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/count.js) | Count elements |
| [`getMatrixDataType(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/getMatrixDataType.js) | Get data type |

### 5.8 Selection and Partitioning

| Function | Description |
|----------|-------------|
| [`diff(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/diff.js) | Discrete difference |
| [`partitionSelect(matrix, n)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/partitionSelect.js) | Partition and select nth element |

---

## 6. Algebra

### 6.1 Equation Solving

| Function | Description |
|----------|-------------|
| [`lsolve(A, b)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/lsolve.js) | Solve linear system Ax = b |
| [`lusolve(A, b)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/lusolve.js) | Solve using LU decomposition |
| [`usolve(A, b)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/usolve.js) | Solve upper triangular system |
| [`lsolveAll(A, b)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/lsolveAll.js) | Solve for all solutions |
| [`usolveAll(A, b)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/usolveAll.js) | Solve upper triangular (all solutions) |

### 6.2 Matrix Decomposition

| Function | Description |
|----------|-------------|
| [`lup(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/lup.js) | LUP decomposition |
| [`qr(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/qr.js) | QR decomposition |
| [`schur(matrix)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/schur.js) | Schur decomposition |
| [`slu(matrix, threshold)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/slu.js) | Sparse LU decomposition |

### 6.3 Symbolic Math

| Function | Description |
|----------|-------------|
| [`simplify(expr)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/simplify.js) | Simplify symbolic expression |
| [`rationalize(expr)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/rationalize.js) | Rationalize expression |
| [`derivative(expr, var)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/derivative.js) | Symbolic derivative |
| [`resolve(expr)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/resolve.js) | Resolve expression |
| [`symbolicEqual(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/symbolicEqual.js) | Check symbolic equality |

### 6.4 Expression Analysis

| Function | Description |
|----------|-------------|
| [`simplifyCore(expr)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/simplifyCore.js) | Core simplification |
| [`simplifyConstant(expr)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/simplifyConstant.js) | Simplify constants |
| [`leafCount(expr)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/leafCount.js) | Count leaf nodes |

### 6.5 Polynomial Operations

| Function | Description |
|----------|-------------|
| [`polynomialRoot(n)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/polynomialRoot.js) | Roots of polynomial |
| [`sylvester(A, b)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/sylvester.js) | Sylvester equation |
| [`lyap(A, Q, C)`](libs/mathjs/src/expression/embeddedDocs/function/algebra/lyap.js) | Lyapunov equation |

---

## 7. Statistics

### 7.1 Descriptive Statistics

| Function | Description |
|----------|-------------|
| [`mean(a, b, ...)`](libs/mathjs/src/expression/embeddedDocs/function/statistics/mean.js) | Arithmetic mean |
| [`median(a, b, ...)`](libs/mathjs/src/expression/embeddedDocs/function/statistics/median.js) | Median value |
| [`mode(a, b, ...)`](libs/mathjs/src/expression/embeddedDocs/function/statistics/mode.js) | Mode (most frequent) |
| [`max(a, b, ...)`](libs/mathjs/src/expression/embeddedDocs/function/statistics/max.js) | Maximum value |
| [`min(a, b, ...)`](libs/mathjs/src/expression/embeddedDocs/function/statistics/min.js) | Minimum value |
| [`prod(a, b, ...)`](libs/mathjs/src/expression/embeddedDocs/function/statistics/prod.js) | Product of values |
| [`sum(a, b, ...)`](libs/mathjs/src/expression/embeddedDocs/function/statistics/sum.js) | Sum of values |

### 7.2 Spread Statistics

| Function | Description |
|----------|-------------|
| [`std(a, b, ...)`](libs/mathjs/src/expression/embeddedDocs/function/statistics/std.js) | Standard deviation |
| [`variance(a, b, ...)`](libs/mathjs/src/expression/embeddedDocs/function/statistics/variance.js) | Variance |
| [`mad(a, b, ...)`](libs/mathjs/src/expression/embeddedDocs/function/statistics/mad.js) | Mean absolute deviation |
| [`quantileSeq(a, q)`](libs/mathjs/src/expression/embeddedDocs/function/statistics/quantileSeq.js) | Quantile of sequence |

### 7.3 Correlation

| Function | Description |
|----------|-------------|
| [`corr(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/statistics/corr.js) | Pearson correlation coefficient |

### 7.4 Cumulative Operations

| Function | Description |
|----------|-------------|
| [`cumsum(a, b, ...)`](libs/mathjs/src/expression/embeddedDocs/function/statistics/cumsum.js) | Cumulative sum |

---

## 8. Probability & Combinatorics

### 8.1 Probability Distributions

| Function | Description |
|----------|-------------|
| [`distribution(name)`](libs/mathjs/src/expression/embeddedDocs/function/probability/distribution.js) | Create distribution object |
| [`random()`](libs/mathjs/src/expression/embeddedDocs/function/probability/random.js) | Random number in [0, 1) |
| [`randomInt(min, max)`](libs/mathjs/src/expression/embeddedDocs/function/probability/randomInt.js) | Random integer |
| [`pickRandom(array)`](libs/mathjs/src/expression/embeddedDocs/function/probability/pickRandom.js) | Pick random element |
| [`bernoulli(p)`](libs/mathjs/src/expression/embeddedDocs/function/probability/bernoulli.js) | Bernoulli distribution |

### 8.2 Combinatorics

| Function | Description |
|----------|-------------|
| [`combinations(n, k)`](libs/mathjs/src/expression/embeddedDocs/function/probability/combinations.js) | n choose k (binomial coefficient) |
| [`combinationsWithRep(n, k)`](libs/mathjs/src/expression/embeddedDocs/function/probability/combinationsWithRep.js) | Combinations with repetition |
| [`permutations(n, k)`](libs/mathjs/src/expression/embeddedDocs/function/probability/permutations.js) | Permutations: P(n, k) |
| [`factorial(n)`](libs/mathjs/src/expression/embeddedDocs/function/probability/factorial.js) | n! (factorial) |
| [`multinomial(n, k...)`](libs/mathjs/src/expression/embeddedDocs/function/probability/multinomial.js) | Multinomial coefficient |

### 8.3 Special Functions

| Function | Description |
|----------|-------------|
| [`gamma(x)`](libs/mathjs/src/expression/embeddedDocs/function/probability/gamma.js) | Gamma function Γ(x) |
| [`lgamma(x)`](libs/mathjs/src/expression/embeddedDocs/function/probability/lgamma.js) | Log-gamma function ln(Γ(x)) |
| [`erf(x)`](libs/mathjs/src/expression/embeddedDocs/function/special/erf.js) | Error function |
| [`zeta(x)`](libs/mathjs/src/expression/embeddedDocs/function/special/zeta.js) | Riemann zeta function |

### 8.4 Number Sequences

| Function | Description |
|----------|-------------|
| [`bellNumbers(n)`](libs/mathjs/src/expression/embeddedDocs/function/combinatorics/bellNumbers.js) | Bell numbers |
| [`catalan(n)`](libs/mathjs/src/expression/embeddedDocs/function/combinatorics/catalan.js) | Catalan numbers |
| [`stirlingS2(n, k)`](libs/mathjs/src/expression/embeddedDocs/function/combinatorics/stirlingS2.js) | Stirling numbers of 2nd kind |
| [`composition(n, k)`](libs/mathjs/src/expression/embeddedDocs/function/combinatorics/composition.js) | Compositions |

### 8.5 Information Theory

| Function | Description |
|----------|-------------|
| [`kldivergence(p, q)`](libs/mathjs/src/expression/embeddedDocs/function/probability/kldivergence.js) | Kullback-Leibler divergence |

---

## 9. Set Operations

| Function | Description |
|----------|-------------|
| [`setUnion(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/set/setUnion.js) | Union of sets |
| [`setIntersect(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/set/setIntersect.js) | Intersection of sets |
| [`setDifference(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/set/setDifference.js) | Set difference |
| [`setSymDifference(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/set/setSymDifference.js) | Symmetric difference |
| [`setIsSubset(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/set/setIsSubset.js) | Check if a ⊆ b |
| [`setSize(a)`](libs/mathjs/src/expression/embeddedDocs/function/set/setSize.js) | Cardinality of set |
| [`setDistinct(a)`](libs/mathjs/src/expression/embeddedDocs/function/set/setDistinct.js) | Remove duplicates |
| [`setCartesian(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/set/setCartesian.js) | Cartesian product |
| [`setMultiplicity(a)`](libs/mathjs/src/expression/embeddedDocs/function/set/setMultiplicity.js) | Multiplicity of elements |
| [`setPowerset(a)`](libs/mathjs/src/expression/embeddedDocs/function/set/setPowerset.js) | Power set |

---

## 10. Units

### 10.1 Unit Creation

| Function | Description |
|----------|-------------|
| [`unit(value, unit)`](libs/mathjs/src/expression/embeddedDocs/construction/unit.js) | Create unit with value |
| [`createUnit(unit)`](libs/mathjs/src/expression/embeddedDocs/construction/createUnit.js) | Define new unit |
| [`splitUnit(value, parts)`](libs/mathjs/src/expression/embeddedDocs/construction/splitUnit.js) | Split into multiple units |

### 10.2 Unit Operations

| Function | Description |
|----------|-------------|
| [`to(unit)`](libs/mathjs/src/expression/embeddedDocs/function/units/to.js) | Convert to different unit |
| [`toBest(unit)`](libs/mathjs/src/expression/embeddedDocs/function/units/toBest.js) | Convert to best unit |

### 10.3 Physical Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `speedOfLight` | 299792458 m/s | Speed of light in vacuum |
| `gravitationalConstant` | 6.67430e-11 m³/(kg·s²) | Gravitational constant |
| `planckConstant` | 6.62607015e-34 J·s | Planck constant |
| `boltzmannConstant` | 1.380649e-23 J/K | Boltzmann constant |
| `avogadroConstant` | 6.02214076e23 mol⁻¹ | Avogadro constant |
| And many more... |

---

## 11. Expression Parsing & Evaluation

| Function | Description |
|----------|-------------|
| [`parse(expr)`](libs/mathjs/src/expression/embeddedDocs/function/expression/parse.js) | Parse expression to node tree |
| [`compile(expr)`](libs/mathjs/src/expression/embeddedDocs/function/expression/compile.js) | Compile expression for reuse |
| [`evaluate(expr)`](libs/mathjs/src/expression/embeddedDocs/function/expression/evaluate.js) | Evaluate expression |
| [`parser()`](libs/mathjs/src/expression/embeddedDocs/function/expression/parser.js) | Create interactive parser |
| [`help(expr)`](libs/mathjs/src/expression/embeddedDocs/function/expression/help.js) | Get help for function/expression |

---

## 12. Relational & Logical Operations

### 12.1 Comparisons

| Function | Description |
|----------|-------------|
| [`equal(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/relational/equal.js) | a == b (strict equality) |
| [`unequal(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/relational/unequal.js) | a != b |
| [`smaller(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/relational/smaller.js) | a < b |
| [`larger(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/relational/larger.js) | a > b |
| [`smallerEq(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/relational/smallerEq.js) | a <= b |
| [`largerEq(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/relational/largerEq.js) | a >= b |
| [`compare(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/relational/compare.js) | Compare: -1, 0, or 1 |
| [`compareNatural(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/relational/compareNatural.js) | Natural order comparison |
| [`deepEqual(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/relational/deepEqual.js) | Deep equality check |

### 12.2 Text Comparisons

| Function | Description |
|----------|-------------|
| [`equalText(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/relational/equalText.js) | Case-sensitive string equality |
| [`compareText(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/relational/compareText.js) | Lexicographic string comparison |

### 12.3 Logical Operations

| Function | Description |
|----------|-------------|
| [`and(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/logical/and.js) | Logical AND: a && b |
| [`or(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/logical/or.js) | Logical OR: a \|\| b |
| [`not(a)`](libs/mathjs/src/expression/embeddedDocs/function/logical/not.js) | Logical NOT: !a |
| [`xor(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/logical/xor.js) | Logical XOR: a ^ b |
| [`nullish(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/logical/nullish.js) | Nullish coalescing: a ?? b |

---

## 13. Bitwise Operations

| Function | Description |
|----------|-------------|
| [`bitAnd(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/bitwise/bitAnd.js) | Bitwise AND: a & b |
| [`bitOr(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/bitwise/bitOr.js) | Bitwise OR: a \| b |
| [`bitXor(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/bitwise/bitXor.js) | Bitwise XOR: a ^ b |
| [`bitNot(a)`](libs/mathjs/src/expression/embeddedDocs/function/bitwise/bitNot.js) | Bitwise NOT: ~a |
| [`leftShift(a, n)`](libs/mathjs/src/expression/embeddedDocs/function/bitwise/leftShift.js) | Left shift: a << n |
| [`rightArithShift(a, n)`](libs/mathjs/src/expression/embeddedDocs/function/bitwise/rightArithShift.js) | Arithmetic right shift: a >> n |
| [`rightLogShift(a, n)`](libs/mathjs/src/expression/embeddedDocs/function/bitwise/rightLogShift.js) | Logical right shift: a >>> n |

---

## 14. Geometry

| Function | Description |
|----------|-------------|
| [`distance(a, b)`](libs/mathjs/src/expression/embeddedDocs/function/geometry/distance.js) | Euclidean distance between points |
| [`intersect(endPoint1, endPoint2, line3, line4)`](libs/mathjs/src/expression/embeddedDocs/function/geometry/intersect.js) | Intersection of two lines |

---

## 15. Signal Processing

| Function | Description |
|----------|-------------|
| [`fft(vector)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/fft.js) | Fast Fourier Transform |
| [`ifft(vector)`](libs/mathjs/src/expression/embeddedDocs/function/matrix/ifft.js) | Inverse FFT |
| [`zpk2tf(z, p, k)`](libs/mathjs/src/expression/embeddedDocs/function/signal/zpk2tf.js) | Zero-pole-gain to transfer function |
| [`freqz(b, a, w)`](libs/mathjs/src/expression/embeddedDocs/function/signal/freqz.js) | Digital filter frequency response |

---

## 16. Numeric Solvers

| Function | Description |
|----------|-------------|
| [`solveODE(ode, tspan, y0)`](libs/mathjs/src/expression/embeddedDocs/function/numeric/solveODE.js) | Solve ordinary differential equations |

---

## 17. String/Formatting

| Function | Description |
|----------|-------------|
| [`format(value, precision)`](libs/mathjs/src/expression/embeddedDocs/function/utils/format.js) | Format number to string |
| [`print(template, values)`](libs/mathjs/src/expression/embeddedDocs/function/utils/print.js) | Print formatted string |
| [`bin(value)`](libs/mathjs/src/expression/embeddedDocs/function/utils/bin.js) | Convert to binary string |
| [`oct(value)`](libs/mathjs/src/expression/embeddedDocs/function/utils/oct.js) | Convert to octal string |
| [`hex(value)`](libs/mathjs/src/expression/embeddedDocs/function/utils/hex.js) | Convert to hexadecimal string |
| [`string(value)`](libs/mathjs/src/expression/embeddedDocs/construction/string.js) | Convert to string |

---

## 18. Utility Functions

### 18.1 Type Checking

| Function | Description |
|----------|-------------|
| [`isNumber(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isNumeric.js) | Check if value is number |
| [`isBigNumber(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isNumeric.js) | Check if value is BigNumber |
| [`isComplex(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isNumeric.js) | Check if value is complex |
| [`isFraction(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isNumeric.js) | Check if value is fraction |
| [`isMatrix(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isNumeric.js) | Check if value is matrix |
| [`isSparseMatrix(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isNumeric.js) | Check if value is sparse matrix |
| [`isDenseMatrix(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isNumeric.js) | Check if value is dense matrix |
| [`isArray(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isNumeric.js) | Check if value is array |
| [`isString(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isNumeric.js) | Check if value is string |
| [`isBoolean(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isNumeric.js) | Check if value is boolean |
| [`isUnit(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isNumeric.js) | Check if value is unit |
| [`isNode(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isNumeric.js) | Check if value is node |
| [`typeOf(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/typeOf.js) | Get type name as string |

### 18.2 Numeric Predicates

| Function | Description |
|----------|-------------|
| [`isInteger(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isInteger.js) | Check if number is integer |
| [`isPositive(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isPositive.js) | Check if number is positive |
| [`isNegative(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isNegative.js) | Check if number is negative |
| [`isZero(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isZero.js) | Check if number is zero |
| [`isNaN(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isNaN.js) | Check if NaN |
| [`isFinite(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isFinite.js) | Check if finite |
| [`isBounded(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isBounded.js) | Check if bounded |
| [`hasNumericValue(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/hasNumericValue.js) | Check if has numeric value |
| [`isPrime(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/isPrime.js) | Check if prime |

### 18.3 Other Utilities

| Function | Description |
|----------|-------------|
| [`clone(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/clone.js) | Clone value |
| [`numeric(x)`](libs/mathjs/src/expression/embeddedDocs/function/utils/numeric.js) | Convert to number |

---

## 19. Constants

### 19.1 Mathematical Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `pi` | 3.14159265358979... | Ratio of circumference to diameter |
| `tau` | 6.28318530717958... | 2π (circumference to radius) |
| `e` | 2.71828182845904... | Base of natural logarithm |
| `phi` | 1.61803398874989... | Golden ratio (1 + √5)/2 |

### 19.2 Logarithmic Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `LN2` | 0.69314718055994... | Natural log of 2 |
| `LN10` | 2.30258509299404... | Natural log of 10 |
| `LOG2E` | 1.44269504088896... | Log base 2 of e |
| `LOG10E` | 0.43429448190325... | Log base 10 of e |
| `SQRT2` | 1.41421356237309... | Square root of 2 |
| `SQRT1_2` | 0.70710678118654... | Square root of 1/2 |

### 19.3 Boolean Constants

| Constant | Value |
|----------|-------|
| `true` | true |
| `false` | false |
| `null` | null |

### 19.4 Special Values

| Constant | Value | Description |
|----------|-------|-------------|
| `Infinity` | Infinity | Positive infinity |
| `NaN` | NaN | Not a number |
| `i` | 0 + 1i | Imaginary unit |

### 19.5 Other Constants

| Constant | Description |
|----------|-------------|
| `version` | Mathjs version string |

---

## 20. Core/Configuration

### 20.1 Configuration

| Function | Description |
|----------|-------------|
| [`config(settings)`](libs/mathjs/src/expression/embeddedDocs/core/config.js) | Configure mathjs settings |
| `number` | Default number type ('number', 'BigNumber', 'Fraction') |
| `precision` | Significant digits for BigNumber |
| `epsilon` | Tolerance for comparisons |
| `matrix` | Default matrix type ('Matrix', 'Array') |
| `simplify` | Simplification options |

### 20.2 Factory Functions

| Function | Description |
|----------|-------------|
| [`create()`](libs/mathjs/src/core/create.js) | Create new mathjs instance |
| [`factory()`](libs/mathjs/src/core/factoriesAny.js) | Create factory function |

### 20.3 Import/Export

| Function | Description |
|----------|-------------|
| [`import(functions)`](libs/mathjs/src/expression/embeddedDocs/core/import.js) | Import functions into mathjs |

### 20.4 Type System

| Function | Description |
|----------|-------------|
| [`typed()`](libs/mathjs/src/expression/embeddedDocs/core/typed.js) | Typed-function system |

---

## Appendix A: Node Types

Mathjs expression trees consist of various node types:

| Node Type | Description |
|-----------|-------------|
| `ConstantNode` | Numeric/string constant |
| `SymbolNode` | Variable/function reference |
| `OperatorNode` | Mathematical operator |
| `FunctionNode` | Function call |
| `ParenthesisNode` | Parenthesized expression |
| `ArrayNode` | Array literal |
| `MatrixNode` | Matrix literal |
| `IndexNode` | Index access |
| `AccessorNode` | Property access |
| `AssignmentNode` | Variable assignment |
| `BlockNode` | Block of statements |
| `RangeNode` | Range expression |
| `RelationalNode` | Relational expression |
| `ConditionalNode` | Conditional (ternary) expression |

---

## Appendix B: Operator Precedence

| Precedence | Operators | Associativity |
|------------|-----------|---------------|
| 16 | () [] . | Left-to-right |
| 15 | ! | Right-to-left |
| 14 | ^ | Right-to-left |
| 13 | * / % ./ .* | Left-to-right |
| 12 | + - | Left-to-right |
| 11 | : | Left-to-right |
| 10 | == != < > <= >= | Left-to-right |
| 9 | and | Left-to-right |
| 8 | or | Left-to-right |

---

## Appendix C: Default Configuration

```javascript
{
  // Number type for calculations
  number: 'number',        // 'number' | 'BigNumber' | 'Fraction'
  
  // Precision for BigNumber (significant digits)
  precision: 64,
  
  // Matrix output type
  matrix: 'Matrix',        // 'Matrix' | 'Array'
  
  // Default data type for new matrices
  matrixDefault: 'dense',  // 'dense' | 'sparse'
  
  // Simplification options
  simplify: {
    alpha: 1,
    maxTermLength: 30,
    rules: [...],
    timeout: 1000
  },
  
  // Tolerance for comparisons
  epsilon: 1e-12,
  
  // Random seed
  randomSeed: null
}
```

---

*Document generated for mathjs vs mathzig comparison project.*
*Total documented functions: 250+*
