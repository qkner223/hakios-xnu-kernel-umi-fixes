#pragma once
#include <stdint.h>

/* C-compatible allocation context, thread-local and scoped around plug-in resource creation.
 * Zero leaves queue-owned command/slab pools alone. The BO key also includes the
 * GEM flags; size is matched exactly, or by best fit within one page (or an eighth)
 * of slack unless bo-cache-fit-off says otherwise. No texture object or IOSurface
 * is cached. */
enum { HM_BO_BUFFER = 1, HM_BO_TEXTURE = 2, HM_BO_MEMORYLESS = 3 };
enum {
    HM_BO_ALLOCATIONS, HM_BO_HITS, HM_BO_NEW, HM_BO_MAPS, HM_BO_UNMAPS,
    HM_BO_EVICTIONS, HM_BO_BUSY, HM_BO_ALLOC_NS, HM_BO_MAP_NS, HM_BO_UNMAP_NS,
    /* FIT_HITS: a request served by a cached BO up to one page (or an eighth) larger,
     * because a window laid out one row shorter is the same buffer physically. WASTE is
     * the sum of those size differences handed out, not memory retained. */
    HM_BO_ZERO_NS, HM_BO_MEMORYLESS_HITS, HM_BO_FIT_HITS, HM_BO_FIT_WASTE_BYTES, HM_BO_COUNTER_COUNT,
    HM_BO_CACHED_BYTES = HM_BO_COUNTER_COUNT, HM_BO_MEMORYLESS_BYTES, HM_BO_CACHED_COUNT,
    HM_BO_STAT_COUNT
};
#ifdef __cplusplus
extern "C" {
#endif
uint64_t hakios_metal_bo_context(uint64_t context);
/* Window counters reset; retained byte/object gauges do not. */
void hakios_metal_bo_cache_take(uint64_t out[HM_BO_STAT_COUNT]);
/* Whether a cached BO may satisfy a slightly smaller request. On by default; the file
 * /var/db/hakios-metal-cache/bo-cache-fit-off turns it off, read once per process.
 * The setter is for tests (the file cannot be created in a host sandbox). */
int hakios_metal_bo_cache_fit_enabled(void);
void hakios_metal_bo_cache_fit_set(int on);
#ifdef __cplusplus
}
#endif
static inline uint64_t hm_bo_key(unsigned format, unsigned usage, unsigned kind) {
    return (uint64_t)format | ((uint64_t)usage << 32) | ((uint64_t)kind << 56);
}
