const std = @import("std");

pub fn mandelbrotIterations(cr: f64, ci: f64, max_iter: i32) i32 {
    var zr: f64 = 0;
    var zi: f64 = 0;
    var i: i32 = 0;
    while (i < max_iter) : (i += 1) {
        const zr2 = zr * zr;
        const zi2 = zi * zi;
        if (zr2 + zi2 > 4.0) return i;
        zi = 2.0 * zr * zi + ci;
        zr = zr2 - zi2 + cr;
    }
    return max_iter;
}

pub fn benchMandelbrot(width: usize, height: usize, max_iter: i32, repeats: usize) f64 {
    var checksum: f64 = 0;
    var r: usize = 0;
    while (r < repeats) : (r += 1) {
        var y: usize = 0;
        while (y < height) : (y += 1) {
            const ci = (@as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(height))) * 2.5 - 1.25;
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const cr = (@as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(width))) * 3.5 - 2.0;
                checksum += @floatFromInt(mandelbrotIterations(cr, ci, max_iter));
            }
        }
    }
    return checksum;
}