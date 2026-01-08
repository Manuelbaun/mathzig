const std = @import("std");

pub fn factorial(n: f64) f64 {
    if (n < 0) return std.math.nan(f64);
    if (n == 0) return 1;
    if (n > 170) return std.math.inf(f64); // Limit for f64
    
    var res: f64 = 1;
    var i: f64 = 1;
    while (i <= n) : (i += 1) {
        res *= i;
    }
    return res;
}

pub fn gcd(a: f64, b: f64) f64 {
    var x = @abs(@as(i64, @intFromFloat(a)));
    var y = @abs(@as(i64, @intFromFloat(b)));
    
    while (y != 0) {
        const temp = y;
        y = @mod(x, y);
        x = temp;
    }
    return @floatFromInt(x);
}

pub fn lcm(a: f64, b: f64) f64 {
    if (a == 0 or b == 0) return 0;
    const g = gcd(a, b);
    return @abs(a * b) / g;
}

pub fn isPrime(n: f64) bool {
    if (n <= 1) return false;
    if (n <= 3) return true;
    if (@mod(n, 2) == 0 or @mod(n, 3) == 0) return false;
    
    const val = @as(i64, @intFromFloat(n));
    var i: i64 = 5;
    while (i * i <= val) : (i += 6) {
        if (@mod(val, i) == 0 or @mod(val, i + 2) == 0) return false;
    }
    return true;
}

pub fn combinations(n: f64, k: f64) f64 {
    if (k < 0 or k > n) return 0;
    if (k == 0 or k == n) return 1;
    var res: f64 = 1;
    const min_k = if (k < n - k) k else n - k;
    var i: f64 = 1;
    while (i <= min_k) : (i += 1) {
        res = res * (n - min_k + i) / i;
    }
    return @round(res);
}

pub fn permutations(n: f64, k: f64) f64 {
    if (k < 0 or k > n) return 0;
    var res: f64 = 1;
    var i: f64 = 0;
    while (i < k) : (i += 1) {
        res *= (n - i);
    }
    return @round(res);
}
