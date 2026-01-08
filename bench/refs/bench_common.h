#pragma once

#include <stdint.h>
#include <stdio.h>
#include <time.h>

#ifdef __APPLE__
#include <mach/mach_time.h>
#endif

static inline uint64_t bench_now_ns(void) {
#ifdef __APPLE__
    static mach_timebase_info_data_t timebase = {0, 0};
    if (timebase.denom == 0) {
        mach_timebase_info(&timebase);
    }
    return mach_absolute_time() * timebase.numer / timebase.denom;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
#endif
}

static inline void bench_log_csv(
    int64_t timestamp,
    const char *feature_id,
    const char *test_name,
    uint64_t iterations,
    double duration_ms,
    double checksum
) {
    const double ops_per_sec = (double)iterations / (duration_ms / 1000.0);
    fprintf(stdout, "%lld,%s,%s,%llu,%.4f,%.2f,0,0,0,checksum=%.6f\n",
        (long long)timestamp,
        feature_id,
        test_name,
        (unsigned long long)iterations,
        duration_ms,
        ops_per_sec,
        checksum);
}