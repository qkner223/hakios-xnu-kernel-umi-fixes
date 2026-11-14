#!/usr/bin/env python3
"""Run the shipped texture completion SPI as QuartzCore's finish_image calls it."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[2] / 'userland/src/HakiosMetalCA.m').read_text()
source = source[source.index('@implementation HakiosMetalTexture\n'):]

def method(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

harness = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdatomic.h>
#include <stdint.h>
#include <pthread.h>
#define hm_print(...) ((void)0)
#define hm_texture_trace(...) ((void)0)
#define hm_handoff_on() NO
static struct { unsigned textureWaits; } hm_diag;
#define hm_diag_add(counter) (*(counter) += 1)
enum { HAKIOS_METAL_DRAIN_CPU_SYNC = 1 };
static void hakios_metal_drain_all(unsigned reason) { (void)reason; }
typedef struct { atomic_bool complete; } hakios_metal_texture;
static atomic_bool published;
static pthread_mutex_t hm_use_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t hm_use_cond = PTHREAD_COND_INITIALIZER;
static dispatch_semaphore_t publicationEntered;
static BOOL hm_use_complete(const uint64_t *uses) { (void)uses; return atomic_load(&published); }
static BOOL hm_use_in_flight(const uint64_t *uses) {
    (void)uses; BOOL busy = !atomic_load(&published);
    if (busy) dispatch_semaphore_signal(publicationEntered);
    return busy;
}
static BOOL hm_fps_on(void) { return NO; }
static double hm_now(void) { return 0; }
static void hm_fps_texture_waited(double t) { (void)t; }
/* the plug-in's own wait: drain first, then at most two seconds of timed wait */
static void hm_use_wait(const uint64_t *uses) {
    struct timespec deadline;
    BOOL late = NO;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 2;
    hakios_metal_drain_all(HAKIOS_METAL_DRAIN_CPU_SYNC);
    pthread_mutex_lock(&hm_use_lock);
    while (hm_use_in_flight(uses) && !late) late = pthread_cond_timedwait(&hm_use_cond, &hm_use_lock, &deadline) != 0 && hm_use_in_flight(uses);
    pthread_mutex_unlock(&hm_use_lock);
    (void)late;
}
static dispatch_semaphore_t entered, gpu, returned;
static int hakios_metal_texture_is_complete(hakios_metal_texture *t) { return atomic_load(&t->complete); }
static int hakios_metal_texture_sync(hakios_metal_texture *t) {
    dispatch_semaphore_signal(entered);
    dispatch_semaphore_wait(gpu, DISPATCH_TIME_FOREVER);
    assert(atomic_load(&t->complete));
    return 0;
}
@interface HakiosMetalTexture : NSObject { @public hakios_metal_texture *_texture; HakiosMetalTexture *_parent; BOOL _shadow; uint64_t _uses[4]; }
- (BOOL)isComplete;
- (void)waitUntilComplete;
@end
@implementation HakiosMetalTexture
METHODS
@end
int main(void) {
    @autoreleasepool {
        hakios_metal_texture backing;
        atomic_init(&backing.complete, false);
        HakiosMetalTexture *texture = [HakiosMetalTexture new]; texture->_texture = &backing;
        assert(![texture isComplete]);
        entered = dispatch_semaphore_create(0); gpu = dispatch_semaphore_create(0); returned = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            @autoreleasepool { [texture waitUntilComplete]; dispatch_semaphore_signal(returned); }
        });
        assert(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        assert(dispatch_semaphore_wait(returned, DISPATCH_TIME_NOW) != 0);
        atomic_store(&backing.complete, true); dispatch_semaphore_signal(gpu);
        assert(dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        assert([texture isComplete]);
        // A shadow's GPU fence passes before its IOSurface writeback completes.
        // CA must still observe incomplete, including through a texture view.
        texture->_shadow = YES; atomic_init(&published, false);
        HakiosMetalTexture *view = [HakiosMetalTexture new]; view->_parent = texture; view->_texture = &backing;
        assert(![view isComplete]);
        publicationEntered = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            @autoreleasepool { [view waitUntilComplete]; dispatch_semaphore_signal(returned); }
        });
        // A view has its own core wrapper over the same backing.
        assert(!dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
        dispatch_semaphore_signal(gpu);
        assert(!dispatch_semaphore_wait(publicationEntered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
        assert(dispatch_semaphore_wait(returned, DISPATCH_TIME_NOW) != 0 && ![view isComplete]);
        pthread_mutex_lock(&hm_use_lock); atomic_store(&published, true); pthread_cond_broadcast(&hm_use_cond); pthread_mutex_unlock(&hm_use_lock);
        assert(!dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
        assert([view isComplete]);
        [view release]; dispatch_release(publicationEntered);
        [texture release]; dispatch_release(entered); dispatch_release(gpu); dispatch_release(returned);
    }
    puts("Pencil texture handoff: backing fence, shadow publication and view completion passed");
}
'''.replace('METHODS', method('- (BOOL)isComplete') + '\n' + method('- (void)waitUntilComplete'))

with tempfile.TemporaryDirectory(prefix='hakios-pencil-plugin-') as directory:
    directory = Path(directory)
    (directory / 'test.m').write_text(harness)
    subprocess.run(['clang', '-fblocks', '-Werror', '-framework', 'Foundation', str(directory / 'test.m'),
                    '-o', str(directory / 'test')], check=True)
    subprocess.run([str(directory / 'test')], check=True)
