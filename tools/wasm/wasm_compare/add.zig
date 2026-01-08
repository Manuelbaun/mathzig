// Minimal Zig expression equivalent to: a=1; b=3; c=a+b; c
export fn eval() f64 {
    const a: f64 = 1.0;
    const b: f64 = 3.0;
    const c: f64 = a + b;
    return c;
}
