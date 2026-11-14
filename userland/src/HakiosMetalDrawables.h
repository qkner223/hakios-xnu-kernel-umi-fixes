/* CA drawable handoff, including VectorKit's direct presents. */
static struct {
    pthread_mutex_t lock;
    unsigned requests, returned, nils, presents, registered, presented, pending, nextActive, presentActive;
    unsigned contentsChanged, flushes;
    NSUInteger maximum;
    double nextMax, presentMax;
} hm_drawables = { .lock = PTHREAD_MUTEX_INITIALIZER };
static id (*hm_next_drawable_original)(id, SEL);
static void (*hm_present_original)(id, SEL);
static void (*hm_present_time_original)(id, SEL, double);
static void (*hm_present_duration_original)(id, SEL, double);
static void (*hm_add_presented_original)(id, SEL, MTLDrawablePresentedHandler);

static id hm_next_drawable(id layer, SEL sel)
{
    if (!hm_fps_on()) return hm_next_drawable_original(layer, sel);
    const double start = hm_now();
    const NSUInteger maximum = ((NSUInteger (*)(id, SEL))objc_msgSend)(layer, @selector(maximumDrawableCount));
    pthread_mutex_lock(&hm_drawables.lock);
    hm_drawables.requests++;
    hm_drawables.nextActive++;
    hm_drawables.maximum = maximum;
    pthread_mutex_unlock(&hm_drawables.lock);
    hm_drawable_trace("next-request", layer, nil, 0);
    id drawable = hm_next_drawable_original(layer, sel);
    const double elapsed = hm_now() - start;
    hm_drawable_trace("next-return", layer, drawable, elapsed);
    pthread_mutex_lock(&hm_drawables.lock);
    hm_drawables.nextActive--;
    hm_drawables.returned++;
    hm_drawables.nils += drawable == nil;
    hm_drawables.nextMax = MAX(hm_drawables.nextMax, elapsed);
    pthread_mutex_unlock(&hm_drawables.lock);
    if (elapsed >= 0.1 || drawable == nil)
        hm_print("ca-drawables: nextDrawable layer=%p maximumDrawableCount=%lu returned=%p wait=%.1f ms\n",
                 layer, (unsigned long)maximum,
                 drawable, elapsed * 1e3);
    return drawable;
}

static void hm_drawable_add_presented(id drawable, SEL sel, MTLDrawablePresentedHandler handler)
{
    if (!hm_fps_on()) { hm_add_presented_original(drawable, sel, handler); return; }
    pthread_mutex_lock(&hm_drawables.lock);
    hm_drawables.registered++;
    hm_drawables.pending++;
    pthread_mutex_unlock(&hm_drawables.lock);
    // Observe only handlers the client registered. Do not enable CA's handler
    // retention path for clients that do not use it (VectorKit).
    hm_drawable_trace("handler-register", nil, drawable, 0);
    hm_add_presented_original(drawable, sel, ^(id<MTLDrawable> done) {
        pthread_mutex_lock(&hm_drawables.lock);
        hm_drawables.presented++;
        hm_drawables.pending--;
        pthread_mutex_unlock(&hm_drawables.lock);
        hm_drawable_trace("handler-deliver", nil, done, 0);
        handler(done);
    });
}

static double hm_drawable_present_begin(void)
{
    if (!hm_fps_on()) return -1;
    pthread_mutex_lock(&hm_drawables.lock);
    hm_drawables.presents++;
    hm_drawables.presentActive++;
    pthread_mutex_unlock(&hm_drawables.lock);
    return hm_now();
}

static void hm_drawable_present_end(double start)
{
    if (start < 0) return;
    const double elapsed = hm_now() - start;
    pthread_mutex_lock(&hm_drawables.lock);
    hm_drawables.presentActive--;
    hm_drawables.presentMax = MAX(hm_drawables.presentMax, elapsed);
    pthread_mutex_unlock(&hm_drawables.lock);
}

/* QuartzCore's image-queue-only present branch does not dirty the layer. AGX
 * supplies the surface/display handoff that makes that branch visible; this
 * driver has no AGX surface fence. Finish the surface's committed GPU uses,
 * insert it through CA's original method, then commit the changed queue through
 * the layer. Capture the layer before present releases its private references.
 * presentsWithTransaction is a layer policy, not the current thread's transaction
 * depth (VectorKit sets it to YES). CATransaction flush submits an implicit
 * transaction and leaves an explicit transaction open, as CA's flush implements.
 */
static id hm_drawable_prepare(id drawable)
{
    id layer = [((id (*)(id, SEL))objc_msgSend)(drawable, @selector(layer)) retain];
    hm_drawable_trace("present-call", layer, drawable, 0);
    id texture = ((id (*)(id, SEL))objc_msgSend)(drawable, @selector(texture));
    ((void (*)(id, SEL))objc_msgSend)(texture, sel_getUid("waitUntilComplete"));
    hm_drawable_trace("texture-ready", layer, drawable, 0);
    /* CA otherwise inserts from an IOSurfaceSharedEvent listener after present
     * returns. GPU completion above replaces that unsupported display fence;
     * select CA's synchronous insertion before dirtying its image queue. */
    ((void (*)(id, SEL, id))objc_msgSend)(drawable, sel_getUid("setSharedEvent:"), nil);
    return layer;
}

static void hm_drawable_commit(id layer)
{
    ((void (*)(id, SEL))objc_msgSend)(layer, sel_getUid("setContentsChanged"));
    hm_drawable_trace("contents-dirty", layer, nil, 0);
    ((void (*)(id, SEL))objc_msgSend)((id)objc_getClass("CATransaction"), @selector(flush));
    hm_drawable_trace("transaction-flush-return", layer, nil, 0);
    if (hm_fps_on()) {
        pthread_mutex_lock(&hm_drawables.lock);
        hm_drawables.contentsChanged++;
        hm_drawables.flushes++;
        pthread_mutex_unlock(&hm_drawables.lock);
    }
    [layer release];
}

static void hm_drawable_present(id drawable, SEL sel)
{
    const double start = hm_drawable_present_begin();
    id layer = hm_drawable_prepare(drawable);
    hm_present_original(drawable, sel);
    hm_drawable_trace("present-return-inserted", layer, drawable, 0);
    hm_drawable_commit(layer);
    hm_drawable_present_end(start);
}

static void hm_drawable_present_time(id drawable, SEL sel, double time)
{
    const double start = hm_drawable_present_begin();
    id layer = hm_drawable_prepare(drawable);
    hm_drawable_trace("present-at-time", layer, drawable, time);
    hm_present_time_original(drawable, sel, time);
    hm_drawable_trace("present-return-inserted", layer, drawable, 0);
    hm_drawable_commit(layer);
    hm_drawable_present_end(start);
}

static void hm_drawable_present_duration(id drawable, SEL sel, double duration)
{
    const double start = hm_drawable_present_begin();
    id layer = hm_drawable_prepare(drawable);
    hm_drawable_trace("present-min-duration", layer, drawable, duration);
    hm_present_duration_original(drawable, sel, duration);
    hm_drawable_trace("present-return-inserted", layer, drawable, 0);
    hm_drawable_commit(layer);
    hm_drawable_present_end(start);
}

static void hm_drawables_install(void)
{
    Class layer = objc_getClass("CAMetalLayer"), drawable = objc_getClass("CAMetalDrawable");
    // Metal-only processes need not load QuartzCore. Retry at IOSurface texture creation.
    if (layer == Nil || drawable == Nil) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hm_drawable_diagnostics_install(layer, drawable);
        hm_next_drawable_original = (void *)method_setImplementation(class_getInstanceMethod(layer, @selector(nextDrawable)), (IMP)hm_next_drawable);
        hm_present_original = (void *)method_setImplementation(class_getInstanceMethod(drawable, @selector(present)), (IMP)hm_drawable_present);
        hm_present_time_original = (void *)method_setImplementation(class_getInstanceMethod(drawable, @selector(presentAtTime:)), (IMP)hm_drawable_present_time);
        hm_present_duration_original = (void *)method_setImplementation(class_getInstanceMethod(drawable, @selector(presentAfterMinimumDuration:)), (IMP)hm_drawable_present_duration);
        hm_add_presented_original = (void *)method_setImplementation(class_getInstanceMethod(drawable, @selector(addPresentedHandler:)), (IMP)hm_drawable_add_presented);
    });
}

static void hm_drawables_report(void)
{
    pthread_mutex_lock(&hm_drawables.lock);
    hm_print("ca-drawables: next=%u returned=%u nil=%u next-active=%u next-max=%.1f ms maximumDrawableCount=%lu; present=%u handlers=%u delivered=%u pending=%u present-active=%u present-max=%.1f ms contents-changed=%u flush=%u\n",
             hm_drawables.requests, hm_drawables.returned, hm_drawables.nils, hm_drawables.nextActive,
             hm_drawables.nextMax * 1e3, (unsigned long)hm_drawables.maximum,
             hm_drawables.presents, hm_drawables.registered, hm_drawables.presented, hm_drawables.pending,
             hm_drawables.presentActive, hm_drawables.presentMax * 1e3, hm_drawables.contentsChanged, hm_drawables.flushes);
    hm_drawables.requests = hm_drawables.returned = hm_drawables.nils = hm_drawables.presents = hm_drawables.registered = hm_drawables.presented = 0;
    hm_drawables.contentsChanged = hm_drawables.flushes = 0;
    hm_drawables.nextMax = hm_drawables.presentMax = 0;
    pthread_mutex_unlock(&hm_drawables.lock);
}
