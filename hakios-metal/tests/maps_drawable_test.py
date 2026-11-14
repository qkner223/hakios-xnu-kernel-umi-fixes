#!/usr/bin/env python3
"""Run the shipped drawable handoff against a CA image queue and three-slot pool."""
from pathlib import Path
import argparse
import subprocess
import tempfile

header = Path(__file__).resolve().parents[2] / 'userland/src/HakiosMetalDrawables.h'
parser = argparse.ArgumentParser()
parser.add_argument('--control', choices=['commit', 'event', 'completion', 'policy'])
args = parser.parse_args()
implementation = header.read_text()
if args.control == 'commit':
    implementation = implementation.replace('    hm_drawable_commit(layer);', '    [layer release];')
if args.control == 'policy':
    implementation = implementation.replace('    ((void (*)(id, SEL))objc_msgSend)((id)objc_getClass("CATransaction"), @selector(flush));', '    if (!((BOOL (*)(id, SEL))objc_msgSend)(layer, sel_getUid("presentsWithTransaction"))) ((void (*)(id, SEL))objc_msgSend)((id)objc_getClass("CATransaction"), @selector(flush));')
if args.control == 'event':
    implementation = implementation.replace('    ((void (*)(id, SEL, id))objc_msgSend)(drawable, sel_getUid("setSharedEvent:"), nil);', '')
if args.control == 'completion':
    implementation = implementation.replace('    ((void (*)(id, SEL))objc_msgSend)(texture, sel_getUid("waitUntilComplete"));', '    (void)texture;')
harness = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <assert.h>
#include <pthread.h>
#include <time.h>
#define hm_print(...) ((void)0)
static BOOL diagnostics;
static BOOL hm_fps_on(void) { return diagnostics; }
static double hm_now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static void hm_drawable_trace(const char *s, id l, id d, double a) { (void)s; (void)l; (void)d; (void)a; }
static void hm_drawable_diagnostics_install(Class l, Class d) { (void)l; (void)d; }
@protocol MTLDrawable;
typedef void (^Presented)(id<MTLDrawable>);
typedef Presented MTLDrawablePresentedHandler;
@protocol MTLDrawable
- (void)addPresentedHandler:(Presented)handler;
@end
@class CAMetalLayer;
static __thread CAMetalLayer *dirtyLayer;
static __thread unsigned transactionDepth;
@interface CATransaction : NSObject
+ (void)flush;
+ (void)begin;
+ (void)commit;
@end
@interface HMTexture : NSObject { @public BOOL complete; unsigned waits; }
- (void)waitUntilComplete;
@end
@implementation HMTexture
- (void)waitUntilComplete { waits++; complete = YES; }
@end
@interface CAMetalDrawable : NSObject <MTLDrawable> {
    Presented _handler;
@public
    BOOL busy;
    BOOL deferred;
    unsigned kind;
    double argument;
    CAMetalLayer *owner;
    HMTexture *image;
    BOOL queued;
    id sharedEvent;
}
- (void)present;
- (void)presentAtTime:(double)time;
- (void)presentAfterMinimumDuration:(double)duration;
- (void)deliver;
- (void)finish;
@end
@interface CAMetalLayer : NSObject {
@public
    CAMetalDrawable *pool[3];
    dispatch_semaphore_t entered, proceed;
    BOOL transaction;
    unsigned latest, displayed, changes, flushes;
}
- (id)nextDrawable;
- (NSUInteger)maximumDrawableCount;
- (BOOL)presentsWithTransaction;
- (void)setContentsChanged;
- (void)insert:(CAMetalDrawable *)drawable;
- (void)commit;
@end
@implementation CAMetalLayer
- (id)init { self = [super init]; for (unsigned i = 0; i < 3; ++i) {
    pool[i] = [CAMetalDrawable new]; pool[i]->image = [HMTexture new];
} return self; }
- (void)dealloc { for (unsigned i = 0; i < 3; ++i) [pool[i] release]; [super dealloc]; }
- (NSUInteger)maximumDrawableCount { return 3; }
- (id)nextDrawable {
    if (entered) { dispatch_semaphore_signal(entered); dispatch_semaphore_wait(proceed, DISPATCH_TIME_FOREVER); }
    for (unsigned i = 0; i < 3; ++i) if (!pool[i]->busy) { pool[i]->busy = YES; pool[i]->owner = self; pool[i]->image->complete = NO; pool[i]->sharedEvent = @"CA surface event"; return pool[i]; }
    return nil;
}
- (BOOL)presentsWithTransaction { return transaction; }
- (void)setContentsChanged { assert(latest > displayed); changes++; dirtyLayer = self; }
- (void)insert:(CAMetalDrawable *)drawable {
    assert(drawable->image->complete); latest++; drawable->queued = YES;
    drawable->owner = nil; // CA releases its private references at present
}
- (void)commit {
    displayed = latest; flushes++;
    for (unsigned i = 0; i < 3; ++i) if (pool[i]->queued) {
        pool[i]->queued = NO; [pool[i] finish];
    }
}
@end
@implementation CATransaction
+ (void)flush { if (transactionDepth) return; CAMetalLayer *layer = dirtyLayer; dirtyLayer = nil; [layer commit]; }
+ (void)begin { transactionDepth++; }
+ (void)commit { assert(transactionDepth); if (!--transactionDepth) [self flush]; }
@end
@implementation CAMetalDrawable
- (void)dealloc { [image release]; [super dealloc]; }
- (id)layer { return owner; }
- (id)texture { return image; }
- (void)setSharedEvent:(id)event { assert(image->complete); sharedEvent = event; }
- (void)addPresentedHandler:(Presented)handler { assert(!_handler); _handler = [handler copy]; }
- (void)finish {
    if (deferred) return;
    assert(busy); busy = NO;
    if (_handler) { _handler((id)self); [_handler release]; _handler = nil; }
}
- (void)deliver { deferred = NO; [self finish]; }
- (void)present { assert(!sharedEvent); kind = 1; [owner insert:self]; }
- (void)presentAtTime:(double)time { assert(!sharedEvent); kind = 2; argument = time; [owner insert:self]; }
- (void)presentAfterMinimumDuration:(double)duration { assert(!sharedEvent); kind = 3; argument = duration; [owner insert:self]; }
@end

#include "HEADER"
int main(void) {
    @autoreleasepool {
        CAMetalLayer *layer = [CAMetalLayer new];
        hm_drawables_install(); // functional handoff also works with metal_fps disabled
        [[layer nextDrawable] present];
        assert(layer->displayed == 1 && layer->changes == 1 && layer->flushes == 1);
        assert(!hm_drawables.presents && !hm_drawables.requests);
        layer->transaction = YES;
        [CATransaction begin];
        [[layer nextDrawable] present];
        assert(layer->displayed == 1 && layer->latest == 2 && layer->changes == 2 && layer->flushes == 1);
        [CATransaction flush];
        assert(layer->displayed == 1);
        [CATransaction commit];
        assert(layer->displayed == 2 && layer->flushes == 2);
        // A layer policy does not create an explicit transaction on a dispatch worker.
        dispatch_semaphore_t published = dispatch_semaphore_create(0);
        for (unsigned policy = 0; policy < 2; ++policy) {
            layer->transaction = policy;
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                @autoreleasepool { [[layer nextDrawable] present]; dispatch_semaphore_signal(published); }
            });
            assert(!dispatch_semaphore_wait(published, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
            assert(layer->displayed == 3 + policy && layer->flushes == 3 + policy);
        }
        dispatch_release(published);
        layer->transaction = NO;
        diagnostics = YES; hm_drawables_install(); hm_drawables_install();
        for (unsigned frame = 0; frame < 30; ++frame) {
            CAMetalDrawable *drawables[3];
            for (unsigned i = 0; i < 3; ++i) drawables[i] = [layer nextDrawable];
            assert(![layer nextDrawable]);
            for (unsigned i = 0; i < 3; ++i) assert(drawables[i].retainCount == 1);
            [drawables[0] present];
            [drawables[1] presentAtTime:123.25];
            [drawables[2] presentAfterMinimumDuration:0.125];
            assert(drawables[0]->kind == 1);
            assert(drawables[1]->kind == 2 && drawables[1]->argument == 123.25);
            assert(drawables[2]->kind == 3 && drawables[2]->argument == 0.125);
            for (unsigned i = 0; i < 3; ++i) assert(drawables[i].retainCount == 1);
        }
        assert(layer->displayed == 94 && layer->changes == 94 && layer->flushes == 94);
        assert(hm_drawables.contentsChanged == 90 && hm_drawables.flushes == 90);
        assert(hm_drawables.requests == 120 && hm_drawables.returned == 120 && hm_drawables.nils == 30);
        assert(hm_drawables.presents == 90 && !hm_drawables.registered && !hm_drawables.presented);
        assert(!hm_drawables.pending && hm_drawables.maximum == 3);
        assert(!hm_drawables.nextActive && !hm_drawables.presentActive);
        hm_drawables_report(); assert(!hm_drawables.requests && !hm_drawables.presents);
        __block unsigned delivered = 0;
        for (unsigned i = 0; i < 3; ++i) {
            CAMetalDrawable *drawable = [layer nextDrawable]; drawable->deferred = YES;
            [drawable addPresentedHandler:^(id<MTLDrawable> done) { assert(done == (id)layer->pool[i]); delivered++; }];
            [drawable present];
        }
        assert(![layer nextDrawable] && hm_drawables.pending == 3);
        hm_drawables_report(); assert(hm_drawables.pending == 3);
        for (unsigned i = 0; i < 3; ++i) [layer->pool[i] deliver];
        assert(!hm_drawables.pending && hm_drawables.presented == 3 && delivered == 3);
        hm_drawables_report();
        layer->entered = dispatch_semaphore_create(0); layer->proceed = dispatch_semaphore_create(0);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            @autoreleasepool { [[layer nextDrawable] present]; dispatch_semaphore_signal(done); }
        });
        assert(!dispatch_semaphore_wait(layer->entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
        assert(hm_drawables.requests == 1 && hm_drawables.returned == 0 && hm_drawables.nextActive == 1);
        hm_drawables_report(); assert(hm_drawables.nextActive == 1);
        dispatch_semaphore_signal(layer->proceed);
        assert(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
        assert(!hm_drawables.nextActive && hm_drawables.returned == 1 && !hm_drawables.presented);
        dispatch_release(done); dispatch_release(layer->entered); dispatch_release(layer->proceed);
        [layer release];
    }
    puts("CA handoff: GPU before synchronous insert, contents commit, foreground display, transaction boundaries, three-slot reuse, diagnostics and lifetimes passed");
}
'''.replace('#include "HEADER"', implementation).replace('CATransaction', 'HMTestTransaction').replace('CAMetalLayer', 'HMTestMetalLayer').replace('CAMetalDrawable', 'HMTestMetalDrawable')
with tempfile.TemporaryDirectory(prefix='hakios-maps-drawables-') as directory:
    directory = Path(directory)
    (directory / 'test.m').write_text(harness)
    subprocess.run(['clang', '-fblocks', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', '-framework', 'Foundation',
                    str(directory / 'test.m'), '-o', str(directory / 'test')], check=True)
    result = subprocess.run([str(directory / 'test')])
    if args.control:
        assert result.returncode != 0, 'old behavior unexpectedly passed'
        print(f'{args.control} control rejected as expected')
    else:
        result.check_returncode()
