#ifndef HAKIOS_METAL_PERF_H
#define HAKIOS_METAL_PERF_H
#include <stdint.h>
#include <time.h>

/* Nested spans overlap; only compare siblings. CPU is the calling thread's
 * CPU clock, wall includes blocking and descheduling. Enabled by metal_fps. */
enum {
    HM_PERF_BO, HM_PERF_NEW_IOCTL, HM_PERF_IOVA, HM_PERF_MAP,
    HM_PERF_POOL_HIT, HM_PERF_POOL_MISS,
    HM_PERF_CLOSE_PASS, HM_PERF_COMMAND_BO, HM_PERF_UPLOAD,
    HM_PERF_QUEUE_LOCK, HM_PERF_FAULTS, HM_PERF_GPU_SUBMIT,
    HM_PERF_SUBMIT, HM_PERF_BO_LIST, HM_PERF_SUBMIT_IOCTL,
    HM_PERF_TURN, HM_PERF_EVENTS, HM_PERF_COMMIT_CORE, HM_PERF_SYNC,
    HM_PERF_SCHEDULED, HM_PERF_COMMIT,
    HM_PERF_RENDER_PIPELINE, HM_PERF_COMPUTE_PIPELINE, HM_PERF_CB_SLOT,
    HM_PERF_COUNT
};
typedef struct { uint64_t count, wall, cpu, max, bytes; } hm_perf_stat;
typedef struct { uint64_t wall, cpu; } hm_perf_mark;
#ifdef __cplusplus
extern "C" {
#endif
void hakios_metal_perf_enable(int on);
int hakios_metal_perf_enabled(void);
void hakios_metal_perf_add(unsigned slot, uint64_t wall, uint64_t cpu, uint64_t bytes);
void hakios_metal_perf_take(hm_perf_stat out[HM_PERF_COUNT]);
#ifdef __cplusplus
}
#endif
static inline uint64_t hm_perf_clock(clockid_t id) {
    struct timespec t;
    clock_gettime(id, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}
static inline hm_perf_mark hm_perf_begin(void) {
    hm_perf_mark m = {0, 0};
    if (hakios_metal_perf_enabled()) {
        m.wall = hm_perf_clock(CLOCK_MONOTONIC);
        m.cpu = hm_perf_clock(CLOCK_THREAD_CPUTIME_ID);
    }
    return m;
}
static inline void hm_perf_end(unsigned slot, hm_perf_mark m, uint64_t bytes) {
    if (m.wall) {
        uint64_t cpu = hm_perf_clock(CLOCK_THREAD_CPUTIME_ID) - m.cpu;
        hakios_metal_perf_add(slot, hm_perf_clock(CLOCK_MONOTONIC) - m.wall, cpu, bytes);
    }
}
#ifdef __cplusplus
struct HMPerfScope {
    unsigned slot;
    uint64_t bytes;
    hm_perf_mark start = hm_perf_begin();
    explicit HMPerfScope(unsigned s, uint64_t b = 0) : slot(s), bytes(b) {}
    ~HMPerfScope() { hm_perf_end(slot, start, bytes); }
};
#endif
#endif
