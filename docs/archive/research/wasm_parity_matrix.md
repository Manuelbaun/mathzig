# WASM AOT Backend: Feature Parity Matrix

## 🟢 Phase 1-3: Scalar, Loops, and Memory (DONE)
| MathZig Feature | Status | Notes |
| :--- | :--- | :--- |
| Basic Arithmetic | ✅ | `+`, `-`, `*`, `/`, `%`, `neg` |
| Variables | ✅ | `load_var`, `store_var` |
| Constants | ✅ | `push_const` (f64, bool, string) |
| Standard Math | ✅ | Imports from `env` (sin, cos, etc.) |
| Logical Ops | ✅ | `and`, `or`, `not` (short-circuiting) |
| Control Flow | ✅ | `if/else`, Ternary, `while`, `for` |
| Memory | ✅ | Bump Pointer Allocator |
| Matrices | ✅ | `mat_create`, `get_index` |

## 🔵 Phase 4: Advanced & SIMD (IN PROGRESS)
| MathZig Feature | Status | Notes |
| :--- | :--- | :--- |
| Matrix Ops | 🔴 | Element-wise arithmetic, GEMM linking |
| Complex Math | 🔴 | Complex arithmetic runtime linking |
| Time-Series | 🔴 | Temporal aggregations, resampling |
| Optimizations | 🔴 | Constant folding, peephole passes |
| Arbitrary Jumps| 🔴 | Relooper algorithm |
| SIMD128 | 🔴 | Mapping @Vector to v128 |

## ❌ Out of Scope
- Multicore / Threading (WASM constraint)
- File I/O (must be handled by host)
