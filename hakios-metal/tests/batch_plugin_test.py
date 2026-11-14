#!/usr/bin/env python3
"""Run actual CA queue/sync/handler/present methods in a Foundation host harness."""
from pathlib import Path
import argparse
parser = argparse.ArgumentParser()
parser.add_argument("--control-shadow", action="store_true")
args = parser.parse_args()
import re
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[2] / 'userland/src/HakiosMetalCA.m').read_text()
start = source.index('- (void)hakiosEnqueue:(HakiosMetalCommandBuffer *)buffer\n{')
queue_methods = source[start:source.index('\n@end', start)]

def method(signature):
    match = re.search(re.escape(signature) + r'\s*\{', source)
    start, brace = match.start(), match.end() - 1
    line_end = source.index('\n', brace)
    end = line_end if source[brace:line_end].endswith('}') else source.index('\n}', brace) + 2
    return source[start:end]

cb_methods = '\n'.join(method(s) for s in [
    '- (unsigned)hakiosDrainReason', '- (void)hakiosRequireSync:(unsigned)reason',
    '- (void)hakiosSent', '- (void)waitUntilScheduled', '- (void)waitUntilCompleted',
    '- (void)hakiosDeliver:(MTLCommandBufferHandler)handler', '- (void)hakiosDeliverScheduled',
    '- (void)hakiosWriteShadowAtCompletion:(HakiosMetalTexture *)texture', '- (void)hakiosCompletedNow', '- (void)addScheduledHandler:(MTLCommandBufferHandler)handler',
    '- (void)addCompletedHandler:(MTLCommandBufferHandler)handler', '- (void)presentDrawable:(id)drawable',
    '- (void)encodeSignalEvent:(id)event value:(uint64_t)value',
])
if args.control_shadow:
    cb_methods = cb_methods.replace('[texture hakiosWriteBackShadow];', '[self hakiosDeliver:^(id<MTLCommandBuffer> done) { (void)done; [texture hakiosWriteBackShadow]; }];')
fence_methods = '\n'.join(method(s) for s in ['- (void)updateFence:(id)fence', '- (void)waitForFence:(id)fence',
    '- (void)updateFence:(id)fence afterStages:(MTLRenderStages)stages', '- (void)waitForFence:(id)fence beforeStages:(MTLRenderStages)stages'])

harness = r'''
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <assert.h>
#include <limits.h>
#include <sched.h>
#include <pthread.h>
#define HM_ONCE(...) ((void)0)
#define hm_print(...) ((void)0)
#define hm_texture_trace(...) ((void)0)
#define hm_handoff_on() NO
static struct { unsigned cb, fenceReads, fenceWrites, visibleWrites, shadowQueued, shadowPublished, signals; } hm_diag;
#define hm_diag_add(counter) (*(counter) += 1)
#define hm_use_set(...) ((void)0)
#define hm_fps_note(...) ((void)0)
#define hm_fps_waited(...) ((void)0)
#define hm_now() 0.0
typedef int hm_perf_mark;
#define hm_perf_begin() 0
#define hm_perf_end(...) ((void)phase)
#define hakios_metal_cb_refuse(...) assert(0)
static BOOL hm_ca_sync(void) { return NO; }
enum { HAKIOS_METAL_DRAIN_SURFACE, HAKIOS_METAL_DRAIN_CPU_SYNC, HAKIOS_METAL_DRAIN_CROSS_QUEUE,
       HAKIOS_METAL_DRAIN_LIMIT, HAKIOS_METAL_DRAIN_IDLE };
enum { HAKIOS_METAL_SCHEDULED = 3, HAKIOS_METAL_COMPLETED = 4, HAKIOS_METAL_ERROR = 5 };
typedef struct { unsigned index, status; BOOL surface; } hakios_metal_cb;
struct hakios_metal_commit { hakios_metal_cb *cb; void (*callback)(hakios_metal_cb *, void *); void *context; };
typedef struct { struct hakios_metal_commit entries[8]; void (*scheduled[8])(hakios_metal_cb *, void *); unsigned n; } hakios_metal_queue;
static BOOL disabled;
static dispatch_queue_t clientCompletion;
static id publication;
static unsigned submits, largest, prepared, scheduled, order[64], n, reasonsSeen[5];
static hakios_metal_queue *queues[16];
static unsigned queueCount;
static BOOL holdStage;
static dispatch_semaphore_t stageEntered, stageRelease;
static int testAccess(const char *path, int mode) { (void)path; (void)mode; return disabled ? 0 : -1; }
#define access testAccess
#define F_OK 0
static unsigned hakios_metal_cb_status(hakios_metal_cb *cb) { return cb->status; }
static void hakios_metal_cb_wait(hakios_metal_cb *cb) { assert(cb->status == HAKIOS_METAL_COMPLETED); }
static void publish(const struct hakios_metal_commit *entries, unsigned count,
                    void (**callbacks)(hakios_metal_cb *, void *)) {
    submits++; largest = MAX(largest, count);
    for (unsigned i = 0; i < count; i++) { entries[i].cb->status = HAKIOS_METAL_SCHEDULED; order[n++] = entries[i].cb->index; }
    for (unsigned i = 0; i < count; i++) if (callbacks && callbacks[i]) callbacks[i](entries[i].cb, entries[i].context);
    for (unsigned i = 0; i < count; i++) {
        entries[i].cb->status = HAKIOS_METAL_COMPLETED;
        if (entries[i].callback) entries[i].callback(entries[i].cb, entries[i].context);
    }
}
static void hakios_metal_cb_commit(hakios_metal_cb *cb, void (*callback)(hakios_metal_cb *, void *), void *context) {
    struct hakios_metal_commit entry = {cb, callback, context}; publish(&entry, 1, NULL);
}
static void hakios_metal_queue_drain(hakios_metal_queue *q, unsigned reason) {
    unsigned count = q->n;
    if (!count) return;
    struct hakios_metal_commit entries[8]; void (*callbacks[8])(hakios_metal_cb *, void *);
    memcpy(entries, q->entries, count * sizeof(*entries)); memcpy(callbacks, q->scheduled, count * sizeof(*callbacks));
    q->n = 0; reasonsSeen[reason]++; publish(entries, count, callbacks);
}
static void hakios_metal_drain_all(unsigned reason) {
    for (unsigned i = 0; i < queueCount; i++) hakios_metal_queue_drain(queues[i], reason);
}
static void hakios_metal_queue_stage_batch(hakios_metal_queue *q, const struct hakios_metal_commit *entries, unsigned count,
                                         void (*scheduledCallback)(hakios_metal_cb *, void *), const unsigned *reasons) {
    if (holdStage) { dispatch_semaphore_signal(stageEntered); dispatch_semaphore_wait(stageRelease, DISPATCH_TIME_FOREVER); }
    for (unsigned i = 0; i < count; i++) {
        q->entries[q->n] = entries[i]; q->scheduled[q->n++] = scheduledCallback;
        entries[i].cb->status = 2;
        if (entries[i].cb->surface || reasons[i] != HAKIOS_METAL_DRAIN_IDLE)
            hakios_metal_queue_drain(q, entries[i].cb->surface ? HAKIOS_METAL_DRAIN_SURFACE : reasons[i]);
        else if (q->n == 8) hakios_metal_queue_drain(q, HAKIOS_METAL_DRAIN_LIMIT);
    }
}
@interface NSObject (EventTest)
- (void)hakiosSignal:(uint64_t)value;
@end
@interface HakiosMetalEvent : NSObject { @public uint64_t value; }
- (void)hakiosSignal:(uint64_t)signal;
@end
@implementation HakiosMetalEvent
- (void)hakiosSignal:(uint64_t)signal { if (publication) assert([[publication valueForKey:@"visible"] boolValue]); value = signal; }
@end
@interface HakiosMetalTexture : NSObject { @public BOOL visible; unsigned writes; HakiosMetalTexture *parent; }
- (id)parentTexture;
- (void)hakiosUsedBy:(uint64_t)seq;
- (void)hakiosShadowWriteQueued;
- (void)hakiosWriteBackShadow;
@end
@implementation HakiosMetalTexture
- (id)parentTexture { return parent; }
- (void)hakiosUsedBy:(uint64_t)seq { (void)seq; }
- (void)hakiosShadowWriteQueued { writes++; }
- (void)hakiosWriteBackShadow { visible = YES; writes--; }
@end
@class HakiosMetalCommandBuffer;
@interface HakiosMetalCommandQueue : NSObject {
    hakios_metal_queue *_queue; dispatch_queue_t _deferred; NSMutableArray *_pending; unsigned _onDeferred; BOOL _idlePending;
}
- (void)hakiosEnqueue:(HakiosMetalCommandBuffer *)buffer;
- (void)hakiosCommit:(HakiosMetalCommandBuffer *)buffer;
- (void)hakiosSendBuffers:(NSArray *)buffers;
- (void)hakiosDrain:(unsigned)reason;
- (dispatch_queue_t)hakiosCompletionQueue;
- (void)join;
@end
@interface HakiosMetalCommandBuffer : NSObject {
@public
    hakios_metal_cb core; hakios_metal_cb *_cb; HakiosMetalCommandQueue *_queue;
    BOOL ready, waits, _committed, _scheduledDelivered, _completedDelivered; unsigned _drainReason;
    NSMutableArray *_scheduled, *_completed, *_signals, *_shadowTargets;
    NSMutableSet *_probeReads, *_probeWrites;
    uint64_t _useSeq;
    dispatch_semaphore_t _sent;
}
- (BOOL)hakiosReadyToSubmit;
- (void)hakiosMarkReady;
- (BOOL)hakiosWaits;
- (void)hakiosPrepareSend;
- (hakios_metal_cb *)hakiosCommandBuffer;
- (void)hakiosSent;
- (void)hakiosSubmit;
- (void)hakiosDeliverScheduled;
- (void)hakiosCompletedNow;
- (void)hakiosRequireSync:(unsigned)reason;
- (unsigned)hakiosDrainReason;
- (void)waitUntilScheduled;
- (void)waitUntilCompleted;
- (void)addScheduledHandler:(MTLCommandBufferHandler)handler;
- (void)addCompletedHandler:(MTLCommandBufferHandler)handler;
- (void)presentDrawable:(id)drawable;
- (void)encodeSignalEvent:(id)event value:(uint64_t)value;
- (void)hakiosPaySlot;
- (id)error;
@end
@implementation HakiosMetalCommandQueue
QUEUE_METHODS
- (id)init { self = [super init]; _queue = calloc(1, sizeof(*_queue)); queues[queueCount++] = _queue; return self; }
- (dispatch_queue_t)hakiosCompletionQueue { return clientCompletion; }
- (void)join { if (_deferred) dispatch_sync(_deferred, ^{}); }
- (void)dealloc {
    assert(!_queue->n); assert(queueCount && queues[queueCount - 1] == _queue); queueCount--;
    free(_queue); [_pending release]; if (_deferred) dispatch_release(_deferred); [super dealloc];
}
@end
static void hm_completed(hakios_metal_cb *cb, void *context) {
    (void)cb; [(HakiosMetalCommandBuffer *)context hakiosCompletedNow]; [(id)context release];
}
@implementation HakiosMetalCommandBuffer
CB_METHODS
- (id)init { self = [super init]; _cb = &core; _sent = dispatch_semaphore_create(0); return self; }
- (BOOL)hakiosReadyToSubmit { return ready; }
- (void)hakiosMarkReady { ready = YES; }
- (BOOL)hakiosWaits { return waits; }
- (void)hakiosPrepareSend { assert(!core.status); prepared++; [self retain]; }
- (hakios_metal_cb *)hakiosCommandBuffer { return _cb; }
- (void)hakiosSubmit { [self hakiosPrepareSend]; hakios_metal_cb_commit(_cb, hm_completed, self); [self hakiosSent]; }
- (void)hakiosPaySlot { scheduled++; }
- (id)error { return nil; }
- (void)dealloc { [_scheduled release]; [_completed release]; dispatch_release(_sent); [super dealloc]; }
@end
@interface FenceEncoder : NSObject { @public HakiosMetalCommandBuffer *_commandBuffer; }
- (void)updateFence:(id)fence;
- (void)waitForFence:(id)fence;
- (void)updateFence:(id)fence afterStages:(MTLRenderStages)stages;
- (void)waitForFence:(id)fence beforeStages:(MTLRenderStages)stages;
@end
@implementation FenceEncoder
FENCE_METHODS
@end
@interface Drawable : NSObject { @public BOOL presented; }
- (void)present;
@end
@implementation Drawable
- (void)present { presented = YES; }
@end
static HakiosMetalCommandBuffer *buffer(HakiosMetalCommandQueue *q, unsigned index) {
    HakiosMetalCommandBuffer *b = [[[HakiosMetalCommandBuffer alloc] init] autorelease];
    b->_queue = q; b->core.index = index; return b;
}
static void commit(HakiosMetalCommandBuffer *b) { b->_committed = YES; [b->_queue hakiosEnqueue:b]; [b->_queue hakiosCommit:b]; }
static void reset(void) { submits = largest = prepared = scheduled = n = 0; memset(reasonsSeen, 0, sizeof(reasonsSeen)); }
int main(int argc, char **argv) {
    disabled = argc > 1; (void)argv;
    @autoreleasepool {
        // Ordinary serial commits must remain private until the explicit idle boundary.
        reset(); HakiosMetalCommandQueue *q = [HakiosMetalCommandQueue new];
        for (unsigned i = 0; i < 4; i++) commit(buffer(q, i));
        assert(submits == (disabled ? 4 : 0));
        hakios_metal_drain_all(HAKIOS_METAL_DRAIN_IDLE);
        assert(submits == (disabled ? 4 : 1)); assert(largest == (disabled ? 1 : 4));
        for (unsigned i = 0; i < 4; i++) assert(order[i] == i);
        [q release];
        // An actual CFRunLoop idle observer, with no later commit, must flush.
        reset(); q = [HakiosMetalCommandQueue new]; commit(buffer(q, 0));
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, false);
        assert(submits == 1 && scheduled == 1); [q release];
        // Surface write and present include earlier private CBs in their drain.
        for (unsigned present = 0; present < 2; present++) {
            reset(); q = [HakiosMetalCommandQueue new]; commit(buffer(q, 0));
            HakiosMetalCommandBuffer *b = buffer(q, 1); Drawable *d = [Drawable new];
            if (present) [b presentDrawable:d]; else b->core.surface = YES;
            commit(b); assert(submits == (disabled ? 2 : 1)); assert(!present || d->presented);
            if (!disabled) assert(reasonsSeen[HAKIOS_METAL_DRAIN_SURFACE] == 1);
            [d release]; [q release];
        }
        // Every CPU wait and late handler uses the actual plugin sync path.
        for (unsigned sync = 0; sync < 4; sync++) {
            reset(); q = [HakiosMetalCommandQueue new];
            HakiosMetalCommandBuffer *b = buffer(q, 0); commit(b);
            __block unsigned callback = 0;
            if (sync == 0) [b waitUntilScheduled];
            if (sync == 1) [b waitUntilCompleted];
            if (sync == 2) [b addScheduledHandler:^(id<MTLCommandBuffer> cb) { (void)cb; callback++; }];
            if (sync == 3) [b addCompletedHandler:^(id<MTLCommandBuffer> cb) { (void)cb; callback++; }];
            assert(submits == 1 && scheduled == 1); assert(sync < 2 || callback == 1);
            [q release];
        }
        // Pre-registered callbacks force submission at commit; scheduled precedes completed.
        reset(); q = [HakiosMetalCommandQueue new]; commit(buffer(q, 0));
        HakiosMetalCommandBuffer *b = buffer(q, 1); NSMutableArray *calls = [NSMutableArray array];
        [b addScheduledHandler:^(id<MTLCommandBuffer> cb) { assert([(HakiosMetalCommandBuffer *)cb hakiosCommandBuffer]->status >= 3); [calls addObject:@1]; }];
        [b addCompletedHandler:^(id<MTLCommandBuffer> cb) { (void)cb; [calls addObject:@2]; }];
        commit(b); assert(([calls isEqual:@[@1, @2]])); assert(submits == (disabled ? 2 : 1)); [q release];
        // A scheduled handler may reenter waitUntilScheduled and append a completion handler.
        reset(); q = [HakiosMetalCommandQueue new]; b = buffer(q, 0); calls = [NSMutableArray array];
        [b addScheduledHandler:^(id<MTLCommandBuffer> cb) {
            [calls addObject:@1]; [(HakiosMetalCommandBuffer *)cb waitUntilScheduled];
            [(HakiosMetalCommandBuffer *)cb addCompletedHandler:^(id<MTLCommandBuffer> done) { (void)done; [calls addObject:@3]; }];
        }];
        [b addCompletedHandler:^(id<MTLCommandBuffer> cb) { (void)cb; [calls addObject:@2]; }];
        commit(b); assert(([calls isEqual:@[@1, @2, @3]])); [q release];
        // Failed recording must wake scheduling waiters without invoking scheduled handlers.
        reset(); q = [HakiosMetalCommandQueue new]; b = buffer(q, 0); b->core.status = HAKIOS_METAL_ERROR;
        b->_committed = YES; [b hakiosCompletedNow];
        __block unsigned errorScheduled = 0;
        [b addScheduledHandler:^(id<MTLCommandBuffer> cb) { (void)cb; errorScheduled++; }];
        [b waitUntilScheduled]; assert(errorScheduled == 0); [q release];
        // Event signals and encoder fence entry points make the signaller a submission boundary.
        for (unsigned kind = 0; kind < 5; kind++) {
            reset(); q = [HakiosMetalCommandQueue new]; commit(buffer(q, 0)); b = buffer(q, 1);
            HakiosMetalEvent *event = [HakiosMetalEvent new]; FenceEncoder *encoder = [FenceEncoder new];
            encoder->_commandBuffer = b;
            if (kind == 0) [b encodeSignalEvent:event value:7];
            if (kind == 1) [encoder updateFence:nil];
            if (kind == 2) [encoder waitForFence:nil];
            if (kind == 3) [encoder updateFence:nil afterStages:MTLRenderStageVertex];
            if (kind == 4) [encoder waitForFence:nil beforeStages:MTLRenderStageFragment];
            commit(b); assert(submits == (disabled ? 2 : 1));
            if (kind == 0) assert(event->value == 7);
            if (!disabled) assert(reasonsSeen[HAKIOS_METAL_DRAIN_CPU_SYNC] == 1);
            [encoder release]; [event release]; [q release];
        }
        // CA's client completion queue is occupied by the snapshot request.
        // Driver publication must precede the event and cannot be dispatched to that queue.
        reset(); q = [HakiosMetalCommandQueue new]; b = buffer(q, 0);
        HakiosMetalTexture *tile = [HakiosMetalTexture new], *view = [HakiosMetalTexture new];
        view->parent = tile; publication = tile;
        clientCompletion = dispatch_queue_create("CA.client-completion", DISPATCH_QUEUE_SERIAL);
        dispatch_suspend(clientCompletion);
        [b hakiosWriteShadowAtCompletion:tile]; [b hakiosWriteShadowAtCompletion:view];
        assert(tile->writes == 1 && b->_shadowTargets.count == 1);
        HakiosMetalEvent *ready = [HakiosMetalEvent new]; [b encodeSignalEvent:ready value:9];
        __block unsigned clientCalls = 0;
        [b addCompletedHandler:^(id<MTLCommandBuffer> done) { (void)done; assert(tile->visible); clientCalls++; }];
        commit(b);
        assert(tile->visible && !tile->writes && ready->value == 9 && clientCalls == 0);
        dispatch_resume(clientCompletion); dispatch_sync(clientCompletion, ^{});
        assert(clientCalls == 1);
        dispatch_release(clientCompletion); clientCompletion = NULL; publication = nil;
        [tile release]; [view release]; [ready release]; [q release];
        // CPU sync racing the stage must drain after the stale IDLE snapshot has been handed over.
        if (!disabled) {
            reset(); q = [HakiosMetalCommandQueue new]; b = buffer(q, 0);
            holdStage = YES; stageEntered = dispatch_semaphore_create(0); stageRelease = dispatch_semaphore_create(0);
            dispatch_group_t group = dispatch_group_create();
            dispatch_group_async(group, dispatch_get_global_queue(0, 0), ^{ @autoreleasepool { commit(b); } });
            dispatch_semaphore_wait(stageEntered, DISPATCH_TIME_FOREVER);
            dispatch_group_async(group, dispatch_get_global_queue(0, 0), ^{ @autoreleasepool { [b waitUntilScheduled]; } });
            while (!__atomic_load_n(&b->_drainReason, __ATOMIC_ACQUIRE)) sched_yield();
            dispatch_semaphore_signal(stageRelease);
            assert(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
            holdStage = NO; dispatch_release(group); dispatch_release(stageEntered); dispatch_release(stageRelease);
            [q join]; assert(submits == 1); [q release];
        }
        // PencilKit's dispatch render work item can commit private work and return without running a CFRunLoop.
        reset(); q = [HakiosMetalCommandQueue new];
        dispatch_queue_t caller = dispatch_queue_create("pencil.render", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t returned = dispatch_semaphore_create(0);
        dispatch_async(caller, ^{ @autoreleasepool { commit(buffer(q, 0)); } dispatch_semaphore_signal(returned); });
        dispatch_semaphore_wait(returned, DISPATCH_TIME_FOREVER);
        [q join];
        assert(submits == 1 && scheduled == 1);
        [q release]; dispatch_release(caller); dispatch_release(returned);
        // Enqueue reservations and an event wait still preserve submission order.
        for (unsigned event = 0; event < 2; event++) {
            reset(); q = [HakiosMetalCommandQueue new]; NSMutableArray *buffers = [NSMutableArray array];
            for (unsigned i = 0; i < 4; i++) {
                HakiosMetalCommandBuffer *next = buffer(q, i); next->waits = event && i == 0;
                next->_committed = YES; [buffers addObject:next]; [q hakiosEnqueue:next];
            }
            for (unsigned i = 1; i < 4; i++) [q hakiosCommit:buffers[i]];
            assert(submits == 0); [q hakiosCommit:buffers[0]]; [q join];
            hakios_metal_drain_all(HAKIOS_METAL_DRAIN_IDLE);
            assert(prepared == 4 && scheduled == 4 && n == 4);
            for (unsigned i = 0; i < 4; i++) assert(order[i] == i);
            assert(submits == (disabled ? 4 : event ? 2 : 1)); [q release];
        }
    }
    puts("CA queue: private serial batch, surface/present, CPU waits/handlers, callback order, runloop idle, event order, rollback passed");
}
'''.replace('QUEUE_METHODS', queue_methods).replace('CB_METHODS', cb_methods).replace('FENCE_METHODS', fence_methods)
with tempfile.TemporaryDirectory(prefix='hakios-batch-plugin-') as directory:
    directory = Path(directory)
    (directory / 'test.m').write_text(harness)
    subprocess.run(['clang', '-fblocks', '-Werror', '-Wno-deprecated-declarations', '-framework', 'Foundation',
                    '-framework', 'CoreFoundation', str(directory / 'test.m'), '-o', str(directory / 'test')], check=True)
    result = subprocess.run([str(directory / 'test')])
    if args.control_shadow:
        assert result.returncode != 0, 'deferred publication unexpectedly passed'
        print('deferred shadow publication rejected as expected')
        raise SystemExit(0)
    result.check_returncode()
    subprocess.run([str(directory / 'test'), 'off'], check=True)
