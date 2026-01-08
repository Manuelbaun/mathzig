#include "bench_common.h"

static int mandelbrot_iterations(double cr, double ci, int max_iter) {
    double zr = 0.0;
    double zi = 0.0;
    int i = 0;
    while (i < max_iter) {
        const double zr2 = zr * zr;
        const double zi2 = zi * zi;
        if (zr2 + zi2 > 4.0) {
            return i;
        }
        zi = 2.0 * zr * zi + ci;
        zr = zr2 - zi2 + cr;
        i += 1;
    }
    return max_iter;
}

static double bench_mandelbrot(uint64_t width, uint64_t height, int max_iter, uint64_t repeats) {
    double checksum = 0.0;
    for (uint64_t r = 0; r < repeats; r += 1) {
        for (uint64_t y = 0; y < height; y += 1) {
            const double ci = ((double)y / (double)height) * 2.5 - 1.25;
            for (uint64_t x = 0; x < width; x += 1) {
                const double cr = ((double)x / (double)width) * 3.5 - 2.0;
                checksum += (double)mandelbrot_iterations(cr, ci, max_iter);
            }
        }
    }
    return checksum;
}

int main(int argc, char **argv) {
    const char *feature_id = (argc > 1) ? argv[1] : "baseline";
    const int64_t timestamp = (int64_t)time(NULL);

    const uint64_t width = 160;
    const uint64_t height = 160;
    const int max_iter = 500;
    const uint64_t pixels_per_pass = width * height;
    const uint64_t target_iters = 2 * 1000 * 1000;
    const uint64_t repeats = target_iters / pixels_per_pass;
    const uint64_t iterations = repeats * pixels_per_pass;

    const uint64_t start = bench_now_ns();
    const double checksum = bench_mandelbrot(width, height, max_iter, repeats);
    const uint64_t end = bench_now_ns();

    const double duration_ms = (double)(end - start) / 1000000.0;
    bench_log_csv(timestamp, feature_id, "ref_c_mandelbrot", iterations, duration_ms, checksum);
    return 0;
}