#!/usr/bin/env python3
"""Exercise shipped blit/shadow methods with delayed GPU copies and surface seeds."""
from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--control', choices=['source', 'destination', 'view', 'writes'])
args = parser.parse_args()
source = (Path(__file__).resolve().parents[2] / 'userland/src/HakiosMetalCA.m').read_text()

def extract(signature, start=0):
    begin = source.index(signature, start)
    brace = source.index('{', begin)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[begin:end]

texture_start = source.index('@implementation HakiosMetalTexture\n')
methods = '\n'.join(extract(s, texture_start) for s in [
    '- (BOOL)hakiosIsShadow', '- (void)hakiosRefreshShadow',
    '- (void)hakiosWriteBackShadow', '- (void)hakiosShadowWriteQueued'])
helper = 'static hakios_metal_texture *\n' + extract('hm_blit_texture(')
copy = extract('- (void)copyFromTexture:(id)sourceTexture sourceSlice:', source.index('/* Texture copies are'))
if args.control == 'source':
    helper = helper.replace('[texture hakiosRefreshShadow];', '')
if args.control == 'destination':
    helper = helper.replace('write && [texture hakiosIsShadow]', 'NO')
if args.control == 'view':
    methods = methods.replace('return _parent != nil ? [_parent hakiosIsShadow] : _shadow;', 'return _shadow;')
if args.control == 'writes':
    # the refresh as it was: it copies the surface over a copy that still has GPU writes to write back
    methods = methods.replace('if (!oldRule && __atomic_load_n(&_shadowWrites, __ATOMIC_RELAXED) != 0) {', 'if (0) {')

harness = r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#define hm_print(...) ((void)0)
#define hm_texture_trace(...) ((void)0)
#define hm_handoff_on() NO
static struct { unsigned shadowImports, shadowQueued, imports, planeImports; } hm_diag;
#define hm_diag_add(counter) (*(counter) += 1)
#define kIOSurfaceLockReadOnly 1
#define kIOReturnSuccess 0
typedef struct { uint8_t rows[32]; uint32_t seed; } *IOSurfaceRef;
typedef struct { uint8_t rows[32]; } hakios_metal_texture;
typedef struct { hakios_metal_texture *from, *to; unsigned sx, dx, width; } hakios_metal_cb;
static uint32_t IOSurfaceGetSeed(IOSurfaceRef s) { return s->seed; }
static unsigned IOSurfaceGetID(IOSurfaceRef s) { (void)s; return 1; }
static unsigned IOSurfaceGetWidth(IOSurfaceRef s) { (void)s; return 8; }
static unsigned IOSurfaceGetHeight(IOSurfaceRef s) { (void)s; return 1; }
static unsigned IOSurfaceGetPlaneCount(IOSurfaceRef s) { (void)s; return 0; }
static size_t IOSurfaceGetBytesPerRow(IOSurfaceRef s) { (void)s; return 32; }
static size_t IOSurfaceGetBytesPerRowOfPlane(IOSurfaceRef s, NSUInteger p) { (void)p; return IOSurfaceGetBytesPerRow(s); }
static void *IOSurfaceGetBaseAddress(IOSurfaceRef s) { return s->rows; }
static void *IOSurfaceGetBaseAddressOfPlane(IOSurfaceRef s, NSUInteger p) { (void)p; return s->rows; }
static int IOSurfaceLock(IOSurfaceRef s, unsigned o, uint32_t *seed) { (void)o; if(seed) *seed=s->seed; return 0; }
static int IOSurfaceUnlock(IOSurfaceRef s, unsigned o, uint32_t *seed) { if (!o) s->seed+=2; if(seed) *seed=s->seed; return 0; }
static unsigned hakios_metal_texture_width(hakios_metal_texture *t) { (void)t; return 8; }
static unsigned hakios_metal_texture_height(hakios_metal_texture *t) { (void)t; return 1; }
static int hakios_metal_texture_replace(hakios_metal_texture *t, unsigned x, unsigned y, unsigned w, unsigned h, const void *p, uint64_t pitch) {
    (void)x; (void)y; (void)w; (void)h; (void)pitch; memcpy(t->rows,p,32); return 0;
}
static int hakios_metal_texture_read(hakios_metal_texture *t, unsigned x, unsigned y, unsigned w, unsigned h, void *p, uint64_t pitch) {
    (void)x; (void)y; (void)w; (void)h; (void)pitch; memcpy(p,t->rows,32); return 0;
}
static int hakios_metal_cb_blit(hakios_metal_cb *cb, hakios_metal_texture *from, unsigned sl, unsigned sx, unsigned sy, unsigned sw, unsigned sh,
                               hakios_metal_texture *to, unsigned dl, unsigned dx, unsigned dy, unsigned dw, unsigned dh, unsigned flags) {
    (void)sl; (void)sy; (void)sh; (void)dl; (void)dy; (void)dw; (void)dh; (void)flags;
    *cb=(hakios_metal_cb){from,to,sx,dx,sw}; return 0;
}
static const char *hakios_metal_error(void) { return "error"; }
static void hakios_metal_cb_refuse(hakios_metal_cb *cb, const char *why) { (void)cb; (void)why; abort(); }
static double hm_now(void) { return 0; }
static int hm_ca_arg(const char *a) { (void)a; return 0; }
static BOOL hm_flicker_say(unsigned *n) { (void)n; return NO; }
static void hm_fps_shadow_blit(BOOL write) { (void)write; }
static void hm_fps_shadow(BOOL in, double t) { (void)in; (void)t; }
static void hm_fps_shadow_kept(BOOL torn) { (void)torn; }
static void hm_fps_ycbcr_time(double t) { (void)t; }
@interface HakiosMetalTexture : NSObject {
@public
    hakios_metal_texture *_texture;
    HakiosMetalTexture *_parent;
    IOSurfaceRef _iosurface;
    NSUInteger _iosurfacePlane;
    BOOL _shadow;
    uint32_t _shadowSeed;
    uint8_t *_shadowBase;
    MTLTextureUsage _usage;
    NSLock *_shadowLock;
    unsigned _shadowWrites;
    int _ycbcr;
}
- (BOOL)hakiosIsShadow;
- (void)hakiosRefreshShadow;
- (void)hakiosWriteBackShadow;
- (void)hakiosShadowWriteQueued;
@end
@implementation HakiosMetalTexture
- (BOOL)hakiosConvertYCbCr { abort(); }
- (void)hakiosUsedBy:(uint64_t)s { (void)s; }
- (hakios_metal_texture *)hakiosTexture { return _texture; }
- (id)parentTexture { return _parent; }
METHODS
@end
@interface HakiosMetalCommandBuffer : NSObject {
@public
    hakios_metal_cb core;
    NSMutableArray *handlers;
    NSMutableArray *_shadowTargets; uint64_t _useSeq;
}
@end
@implementation HakiosMetalCommandBuffer
- (id)init { self=[super init]; handlers=[NSMutableArray new]; return self; }
- (void)dealloc { [_shadowTargets release]; [handlers release]; [super dealloc]; }
- (hakios_metal_cb *)hakiosCommandBuffer { return &core; }
SHADOW_REGISTER
- (void)hakiosTrackTexture:(id)t write:(BOOL)w { (void)t; (void)w; }
- (void)addCompletedHandler:(void (^)(id<MTLCommandBuffer>))h { [handlers addObject:[[h copy] autorelease]]; }
- (void)complete {
    memcpy(core.to->rows+4*core.dx, core.from->rows+4*core.sx, 4*core.width);
    for (HakiosMetalTexture *t in _shadowTargets) [t hakiosWriteBackShadow];
    [_shadowTargets removeAllObjects];
    for (void (^handler)(id<MTLCommandBuffer>) in handlers) handler((id)self);
    [handlers removeAllObjects];
}
@end
@interface HakiosMetalBlitCommandEncoder : NSObject { @public HakiosMetalCommandBuffer *_commandBuffer; }
@end
@implementation HakiosMetalBlitCommandEncoder
- (uint64_t)hakiosUseSeq { return 1; }
HELPER
COPY
@end
static HakiosMetalTexture *wrap(hakios_metal_texture *core, IOSurfaceRef surface) {
    HakiosMetalTexture *t=[HakiosMetalTexture new]; t->_texture=core; t->_iosurface=surface;
    t->_shadow=surface!=NULL; t->_usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    if(surface) t->_shadowSeed=surface->seed;
    return t;
}
static void copyPixels(HakiosMetalBlitCommandEncoder *e, id from, id to, unsigned dx, unsigned width) {
    [e copyFromTexture:from sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,1,1)
             toTexture:to destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(dx,0,0)];
}
int main(void) {
    @autoreleasepool {
        struct { uint8_t rows[32]; uint32_t seed; } surface={{0},1}, output={{0},1};
        hakios_metal_texture background={0}, canvas={0}, shadow={0};
        HakiosMetalTexture *source=wrap(&background,(IOSurfaceRef)&surface), *destination=wrap(&canvas,NULL);
        HakiosMetalTexture *view=wrap(&background,NULL); view->_parent=source;
        HakiosMetalCommandBuffer *cb=[HakiosMetalCommandBuffer new];
        HakiosMetalBlitCommandEncoder *e=[HakiosMetalBlitCommandEncoder new]; e->_commandBuffer=cb;
        // The snapshot wrapper survives several strokes; a CPU/CA update advances its surface seed.
        for(unsigned stroke=1;stroke<=3;stroke++) {
            surface.rows[4*stroke]=stroke; surface.seed+=2;
            copyPixels(e,view,destination,0,8);
            assert(canvas.rows[4*stroke]==0); // GPU has not run
            assert(cb->handlers.count==0); // source read does not add a writeback or force a completion callback
            [cb complete];
            for(unsigned old=1;old<=stroke;old++) assert(canvas.rows[4*old]==old);
        }
        // Partial copy into a shadow view preserves pixels outside the copy and publishes only on completion.
        output.rows[28]=99; output.seed+=2;
        HakiosMetalTexture *target=wrap(&shadow,(IOSurfaceRef)&output); target->_shadowSeed=1;
        HakiosMetalTexture *targetView=wrap(&shadow,NULL); targetView->_parent=target;
        copyPixels(e,destination,targetView,0,4);
        assert(cb->_shadowTargets.count==1 && target->_shadowWrites==1 && output.rows[4]==0);
        [cb complete];
        assert(!target->_shadowWrites && output.rows[4]==1 && output.rows[8]==2 && output.rows[12]==3 && output.rows[28]==99);
        assert(target->_shadowSeed==output.seed);
        // A refresh while this copy still has GPU writes to write back takes no copy: the surface, which does not have
        // that drawing yet, must not replace it (App Library's black region). The surface's seed moving stands for
        // another pass's write-back landing in between.
        struct { uint8_t rows[32]; uint32_t seed; } late={{0},1};
        hakios_metal_texture lateCore={0};
        HakiosMetalTexture *lateTarget=wrap(&lateCore,(IOSurfaceRef)&late); lateTarget->_shadowSeed=late.seed+1; // as -hakiosShadow:
        HakiosMetalTexture *lateView=wrap(&lateCore,NULL); lateView->_parent=lateTarget;
        [lateTarget hakiosRefreshShadow];               // the copy, and the base it keeps
        HakiosMetalCommandBuffer *cb2=[HakiosMetalCommandBuffer new];
        HakiosMetalBlitCommandEncoder *e2=[HakiosMetalBlitCommandEncoder new]; e2->_commandBuffer=cb2;
        copyPixels(e2,destination,lateView,4,4);       // a pass draws into the copy (pixels 4..7); its buffer has not completed
        assert(lateTarget->_shadowWrites==1 && lateCore.rows[20]==0);
        late.rows[12]=5; late.seed+=2;                 // the surface moves under the copy
        [lateTarget hakiosRefreshShadow];               // binding it for a sample, before the write-back
        assert(lateCore.rows[12]==0);                   // the copy kept what it had...
        assert(lateTarget->_shadowSeed==1);              // ...and took no new base or seed: the refresh gave way
        [cb2 complete];
        assert(!lateTarget->_shadowWrites && late.rows[20]==1 && late.rows[12]==5 && late.rows[16]==0);
        free(target->_shadowBase); free(source->_shadowBase); free(lateTarget->_shadowBase);
        [lateView release]; [lateTarget release]; [e2 release]; [cb2 release];
        [targetView release]; [target release]; [view release]; [source release]; [destination release]; [e release]; [cb release];
    }
    puts("Shadow blit: updated canvas snapshots, partial destination publication, views and GPU completion passed");
}
'''.replace('METHODS', methods).replace('HELPER', helper).replace('COPY', copy).replace('SHADOW_REGISTER', extract('- (void)hakiosWriteShadowAtCompletion:(HakiosMetalTexture *)texture\n')).replace('IOSurface', 'HMTestSurface').replace('kIOReturnSuccess', 'HMTestSuccess')
with tempfile.TemporaryDirectory(prefix='hakios-shadow-blit-') as directory:
    directory=Path(directory)
    (directory/'test.m').write_text(harness)
    subprocess.run(['clang','-fblocks','-Werror','-framework','Foundation','-framework','Metal',str(directory/'test.m'),'-o',str(directory/'test')],check=True)
    result=subprocess.run([str(directory/'test')])
    if args.control:
        assert result.returncode != 0, 'old behavior unexpectedly passed'
        print(f'{args.control} control rejected as expected')
    else:
        result.check_returncode()
