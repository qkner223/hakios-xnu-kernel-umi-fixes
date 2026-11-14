/*
 * (hakios) This is vcvkk's plug-in (github.com/vcvkk/darwin-redwood, branch hakios-workspace, userland/src/HakiosMetal.m
 * at eb9fdf5), the one that serves CoreAnimation's window server, with what this tree adds for it: CoreAnimation's
 * shaders chosen by pipeline (hm_bitcode_for()), QuartzCore's pipeline library given a default.metallib, stand-ins for
 * functions the library lacks (hm_stand_ins), and the device, shown to every process.
 * Built instead of hakios-metal's plug-in with METAL_PLUGIN=ca (userland/build.sh); the library it needs comes from
 * tools/ca-metallib.py.
 */
/*
 * HakiosMetal: the Metal plug-in of hakios, over the C interface of hakios-metal.
 *
 * Metal.framework finds a GPU by reading MetalPluginName and MetalPluginClassName off the IOAcceleratorES service
 * (docs: the kernel's IOAcceleratorES::setProperties, behind boot-arg metal=1), opens
 * /System/Library/Extensions/<name>.bundle with NSBundle, takes the class the second property names and sends it
 * -initWithAcceleratorPort:. That object is the device; everything Metal does afterwards it does by sending that object
 * and the objects it hands out the selectors of its protocols. This file is those objects. The GPU work itself -- memory,
 * the compiler, command buffers, the ring -- is hakios-metal's (include/hakios-metal/hakios_metal.h), linked in as a
 * static library; nothing here touches a register or a packet.
 *
 * What is written here is written against MEASUREMENTS, taken with an earlier Gallium-based plug-in on the same
 * phone (iOS 16.5, Metal 306.6.4). Each one is a thing that aborted a process before it was known:
 *
 *   - the device class subclasses Metal's private _MTLDevice DIRECTLY. The symbol _OBJC_CLASS_$__MTLDevice links
 *     because IOGPU.framework imports it; IOGPUMetalDevice, the class Apple's own driver subclasses, cannot be used
 *     because its init opens the accelerator with IOServiceOpen type 1, which this kernel refuses.
 *   - the contract MTLAddDevice puts on that object is FOUR methods and one protocol: -initWithAcceleratorPort: not
 *     nil, -featureProfile (0 is the lowest value whose limits table fills; 2, 3 and 10-12 abort inside Apple's
 *     initLimits), -maxBufferLength non-zero, -supportsVertexAmplificationCount:, and conformance to <MTLDeviceSPI>,
 *     which is private, requires 337 methods and is declared here at runtime with class_addProtocol. Both
 *     conformsToProtocol: checks in MTLAddDevice are asserts: a class without the protocol does not get a nil, it
 *     gets abort(), and a daemon that aborts is restarted by launchd (88 crashes in 100 s, measured).
 *   - Apple's own ivars are never laid out here: the few that have to be touched are found BY NAME with
 *     class_getInstanceVariable, in the Metal this code is actually running against.
 *   - -[_MTLCommandQueue initWithDevice:descriptor:] and -[_MTLComputePipelineState
 *     initWithDevice:pipelineStateDescriptor:] assert a non-nil descriptor; the first version of each in the earlier
 *     plug-in passed nil and was killed by it.
 *   - -[_MTLCommandBuffer initWithQueue:retainedReferences:synchronousDebugMode:] waits on the queue's 64-slot
 *     semaphore, and nothing in Metal signals it for a driver that does its own completion: the 65th -commandBuffer
 *     blocked for four minutes. The slot is given back here when the command buffer completes.
 *   - -[_MTLCommandEncoder initWithCommandBuffer:] retains the command buffer and -endEncoding is the only thing that
 *     releases it; -[_MTLCommandEncoder dealloc] aborts with "Command encoder released without endEncoding" (43 times
 *     in one boot). Every -endEncoding here calls super.
 *   - -commitWithDeadline: is an abstract method of _MTLCommandBuffer (its body is doesNotRecognizeSelector:), so it
 *     has to be overridden; so is -setThreadgroupPackingDisabled: of _MTLCommandEncoder.
 *   - -[_MTLDevice compiler] is a nil-stub and both pipeline entry points route through it, so a driver that leaves
 *     them alone gets nil and no reason. Metal parses .metallib containers itself (newLibraryWithData: asks the driver
 *     nothing) and the function's AIR is one call away: -[_MTLFunction bitcodeData] (<MTLFunctionSPI>) returns the
 *     function's module in LLVM's 0x0B17C0DE wrapper, the same bytes hakios-metal's own reader finds (checked by
 *     checksum on every function of a system library). So the pipeline-state entry points are overridden, as Apple's
 *     own AGX driver overrides them, and the bitcode goes to hakios_metal_kernel_compile_bitcode.
 *   - -targetDeviceInfo is a nil-stub of _MTLDevice that respondsToSelector: says yes to, and its one caller
 *     (QuartzCore asking for its precompiled pipeline library) dereferences the answer: 44 crashes in one boot. It is
 *     answered with a real struct, as Apple's own branch for a device that does not respond would fill one.
 *   - rendering (read off the shared cache of this image, 20F66, with the earlier work's tools): the render pipeline
 *     state's base class is _MTLRenderPipelineState, whose designated initialiser -initWithDevice:pipelineStateDescriptor:
 *     (0x181a294dc) opens the validation context "Render Pipeline Descriptor Validation", asserts "device must not be
 *     nil." / "device is not a MTLDevice." / "desc must not be nil." / "desc is not a MTLRenderPipelineDescriptor." and
 *     one rule about tessellationFactorScaleEnabled with indirect command buffers, then reads label (copied),
 *     supportIndirectCommandBuffers, textureWriteRoundingMode, meshFunction and, with one, the two mesh threadgroup
 *     limits -- and NOT the vertex or fragment function, the colour attachments, the vertex descriptor or the sample
 *     counts. Every one of those is this plug-in's to read, so the pipeline is validated here before super sees the
 *     descriptor (the context's end is the abort of the sampler lesson). There is no _MTLRenderCommandEncoder: Apple's
 *     render encoder descends from _MTLCommandEncoder through IOGPUMetalCommandEncoder, so the plug-in's descends from
 *     _MTLCommandEncoder directly, as the compute one does; -[_MTLCommandBuffer renderCommandEncoderWithDescriptor:]
 *     does not exist (the selector is the public protocol's and the driver's command buffer answers it, as
 *     AGXA11FamilyCommandBuffer does), and -[IOGPUMetalRenderCommandEncoder initWithCommandBuffer:descriptor:] drops
 *     the pass descriptor: the attachments are read here, in full, and nothing of Metal's reads them again.
 *
 * And one rule that is a measurement too: EVERYTHING THIS FILE DOES NOT IMPLEMENT REFUSES OUT LOUD. Of the 563
 * methods the earlier plug-in grew, 181 answered nil, zero or nothing without a line anywhere, and a nil without a
 * line was the failure mode that cost the most boots: a blit encoder answering nil silently hid that the window
 * server asked for a texture copy in every boot anybody had read. So every selector a Metal protocol declares and this
 * file does not answer goes through -forwardInvocation: (hm_forward below), which prints the selector, the class and
 * the caller once (then on powers of two, with the count) and returns zeros, which is what Metal's own nil-stubs
 * return; a selector no protocol declares prints the same line and then raises, which is what Metal's own abstract
 * methods do. Nil-stubs INHERITED from Metal's base classes stay silent -- the runtime cannot tell them from a real
 * method, and only reading the cache can (the private tree's tools/metal/absmeth.py did) -- which is why the ones
 * known to matter are overridden by name here.
 *
 * Every line carries the process it was written by: a driver is a library, several Metal clients may be alive in one
 * boot, and a refusal nobody can attribute is half a refusal. Manual reference counting throughout (no ARC): the file
 * sends objc_msgSend by hand and installs protocols at runtime, and the private base classes are declared by name
 * only, nothing of their layout.
 *
 * SPDX-License-Identifier: MIT
 */

#import <Foundation/Foundation.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <limits.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <pthread.h>
#include <execinfo.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "hakios-metal/hakios_metal.h"
#include "hakios-metal/perf.h"

static IOReturn hm_batch_surface_lock(IOSurfaceRef surface, IOSurfaceLockOptions options, uint32_t *seed)
{
    if (hakios_metal_surface_sync(IOSurfaceGetID(surface)) != 0) return kIOReturnError;
    return IOSurfaceLock(surface, options, seed);
}
#define IOSurfaceLock hm_batch_surface_lock

/* --- printing ----------------------------------------------------------------------------------------------- */

static void hm_print(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static int hm_print_fd = -1;    /* where hm_print writes: stderr, the console, or (metal_m2v=1) a copy of stderr kept aside */

/* To stderr, as one write: a launchd job's stderr is the console (userland/mkjobs.py sets StandardErrorPath) and its
 * stdout is nowhere, so the window server's lines -- the client this plug-in is for -- reached no log while they went
 * to stdout; one write keeps two threads' lines from interleaving. Flushed every time for the same reason as before:
 * the processes that reach a refusal are the ones that then abort, and a line not written dies with them. */
static void
hm_print(const char *fmt, ...)
{
	static char who[96];
	char line[1024];
	va_list ap;
	int n;

	if (who[0] == '\0') {
		snprintf(who, sizeof(who), "HakiosMetal[%s %d]", getprogname(), getpid());
	}
	n = snprintf(line, sizeof(line), "%s: ", who);
	va_start(ap, fmt);
	if (vsnprintf(line + n, sizeof(line) - (size_t)n, fmt, ap) >= (int)(sizeof(line) - (size_t)n)) {
		line[sizeof(line) - 2] = '\n';   /* (cut: the line still ends where a line ends) */
	}
	va_end(ap);
	/* An application's stderr is /dev/null (a launchd job's is the log); there the line goes to the console instead, as
	 * libhakios.sb.dylib's does in the programs it is given to, so that what this plug-in says inside Maps is read too */
	{
		int fd = hm_print_fd;

		if (fd < 0) {
			struct stat err, null;

			fd = 2;
			if (fstat(2, &err) == 0 && stat("/dev/null", &null) == 0 && S_ISCHR(err.st_mode) && err.st_rdev == null.st_rdev) {
				int console = open("/dev/console", O_WRONLY | O_NOCTTY);

				if (console >= 0) fd = console;
			}
		}
		hm_print_fd = fd;
		(void)!write(fd, line, strlen(line));
	}
}

/* a sentence that is true every time and says nothing new after the first */
#define HM_ONCE(...)							\
	do {								\
		static BOOL hm_said_;					\
									\
		if (!hm_said_) {					\
			hm_said_ = YES;					\
			hm_print(__VA_ARGS__);				\
		}							\
	} while (0)

/* --- flicker-diag: an IOSurface written on the processor while the GPU reads it (Freeform's stroke, 2026-11-10) ---
 * A write lock moves a surface's seed at the lock and again at the unlock (MiniIOSurface.cpp: lockCommon; it starts
 * at 1), so an even seed is a writer between the two. Lines are bounded: the first 24 of each kind, then one in 256. */
extern Boolean IOSurfaceGetProhibitUseCount(IOSurfaceRef buffer);   /* (exported by IOSurface, not in its header) */

static BOOL
hm_flicker_say(unsigned *count)
{
	const unsigned n = __atomic_add_fetch(count, 1, __ATOMIC_RELAXED);

	return n <= 24 || n % 256 == 0;
}

/* IOSurfaceIsInUse, which aborts on a surface made with kIOSurfaceProhibitUseCount: -1 there */
static int
hm_surface_in_use(IOSurfaceRef s)
{
	return IOSurfaceGetProhibitUseCount(s) ? -1 : IOSurfaceIsInUse(s) ? 1 : 0;
}

/* --- pixels looked at on the processor (HakiosMetalPixels.h: plain C, run by hakios-metal/tests/pixels_test.cpp) --- */

#include "HakiosMetalPixels.h"
#include "HakiosMetalYCbCr.h"

static void hm_fps_ycbcr(void);
static void hm_fps_ycbcr_time(double seconds); /* time spent copying planes and converting a YCbCr bind */
static void hm_fps_ycbcr_gpu(double seconds);

/* The matrix a two-plane surface declares: CoreVideo's attachment ("CVImageBufferYCbCrMatrix", ITU_R_709_2 for an HD
 * video, which a buffer's propagated attachments put on its surface), else the surface's own key. HM_YCC_UNKNOWN when
 * neither is there; *FROM the key it came from. */
static int
hm_surface_ycc_matrix(IOSurfaceRef surface, const char **from)
{
	static const char *const keys[] = { "CVImageBufferYCbCrMatrix", "IOSurfaceYCbCrMatrix" };

	*from = "none";
	for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
		CFStringRef key = CFStringCreateWithCString(NULL, keys[i], kCFStringEncodingUTF8);
		CFTypeRef value = key != NULL ? IOSurfaceCopyValue(surface, key) : NULL;
		char name[64] = "";
		int matrix = HM_YCC_UNKNOWN;

		if (key != NULL) CFRelease(key);
		if (value == NULL) continue;
		if (CFGetTypeID(value) == CFStringGetTypeID() && CFStringGetCString((CFStringRef)value, name, sizeof(name), kCFStringEncodingUTF8)) {
			matrix = hm_ycc_matrix_named(name);
		}
		CFRelease(value);
		if (matrix != HM_YCC_UNKNOWN) {
			*from = keys[i];
			return matrix;
		}
	}
	return HM_YCC_UNKNOWN;
}

/* A '420v' frame CA is converting (called under the read lock): any 0 in it is a byte its producer had not written
 * yet, and its (0, 0) CbCr pairs are what come out green (v8). Said for the first 32 such frames and every 128th after;
 * the first 8 are measured again 4 and 40 ms later with the seed, which tells a producer still writing (the zeros go,
 * the seed stays) from one that never writes them. Measures only. */
static void
hm_ycc_report_unwritten(IOSurfaceRef surface, const hm_ycc_planes *planes, size_t w, size_t h, uint32_t seed)
{
	static unsigned frames, unwritten;
	hm_ycc_unwritten u;

	hm_ycc_measure_unwritten(planes, w, h, &u);
	const unsigned n = __atomic_add_fetch(&frames, 1, __ATOMIC_RELAXED);
	if (u.zeroC == 0 && u.zeroY == 0) return;
	const unsigned k = __atomic_add_fetch(&unwritten, 1, __ATOMIC_RELAXED);
	if (k > 32 && k % 128 != 0) return;
	hm_print("ycbcr: 420v IOSurface %u seed %u converted with unwritten bytes: CbCr %zu of %zu pairs zero (rows %zu-%zu of %zu), "
		 "Y %zu of %zu zero; %u of %u 420v frames so far\n", IOSurfaceGetID(surface), seed, u.zeroC, planes->cw * planes->ch,
		 u.rowFirst, u.rowLast, planes->ch, u.zeroY, w * h, k, n);
	if (k > 8) return;
	const hm_ycc_planes later = *planes;
	CFRetain(surface);
	for (int ms = 4; ms <= 40; ms *= 10) {
		CFRetain(surface);
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
			uint32_t now = 0;
			hm_ycc_unwritten v;

			IOSurfaceLock(surface, kIOSurfaceLockReadOnly, &now);
			hm_ycc_measure_unwritten(&later, w, h, &v);
			IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
			hm_print("ycbcr: 420v IOSurface %u seed %u, %d ms later seed %u: CbCr %zu pairs zero (rows %zu-%zu), Y %zu zero\n",
				 IOSurfaceGetID(surface), seed, ms, now, v.zeroC, v.rowFirst, v.rowLast, v.zeroY);
			CFRelease(surface);
		});
	}
	CFRelease(surface);
}

/*
 * The census of flat pictures: a picture of 64 x 64 or more that a client hands over as one colour (every sample of
 * a 16 x 16 grid the same pixel, or for ASTC the same void-extent block), said once per size, format and colour. The
 * materials' purple came in so under GL (an 846 x 1827 ASTC picture of RGBA16 5959,1414,5959: PURPLE-umi.md): if it
 * comes in so here too, the purple is the client's picture -- a wallpaper snapshot nobody made -- and no GPU fault;
 * if it does not, it is made on the GPU. "the purple placeholder" marks red = blue well above green.
 */
static void
hm_flat_census(const char *via, uint64_t texture, unsigned format, size_t w, size_t h, const void *bytes, size_t bytesPerRow)
{
	static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
	static struct { unsigned format; uint32_t w, h; uint8_t rgba[4]; } told[64];
	static unsigned count, others;
	uint8_t rgba[4];
	int hdr = 0;

	if (w * h < 64 * 64 || !hm_picture_flat(format, w, h, (const uint8_t *)bytes, bytesPerRow, rgba, &hdr)) {
		return;
	}
	const BOOL magenta = hm_rgba_magenta(rgba);
	unsigned bw = 0, bh = 0;
	const BOOL astc = hm_astc_block(format, &bw, &bh);
	pthread_mutex_lock(&lock);
	for (unsigned i = 0; i < count; i++) {
		if (told[i].format == format && told[i].w == w && told[i].h == h && memcmp(told[i].rgba, rgba, 4) == 0) {
			pthread_mutex_unlock(&lock);
			return;
		}
	}
	/* (the room kept for the purple: flat greys and blacks are common and say little) */
	if (count == sizeof(told) / sizeof(told[0]) || (!magenta && others >= 40)) {
		pthread_mutex_unlock(&lock);
		return;
	}
	told[count].format = format;
	told[count].w = (uint32_t)w;
	told[count].h = (uint32_t)h;
	memcpy(told[count].rgba, rgba, 4);
	count++;
	others += !magenta;
	pthread_mutex_unlock(&lock);
	hm_print("flat picture: %zux%zu, pixel format %u%s, texture %llu, through %s: every sample RGBA8 (%u, %u, %u, %u)%s\n", w, h, format,
		 astc ? (hdr ? " (ASTC, HDR void extent)" : " (ASTC void extent)") : "",
		 (unsigned long long)texture, via, rgba[0], rgba[1], rgba[2], rgba[3], magenta ? " -- the purple placeholder" : "");
}

/*
 * Who sent the selector. backtrace(3) gives the frames; the ones inside this image, libobjc and CoreFoundation (the
 * forwarding machinery itself) are skipped, and the first frame beyond them is named by image and address, the
 * address also unslid (the shared cache's load address taken off), because every measurement of Metal on this port
 * is written in the cache's own addresses.
 */
static void
hm_caller(char *out, size_t size)
{
	void *frames[16];
	int n = backtrace(frames, (int)(sizeof(frames) / sizeof(frames[0])));

	for (int i = 1; i < n; i++) {
		Dl_info info;
		const char *image;
		intptr_t slide = 0;

		if (dladdr(frames[i], &info) == 0 || info.dli_fname == NULL) {
			continue;
		}
		image = strrchr(info.dli_fname, '/');
		image = image != NULL ? image + 1 : info.dli_fname;
		if (strcmp(image, "HakiosMetal") == 0 || strcmp(image, "libobjc.A.dylib") == 0 ||
		    strcmp(image, "CoreFoundation") == 0 || strcmp(image, "Foundation") == 0) {
			continue;
		}
		for (uint32_t k = 0; k < _dyld_image_count(); k++) {
			if ((const void *)_dyld_get_image_header(k) == info.dli_fbase) {
				slide = _dyld_get_image_vmaddr_slide(k);
				break;
			}
		}
		snprintf(out, size, "%s%s%s at %#lx (unslid %#lx)", image, info.dli_sname != NULL ? " " : "",
			 info.dli_sname != NULL ? info.dli_sname : "", (unsigned long)(uintptr_t)frames[i],
			 (unsigned long)((uintptr_t)frames[i] - (uintptr_t)slide));
		return;
	}
	snprintf(out, size, "(no frame outside the runtime among %d)", n);
}

/*
 * One refusal line per (class, selector), then again on powers of two of that pair's count. Per pair and not per call
 * site, because one -forwardInvocation: is the call site of every refused selector of a class; and not on every call,
 * because the window server asked the earlier plug-in for one thing 862 times in a boot and the repetitions pushed
 * the rest of the log out of the loader's window.
 */
static void
hm_refusal(id self, SEL sel, const char *how)
{
	static struct {
		Class cls;
		SEL sel;
		unsigned long times;
	} seen[64];
	static unsigned nseen;
	static unsigned long beyond;
	Class cls = object_getClass(self);
	unsigned long *times = NULL;
	char caller[256];

	for (unsigned i = 0; i < nseen; i++) {
		if (seen[i].cls == cls && seen[i].sel == sel) {
			times = &seen[i].times;
			break;
		}
	}
	if (times == NULL && nseen < sizeof(seen) / sizeof(seen[0])) {
		seen[nseen].cls = cls;
		seen[nseen].sel = sel;
		times = &seen[nseen].times;
		nseen++;
	}
	if (times == NULL) {
		times = &beyond;
	}
	if ((++*times & (*times - 1)) != 0) {
		return;
	}
	hm_caller(caller, sizeof(caller));
	hm_print("refused: -[%s %s] %s; asked by %s\n", class_getName(cls), sel_getName(sel), how, caller);
	if (*times > 1) {
		hm_print("  ... and that is the %lu'th time%s\n", *times,
			 times == &beyond ? ", counting every pair past the 64 this keeps apart" : "");
	}
}

/* --- the catch-all for selectors nobody here answers -------------------------------------------------------- */

/* the type encoding a protocol (or one it adopts) declares for SEL, or NULL */
static const char *
hm_protocol_types(Protocol *protocol, SEL sel, unsigned depth)
{
	struct objc_method_description d = protocol_getMethodDescription(protocol, sel, YES, YES);
	const char *types = d.types;
	unsigned n = 0;
	Protocol *__unsafe_unretained *adopted;

	if (types == NULL) {
		d = protocol_getMethodDescription(protocol, sel, NO, YES);
		types = d.types;
	}
	if (types != NULL || depth > 8) {
		return types;
	}
	adopted = protocol_copyProtocolList(protocol, &n);
	for (unsigned i = 0; i < n && types == NULL; i++) {
		types = hm_protocol_types(adopted[i], sel, depth + 1);
	}
	free(adopted);
	return types;
}

/*
 * The signature of a selector this class does not implement but one of its protocols declares. That is what makes a
 * refusal SAFE to return from: a method returning a struct is handed a hidden pointer to the caller's buffer, one
 * returning a float is read out of d0, and only the declared encoding says which -- a guessed signature would leave
 * the caller reading what happened to be there. <MTLDeviceSPI>'s 337 encodings are in Metal.framework's metadata, so
 * they are found here; a selector of a protocol that is not in this process at all (the AGX bundle's SPIs) has no
 * signature and goes to -doesNotRecognizeSelector: instead, which raises.
 */
static NSMethodSignature *
hm_protocol_signature(Class cls, SEL sel)
{
	for (Class c = cls; c != Nil; c = class_getSuperclass(c)) {
		unsigned n = 0;
		Protocol *__unsafe_unretained *protocols = class_copyProtocolList(c, &n);
		const char *types = NULL;

		for (unsigned i = 0; i < n && types == NULL; i++) {
			types = hm_protocol_types(protocols[i], sel, 0);
		}
		free(protocols);
		if (types != NULL) {
			return [NSMethodSignature signatureWithObjCTypes:types];
		}
	}
	return nil;
}

/* the refusal itself: the line, then zeros of the declared return width, which is what Metal's own nil-stubs return */
static void
hm_forward(id self, NSInvocation *invocation)
{
	NSMethodSignature *signature = [invocation methodSignature];
	NSUInteger length = [signature methodReturnLength];

	hm_refusal(self, [invocation selector], "is not implemented in this plug-in; it returns zeros");
	if (length > 0) {
		void *zero = calloc(1, length);

		if (zero != NULL) {
			[invocation setReturnValue:zero];
			free(zero);
		}
	}
}

/* The three methods every class of this file carries. -methodSignatureForSelector: asks super first so that a method
 * that exists is never forwarded; -doesNotRecognizeSelector: prints before super raises, so that the exception's
 * sentence -- which names the RECEIVER and reads exactly like a missing method -- has a line beside it that names the
 * sender. */
#define HM_REFUSES_OUT_LOUD								\
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel			\
{										\
	NSMethodSignature *s = [super methodSignatureForSelector:sel];		\
										\
	return s != nil ? s : hm_protocol_signature([self class], sel);		\
}										\
- (void)forwardInvocation:(NSInvocation *)invocation				\
{										\
	hm_forward(self, invocation);						\
}										\
- (void)doesNotRecognizeSelector:(SEL)sel					\
{										\
	hm_refusal(self, sel, "is declared by no protocol in this process and "	\
		   "implemented by nothing in its class chain; it raises");	\
	[super doesNotRecognizeSelector:sel];					\
}

/* a protocol declared on a class at runtime: the compiler put the protocol object into this image by the @protocol()
 * reference, so it exists in the process whether or not Metal's own metadata declares it (the public MTLCommandQueue,
 * for one, is declared only in the AGX bundle on this phone, which never loads here) */
static void
hm_adopt(Class cls, Protocol *protocol, const char *name)
{
	if (protocol == NULL) {
		hm_print("protocol %s is not in this process; %s cannot declare it\n", name, class_getName(cls));
		return;
	}
	if (!class_conformsToProtocol(cls, protocol) && !class_addProtocol(cls, protocol)) {
		hm_print("class_addProtocol(%s, %s) refused\n", class_getName(cls), name);
	}
}

/* an ivar of Apple's, by name, in the Metal this process runs: never an offset written down */
static Ivar
hm_ivar(const char *className, const char *ivarName)
{
	Class cls = objc_getClass(className);

	return cls != Nil ? class_getInstanceVariable(cls, ivarName) : NULL;
}

/* host time as Metal's CFTimeInterval reports it (seconds of mach_absolute_time) */
static double
hm_now(void)
{
	static mach_timebase_info_data_t timebase;

	if (timebase.denom == 0) {
		mach_timebase_info(&timebase);
	}
	return (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e9;
}

/* --- the private base classes, by name only ---------------------------------------------------------------- */

/* The designated initialisers are the ones Apple's own driver sends to super (IOGPUMetalCommandQueue,
 * IOGPUMetalCommandEncoder, AGXA11FamilyComputePipeline), read out of the cache by the earlier work; nothing of any
 * layout is declared. */
@interface _MTLDevice : NSObject
- (instancetype)init;
@end

@interface _MTLObjectWithLabel : NSObject
- (instancetype)init;
- (NSString *)label;   /* the base's own: ivar _label under _labelLock */
- (void)setLabel:(NSString *)label;
@end

@interface _MTLResource : _MTLObjectWithLabel
@end

@interface _MTLCommandQueue : _MTLObjectWithLabel
- (instancetype)initWithDevice:(id)device descriptor:(id)descriptor;
- (NSUInteger)maxCommandBufferCount;
@end

@interface _MTLCommandBuffer : _MTLObjectWithLabel
- (instancetype)initWithQueue:(id)queue retainedReferences:(BOOL)retained synchronousDebugMode:(BOOL)synchronous;
@end

@interface _MTLCommandEncoder : _MTLObjectWithLabel
- (instancetype)initWithCommandBuffer:(id)commandBuffer;
- (void)endEncoding;
@end

@interface _MTLComputePipelineState : NSObject
- (instancetype)initWithDevice:(id)device pipelineStateDescriptor:(id)descriptor;
@end

/* The render pipeline state's base (what AGXA11FamilyRenderPipeline sends to super). It answers <MTLRenderPipelineState>
 * itself: -label and -device are ivars its initialiser fills, -gpuResourceID is -gpuHandle is the resourceIndex ivar,
 * and allocatedSize, imageblockSampleLength, imageblockMemoryLengthForDimensions:, maxTotalThreadsPerThreadgroup and
 * uniqueIdentifier are nil-stubs (tools/metal/absmeth.py over the class: 65 selectors, 5 nil-stubs, 21 ivars). The
 * initialiser asserts a non-nil _MTLDevice and a non-nil MTLRenderPipelineDescriptor (see the header) and reads six
 * properties none of which is a function or an attachment, so what is handed to it has been checked here first. */
@interface _MTLRenderPipelineState : NSObject
- (instancetype)initWithDevice:(id)device pipelineStateDescriptor:(id)descriptor;
@end

/* The sampler HAS a base class (ivars _device, _label, _pixelFormat, _resourceIndex, _gpuAddress; it answers its whole
 * protocol itself), and its designated initialiser -- what AGXA11FamilySampler sends to super -- VALIDATES: it opens Metal's
 * "New Sampler State Validation" context and records "device must not be nil.", "desc must not be nil.", "desc is not a
 * MTLSamplerDescriptor.", "filter is not a valid MTLSamplerMinMagFilter." (minFilter, magFilter, mipFilter each < 3),
 * "addressMode is not a valid MTLSamplerAddressMode." (s, t, r each < 7), the border colour (< 4) and the compare function;
 * the context's end is _MTLReportFailure, which aborts the process (the frame the earlier plug-in read as
 * _MTLReportFailure.cold.1 above abort). So every one of those is checked HERE before super is given the descriptor. */
@interface _MTLSamplerState : NSObject
- (instancetype)initWithDevice:(id)device samplerDescriptor:(id)descriptor;
@end

/*
 * The one struct Metal reads out of a device by raw pointer. Name and field types are Apple's own, from the type
 * encoding MTLDeviceSPI records for -targetDeviceInfo (r^{MTLTargetDeviceArch=QI*}16@0:8); which field means what was
 * read off its readers: +0x08 pairs with 1 into a pipeline cache version, +0x10 is formatted into
 * "<pipelinelib>/pipelines.%s" and must be a C string, +0x00 is read by nothing on that path.
 */
struct MTLTargetDeviceArch {
	uint64_t target;
	uint32_t version;
	char *name;
};

_Static_assert(sizeof(struct MTLTargetDeviceArch) == 24 && __builtin_offsetof(struct MTLTargetDeviceArch, version) == 8 &&
	       __builtin_offsetof(struct MTLTargetDeviceArch, name) == 16, "Metal reads the name at +0x10 and the version at +0x8");

/* Metal's buffer table has 31 entries per stage (profile 0's maxVertexBuffers); the compute encoder's is the same size */
#define HM_MAX_BUFFERS 31
/* The texture and sampler tables: 128 and 16 are what Apple's AIR modules declare for this phone (air.max_textures 128,
 * air.max_samplers 16 in every .metallib of the image) and what profile 0 gives samplers (16). hakios-metal serves the
 * first 16 texture indices (kernel.hpp: kMaxTextureSlots) and refuses a kernel declaring one beyond that by name at
 * dispatch; the encoder keeps Metal's full table so that a binding past 16 is stored, not dropped, and the dispatch says why. */
#define HM_MAX_TEXTURES 128
#define HM_MAX_SAMPLERS 16

/* --- the classes ------------------------------------------------------------------------------------------- */

@class HakiosMetalCommandQueue;
@class HakiosMetalCommandBuffer;

/* _MTLDevice answers this one itself (it sends the source to MTLCompilerService); the SDK's headers do not say so */
@interface _MTLDevice (HakiosMetalSource)
- (id)newLibraryWithSource:(NSString *)source options:(MTLCompileOptions *)options error:(NSError **)error;
@end

/* and this one (MTLPipelineLibraryBuilder::newLibraryWithFile), reading the .pipelinelib directory */
@interface _MTLDevice (HakiosMetalPipelineLibrary)
- (id)newPipelineLibraryWithFilePath:(NSString *)path error:(NSError **)error;
@end

/* and these (0x181a43838, 0x181aa8f4c): an _MTLFunctionInternal named "#main" over the GLES IR, its function data
 * marking it GL's; nothing is compiled */
@interface _MTLDevice (HakiosMetalGLES)
- (id)newFunctionWithGLESIR:(const void *)ir inputsDescription:(dispatch_data_t)inputs functionType:(NSUInteger)type;
- (id)newFunctionWithGLESIR:(const void *)ir functionType:(NSUInteger)type;
@end

@interface HakiosMetalDevice : _MTLDevice {
	io_service_t _acceleratorService;        /* the IOAcceleratorES service Metal handed us */
	hakios_metal_device *_gpu;               /* hakios-metal's device: the kernel's HakiosGPU client */
	struct MTLTargetDeviceArch _target;      /* answered by pointer: see -targetDeviceInfo */
	char _targetName[96];                    /* the bytes _target.name points at, inside the object */
	NSString *_name;
}
- (hakios_metal_device *)hakiosDevice;
@end

/*
 * Which command buffers a resource is in: -[IOGPUMetalResource isComplete] (iOS 16.5, 0x1ec17f860) answers whether the GPU
 * has finished every submission that used the resource -- the resource's last-use stamp against the completed one, no
 * wait -- and -waitUntilComplete waits for it. AppleMetalGLRenderer asks a buffer that before GL writes into it
 * (gldTestMemoryPlugin: glBufferSubData, glMapBufferRange), and the plug-in had no such method on its buffers: the first
 * GL application to update a buffer while playing a video died of it (bili-inter, v26). Here each command buffer is a
 * sequence number (made when it is, committed, completed), each draw, dispatch and blit marks the resources it binds with
 * its command buffer's number (the last HM_USES of them are kept), and a resource is complete when none of those is
 * committed and not yet done. A command buffer still being recorded does not count, as Apple's does not (its work is not
 * submitted; GL commits its own before it waits), so -waitUntilComplete cannot wait for a buffer nobody will commit.
 */
#define HM_USE_SLOTS 4096u
#define HM_USES 4u
enum { HM_USE_RECORDING = 1, HM_USE_COMMITTED = 2, HM_USE_DONE = 3 };
static struct { uint64_t seq; unsigned state; } hm_use[HM_USE_SLOTS];   /* by sequence number; a slot reused is long done */
static uint64_t hm_use_next = 1;
static pthread_mutex_t hm_use_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t hm_use_cond = PTHREAD_COND_INITIALIZER;

static uint64_t
hm_use_begin(void)
{
	uint64_t seq;

	pthread_mutex_lock(&hm_use_lock);
	seq = hm_use_next++;
	hm_use[seq % HM_USE_SLOTS].seq = seq;
	hm_use[seq % HM_USE_SLOTS].state = HM_USE_RECORDING;
	pthread_mutex_unlock(&hm_use_lock);
	return seq;
}

static void
hm_use_set(uint64_t seq, unsigned state)
{
	pthread_mutex_lock(&hm_use_lock);
	if (seq != 0 && hm_use[seq % HM_USE_SLOTS].seq == seq) {
		hm_use[seq % HM_USE_SLOTS].state = state;
	}
	if (state == HM_USE_DONE) {
		pthread_cond_broadcast(&hm_use_cond);
	}
	pthread_mutex_unlock(&hm_use_lock);
}

/* (under hm_use_lock) one of USES committed and not completed */
static BOOL
hm_use_in_flight(const uint64_t *uses)
{
	for (unsigned i = 0; i < HM_USES; i++) {
		const uint64_t seq = __atomic_load_n(&uses[i], __ATOMIC_RELAXED);

		if (seq != 0 && hm_use[seq % HM_USE_SLOTS].seq == seq && hm_use[seq % HM_USE_SLOTS].state == HM_USE_COMMITTED) {
			return YES;
		}
	}
	return NO;
}

/* a resource's record of SEQ (the encoding thread; a lost race costs an older entry, never a wrong one) */
static void
hm_use_mark(uint64_t *uses, unsigned *at, uint64_t seq)
{
	if (seq == 0) {
		return;
	}
	for (unsigned i = 0; i < HM_USES; i++) {
		if (__atomic_load_n(&uses[i], __ATOMIC_RELAXED) == seq) {
			return;
		}
	}
	__atomic_store_n(&uses[__atomic_fetch_add(at, 1, __ATOMIC_RELAXED) % HM_USES], seq, __ATOMIC_RELAXED);
}

static BOOL
hm_use_complete(const uint64_t *uses)
{
	BOOL busy;

	pthread_mutex_lock(&hm_use_lock);
	busy = hm_use_in_flight(uses);
	pthread_mutex_unlock(&hm_use_lock);
	return !busy;
}

/* (at most two seconds: a wait asked from inside a completion handler of the same queue would otherwise wait for a
 * completion that only comes after the handler returns; said once if it ever runs out) */
static void
hm_use_wait(const uint64_t *uses)
{
    hakios_metal_drain_all(HAKIOS_METAL_DRAIN_CPU_SYNC);
	struct timespec deadline;
	BOOL late = NO;

	clock_gettime(CLOCK_REALTIME, &deadline);
	deadline.tv_sec += 2;
	pthread_mutex_lock(&hm_use_lock);
	while (hm_use_in_flight(uses) && !late) {
		late = pthread_cond_timedwait(&hm_use_cond, &hm_use_lock, &deadline) != 0 && hm_use_in_flight(uses);
	}
	pthread_mutex_unlock(&hm_use_lock);
	if (late) {
		HM_ONCE("-waitUntilComplete gave up after 2 s with the resource's command buffer still in flight (a wait from its own "
			"queue's completion?)\n");
	}
}

/*
 * A read after a write, across command buffers, through a shadow copy (v29u: the App Library's background black).
 *
 * A surface whose rows the GPU cannot take where they lie (a pitch that is not a multiple of 64 bytes) is drawn through
 * copies of its rows, and every pass that draws into it is given a copy of its own -- CoreAnimation draws the App
 * Library's snapshot through several, each a copy of its own. A copy's GPU writes reach the surface when that copy's
 * command buffer completes (-hakiosWriteBackShadow), so a pass in a later command buffer that *samples* the surface
 * through yet another copy takes the surface as it was before those writes landed: the previous snapshot, or nothing at
 * all the first time (the surface is new and zero). Zero-copy scanout raised the frame rate and the write-back kept its
 * cost, and the gap between them became one the user sees: the background goes black for a frame or two.
 *
 * So what is queued here is a count, per surface, of the copies whose GPU writes have not yet been written back. A
 * command buffer that samples such a surface waits for them (bounded) before it is submitted, and takes its copies from
 * the surface again. The table is fixed and the count is a hint: a full table loses an entry, which costs a wait, never
 * a wrong picture, and a wait that runs out is counted and leaves the sample as it was before.
 */
#define HM_SHADOW_SURFACES 16u
static struct { IOSurfaceID id; unsigned pending; } hm_shadowSurface[HM_SHADOW_SURFACES];
static pthread_mutex_t hm_shadowSurfaceLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t hm_shadowSurfaceCond = PTHREAD_COND_INITIALIZER;

/* (an entry is found by surface id alone: an id is not reused while a write into that surface is still queued, which is
 * the only time an entry is looked at, and the texture that queued it holds the surface until then) */
static unsigned
hm_shadow_surface_slot(IOSurfaceID id)
{
	unsigned free_ = HM_SHADOW_SURFACES;

	for (unsigned i = 0; i < HM_SHADOW_SURFACES; i++) {
		if (hm_shadowSurface[i].pending != 0) {
			if (hm_shadowSurface[i].id == id) {
				return i;
			}
		} else if (free_ == HM_SHADOW_SURFACES) {
			free_ = i;
		}
	}
	return free_ != HM_SHADOW_SURFACES ? free_ : 0;   /* (full: the first, whose count is lost) */
}

static void
hm_shadow_surface_add(IOSurfaceID id)
{
	unsigned i;

	pthread_mutex_lock(&hm_shadowSurfaceLock);
	i = hm_shadow_surface_slot(id);
	if (hm_shadowSurface[i].pending == 0 || hm_shadowSurface[i].id != id) {
		hm_shadowSurface[i].id = id;
		hm_shadowSurface[i].pending = 0;
	}
	hm_shadowSurface[i].pending++;
	pthread_mutex_unlock(&hm_shadowSurfaceLock);
}

/* a queued write has reached the surface (written back), or the command buffer that owed it went away */
static void
hm_shadow_surface_done(IOSurfaceID id)
{
	unsigned i;

	pthread_mutex_lock(&hm_shadowSurfaceLock);
	i = hm_shadow_surface_slot(id);
	if (hm_shadowSurface[i].pending != 0 && hm_shadowSurface[i].id == id) {
		if (--hm_shadowSurface[i].pending == 0) {
			pthread_cond_broadcast(&hm_shadowSurfaceCond);
		}
	}
	pthread_mutex_unlock(&hm_shadowSurfaceLock);
}

static unsigned
hm_shadow_surface_pending(IOSurfaceID id)
{
	unsigned i, pending = 0;

	pthread_mutex_lock(&hm_shadowSurfaceLock);
	i = hm_shadow_surface_slot(id);
	if (hm_shadowSurface[i].pending != 0 && hm_shadowSurface[i].id == id) {
		pending = hm_shadowSurface[i].pending;
	}
	pthread_mutex_unlock(&hm_shadowSurfaceLock);
	return pending;
}

/* Wait until at most OWN of the surface's queued writes are still out; OWN is what this command buffer queues itself,
 * whose completion it cannot wait for (it is not submitted yet). Returns NO when the wait ran out. */
static BOOL
hm_shadow_surface_wait(IOSurfaceID id, unsigned own, double seconds)
{
	struct timespec deadline;
	BOOL drained = YES;

	clock_gettime(CLOCK_REALTIME, &deadline);
	deadline.tv_sec += (time_t)seconds;
	deadline.tv_nsec += (long)((seconds - (double)(time_t)seconds) * 1e9);
	if (deadline.tv_nsec >= 1000000000L) {
		deadline.tv_sec++;
		deadline.tv_nsec -= 1000000000L;
	}
	pthread_mutex_lock(&hm_shadowSurfaceLock);
	{
		const unsigned i = hm_shadow_surface_slot(id);

		while (hm_shadowSurface[i].id == id && hm_shadowSurface[i].pending > own && drained) {
			/* (late only when the deadline passed with writes still out: a wakeup for another surface's, or a spurious
			 * one, is not a wait that ran out) */
			if (pthread_cond_timedwait(&hm_shadowSurfaceCond, &hm_shadowSurfaceLock, &deadline) != 0 &&
			    hm_shadowSurface[i].id == id && hm_shadowSurface[i].pending > own) {
				drained = NO;
			}
		}
	}
	pthread_mutex_unlock(&hm_shadowSurfaceLock);
	return drained;
}

@interface HakiosMetalBuffer : _MTLResource {
	HakiosMetalDevice *_device;
	hakios_metal_buffer *_buffer;
	uint64_t _uses[HM_USES];   /* the command buffers that last bound it (-isComplete) */
	unsigned _usesAt;
	/* a no-copy buffer's own pages and the block Metal promises to call when the buffer goes (see
	 * -newBufferWithBytesNoCopy:...) */
	void (^_deallocator)(void *, NSUInteger);
	void *_callerBytes;
	NSUInteger _callerLength;
}
- (instancetype)initWithHakiosDevice:(HakiosMetalDevice *)device length:(NSUInteger)length;
- (void)hakiosSetDeallocator:(void (^)(void *, NSUInteger))deallocator bytes:(void *)bytes length:(NSUInteger)length;
- (hakios_metal_buffer *)hakiosBuffer;
- (void *)contents;
- (void)hakiosUsedBy:(uint64_t)seq;
@end

/*
 * A texture: hakios-metal's, one 2D level in GPU memory of its own, laid out as the GPU reads it (linear rows of
 * -bufferBytesPerRow bytes). Metal has no _MTLTexture base class to inherit from -- Apple's chain is AGXTexture :
 * IOGPUMetalTexture : IOGPUMetalResource : _MTLResource, and IOGPU never loads here -- so the class subclasses _MTLResource
 * directly and declares <MTLTexture>, <MTLTextureSPI>, <MTLTextureImplementation> and <MTLResourceSPI> at +load, the road
 * the other classes take. Metal reads no ivar of a texture: every fact about one is asked by selector, which is why every
 * member of those protocols that has a value here answers it below and none is left to the catch-all's zeros -- a width of
 * zero, pixel format 0 (Invalid), a swizzle of four zeros (every channel reads 0) and NO to isComplete would each be
 * wrong without a word.
 */
@interface HakiosMetalTexture : _MTLResource {
	HakiosMetalDevice *_device;
	hakios_metal_texture *_texture;
	uint64_t _uses[HM_USES];            /* the command buffers that last bound it (-isComplete) */
	unsigned _usesAt;
	MTLTextureUsage _usage;             /* what hakios-metal was given: ShaderRead, ShaderWrite, or both */
	MTLResourceOptions _askedOptions;   /* the descriptor's, for -unfilteredResourceOptions; what was GIVEN is shared memory */
	BOOL _allowGPUOptimizedContents;    /* the descriptor's word; the layout is linear either way */
	uint64_t _uniqueIdentifier;         /* from a counter, never 0 and never the object's address: see hm_next_resource_id */
	IOSurfaceRef _iosurface;            /* the surface whose pixels the texture's rows are (retained), NULL for one of its own */
	NSUInteger _iosurfacePlane;
	BOOL _shadow;                       /* the rows are a copy of _iosurface's, refreshed when its seed moves (see below) */
	uint32_t _shadowSeed;
	uint8_t *_shadowBase;               /* ... and, for a copy something writes, the surface's rows as the copy last took them */
	hakios_metal_texture *_turnedSurface; /* a framebuffer with a rotation: the surface itself, upright, that _texture is turned into */
	unsigned _turn;                     /* ... by this a6xx_rotation (the 2D engine's, probe "2D rotation") */
	HakiosMetalTexture *_parent;        /* a view: _texture is the parent's and is freed with it, not with the view... */
	BOOL _ownsView;                     /* ...unless the view names a level or slices of it: then _texture is the core's
	                                     * own view of the parent's memory (Texture::view), and is the view's to free */
	NSUInteger _parentLevel, _parentSlice;
	BOOL _swizzled;                     /* a swizzled view: _texture is the core's, read through _swizzle */
	MTLTextureSwizzleChannels _swizzle;
	void (^_deallocator)(void *, NSUInteger);   /* a no-copy texture's: its caller's bytes are given back at dealloc */
	int _ycbcr;                         /* a two-plane surface read as RGBA8 converted from it: 0 not, else its matrix (HM_YCC_*) */
	BOOL _ycbcrFull;                    /* ... '420f' (full range) rather than '420v' (video range) */
	MTLPixelFormat _ycbcrFormat;        /* ... and the private format it was asked as (500, 540), which it answers */
	BOOL _ycbcrDeclared;                /* ... the matrix the surface declares (else BT.601, looked for again at each copy) */
	BOOL _ycbcrTold;                    /* ... its first frame said (the census of YCbCr surfaces) */
	uint8_t *_ycbcrRows;                /* reused RGBA8 conversion destination, avoiding a 5 MB malloc/free per frame */
	size_t _ycbcrRowsBytes;
	hakios_metal_queue *_ycbcrGPUQueue; /* the conversion pass is synchronous before CA samples the shadow */
	hakios_metal_kernel *_ycbcrGPUKernel;
	hakios_metal_buffer *_ycbcrGPUParams;
	BOOL _ycbcrGPUReported;
	hakios_metal_texture *_ycbcrGPULuma, *_ycbcrGPUChroma;
	NSLock *_shadowLock;                /* a texture can be bound by CA's worker threads at the same time */
	unsigned _shadowWrites;             /* flicker-diag: GPU writes into the copy not yet written back */
	void *_deallocBytes;
	NSUInteger _deallocLength;
}
- (instancetype)initWithHakiosDevice:(HakiosMetalDevice *)device texture:(hakios_metal_texture *)texture
			  descriptor:(MTLTextureDescriptor *)descriptor usage:(MTLTextureUsage)usage;
- (hakios_metal_texture *)hakiosTexture;
- (void)hakiosSetIOSurface:(IOSurfaceRef)surface plane:(NSUInteger)plane;
- (void)hakiosShadow:(IOSurfaceRef)surface;
- (void)hakiosShadow:(IOSurfaceRef)surface plane:(NSUInteger)plane;
- (BOOL)hakiosIsShadow;
- (BOOL)hakiosIsTurned;
- (void)hakiosTurnInto:(hakios_metal_cb *)cb;
- (void)hakiosSetTurned:(hakios_metal_texture *)surface rotation:(unsigned)rotation;
- (void)hakiosWriteBackShadow;
- (void)hakiosShadowWriteQueued;     /* flicker-diag: a command buffer writing the copy, written back at its completion */
- (void)hakiosShadowWriteDropped;    /* that command buffer went away uncompleted: nothing to write back */
static void hm_fps_shadow(BOOL in, double seconds);   /* metal_fps's count of the copies below */
static void hm_fps_shadow_kept(BOOL torn);            /* ... and of the refreshes that took no copy */
static void hm_fps_shadow_sample(unsigned pending, unsigned waited, unsigned timeouts);
static void hm_fps_encoded(double seconds, BOOL held);   /* metal_fps: a buffer's making to its commit */
static BOOL hm_timeline_on(void);   /* metal_fps=timeline */
static void hm_fps_texture_waited(double seconds);
static void hm_fps_shadow_blit(BOOL write);
static void hm_fps_waited(double seconds);   /* metal_fps: time in -waitUntilCompleted */
static void hm_fps_drew(double seconds, unsigned cpu);   /* metal_fps: our time in a draw call */
static void hm_fps_core(double seconds);   /* metal_fps: the core's time in a draw call */
static BOOL hm_fps_on(void);                          /* metal_fps: command buffers timed pass by pass */
#define HM_CACHE_DIR  "/private/var/db/hakios-metal-cache"     /* compiled stages, kept across boots by var_store */
#define HM_CACHE_SEED "/redwood/share/hakios-metal-cache"     /* the same, baked into the image (read-only) */
static BOOL hm_gmem_on(void);                         /* metal_gmem=1: tiled rendering where a pass allows it */
static BOOL hm_pass_wfi(void);                        /* metal_pass_wfi=1: every pass its own full tail and batch start */
- (void)hakiosShadowYCbCr:(IOSurfaceRef)surface format:(MTLPixelFormat)format;
- (BOOL)hakiosConvertYCbCrGPU:(const hm_ycc_planes *)planes width:(size_t)w height:(size_t)h;
- (void)hakiosRefreshShadow;
- (void)hakiosSetDeallocator:(void (^)(void *, NSUInteger))deallocator bytes:(void *)bytes length:(NSUInteger)length;
- (unsigned)hakiosStorageKind;   /* metal_fps=timeline: 0 a surface's, else 1 + its storage mode */
- (void)hakiosUsedBy:(uint64_t)seq;
@end

#include "HakiosMetalBootArgs.h"

static BOOL hm_ca_arg(const char *arg) {
    char args[1024] = {0}; size_t size = sizeof(args)-1;
    return sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && hm_boot_arg_token(args, arg);
}
static BOOL hm_ca_sync(void) {
    static int on = -1;
    if (on < 0) {
        on = hm_ca_arg("metal_sync=1");
    }
    return on != 0;
}
/* boot-arg metal_big=1: mark the CA Metal caller interactive.
 * The morning trace shows CPU0-3 taking 16-31 us per draw and CPU4-6 77-110 us. This is an A/B hint only:
 * the default leaves Apple's QoS untouched. BCM2837 uses Clutch, not Apple's AMP scheduler;
 * QoS does not guarantee placement on a fast core. */
static void hm_big_hint(void) {
    static int done = -1;
    if (done < 0) done = hm_ca_arg("metal_big=1");
    if (done == 1) {
        int error = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        HM_ONCE("metal_big=1: CA Metal caller QoS set to user-interactive (error %d)\n", error);
    }
}

/* A sampler state: hakios-metal's four TEX_SAMP words, computed once from the descriptor, under Metal's own base class
 * (which keeps the device, the label and the pixel format and answers <MTLSamplerState> itself). The ivar names are
 * prefixed so that none can shadow the base's own _device/_label/_pixelFormat/_resourceIndex/_gpuAddress. */
/* A depth/stencil state: the descriptor's depth half as hakios-metal takes it (the compare function and the write), read
 * by this plug-in's render encoder alone. A plain object adopting <MTLDepthStencilState>: nothing in Metal's own code
 * looks inside one on this road (the encoder that binds it is ours), and _MTLDepthStencilState's initialiser is not one
 * this plug-in knows the contract of. */
/* A fence: a name for an ordering this device already keeps. Every encoder of a command buffer runs in the order it
 * was encoded and every command buffer of the queue in commit order, each dispatch and pass flushing what it wrote
 * before the next begins. Fence entry points also make the owning CB a submission boundary.
 * What Metal requires of the object is a device and a label. */
@interface HakiosMetalFence : NSObject <MTLFence> {
	id<MTLDevice> _device;
	NSString *_label;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device;
@end

@implementation HakiosMetalFence
- (instancetype)initWithDevice:(id<MTLDevice>)device
{
	self = [super init];
	if (self != nil) {
		_device = [device retain];
	}
	return self;
}
- (void)dealloc
{
	[_label release];
	[_device release];
	[super dealloc];
}
- (id<MTLDevice>)device { return _device; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label
{
	[label retain];
	[_label release];
	_label = label;
}
@end

/* MTLEvent and MTLSharedEvent: a 64-bit value that command buffers signal when they complete and wait for before they
 * run, and that the processor may read, set and listen to (a shared event). The GPU never touches it: this plug-in's
 * queue runs command buffers one after another, so a signal is applied when its buffer completes and a buffer that
 * waits is committed to the GPU once the value has come (HakiosMetalCommandBuffer). Values only rise, as Metal's do. One
 * class for both: an MTLEvent is a shared event no one shares. A handle for another process is not served. */
@interface HakiosMetalEvent : NSObject <MTLSharedEvent> {
	id<MTLDevice> _device;
	NSString *_label;
	uint64_t _value;                     /* under _lock */
	NSCondition *_lock;
	NSMutableArray *_listeners;          /* { value, listener, block }, under _lock */
}
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (void)hakiosSignal:(uint64_t)value;
- (BOOL)hakiosReached:(uint64_t)value;
- (void)hakiosWaitFor:(uint64_t)value;
@end

@implementation HakiosMetalEvent
- (instancetype)initWithDevice:(id<MTLDevice>)device
{
	self = [super init];
	if (self != nil) {
		_device = [device retain];
		_lock = [[NSCondition alloc] init];
		_listeners = [[NSMutableArray alloc] init];
	}
	return self;
}
- (void)dealloc
{
	[_listeners release];
	[_lock release];
	[_label release];
	[_device release];
	[super dealloc];
}
- (id<MTLDevice>)device { return _device; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label
{
	[label retain];
	[_label release];
	_label = label;
}
- (uint64_t)signaledValue
{
	uint64_t v;

	[_lock lock];
	v = _value;
	[_lock unlock];
	return v;
}
- (void)setSignaledValue:(uint64_t)value { [self hakiosSignal:value]; }

/* the value set (a completing command buffer's signal, or the processor's), the waiters woken, and every listener whose
 * value it reaches called on its own dispatch queue, once */
- (void)hakiosSignal:(uint64_t)value
{
	NSMutableArray *due = [NSMutableArray array];

	[_lock lock];
	_value = value;
	for (NSArray *l in [[_listeners copy] autorelease]) {
		if ([[l objectAtIndex:0] unsignedLongLongValue] <= value) {
			[due addObject:l];
			[_listeners removeObject:l];
		}
	}
	[_lock broadcast];
	[_lock unlock];
	for (NSArray *l in due) {
		MTLSharedEventListener *listener = [l objectAtIndex:1];
		MTLSharedEventNotificationBlock block = [l objectAtIndex:2];
		dispatch_queue_t q = [listener respondsToSelector:@selector(dispatchQueue)] ? [listener dispatchQueue] : nil;

		[self retain];
		dispatch_async(q != nil ? q : dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
			block((id<MTLSharedEvent>)self, value);
			[self release];
		});
	}
}
- (BOOL)hakiosReached:(uint64_t)value
{
	return [self signaledValue] >= value;
}
- (void)hakiosWaitFor:(uint64_t)value
{
    hakios_metal_drain_all(HAKIOS_METAL_DRAIN_CPU_SYNC);
	[_lock lock];
	while (_value < value) {
		[_lock wait];
	}
	[_lock unlock];
}
- (void)notifyListener:(MTLSharedEventListener *)listener atValue:(uint64_t)value block:(MTLSharedEventNotificationBlock)block
{
	BOOL now;

	if (block == nil) {
		return;
	}
	[_lock lock];
	now = _value >= value;
	if (!now) {
		[_listeners addObject:@[ @(value), listener != nil ? (id)listener : (id)[NSNull null], [[block copy] autorelease] ]];
	}
	[_lock unlock];
	if (now) {
		dispatch_queue_t q = [listener respondsToSelector:@selector(dispatchQueue)] ? [listener dispatchQueue] : nil;
		const uint64_t v = [self signaledValue];

		[self retain];
		dispatch_async(q != nil ? q : dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
			block((id<MTLSharedEvent>)self, v);
			[self release];
		});
	}
}
- (BOOL)waitUntilSignaledValue:(uint64_t)value timeoutMS:(uint64_t)milliseconds
{
	NSDate *until = [NSDate dateWithTimeIntervalSinceNow:(double)milliseconds / 1000.0];
	BOOL reached;

	[_lock lock];
	while (_value < value && [_lock waitUntilDate:until]) {
	}
	reached = _value >= value;
	[_lock unlock];
	return reached;
}
- (id)newSharedEventHandle
{
	hm_refusal(self, _cmd, "has no handle another process could open (the value lives in this process alone); it returns nil");
	return nil;
}
@end

/* A texture layout (-newTextureLayoutWithDescriptor:isHeapOrBufferBacked:): how this device wants a texture's bytes in
 * memory a client fills ahead of the texture. ImageIO's ASTCTwiddler asks for one to stage an asset catalogue's ASTC
 * image ("twiddled" into the GPU's order on an Apple GPU), and the bytes reach Metal again through
 * -newTextureWithBytesNoCopy:length:descriptor:deallocator:. Here the order is the plainest: the levels one after
 * another, each in rows of whole blocks (or pixels) packed tight -- and the no-copy texture reads exactly that, so the two
 * agree by construction. -watermark names the layout, so that bytes staged for another one are not taken for these. */
@interface HakiosMetalTextureLayout : NSObject {
	unsigned _blockW, _blockH, _bytes;   /* hakios_metal_format_block's */
	NSUInteger _width, _height, _levels;
}
- (instancetype)initWithDescriptor:(MTLTextureDescriptor *)descriptor blockW:(unsigned)bw blockH:(unsigned)bh bytes:(unsigned)bytes;
@end

/* the tight layout's numbers for one level: its rows of blocks, a row's bytes, and where the level starts */
static void
hm_tight_level(NSUInteger width, NSUInteger height, NSUInteger levels, unsigned bw, unsigned bh, unsigned bytes, NSUInteger level,
	       NSUInteger *offset, NSUInteger *rowBytes, NSUInteger *rows)
{
	NSUInteger at = 0;

	for (NSUInteger l = 0; l < levels; l++) {
		const NSUInteger w = MAX(width >> l, (NSUInteger)1), h = MAX(height >> l, (NSUInteger)1);
		const NSUInteger row = (w + bw - 1) / bw * bytes, down = (h + bh - 1) / bh;

		if (l == level) {
			*offset = at;
			*rowBytes = row;
			*rows = down;
			return;
		}
		at += row * down;
	}
	*offset = at;   /* (LEVEL past the last: where the next would start, the whole size) */
	*rowBytes = 0;
	*rows = 0;
}

@implementation HakiosMetalTextureLayout
- (instancetype)initWithDescriptor:(MTLTextureDescriptor *)descriptor blockW:(unsigned)bw blockH:(unsigned)bh bytes:(unsigned)bytes
{
	self = [super init];
	if (self != nil) {
		_blockW = bw;
		_blockH = bh;
		_bytes = bytes;
		_width = [descriptor width];
		_height = [descriptor height];
		_levels = MAX([descriptor mipmapLevelCount], (NSUInteger)1);
	}
	return self;
}

- (NSUInteger)size
{
	NSUInteger offset, row, rows;

	hm_tight_level(_width, _height, _levels, _blockW, _blockH, _bytes, _levels, &offset, &row, &rows);
	return offset;
}

- (NSUInteger)alignment { return 64; }
- (void)initializeTextureMemory:(void *)memory { (void)memory; }   /* nothing to set up: the bytes are rows, nothing else */
- (void)finalizeTextureMemory:(void *)memory { (void)memory; }

/* "hakios-tight-v1\0": this layout's name for staged bytes to be checked against (16 bytes, ImageIO keeps them) */
struct hm_watermark { uint64_t a, b; };
- (struct hm_watermark)watermark
{
	struct hm_watermark w;

	memcpy(&w, "hakios-tight-v1", 16);
	return w;
}

/* REGION of LEVEL (slice 0, depth 1) between the caller's rows and the tight layout's, in whole blocks either way */
static BOOL
hm_layout_rows(HakiosMetalTextureLayout *l, unsigned bw, unsigned bh, unsigned bytes, NSUInteger width, NSUInteger height, NSUInteger levels,
	       NSUInteger slice, NSUInteger level, MTLRegion r, NSUInteger *at, NSUInteger *rowBytes, NSUInteger *rows, NSUInteger *pitch)
{
	NSUInteger offset, row, down;

	(void)l;
	if (slice != 0 || level >= levels || r.origin.z != 0 || r.size.depth != 1 || r.origin.x % bw != 0 || r.origin.y % bh != 0) {
		hm_print("refused: a texture layout's copy of %lux%lu at (%lu, %lu) of level %lu, slice %lu: one slice, depth 1, whole blocks\n",
			 (unsigned long)r.size.width, (unsigned long)r.size.height, (unsigned long)r.origin.x, (unsigned long)r.origin.y,
			 (unsigned long)level, (unsigned long)slice);
		return NO;
	}
	hm_tight_level(width, height, levels, bw, bh, bytes, level, &offset, &row, &down);
	*at = offset + r.origin.y / bh * row + r.origin.x / bw * bytes;
	*rowBytes = (r.size.width + bw - 1) / bw * bytes;
	*rows = (r.size.height + bh - 1) / bh;
	*pitch = row;
	return YES;
}

- (void)copyFromLinearBytes:(const void *)linear linearOffset:(NSUInteger)linearOffset linearBytesPerRow:(NSUInteger)linearBytesPerRow
	linearBytesPerImage:(NSUInteger)linearBytesPerImage toTextureMemory:(void *)memory textureSlice:(NSUInteger)slice
	       textureLevel:(NSUInteger)level textureRegion:(MTLRegion)region
{
	NSUInteger at, rowBytes, rows, pitch;

	(void)linearBytesPerImage;
	if (!hm_layout_rows(self, _blockW, _blockH, _bytes, _width, _height, _levels, slice, level, region, &at, &rowBytes, &rows, &pitch)) return;
	for (NSUInteger r = 0; r < rows; r++) {
		memcpy((uint8_t *)memory + at + r * pitch, (const uint8_t *)linear + linearOffset + r * linearBytesPerRow, rowBytes);
	}
}

- (void)copyFromTextureMemory:(const void *)memory textureSlice:(NSUInteger)slice textureLevel:(NSUInteger)level
		textureRegion:(MTLRegion)region toLinearBytes:(void *)linear linearOffset:(NSUInteger)linearOffset
	    linearBytesPerRow:(NSUInteger)linearBytesPerRow linearBytesPerImage:(NSUInteger)linearBytesPerImage
{
	NSUInteger at, rowBytes, rows, pitch;

	(void)linearBytesPerImage;
	if (!hm_layout_rows(self, _blockW, _blockH, _bytes, _width, _height, _levels, slice, level, region, &at, &rowBytes, &rows, &pitch)) return;
	for (NSUInteger r = 0; r < rows; r++) {
		memcpy((uint8_t *)linear + linearOffset + r * linearBytesPerRow, (const uint8_t *)memory + at + r * pitch, rowBytes);
	}
}
@end

/* A heap (MTLHeapTypeAutomatic): a budget of SIZE bytes that resources are made from. Every buffer and texture here is a
 * kernel allocation of its own, so one made from the heap is the device's own, counted against the budget (and not given
 * back when it goes: the budget only grows, so a heap refuses early rather than late);
 * what a heap adds on an Apple GPU -- resources aliasing one another's memory after -makeAliasable -- is the one part a
 * resource here cannot do (its -makeAliasable says so). A placement heap is refused where it is asked for. */
@interface HakiosMetalHeap : NSObject <MTLHeap> {
	id<MTLDevice> _device;
	NSString *_label;
	MTLHeapDescriptor *_descriptor;
	NSUInteger _used;
}
- (instancetype)initWithDevice:(id)device descriptor:(MTLHeapDescriptor *)descriptor;
@end

/* An argument encoder (MTLArgumentEncoder) over the layout the AIR front end reads back (nir_air.h, air_argbuf): eight
 * bytes a member, an array member eight bytes an element, the members in order of their [[id(n)]] -- a buffer's GPU
 * address plus its offset, a texture's or sampler's gpuResourceID. A draw or dispatch reads those words when it is
 * recorded (hakios-metal's bindArgumentBuffers) and binds what they name. What this layout cannot hold -- inlined
 * constant data, nested argument buffers, indirect command buffers -- is refused by name where it is asked for. */
@interface HakiosMetalArgumentEncoder : NSObject {
	id<MTLDevice> _device;
	NSString *_label;
	NSUInteger _count;
	NSUInteger *_ids, *_offsets, *_lengths;   /* by position, sorted by id: the member's id, byte offset, array length */
	NSUInteger _length;
	id _buffer;
	NSUInteger _base;
	char _source[96];                         /* where the layout came from, for a refusal to say */
}
- (instancetype)initWithDevice:(id)device arguments:(NSArray *)arguments;
- (void)hakiosSetSource:(const char *)source;
- (instancetype)initWithDevice:(id)device ids:(const unsigned *)ids offsets:(const unsigned *)offsets count:(NSUInteger)count;
@end

@implementation HakiosMetalArgumentEncoder
HM_REFUSES_OUT_LOUD

+ (void)load
{
	hm_adopt(self, @protocol(MTLArgumentEncoder), "MTLArgumentEncoder");
}

- (instancetype)initWithDevice:(id)device arguments:(NSArray *)arguments
{
	self = [super init];
	if (self == nil) return nil;
	NSArray *sorted = [arguments sortedArrayUsingComparator:^NSComparisonResult(MTLArgumentDescriptor *a, MTLArgumentDescriptor *b) {
		return [a index] < [b index] ? NSOrderedAscending : [a index] > [b index] ? NSOrderedDescending : NSOrderedSame;
	}];
	_device = [device retain];
	_count = [sorted count];
	_ids = calloc(_count + 1, sizeof(NSUInteger));
	_offsets = calloc(_count + 1, sizeof(NSUInteger));
	_lengths = calloc(_count + 1, sizeof(NSUInteger));
	for (NSUInteger i = 0; i < _count; i++) {
		MTLArgumentDescriptor *d = sorted[i];
		_ids[i] = [d index];
		_offsets[i] = _length;
		_lengths[i] = [d arrayLength] != 0 ? [d arrayLength] : 1;
		_length += 8 * _lengths[i];
	}
	return self;
}

/* a function's set as its metadata lays it out (hakios_metal_argument_buffer_layout): each member at its own offset,
 * one element each -- the front end reads an array member as members of their own -- and the set eight bytes a member */
- (instancetype)initWithDevice:(id)device ids:(const unsigned *)ids offsets:(const unsigned *)offsets count:(NSUInteger)count
{
	self = [super init];
	if (self == nil) return nil;
	_device = [device retain];
	_count = count;
	_ids = calloc(_count + 1, sizeof(NSUInteger));
	_offsets = calloc(_count + 1, sizeof(NSUInteger));
	_lengths = calloc(_count + 1, sizeof(NSUInteger));
	for (NSUInteger i = 0; i < _count; i++) {
		_ids[i] = ids[i];
		_offsets[i] = offsets[i];
		_lengths[i] = 1;
		_length = MAX(_length, (NSUInteger)offsets[i] + 8);
	}
	return self;
}

- (void)dealloc
{
	free(_ids);
	free(_offsets);
	free(_lengths);
	[_buffer release];
	[_label release];
	[_device release];
	[super dealloc];
}

- (id<MTLDevice>)device { return _device; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { [label retain]; [_label release]; _label = label; }
- (void)hakiosSetSource:(const char *)source { snprintf(_source, sizeof(_source), "%s", source); }
- (NSUInteger)encodedLength { return _length; }
- (NSUInteger)alignment { return 8; }

- (void)setArgumentBuffer:(id)buffer offset:(NSUInteger)offset
{
	[buffer retain];
	[_buffer release];
	_buffer = buffer;
	_base = offset;
}

- (void)setArgumentBuffer:(id)buffer startOffset:(NSUInteger)startOffset arrayElement:(NSUInteger)arrayElement
{
	[self setArgumentBuffer:buffer offset:startOffset + arrayElement * _length];
}

/* the eight bytes of member ID's element ELEMENT in the buffer set above, or NULL (said once) */
- (uint64_t *)hakiosSlot:(NSUInteger)index element:(NSUInteger)element
{
	if (_buffer == nil) {
		HM_ONCE("an argument encoder was given a member before an argument buffer; nothing is written\n");
		return NULL;
	}
	for (NSUInteger i = 0; i < _count; i++) {
		if (index >= _ids[i] && index < _ids[i] + _lengths[i]) {
			const NSUInteger at = _base + _offsets[i] + 8 * (index - _ids[i] + element);
			if (at + 8 > [(id<MTLBuffer>)_buffer length]) return NULL;
			return (uint64_t *)((uint8_t *)[(id<MTLBuffer>)_buffer contents] + at);
		}
	}
	{
		/* which encoder: where its layout came from and the ids it has, so that a member missing from it is told from a
		 * member missing from the function's own set */
		char ids[160] = "";
		size_t n = 0;

		for (NSUInteger i = 0; i < _count && n < sizeof(ids); i++) {
			n += (size_t)snprintf(ids + n, sizeof(ids) - n, "%s%lu", i ? "," : "", (unsigned long)_ids[i]);
		}
		hm_print("refused: an argument encoder's member %lu, which its layout has not got (ids %s, from %s); nothing is written\n",
			 (unsigned long)index, ids, _source[0] ? _source : "a descriptor array");
	}
	return NULL;
}

- (void)setBuffer:(id)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	uint64_t *w = [self hakiosSlot:index element:0];
	if (w != NULL) *w = buffer != nil ? [(id<MTLBuffer>)buffer gpuAddress] + offset : 0;
}

- (void)setBuffers:(const id *)buffers offsets:(const NSUInteger *)offsets withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) [self setBuffer:buffers[i] offset:offsets[i] atIndex:range.location + i];
}

- (void)setTexture:(id)texture atIndex:(NSUInteger)index
{
	uint64_t *w = [self hakiosSlot:index element:0];
	if (w != NULL) *w = texture != nil ? [(id<MTLTexture>)texture gpuResourceID]._impl : 0;
}

- (void)setTextures:(const id *)textures withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) [self setTexture:textures[i] atIndex:range.location + i];
}

- (void)setSamplerState:(id)sampler atIndex:(NSUInteger)index
{
	uint64_t *w = [self hakiosSlot:index element:0];
	if (w != NULL) *w = sampler != nil ? [(id<MTLSamplerState>)sampler gpuResourceID]._impl : 0;
}

- (void)setSamplerStates:(const id *)samplers withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) [self setSamplerState:samplers[i] atIndex:range.location + i];
}

- (void *)constantDataAtIndex:(NSUInteger)index
{
	hm_print("refused: -[MTLArgumentEncoder constantDataAtIndex:%lu]: inlined constant data has no place in the eight-bytes-a-member "
		 "layout; it returns NULL\n", (unsigned long)index);
	return NULL;
}

- (id)newArgumentEncoderForBufferAtIndex:(NSUInteger)index
{
	hm_print("refused: a nested argument encoder (member %lu): argument buffers inside argument buffers are not served; it returns nil\n",
		 (unsigned long)index);
	return nil;
}
@end

/* the types whose slices Metal numbers as layers (a 2D or 1D array's, a cube's or cube array's faces): copied a layer
 * at a time by the core's slice copy, Z the slice */
static BOOL
hm_layered(unsigned type)
{
	return type == MTLTextureType2DArray || type == MTLTextureTypeCube || type == MTLTextureType1DArray || type == MTLTextureTypeCubeArray;
}

@implementation HakiosMetalHeap
/* MPS asks a heap Apple's SPI (-protectionOptions first, which raised and took mediaserverd down once heaps were sized
 * and made): what MTLHeapSPI declares is answered or named by the forwarding below, never an unrecognized selector */
HM_REFUSES_OUT_LOUD

- (instancetype)initWithDevice:(id)device descriptor:(MTLHeapDescriptor *)descriptor
{
	if (objc_getProtocol("MTLHeapSPI") != NULL) {
		hm_adopt([self class], objc_getProtocol("MTLHeapSPI"), "MTLHeapSPI");
	}
	self = [super init];
	if (self != nil) {
		_device = [device retain];
		_descriptor = [descriptor copy];
	}
	return self;
}
- (void)dealloc
{
	[_descriptor release];
	[_label release];
	[_device release];
	[super dealloc];
}
- (id<MTLDevice>)device { return _device; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { [label retain]; [_label release]; _label = label; }
- (MTLStorageMode)storageMode { return [_descriptor storageMode]; }
- (MTLCPUCacheMode)cpuCacheMode { return [_descriptor cpuCacheMode]; }
- (MTLHazardTrackingMode)hazardTrackingMode { return [_descriptor hazardTrackingMode]; }
- (MTLResourceOptions)resourceOptions { return [_descriptor resourceOptions]; }
- (MTLHeapType)type { return [_descriptor type]; }
- (NSUInteger)protectionOptions { return 0; }   /* no protected memory on this port, as a texture answers */
- (NSUInteger)size { return [_descriptor size]; }
- (NSUInteger)usedSize { return _used; }
- (NSUInteger)currentAllocatedSize { return [_descriptor size]; }
- (NSUInteger)maxAvailableSizeWithAlignment:(NSUInteger)alignment
{
	(void)alignment;
	return [_descriptor size] > _used ? [_descriptor size] - _used : 0;
}
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { (void)state; return MTLPurgeableStateNonVolatile; }

/* a resource from the budget: the device's own allocation, refused (nil) when it would overrun the heap, as Metal's is */
- (id)hakiosCounted:(id)resource
{
	NSUInteger size = resource != nil ? [(id<MTLResource>)resource allocatedSize] : 0;

	if (resource == nil) return nil;
	if (_used + size > [_descriptor size]) {
		[resource release];
		return nil;
	}
	_used += size;
	return resource;
}
- (id)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{
	return [self hakiosCounted:[_device newBufferWithLength:length options:options]];
}
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor
{
	return [self hakiosCounted:[_device newTextureWithDescriptor:descriptor]];
}
- (id)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options offset:(NSUInteger)offset
{
	(void)length; (void)options; (void)offset;
	hm_print("refused: a buffer at an offset of a heap: placement is not served (every resource is its own allocation); it returns nil\n");
	return nil;
}
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor offset:(NSUInteger)offset
{
	(void)descriptor; (void)offset;
	hm_print("refused: a texture at an offset of a heap: placement is not served (every resource is its own allocation); it returns nil\n");
	return nil;
}
/* acceleration structures belong to ray tracing, which this GPU's path does not have (the device has none either) */
- (id)newAccelerationStructureWithSize:(NSUInteger)size { (void)size; return [self hakiosNoRayTracing]; }
- (id)newAccelerationStructureWithDescriptor:(MTLAccelerationStructureDescriptor *)d { (void)d; return [self hakiosNoRayTracing]; }
- (id)newAccelerationStructureWithSize:(NSUInteger)size offset:(NSUInteger)offset { (void)size; (void)offset; return [self hakiosNoRayTracing]; }
- (id)newAccelerationStructureWithDescriptor:(MTLAccelerationStructureDescriptor *)d offset:(NSUInteger)offset
{
	(void)d; (void)offset;
	return [self hakiosNoRayTracing];
}
- (id)hakiosNoRayTracing
{
	hm_print("refused: an acceleration structure from a heap: no ray tracing on this GPU's path; it returns nil\n");
	return nil;
}
@end

@interface HakiosMetalDepthStencilState : NSObject <MTLDepthStencilState> {
	id<MTLDevice> _device;
	NSString *_label;
	unsigned _compare;
	BOOL _write;
	BOOL _stencil;
	struct hakios_metal_stencil_face _front, _back;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device descriptor:(MTLDepthStencilDescriptor *)descriptor;
- (unsigned)hakiosDepthCompare;
- (BOOL)hakiosDepthWrite;
- (BOOL)hakiosStencil;
- (const struct hakios_metal_stencil_face *)hakiosStencilFront;
- (const struct hakios_metal_stencil_face *)hakiosStencilBack;
@end

@interface HakiosMetalSamplerState : _MTLSamplerState {
	hakios_metal_sampler *_hakiosSampler;
	uint64_t _hakiosUniqueIdentifier;   /* -[_MTLSamplerState uniqueIdentifier] is a nil-stub, and gpuResourceID is built on it */
}
- (instancetype)initWithHakiosDevice:(HakiosMetalDevice *)device sampler:(hakios_metal_sampler *)sampler
			  descriptor:(MTLSamplerDescriptor *)descriptor;
- (hakios_metal_sampler *)hakiosSampler;
@end

@interface HakiosMetalComputePipelineState : _MTLComputePipelineState {
	HakiosMetalDevice *_device;
	hakios_metal_kernel *_kernel;
	NSString *_label;
}
- (instancetype)initWithHakiosDevice:(HakiosMetalDevice *)device kernel:(hakios_metal_kernel *)kernel descriptor:(id)descriptor;
- (hakios_metal_kernel *)hakiosKernel;
@end

/* A render pipeline state: a vertex and a fragment function compiled and linked by hakios-metal for one colour
 * attachment (hakios_metal_program), under Metal's own base class. The ivar names are prefixed so that none shadows the
 * base's _device and _label, which its designated initialiser fills from the descriptor. */
@interface HakiosMetalRenderPipelineState : _MTLRenderPipelineState {
	HakiosMetalDevice *_hakiosDevice;
	hakios_metal_program *_program;
	uint64_t _hakiosUniqueIdentifier;   /* the base's uniqueIdentifier is a nil-stub; see the sampler */
	/* an uber shader's specialisations (hakiosProgramFor:): its fragment bitcode and constants, the constant buffer
	 * whose bytes choose its path, and the programs compiled for each content seen (NSNull while one compiles) */
	NSData *_fsAir;
	hakios_metal_constant _fsConstants[64];
	unsigned _fsConstantCount;
	int _specBinding;
	unsigned _specLength;
	uint8_t _specMask[256];   /* 0xff for each byte of that buffer the fragment stage reads: a content is those bytes alone */
	NSMutableDictionary *_specialised;
}
- (instancetype)initWithHakiosDevice:(HakiosMetalDevice *)device program:(hakios_metal_program *)program
			  descriptor:(MTLRenderPipelineDescriptor *)descriptor;
- (hakios_metal_program *)hakiosProgram;
- (void)hakiosKeepFragment:(NSData *)air constants:(const hakios_metal_constant *)constants count:(unsigned)count;
- (hakios_metal_program *)hakiosProgramFor:(hakios_metal_buffer *const *)buffers offsets:(const uint64_t *)offsets count:(unsigned)count;
@end

@interface HakiosMetalCommandQueue : _MTLCommandQueue {
	HakiosMetalDevice *_device;
	hakios_metal_queue *_queue;
	NSUInteger _gpuPriority, _backgroundGPUPriority;
	dispatch_queue_t _completionQueue;       /* only where Apple's own ivar is missing */
	dispatch_queue_t _deferred;              /* submissions in enqueue order, including event waits */
	NSMutableArray *_pending;               /* reserved positions, under @synchronized(self) */
	unsigned _onDeferred;                   /* submissions given to _deferred and not yet made, under @synchronized(self) */
	BOOL _idlePending;
}
- (instancetype)initWithHakiosDevice:(HakiosMetalDevice *)device descriptor:(id)descriptor;
- (hakios_metal_queue *)hakiosQueue;
- (dispatch_queue_t)hakiosCompletionQueue;
- (void)hakiosEnqueue:(HakiosMetalCommandBuffer *)buffer;
- (void)hakiosCommit:(HakiosMetalCommandBuffer *)buffer;
- (void)hakiosSendBuffers:(NSArray *)buffers;
- (void)hakiosDrain:(unsigned)reason;
@end

@interface HakiosMetalCommandBuffer : _MTLCommandBuffer {
	HakiosMetalCommandQueue *_queue;
	hakios_metal_cb *_cb;
	NSMutableArray *_scheduled, *_completed; /* handler blocks, copied to the heap */
	NSMutableArray *_shadowTargets;         /* driver publication, inline before events/client callbacks */
	NSMutableArray *_shadowSamples;         /* the shadow copies this buffer samples: surfaces whose queued writes it waits for */
	NSMutableSet *_probeReads, *_probeWrites; /* unique textures per CB; metal_fps handoff diagnostics */
	NSError *_error;
	BOOL _committed;
	BOOL _enqueued, _readyToSubmit, _scheduledDelivered, _completedDelivered;
    unsigned _drainReason;                   /* reason + 1; zero permits private-resource deferral */
	BOOL _owesSlot;                          /* holds one of the queue's maxCommandBufferCount slots */
	double _committedAt;                     /* host seconds, for the GPU times Metal reports */
	double _createdAt;                       /* ...and when it was made: metal_fps's encoding time */
	NSUInteger _protectionOptions;
	NSMutableArray *_signals, *_waits;       /* { HakiosMetalEvent, value }: applied at completion / met before the GPU sees it */
	dispatch_semaphore_t _sent;              /* a held commit: signalled once it has reached the GPU */
	NSMutableArray *_turned;                 /* HakiosMetalTexture: turned framebuffers drawn here, copied into their surfaces at commit */
	IOSurfaceRef _reads[8];                  /* flicker-diag (window server): surfaces sampled here straight from their rows (retained) */
	uint32_t _readSeeds[8];                  /* ... their seeds when first sampled, then when sent to the GPU */
	unsigned _readCount;
	double _sentAt;
	uint64_t _useSeq;                        /* this buffer's number for its resources' -isComplete (hm_use_*) */
}
- (instancetype)initWithHakiosQueue:(HakiosMetalCommandQueue *)queue;
- (uint64_t)hakiosUseSeq;
- (void)hakiosTurnAtCommit:(id)texture;
- (void)hakiosWriteShadowAtCompletion:(HakiosMetalTexture *)texture;
- (void)hakiosTrackTexture:(HakiosMetalTexture *)texture write:(BOOL)write;
- (void)hakiosTrackSample:(HakiosMetalTexture *)texture;
- (void)hakiosShadowSampleSync;
- (void)hakiosNoteRead:(IOSurfaceRef)surface;
- (void)hakiosCheckReads:(BOOL)done;
- (hakios_metal_cb *)hakiosCommandBuffer;
- (double)hakiosCreatedAt;
- (BOOL)hakiosReadyToSubmit;
- (void)hakiosMarkReady;
- (BOOL)hakiosWaits;
- (unsigned)hakiosDrainReason;
- (void)hakiosRequireSync:(unsigned)reason;
- (void)hakiosPrepareSend;
- (void)hakiosSend;
- (void)hakiosSent;
- (void)hakiosDeliverScheduled;
- (void)hakiosSubmit;
@end

/* A parallel render encoder: one pass whose draws come from several sub-encoders, filled on any thread in any order and
 * run in the order they were made. Each records into a core command buffer of its own; -endEncoding appends them to
 * this command buffer in that order (hakios_metal_cb_append). The first takes the pass's load actions and the rest load
 * what came before; every one stores, and the pass's resolves run once at the end, over the whole of it. */
@interface HakiosMetalParallelRenderCommandEncoder : _MTLCommandEncoder {
	HakiosMetalCommandBuffer *_commandBuffer;   /* not retained: the base class retains it until -endEncoding */
	struct hakios_metal_render_pass _pass;
	HakiosMetalTexture *_colorTexture;
	MTLRenderPassDescriptor *_descriptor;       /* copied: its resolves are read at -endEncoding */
	NSMutableArray *_subs;                      /* NSValue (pointer) of each sub-encoder's hakios_metal_cb, in creation order */
	NSLock *_lock;
}
- (instancetype)initWithHakiosCommandBuffer:(HakiosMetalCommandBuffer *)commandBuffer pass:(const struct hakios_metal_render_pass *)pass
			       colorTexture:(HakiosMetalTexture *)texture descriptor:(MTLRenderPassDescriptor *)descriptor;
@end

@interface HakiosMetalBlitCommandEncoder : _MTLCommandEncoder {
	HakiosMetalCommandBuffer *_commandBuffer;   /* not retained: the base class retains it until -endEncoding */
}
- (instancetype)initWithHakiosCommandBuffer:(HakiosMetalCommandBuffer *)commandBuffer;
@end

@interface HakiosMetalComputeCommandEncoder : _MTLCommandEncoder {
	HakiosMetalCommandBuffer *_commandBuffer;   /* not retained, as above */
	HakiosMetalComputePipelineState *_pipeline;
	HakiosMetalBuffer *_buffers[HM_MAX_BUFFERS];
	uint64_t _offsets[HM_MAX_BUFFERS];
	unsigned _highest;                          /* one past the highest index bound */
	HakiosMetalTexture *_textures[HM_MAX_TEXTURES];         /* by Metal texture index: a sampled texture or an image, the kernel decides */
	unsigned _highestTexture;
	HakiosMetalSamplerState *_samplers[HM_MAX_SAMPLERS];    /* by Metal sampler index */
	unsigned _highestSampler;
	NSMutableArray *_scratch;                   /* the buffers -setBytes: made, alive until -endEncoding */
	NSUInteger _threadgroupLength;              /* setThreadgroupMemoryLength: at index 0, given to each dispatch */
	char _refused[160];                         /* a binding this encoder could not take: the dispatch is failed by it */
}
- (instancetype)initWithHakiosCommandBuffer:(HakiosMetalCommandBuffer *)commandBuffer;
@end

/*
 * The render encoder: one colour attachment read off the pass descriptor at creation (Metal reads nothing of it
 * afterwards), the pipeline, viewport, scissor and per-stage buffer tables stored as the compute encoder stores its
 * bindings, and each -drawPrimitives: one whole pass of hakios-metal's (begin, state, draw, end: hakios_metal_cb_draw).
 * No _MTLRenderCommandEncoder exists to inherit from; the base is _MTLCommandEncoder, as for the compute encoder.
 */
@interface HakiosMetalRenderCommandEncoder : _MTLCommandEncoder {
	HakiosMetalCommandBuffer *_commandBuffer;   /* not retained: the base class retains it until -endEncoding */
	hakios_metal_cb *_sub;                      /* a parallel encoder's sub-encoder: its own core command buffer, which
	                                             * the parallel encoder appends in creation order; NULL otherwise */
	HakiosMetalTexture *_colorTexture;          /* colour attachment 0, retained until the encoder goes */
	HakiosMetalTexture *_resolveFrom[8], *_resolveTo[8];   /* each colour attachment's samples and its resolveTexture, retained */
	unsigned _resolveLevel[8];
	BOOL _resolving[8];                         /* the store action resolves (2, 3, or Unknown with a resolveTexture): at -endEncoding */
	struct hakios_metal_render_pass _pass;      /* its hakios texture, load and store actions, clear colour */
	HakiosMetalRenderPipelineState *_pipeline;
	struct hakios_metal_viewport _viewport;
	struct hakios_metal_scissor _scissor;
	BOOL _hasViewport, _hasScissor;             /* unset: hakios-metal takes the whole attachment (NULL) */
	id _indirectArgs;                           /* the next draw is indirect: its words at _indirectOffset of this buffer */
	NSUInteger _indirectOffset;
	HakiosMetalBuffer *_vsBuffers[HM_MAX_BUFFERS];
	HakiosMetalBuffer *_fsBuffers[HM_MAX_BUFFERS];
	uint64_t _vsOffsets[HM_MAX_BUFFERS], _fsOffsets[HM_MAX_BUFFERS];
	unsigned _vsHighest, _fsHighest;            /* one past the highest index bound, per stage */
	HakiosMetalTexture *_fsTextures[HM_MAX_TEXTURES];         /* the fragment stage's [[texture(n)]], retained */
	HakiosMetalSamplerState *_fsSamplers[HM_MAX_SAMPLERS];    /* ... and [[sampler(n)]] */
	unsigned _fsHighestTexture, _fsHighestSampler;
	HakiosMetalTexture *_vsTextures[HM_MAX_TEXTURES];         /* the vertex stage's, the same way */
	HakiosMetalSamplerState *_vsSamplers[HM_MAX_SAMPLERS];
	unsigned _vsHighestTexture, _vsHighestSampler;
	NSMutableArray *_scratch;                   /* the buffers -setVertexBytes:/-setFragmentBytes: made */
	MTLWinding _frontFacingWinding;             /* -setFrontFacingWinding:'s, also in _pass.winding for the draws */
	BOOL _glNoTransform;                        /* -setViewportTransformEnabled:NO (OpenGL ES's own blits): window coordinates */
	BOOL _glProvokingLast;                      /* -setProvokingVertexMode:1, GL's: flat varyings from the last vertex */
	unsigned _flipWidth, _flipHeight;           /* a pass into a yInverted attachment (hm_yinvert_size): its size, the
	                                             * height each draw is turned about; 0: not such a pass */
	char _refused[160];                         /* a binding or state this encoder could not take: the next draw is failed by it */
	NSMutableIndexSet *_visibilityCounted;      /* the result words (offset / 8) a draw of this encoder has counted into */
}
- (instancetype)initWithHakiosCommandBuffer:(HakiosMetalCommandBuffer *)commandBuffer pass:(const struct hakios_metal_render_pass *)pass
			       colorTexture:(HakiosMetalTexture *)texture;
- (instancetype)initWithHakiosCommandBuffer:(HakiosMetalCommandBuffer *)commandBuffer pass:(const struct hakios_metal_render_pass *)pass
			       colorTexture:(HakiosMetalTexture *)texture sub:(hakios_metal_cb *)sub;
- (void)hakiosTakeResolves:(MTLRenderPassDescriptor *)descriptor;
- (void)hakiosSetYInvertWidth:(unsigned)width height:(unsigned)height;
@end

/* ============================================================================================================
 * The device
 * ============================================================================================================ */

/* boot-arg metal_dump=refused (a diagnostic, beside metal_dump=FNV): the bitcode of each function in a pipeline the
 * compiler refused, into the log in hex, labelled, for the host's front end to take apart. What it prints is the
 * system's code: it stays in the log. metal_dump=refused:NAME[,NAME...] dumps those functions alone -- a process
 * refusing a dozen pipelines at once overruns the console ring, and a module with lines missing cannot be read back.
 * metal_dump=fn:NAME[,NAME...] dumps those functions when a pipeline is made of them though nothing was refused, with
 * the function constants they were specialised by: a pipeline that compiles and draws the wrong thing (VideoToolbox's
 * converter over the live wallpaper's frames) is read the same way. */
/* What a draw, dispatch or copy this device refuses does to its command buffer. Apple's driver validates nothing and runs
 * a frame whatever is wrong in it, so by default the refused piece of work is left out -- said, as every refusal is --
 * and the rest of the buffer runs: Resident Evil 4 has, every frame, one dispatch this does not serve yet, and failing
 * the buffer for it showed nothing at all. Boot-arg metal_strict ends the buffer in error instead, as the plug-in
 * always did: what to boot with to find the first refusal of a frame; and HAKIOS_METAL_STRICT=1 in a process's
 * environment, read at each command buffer, for the tests whose refusals are checked by the buffer's error. */
static BOOL
hm_strict(void)
{
	static int strict = -1;
	const char *env = getenv("HAKIOS_METAL_STRICT");

	if (env != NULL) {
		return strcmp(env, "1") == 0;
	}
	if (strict < 0) {
		char args[1024] = {0};
		size_t size = sizeof(args) - 1;

		strict = sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "metal_strict") != NULL;
	}
	return strict != 0;
}

/*
 * CoreAnimation's shaders, chosen (hakios): this image is the iPhone X's, whose QuartzCore carries no default.metallib
 * of its functions -- only default.pipelinelib, a library of pipelines precompiled for Apple's GPU. Its "functions"
 * file holds every pipeline's functions all the same, as AIR: 451 single-function metallibs, the four uber shaders
 * (fixed_vert_lph_gen, fixed_vert_lph_spc, fixed_frag_lph_cpf, fixed_frag_lph_cph) each already specialised for one
 * set of CoreAnimation's constants, and pipelines.desc names them: its section 1 the label of each (in the order of the
 * functions file, "com.apple.coreanimation.frag.A2Xghfc"), its section 7 each pipeline's label with the labels of its
 * two functions. The window server is handed a default.metallib of one variant of each uber shader (ca_metallib=,
 * the kernel's inject.c); here, when a pipeline is made of one of them, the variant its label names is the one
 * compiled -- by the function's own label, or by the pipeline's (draw label -> vertex and fragment labels).
 */
#define HM_CA_PIPELINELIB "/System/Library/Frameworks/QuartzCore.framework/default.pipelinelib"
static NSData *hm_ca_functions;                 /* the functions file, mapped */
static NSMutableDictionary *hm_ca_variants;     /* function label -> NSData of its module (the 0x0B17C0DE wrapper) */
static NSMutableDictionary *hm_ca_pipelines;    /* draw label -> @[vertex label, fragment label] */
static NSMutableDictionary *hm_ca_frag_vert;    /* fragment label -> the vertex label every pipeline of it has */

static NSData *
hm_ca_module(const uint8_t *lib, size_t size)
{
	uint64_t funcs, bc;
	uint32_t entry;

	/* the one function's bitcode: the bitcode section at +0x48 plus the function's OFFT, MDSZ long */
	if (size < 0x58 || memcmp(lib, "MTLB", 4) != 0) {
		return nil;
	}
	memcpy(&funcs, lib + 0x18, 8);
	memcpy(&bc, lib + 0x48, 8);
	if (funcs + 8 > size) {
		return nil;
	}
	memcpy(&entry, lib + funcs + 4, 4);
	for (uint64_t q = funcs + 8, end = funcs + 4 + entry, offt = ~0ull, mdsz = 0; q + 6 <= end && q + 6 <= size;) {
		uint16_t len;

		if (memcmp(lib + q, "ENDT", 4) == 0) {
			break;
		}
		memcpy(&len, lib + q + 4, 2);
		if (memcmp(lib + q, "OFFT", 4) == 0 && len == 24 && q + 6 + 24 <= size) {
			memcpy(&offt, lib + q + 6 + 16, 8);
		} else if (memcmp(lib + q, "MDSZ", 4) == 0 && len == 8 && q + 6 + 8 <= size) {
			memcpy(&mdsz, lib + q + 6, 8);
		}
		q += 6 + len;
		if ((offt != ~0ull && mdsz != 0) && bc + offt + mdsz <= size) {
			return [NSData dataWithBytes:lib + bc + offt length:(NSUInteger)mdsz];
		}
	}
	return nil;
}

static void
hm_ca_load(void)
{
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		NSData *desc = [NSData dataWithContentsOfFile:@HM_CA_PIPELINELIB "/pipelines.desc"];
		const uint8_t *d = [desc bytes], *f;
		size_t dn = [desc length], fn, at = 0;
		uint32_t sections, off[16], n;
		NSMutableArray *labels = [NSMutableArray array];

		hm_ca_functions = [[NSData alloc] initWithContentsOfFile:@HM_CA_PIPELINELIB "/functions"
								 options:NSDataReadingMappedIfSafe error:NULL];
		hm_ca_variants = [[NSMutableDictionary alloc] init];
		hm_ca_pipelines = [[NSMutableDictionary alloc] init];
		hm_ca_frag_vert = [[NSMutableDictionary alloc] init];
		if (desc == nil || hm_ca_functions == nil || dn < 8) {
			hm_print("CoreAnimation's pipeline library is not at " HM_CA_PIPELINELIB ": no variants to choose from\n");
			return;
		}
		memcpy(&sections, d, 4);
		if (sections > 16 || 4 + 4 * sections > dn) {
			return;
		}
		memcpy(off, d + 4, 4 * sections);
		/* section 1: the functions' labels, in the order of the functions file */
		if (sections > 7 && off[1] + 4 <= dn) {
			memcpy(&n, d + off[1], 4);
			for (uint32_t i = 0; i < n && off[1] + 8 + 4 * i <= dn; i++) {
				uint32_t r;

				memcpy(&r, d + off[1] + 4 + 4 * i, 4);
				if (off[1] + r + 16 < dn) {
					const char *label = (const char *)d + off[1] + r + 16;

					[labels addObject:[NSString stringWithUTF8String:strnlen(label, dn - off[1] - r - 16) < 200 ? label : ""]];
				}
			}
		}
		/* the functions file: the metallibs one after the other, in that order */
		f = [hm_ca_functions bytes];
		fn = [hm_ca_functions length];
		for (NSUInteger i = 0; i < [labels count]; i++) {
			const uint8_t *m = at < fn ? memmem(f + at, fn - at, "MTLB", 4) : NULL;
			uint64_t total;
			NSData *module;

			if (m == NULL || (size_t)(m - f) + 0x18 > fn) {
				break;
			}
			memcpy(&total, m + 0x10, 8);
			if ((size_t)(m - f) + total > fn) {
				break;
			}
			if ((module = hm_ca_module(m, (size_t)total)) != nil) {
				hm_ca_variants[labels[i]] = module;
			}
			at = (size_t)(m - f) + (size_t)total;
		}
		/* section 7: each pipeline's label with its functions' (draw, vert, frag), as strings in its entry */
		if (sections > 8 && off[7] + 4 <= dn) {
			memcpy(&n, d + off[7], 4);
			for (uint32_t i = 0; i < n && off[7] + 8 + 4 * i <= dn; i++) {
				uint32_t r, next = i + 1 < n ? 0 : off[8] - off[7];
				NSString *draw = nil, *vert = nil, *frag = nil;

				memcpy(&r, d + off[7] + 4 + 4 * i, 4);
				if (i + 1 < n) {
					memcpy(&next, d + off[7] + 4 + 4 * (i + 1), 4);
				}
				for (uint32_t q = r; q + 24 < next && off[7] + q + 24 < dn; q++) {
					const char *s = (const char *)d + off[7] + q;

					if (strncmp(s, "com.apple.coreanimation.", 24) != 0) {
						continue;
					}
					NSString *label = [NSString stringWithUTF8String:s];
					if ([label hasPrefix:@"com.apple.coreanimation.draw."]) draw = label;
					else if ([label hasPrefix:@"com.apple.coreanimation.vert."]) vert = label;
					else if ([label hasPrefix:@"com.apple.coreanimation.frag."]) frag = label;
					q += (uint32_t)strlen(s);
				}
				if (draw != nil && vert != nil) {
					hm_ca_pipelines[draw] = frag != nil ? @[vert, frag] : @[vert];
					if (frag != nil) hm_ca_frag_vert[frag] = vert;
				}
			}
		}
		hm_print("CoreAnimation's shaders: %lu labelled variants of its uber shaders, %lu pipelines (" HM_CA_PIPELINELIB ")\n",
			 (unsigned long)[hm_ca_variants count], (unsigned long)[hm_ca_pipelines count]);
	});
}

/*
 * The nearest variant to a fragment function the library does not have. CoreAnimation makes pipelines at run time that no
 * precompiled one is: TimgA2S1Xhf_Ixrg (an opaque image, for a compositing filter, the default wallpaper's head) or
 * TimgBdsoA2Xhfn_Isrc (darkenSourceOver, the status bar's legibility gradient). Compiled from the one variant the window server's
 * library holds, those drew something else altogether: the head nothing, the gradient solid white (4 November).
 * A label is T(what is sampled) B(the blend) A(the varyings) S(a second sampler) X(flags)_(the inputs): what is sampled, the blend
 * and the varyings must be the same, or it is another program. Then the fewest inputs changed, and a flag left out (a feature the
 * program did not ask for is not fed) before a flag added. What the letters mean is read from the labels, not from a document.
 */
static NSString *
hm_ca_nearest(NSString *frag)
{
	static NSMutableDictionary *told;
	static NSRegularExpression *form;
	static NSString *const prefix = @"com.apple.coreanimation.frag.";
	NSString *best = nil;
	NSInteger bestCost = NSIntegerMax;

	if (![frag hasPrefix:prefix]) {
		return nil;
	}
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		form = [[NSRegularExpression alloc] initWithPattern:@"^(T[a-z0-9]{3})?(B[a-z]{3})?(D[a-z]{2})?(A[0-9])(S[0-9])?(L[a-z]{2})?X([a-z]*)((?:_[A-Za-z0-9]+)*)$"
							    options:0 error:NULL];
		told = [[NSMutableDictionary alloc] init];
	});
	NSString *(^part)(NSTextCheckingResult *, NSUInteger, NSString *) = ^NSString *(NSTextCheckingResult *m, NSUInteger i, NSString *of) {
		NSRange r = [m rangeAtIndex:i];

		return r.location == NSNotFound ? @"" : [of substringWithRange:r];
	};
	NSString *want = [frag substringFromIndex:[prefix length]];
	NSTextCheckingResult *w = [form firstMatchInString:want options:0 range:NSMakeRange(0, [want length])];

	if (w == nil) {
		return nil;
	}
	for (NSString *candidate in hm_ca_frag_vert) {
		if (![candidate hasPrefix:prefix] || hm_ca_variants[candidate] == nil) {
			continue;
		}
		NSString *have = [candidate substringFromIndex:[prefix length]];
		NSTextCheckingResult *h = [form firstMatchInString:have options:0 range:NSMakeRange(0, [have length])];
		BOOL same = h != nil;
		NSInteger cost = 0;

		for (NSUInteger i = 1; same && i <= 6; i++) {
			same = [part(w, i, want) isEqualToString:part(h, i, have)];
		}
		if (!same) {
			continue;
		}
		NSString *wantFlags = part(w, 7, want), *haveFlags = part(h, 7, have);
		NSArray *wantIn = [part(w, 8, want) componentsSeparatedByString:@"_"], *haveIn = [part(h, 8, have) componentsSeparatedByString:@"_"];

		if ([wantIn count] != [haveIn count]) {
			continue;
		}
		for (NSUInteger i = 0; i < [wantIn count]; i++) {
			/* (an input that does more than was asked for last: IsrcN3Oc3mtc4 is a colour matrix, not a plain sample) */
			cost += [wantIn[i] isEqualToString:haveIn[i]] ? 0 : 100 + labs((long)[haveIn[i] length] - (long)[wantIn[i] length]);
		}
		for (NSUInteger i = 0; i < [wantFlags length]; i++) {
			cost += [haveFlags rangeOfString:[wantFlags substringWithRange:NSMakeRange(i, 1)]].location == NSNotFound ? 3 : 0;
		}
		for (NSUInteger i = 0; i < [haveFlags length]; i++) {
			cost += [wantFlags rangeOfString:[haveFlags substringWithRange:NSMakeRange(i, 1)]].location == NSNotFound ? 10 : 0;
		}
		if (cost < bestCost || (cost == bestCost && [candidate compare:best] == NSOrderedAscending)) {
			best = candidate;
			bestCost = cost;
		}
	}
	@synchronized (told) {
		if (told[frag] == nil) {
			told[frag] = @YES;
			hm_print("CoreAnimation's %s is not in the library: %s stands in for it\n", [want UTF8String],
				 best != nil ? [[best substringFromIndex:[prefix length]] UTF8String] : "nothing of the same kind");
		}
	}
	return best;
}

/* --- OpenGL ES: AppleMetalGLRenderer's shaders -----------------------------------------------------------------------
 *
 * An application's EAGLContext reaches this device through OpenGLES.framework: libGFXShared reads IOGLESMetalBundleName
 * off the IOAcceleratorES service (the kernel publishes it when the switch file below is there), loads
 * /System/Library/Extensions/AppleMetalGLRenderer.bundle, and that renderer draws GL with Metal on this device. A GL
 * program's shaders arrive as -newFunctionWithGLESIR:inputsDescription:functionType:, Apple's GL compiler's serialized
 * IR ([u32 length][the stream], its first word the stream's version), not AIR. On Apple's GPU the compiler service turns
 * it into AIR with OpenGLES.framework/libGLVMPlugin.dylib (MTLCompiler dlopens it and calls
 * oglCodeGenServiceGenerateIR(LLVMContext, stream, length), which hands back an llvm::Module); that is done here, in
 * the process, with the same plug-in and the system's own libLLVM.dylib through its C entry points, then mem2reg and
 * simplifycfg (the generator's output is every GLSL variable in an alloca), and the module is written as bitcode. What
 * comes out is ordinary AIR -- a "#main" vertex or fragment function, air.vertex_input attributes by location,
 * user(slotN) varyings, the default-uniform block as an air.buffer, textures and samplers as arguments -- which the
 * compiler here takes as it takes CoreAnimation's (hakios-metal tests: gl_ijk_vs/gl_ijk_fs, gl_quad_vs/gl_quad_fs,
 * made the same way on the host from the macOS twin of the plug-in). _MTLDevice's own method makes the function
 * object (an _MTLFunctionInternal named "#main" over the IR); the AIR is kept on it, and hm_bitcode_for() hands that
 * to every pipeline made of it. Nothing is linked against libLLVM or the plug-in: both are dlopened, every symbol
 * looked up, and a missing one is a refusal by name (the function is nil, the GL program fails to link, as GL lets
 * it).
 *
 * The inputs description (4 bytes for each fragment function measured on the host, none for a vertex function) is the
 * GL front end's note to Apple's backend; the AIR carries the inputs itself, so it is only printed.
 */
#define HM_GLES_SWITCH HM_CACHE_DIR "/gles-on"   /* the gate: with it the window server publishes IOGLESMetalBundleName */
#define HM_GLES_SWITCH_IMAGE "/redwood/share/gles/gles-on"   /* ... or baked into an image (build.sh EXTRA_SHARE=<dir>/gles) */

static char hm_gles_key, hm_gles_text_key;       /* on a function: its AIR (NSData) and, for the first few, the text */
static volatile BOOL hm_gles_active;             /* this process made a GLES function: it is a GL client */

static struct {
	void *(*contextCreate)(void);
	void (*contextDispose)(void *);
	void (*initialize)(void);
	void *(*generate)(void *, const void *, size_t);
	void (*disposeModule)(void *);
	void *(*writeBitcode)(void *);
	const char *(*bufferStart)(void *);
	size_t (*bufferSize)(void *);
	void (*disposeBuffer)(void *);
	void *(*createPassManager)(void);
	void (*addMem2Reg)(void *);
	void (*addSimplifyCFG)(void *);
	int (*runPassManager)(void *, void *);
	void (*disposePassManager)(void *);
	char *(*printModule)(void *);
	void (*disposeMessage)(char *);
	char why[200];
} hm_glvm;
static pthread_mutex_t hm_glvm_lock = PTHREAD_MUTEX_INITIALIZER;

/* the plug-in and LLVM's C interface, once; hm_glvm.why says what is missing */
static void
hm_glvm_load(void)
{
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		void *llvm = dlopen("/usr/lib/libLLVM.dylib", RTLD_NOW | RTLD_LOCAL);
		void *plugin = dlopen("/System/Library/Frameworks/OpenGLES.framework/libGLVMPlugin.dylib", RTLD_NOW | RTLD_LOCAL);

		if (llvm == NULL || plugin == NULL) {
			snprintf(hm_glvm.why, sizeof(hm_glvm.why), "dlopen: %s", dlerror());
			return;
		}
#define HM_GLVM_SYM(field, handle, name)								\
		if ((*(void **)&hm_glvm.field = dlsym(handle, name)) == NULL) {				\
			snprintf(hm_glvm.why, sizeof(hm_glvm.why), "%s is not in %s", name,		\
				 handle == llvm ? "libLLVM.dylib" : "libGLVMPlugin.dylib");		\
			return;										\
		}
		HM_GLVM_SYM(contextCreate, llvm, "LLVMContextCreate");
		HM_GLVM_SYM(contextDispose, llvm, "LLVMContextDispose");
		HM_GLVM_SYM(disposeModule, llvm, "LLVMDisposeModule");
		HM_GLVM_SYM(writeBitcode, llvm, "LLVMWriteBitcodeToMemoryBuffer");
		HM_GLVM_SYM(bufferStart, llvm, "LLVMGetBufferStart");
		HM_GLVM_SYM(bufferSize, llvm, "LLVMGetBufferSize");
		HM_GLVM_SYM(disposeBuffer, llvm, "LLVMDisposeMemoryBuffer");
		HM_GLVM_SYM(printModule, llvm, "LLVMPrintModuleToString");
		HM_GLVM_SYM(disposeMessage, llvm, "LLVMDisposeMessage");
		HM_GLVM_SYM(initialize, plugin, "oglCodeGenServiceInitialize");
		HM_GLVM_SYM(generate, plugin, "oglCodeGenServiceGenerateIR");
#undef HM_GLVM_SYM
		/* the passes are a refinement: without them the allocas go to scratch memory, which the compiler serves */
		*(void **)&hm_glvm.createPassManager = dlsym(llvm, "LLVMCreatePassManager");
		*(void **)&hm_glvm.addMem2Reg = dlsym(llvm, "LLVMAddPromoteMemoryToRegisterPass");
		*(void **)&hm_glvm.addSimplifyCFG = dlsym(llvm, "LLVMAddCFGSimplificationPass");
		*(void **)&hm_glvm.runPassManager = dlsym(llvm, "LLVMRunPassManager");
		*(void **)&hm_glvm.disposePassManager = dlsym(llvm, "LLVMDisposePassManager");
		hm_glvm.initialize();
	});
}

/* IR, the GLES IR -newFunctionWithGLESIR: is handed ([u32 length][stream]), as AIR bitcode; nil with WHY. TEXT, when
 * not NULL, gets the module as LLVM's text (for the log when a pipeline of it is refused). */
static NSData *
hm_gles_air(const void *ir, NSString **text, char *why, size_t size)
{
	const uint32_t length = ir != NULL ? *(const uint32_t *)ir : 0;
	NSData *air = nil;
	void *context, *module, *buffer;

	hm_glvm_load();
	if (hm_glvm.why[0] != '\0') {
		snprintf(why, size, "no GL code generator: %s", hm_glvm.why);
		return nil;
	}
	if (ir == NULL || length < 4 || length > (64u << 20)) {
		snprintf(why, size, "a GLES IR of %u bytes", length);
		return nil;
	}
	pthread_mutex_lock(&hm_glvm_lock);   /* (the plug-in's state is its own business: one module at a time) */
	context = hm_glvm.contextCreate();
	module = context != NULL ? hm_glvm.generate(context, (const uint8_t *)ir + 4, length) : NULL;
	if (module == NULL) {
		snprintf(why, size, "oglCodeGenServiceGenerateIR refused the stream (version %u, %u bytes)", ((const uint32_t *)ir)[1], length);
	} else {
		if (hm_glvm.createPassManager != NULL && hm_glvm.addMem2Reg != NULL && hm_glvm.runPassManager != NULL) {
			void *pm = hm_glvm.createPassManager();

			if (pm != NULL) {
				hm_glvm.addMem2Reg(pm);
				if (hm_glvm.addSimplifyCFG != NULL) hm_glvm.addSimplifyCFG(pm);
				hm_glvm.runPassManager(pm, module);
				if (hm_glvm.disposePassManager != NULL) hm_glvm.disposePassManager(pm);
			}
		}
		buffer = hm_glvm.writeBitcode(module);
		if (buffer != NULL) {
			air = [NSData dataWithBytes:hm_glvm.bufferStart(buffer) length:hm_glvm.bufferSize(buffer)];
			hm_glvm.disposeBuffer(buffer);
		} else {
			snprintf(why, size, "LLVMWriteBitcodeToMemoryBuffer failed");
		}
		if (air != nil && text != NULL) {
			char *s = hm_glvm.printModule(module);

			if (s != NULL) {
				if (strlen(s) < 65536) *text = [NSString stringWithUTF8String:s];
				hm_glvm.disposeMessage(s);
			}
		}
		hm_glvm.disposeModule(module);
	}
	if (context != NULL) hm_glvm.contextDispose(context);
	pthread_mutex_unlock(&hm_glvm_lock);
	return air;
}

/* a function made by -newFunctionWithGLESIR:...: its AIR, else nil */
static NSData *
hm_gles_bitcode(id function)
{
	return function != nil ? objc_getAssociatedObject(function, &hm_gles_key) : nil;
}

/* a refused pipeline's GLES function, as the generator's AIR text, a line each (the first three refused per process):
 * what to take apart when the compiler here refuses something Apple's GL code generator emits */
static void
hm_gles_dump_refused(const char *stage, id function)
{
	static int dumped;
	NSString *text = function != nil ? objc_getAssociatedObject(function, &hm_gles_text_key) : nil;

	if (text == nil || __atomic_fetch_add(&dumped, 1, __ATOMIC_RELAXED) >= 3) {
		return;
	}
	unsigned n = 0;
	for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
		if ([line length] == 0) continue;
		if (n++ >= 160) {
			hm_print("gles-air %s: (cut at 160 lines)\n", stage);
			break;
		}
		hm_print("gles-air %s: %s\n", stage, [line UTF8String]);
	}
}

/*
 * The gate. The kernel publishes IOGLESMetalBundleName on the accelerator only when asked (IOAcceleratorES::setProperties,
 * metal=1), and the window server asks for it here, once a boot, when /var/db/hakios-metal-cache/gles-on (or, baked into
 * an image, /redwood/share/gles/gles-on) exists: without
 * the file every application's EAGLContext stays nil as before (no OpenGL ES at all, which applications are written to
 * survive). With it they get GL on this device. Removing the file and rebooting takes it away again. Only the first
 * process of a boot with write access to the registry entry (backboardd, which opens the device before any
 * application runs) does it; the others find the property there or the file absent.
 */
static void
hm_gles_gate(io_service_t accelerator)
{
	static dispatch_once_t once;

	if (accelerator == IO_OBJECT_NULL) {
		return;
	}
	dispatch_once(&once, ^{
		CFTypeRef published = IORegistryEntryCreateCFProperty(accelerator, CFSTR("IOGLESMetalBundleName"), kCFAllocatorDefault, 0);
		const char *switched = access(HM_GLES_SWITCH, F_OK) == 0 ? HM_GLES_SWITCH :
				       access(HM_GLES_SWITCH_IMAGE, F_OK) == 0 ? HM_GLES_SWITCH_IMAGE : NULL;
		const BOOL wanted = switched != NULL;

		if (published != NULL) {
			CFRelease(published);
			if (strcmp(getprogname(), "backboardd") == 0) {
				hm_print("gles: the accelerator names AppleMetalGLRenderer: applications' EAGLContexts are served by this device\n");
			}
			return;
		}
		if (!wanted) {
			if (strcmp(getprogname(), "backboardd") == 0) {
				hm_print("gles: off (no %s, no %s): applications get no OpenGL ES context\n", HM_GLES_SWITCH, HM_GLES_SWITCH_IMAGE);
			}
			return;
		}
		/* (the SDK marks the setter unavailable on iOS; IOKit has it, and the kernel's IOAcceleratorES::setProperties is
		 * what answers it) */
		kern_return_t (*set)(io_registry_entry_t, CFStringRef, CFTypeRef) =
			(kern_return_t (*)(io_registry_entry_t, CFStringRef, CFTypeRef))dlsym(RTLD_DEFAULT, "IORegistryEntrySetCFProperty");
		kern_return_t kr = set != NULL ? set(accelerator, CFSTR("IOGLESMetalBundleName"), CFSTR("AppleMetalGLRenderer")) : KERN_FAILURE;
		hm_print("gles: %s exists: asked the kernel to publish IOGLESMetalBundleName = AppleMetalGLRenderer: %s (%#x)\n", switched,
			 kr == KERN_SUCCESS ? "published" : "refused", kr);
	});
}

/* The module to compile for FUNCTION (of the pipeline labelled PIPELINE, vertex stage or not): its variant when
 * CoreAnimation's labels name one, else what the function itself has. */
static NSData *
hm_bitcode_for(id function, NSString *pipeline, BOOL vertex)
{
	static unsigned said;
	NSData *gles = hm_gles_bitcode(function);

	if (gles != nil) {
		return gles;   /* an OpenGL ES function: the AIR made of its GLES IR (above) */
	}
	NSString *name = [function respondsToSelector:@selector(name)] ? [function name] : nil, *label = nil, *chosen = nil;
	NSData *own = ((NSData *(*)(id, SEL))objc_msgSend)(function, sel_getUid("bitcodeData")), *variant = nil;

	/* (edr_scale was compiled as inplace_copy here while the library's was a later CoreAnimation's, whose buffers iOS
	 * 16.5 never binds; iOS 16.5's own library has its own, compiled as it is) */
	if (name == nil || ![name hasPrefix:@"fixed_"]) {
		return own;
	}
	hm_ca_load();
	if ([function respondsToSelector:@selector(label)]) {
		label = [function label];
	}
	if (label != nil && (variant = hm_ca_variants[label]) != nil) {
		chosen = label;
	} else if (pipeline != nil && hm_ca_pipelines[pipeline] != nil) {
		NSArray *pair = hm_ca_pipelines[pipeline];

		chosen = vertex ? pair[0] : ([pair count] > 1 ? pair[1] : nil);
		variant = chosen != nil ? hm_ca_variants[chosen] : nil;
	} else if (pipeline != nil && [pipeline hasPrefix:@"com.apple.coreanimation.draw."]) {
		/* a pipeline CoreAnimation makes at run time, which the library does not name: its fragment function is the
		 * spec after the first '_' (so in all 986 the library names) and its vertex one the one every pipeline of that
		 * fragment function has (one each, in all 444) -- picked apart, a pipeline got the wrong vertex variant and
		 * the link refused it ("reads varying slot 33, which the vertex stage does not write"), and CoreAnimation
		 * aborted the window server */
		NSString *spec = [pipeline substringFromIndex:[@"com.apple.coreanimation.draw." length]];
		NSRange under = [spec rangeOfString:@"_"];
		NSString *frag = under.location != NSNotFound ?
			[@"com.apple.coreanimation.frag." stringByAppendingString:[spec substringFromIndex:NSMaxRange(under)]] : nil;

		if (frag != nil && hm_ca_variants[frag] == nil) {
			frag = hm_ca_nearest(frag);
		}
		chosen = frag == nil ? nil : (vertex ? hm_ca_frag_vert[frag] : frag);
		variant = chosen != nil ? hm_ca_variants[chosen] : nil;
	}
	if (variant == nil || said++ < 40) {
		hm_print("CoreAnimation's %s (label %s, pipeline %s): %s%s\n", [name UTF8String], label ? [label UTF8String] : "none",
			 pipeline ? [pipeline UTF8String] : "none", variant ? "the variant " : "no variant: its own module",
			 variant ? [chosen UTF8String] : "");
	}
	return variant != nil ? variant : own;
}

/* The same choice for UniXNU's Metal on Vulkan (metal_m2v=1), whose functions are its own objects: by the function's name,
 * its label and the pipeline's (native_bridge_metal_variant_hook, NativeBridgeMetalFrontend.mm: variantFunction()). */
static const void *
hm_m2v_variant(const char *name, const char *label, const char *pipeline, int vertex, size_t *length)
{
	static unsigned said;
	NSString *chosen = nil;
	NSData *variant = nil;

	if (name == NULL || strncmp(name, "fixed_", 6) != 0) {
		return NULL;
	}
	hm_ca_load();
	NSString *flabel = label ? @(label) : nil, *plabel = pipeline ? @(pipeline) : nil;
	if (flabel != nil && (variant = hm_ca_variants[flabel]) != nil) {
		chosen = flabel;
	} else if (plabel != nil && hm_ca_pipelines[plabel] != nil) {
		NSArray *pair = hm_ca_pipelines[plabel];

		chosen = vertex ? pair[0] : ([pair count] > 1 ? pair[1] : nil);
		variant = chosen != nil ? hm_ca_variants[chosen] : nil;
	} else if (plabel != nil && [plabel hasPrefix:@"com.apple.coreanimation.draw."]) {
		NSString *spec = [plabel substringFromIndex:[@"com.apple.coreanimation.draw." length]];
		NSRange under = [spec rangeOfString:@"_"];
		NSString *frag = under.location != NSNotFound ?
			[@"com.apple.coreanimation.frag." stringByAppendingString:[spec substringFromIndex:NSMaxRange(under)]] : nil;

		if (frag != nil && hm_ca_variants[frag] == nil) {
			frag = hm_ca_nearest(frag);
		}
		chosen = frag == nil ? nil : (vertex ? hm_ca_frag_vert[frag] : frag);
		variant = chosen != nil ? hm_ca_variants[chosen] : nil;
	}
	if (said++ < 20) {
		hm_print("metal2vulkan: CoreAnimation's %s (label %s, pipeline %s): %s%s\n", name, label ? label : "none",
			 pipeline ? pipeline : "none", variant ? "the variant " : "no variant", variant ? [chosen UTF8String] : "");
	}
	if (variant == nil) {
		return NULL;
	}
	*length = [variant length];
	return [variant bytes];         /* (the dictionary keeps it for good) */
}

static void
hm_dump_function(const char *label, id function, const char *key, const hakios_metal_constant *constants, unsigned count)
{
	char args[1024] = {0};
	size_t size = sizeof(args) - 1;
	const char *at;

	if (function == nil || sysctlbyname("kern.bootargs", args, &size, NULL, 0) != 0 || (at = strstr(args, key)) == NULL ||
	    ![function respondsToSelector:sel_getUid("bitcodeData")]) {
		return;
	}
	at += strlen(key);
	if (*at == ':') {
		const char *name = [[function name] UTF8String];
		bool listed = false;

		for (const char *p = at + 1; name != NULL && *p != '\0' && *p != ' ' && !listed; p += strcspn(p, ", ") + (p[strcspn(p, ", ")] == ',')) {
			size_t len = strcspn(p, ", ");

			listed = strlen(name) == len && strncmp(p, name, len) == 0;
		}
		if (!listed) {
			return;
		}
	}
	NSData *air = hm_bitcode_for(function, nil, NO);
	const uint8_t *b = (const uint8_t *)[air bytes];

	for (NSUInteger o = 0; o < [air length]; o += 64) {
		char line[160];
		size_t n = 0;

		for (NSUInteger i = o; i < o + 64 && i < [air length]; i++) n += (size_t)snprintf(line + n, sizeof(line) - n, "%02x", b[i]);
		hm_print("dump refused-%s %s %06lx %s\n", label, [[function name] UTF8String], (unsigned long)o, line);
	}
	for (unsigned i = 0; i < count; i++) {
		hm_print("dump constant-%s %s %u %#llx\n", label, [[function name] UTF8String], constants[i].index,
			 (unsigned long long)constants[i].bits);
	}
}

static void
hm_dump_refused(const char *label, id function)
{
	hm_dump_function(label, function, "metal_dump=refused", NULL, 0);
}

/* v29d handoff probes share IOSurface IDs across the producer and render server.
 * No drawable/layer is retained by these records; a reused slot gets a new record.
 * The probes are off unless /var/db/hakios-metal-cache/handoff-diag exists: the
 * boot-args have no room left, and the file is read once per process, as the
 * switches beside it are (bo-cache-off, batch-commit-off, gmem-args). */
static BOOL hm_handoff_on(void)
{
    static int on = -1;
    int value = __atomic_load_n(&on, __ATOMIC_RELAXED);

    if (value < 0) {
        value = access("/var/db/hakios-metal-cache/handoff-diag", F_OK) == 0;
        __atomic_store_n(&on, value, __ATOMIC_RELAXED);
    }
    return value != 0;
}

/* Every handoff probe is a counter, taken by the 2 s fps: window: a per-frame,
 * per-pass or per-texture event may not print a line each (v29d's probes printed
 * 562 lines a second). State changes keep a line of their own. */
static struct {
    unsigned cb;
    unsigned encodeReads, encodeWrites, submitReads, submitWrites;
    unsigned fenceReads, fenceWrites, visibleWrites;
    unsigned shadowQueued, shadowPublished;
    unsigned passAttachments;
    unsigned imports, planeImports, shadowImports;
    unsigned cpuWrites, cpuReads, textureWaits;
    unsigned contentsChanges, dirtyMarks, appearanceChanges;
    unsigned txBegin, txCommit, txFlush;
    unsigned signals, poolReuses;
    unsigned steps[10];   /* the drawable steps, in hm_step_names order */
} hm_diag;

static void
hm_diag_add(unsigned *counter)
{
    __atomic_fetch_add(counter, 1, __ATOMIC_RELAXED);
}

static unsigned
hm_diag_take(unsigned *counter)
{
    return __atomic_exchange_n(counter, 0, __ATOMIC_RELAXED);
}

static const char *const hm_step_names[] = {
    "next-request", "next-return", "present-call", "texture-ready", "present-return-inserted",
    "contents-dirty", "transaction-flush-return", "handler-register", "handler-deliver", "other",
};

static unsigned
hm_step(const char *step)
{
    for (unsigned i = 0; i < 9; i++) {
        if (!strcmp(step, hm_step_names[i])) return i;
    }
    return 9;
}

/* where the drawable is the live object the layer method was given with the step */
static BOOL
hm_drawable_live_step(const char *step)
{
    return !strcmp(step, "next-return") || !strcmp(step, "present-call") || !strcmp(step, "texture-ready");
}

static char hm_drawable_record_key;
static NSMapTable *hm_ca_layers;   /* each layer's image queue as last reported: a state-change test */
static CFTypeID (*hm_ca_queue_type)(void);
static unsigned long (*hm_ca_queue_pending)(CFTypeRef);
static uint64_t (*hm_ca_queue_updated)(CFTypeRef);
static unsigned (*hm_ca_queue_pixels)(CFTypeRef);
static void hm_ca_queue_trace(id layer, const char *step)
{
    (void)step;
    id queue = ((id (*)(id, SEL))objc_msgSend)(layer, @selector(contents));
    if (queue == nil || CFGetTypeID((CFTypeRef)queue) != hm_ca_queue_type()) return;
    /* only followed, not printed: the 2 s pass prints it when it changed */
    @synchronized (hm_ca_layers) {
        if ([hm_ca_layers objectForKey:layer] == nil) [hm_ca_layers setObject:@{} forKey:layer];
    }
}

/* a layer's image queue, once a 2 s window and only when it changed */
static void hm_ca_queue_report(id layer)
{
    id queue = ((id (*)(id, SEL))objc_msgSend)(layer, @selector(contents));
    if (queue == nil || CFGetTypeID((CFTypeRef)queue) != hm_ca_queue_type()) return;
    const unsigned long pending = hm_ca_queue_pending((CFTypeRef)queue);
    const uint64_t updated = hm_ca_queue_updated((CFTypeRef)queue);
    const unsigned pixels = hm_ca_queue_pixels((CFTypeRef)queue);
    NSDictionary *last;

    @synchronized (hm_ca_layers) { last = [[hm_ca_layers objectForKey:layer] retain]; }
    const BOOL same = last != nil && [last[@"updated"] unsignedLongLongValue] == updated &&
                      [last[@"pending"] unsignedLongValue] == pending && [last[@"pixels"] unsignedIntValue] == pixels;
    [last release];
    if (same) return;
    @synchronized (hm_ca_layers) {
        [hm_ca_layers setObject:@{ @"updated": @(updated), @"pending": @(pending), @"pixels": @(pixels) } forKey:layer];
    }
    id root = layer, parent;
    while ((parent = ((id (*)(id, SEL))objc_msgSend)(root, sel_getUid("superlayer"))) != nil) root = parent;
    hm_print("ca-queue: layer=%p root=%p queue=%p unconsumed=%lu server-update-host=%llu displayed-pixels=%u t=%.6f\n",
        layer, root, queue, pending, (unsigned long long)updated, pixels, hm_now());
}

/* status and insertSeed of the last drawable reported: a ca-life line only when one changes,
 * not for every present */
static struct { pthread_mutex_t lock; uintptr_t drawable; unsigned long status; unsigned seed; } hm_drawable_state =
    { PTHREAD_MUTEX_INITIALIZER, 0, 0, 0 };

static void hm_drawable_trace(const char *step, id layer, id drawable, double argument)
{
    if (!hm_handoff_on()) return;
    hm_diag_add(&hm_diag.steps[hm_step(step)]);
    if (layer != nil) hm_ca_queue_trace(layer, step);
    NSDictionary *record = drawable != nil ? objc_getAssociatedObject(drawable, &hm_drawable_record_key) : nil;
    if (drawable != nil && (!strcmp(step, "next-return") || !strcmp(step, "present-call"))) {
        id texture = ((id (*)(id, SEL))objc_msgSend)(drawable, @selector(texture));
        IOSurfaceRef surface = [(HakiosMetalTexture *)texture iosurface];
        record = @{ @"texture": @((uintptr_t)texture), @"surface": @(surface != NULL ? IOSurfaceGetID(surface) : 0),
                    @"drawable": @(((uint64_t (*)(id, SEL))objc_msgSend)(drawable, sel_getUid("drawableID"))) };
        objc_setAssociatedObject(drawable, &hm_drawable_record_key, record, OBJC_ASSOCIATION_RETAIN);
        if (surface != NULL) {
            NSDictionary *previous = (NSDictionary *)IOSurfaceCopyValue(surface, CFSTR("HakiosMetalProducer"));
            if (!strcmp(step, "next-return") && previous != nil) hm_diag_add(&hm_diag.poolReuses);
            [previous release];
            IOSurfaceSetValue(surface, CFSTR("HakiosMetalProducer"), (CFTypeRef)@{
                @"pid": @(getpid()), @"layer": @((uintptr_t)layer), @"drawable": record[@"drawable"] });
        }
    }
    /* Only the drawable a layer method passed in the step itself is live: the delayed
     * notifications (release-private, handler deliveries) can arrive after it went away,
     * and an address kept in a record is not the object. */
    if (!hm_drawable_live_step(step)) return;
    const unsigned long status = ((unsigned long (*)(id, SEL))objc_msgSend)(drawable, sel_getUid("status"));
    const unsigned seed = ((unsigned (*)(id, SEL))objc_msgSend)(drawable, sel_getUid("insertSeed"));
    pthread_mutex_lock(&hm_drawable_state.lock);
    /* a status is the drawable's state, not its address (the pool hands the slots round)
     * nor its seed (which the present path writes every frame) */
    const BOOL changed = hm_drawable_state.status != status;
    if (changed) {
        hm_drawable_state.drawable = (uintptr_t)drawable;
        hm_drawable_state.status = status;
        hm_drawable_state.seed = seed;
    }
    pthread_mutex_unlock(&hm_drawable_state.lock);
    if (!changed) return;
    uint64_t tid = 0; pthread_threadid_np(NULL, &tid);
    hm_print("ca-life: step=%s layer=%p drawable=%p id=%llu status=%lu insert-seed=%u tid=%llu main=%u arg=%.6f t=%.6f\n",
             step, layer, drawable, [record[@"drawable"] unsignedLongLongValue], status, seed,
             (unsigned long long)tid, [NSThread isMainThread], argument, hm_now());
}
static BOOL hm_notes_layers_on(void)
{
    return hm_handoff_on() && !strcmp(getprogname(), "MobileNotes");
}
static void (*hm_layer_contents_original)(id, SEL, id);
static void (*hm_layer_dirty_original)(id, SEL);
static void (*hm_layer_hidden_original)(id, SEL, BOOL);
static void (*hm_layer_opaque_original)(id, SEL, BOOL);
static void (*hm_layer_opacity_original)(id, SEL, float);
static void hm_layer_contents(id layer, SEL sel, id contents)
{
    if (hm_layer_contents_original == NULL) return;
    const BOOL changed = hm_notes_layers_on() && ((id (*)(id, SEL))objc_msgSend)(layer, @selector(contents)) != contents;
    hm_layer_contents_original(layer, sel, contents);
    if (changed) hm_diag_add(&hm_diag.contentsChanges);
}
static void hm_layer_dirty(id layer, SEL sel)
{
    if (hm_layer_dirty_original == NULL) return;
    hm_layer_dirty_original(layer, sel);
    if (hm_notes_layers_on()) hm_diag_add(&hm_diag.dirtyMarks);
}
static void hm_layer_hidden(id layer, SEL sel, BOOL value)
{
    if (hm_layer_hidden_original == NULL) return;
    const BOOL changed = hm_notes_layers_on() && ((BOOL (*)(id, SEL))objc_msgSend)(layer, sel_getUid("isHidden")) != value;
    hm_layer_hidden_original(layer, sel, value);
    if (changed) hm_diag_add(&hm_diag.appearanceChanges);
}
static void hm_layer_opaque(id layer, SEL sel, BOOL value)
{
    if (hm_layer_opaque_original == NULL) return;
    const BOOL changed = hm_notes_layers_on() && ((BOOL (*)(id, SEL))objc_msgSend)(layer, sel_getUid("isOpaque")) != value;
    hm_layer_opaque_original(layer, sel, value);
    if (changed) hm_diag_add(&hm_diag.appearanceChanges);
}
static void hm_layer_opacity(id layer, SEL sel, float value)
{
    if (hm_layer_opacity_original == NULL) return;
    const BOOL changed = hm_notes_layers_on() && ((float (*)(id, SEL))objc_msgSend)(layer, sel_getUid("opacity")) != value;
    hm_layer_opacity_original(layer, sel, value);
    if (changed) hm_diag_add(&hm_diag.appearanceChanges);
}
static void (*hm_tx_begin_original)(id, SEL);
static void (*hm_tx_commit_original)(id, SEL);
static void (*hm_tx_flush_original)(id, SEL);
static void hm_tx_begin(id cls, SEL sel)
{
    if (hm_tx_begin_original != NULL) hm_tx_begin_original(cls, sel);
    hm_diag_add(&hm_diag.txBegin);
}
static void hm_tx_commit(id cls, SEL sel)
{
    if (hm_tx_commit_original != NULL) hm_tx_commit_original(cls, sel);
    hm_diag_add(&hm_diag.txCommit);
}
static void hm_tx_flush(id cls, SEL sel)
{
    if (hm_tx_flush_original != NULL) hm_tx_flush_original(cls, sel);
    hm_diag_add(&hm_diag.txFlush);
}

/* Only a method the class implements itself: class_getInstanceMethod walks the
 * superclasses, and method_setImplementation(NULL, ...) is undefined. The real
 * type encoding is printed once, so a wrapper's C signature can be checked
 * against it. Returns the original IMP (NULL when the method is not this class's). */
static IMP hm_hook(Class cls, const char *name, IMP imp)
{
    unsigned count = 0;
    IMP old = NULL;
    Method install = NULL;
    Method *methods = class_copyMethodList(cls, &count);

    for (unsigned i = 0; i < count; i++) {
        if (strcmp(sel_getName(method_getName(methods[i])), name) != 0) continue;
        install = methods[i];
        old = method_getImplementation(install);
        break;
    }
    if (install == NULL) {
        hm_print("handoff: -[%s %s] is not this class's own method; not installed\n", class_getName(cls), name);
    } else {
        hm_print("handoff: -[%s %s] %s\n", class_getName(cls), name, method_getTypeEncoding(install) ?: "(no encoding)");
        method_setImplementation(install, imp);
    }
    free(methods);
    return old;
}

static void hm_drawable_diagnostics_install(Class layer, Class drawable)
{
    (void)layer;
    (void)drawable;
    if (!hm_handoff_on()) return;
    hm_ca_layers = [[NSMapTable weakToStrongObjectsMapTable] retain];
    hm_ca_queue_type = dlsym(RTLD_DEFAULT, "CAImageQueueGetTypeID");
    hm_ca_queue_pending = dlsym(RTLD_DEFAULT, "CAImageQueueGetUnconsumedImageCount");
    hm_ca_queue_updated = dlsym(RTLD_DEFAULT, "CAImageQueueGetLastUpdateHostTime");
    hm_ca_queue_pixels = dlsym(RTLD_DEFAULT, "CAImageQueueGetDisplayedPixelCount");
    dispatch_source_t monitor = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(monitor, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_MSEC * 50);
    dispatch_source_set_event_handler(monitor, ^{
        @autoreleasepool {
            NSArray *layers;
            @synchronized (hm_ca_layers) { layers = [[[hm_ca_layers keyEnumerator] allObjects] retain]; }
            for (id liveLayer in layers) hm_ca_queue_report(liveLayer);
            [layers release];
            NSArray *contexts = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("CAContext"), sel_getUid("allContexts"));
            for (id context in contexts)
                hm_print("ca-context: context=%p id=%u root=%p commit-id=%u t=%.6f\n", context,
                    ((unsigned (*)(id, SEL))objc_msgSend)(context, sel_getUid("contextId")),
                    ((id (*)(id, SEL))objc_msgSend)(context, @selector(layer)),
                    ((unsigned (*)(id, SEL))objc_msgSend)(context, sel_getUid("commitId")), hm_now());
        }
    });
    dispatch_resume(monitor);
    Class caLayer = objc_getClass("CALayer"), tx = objc_getClass("CATransaction");
    hm_layer_contents_original = (void (*)(id, SEL, id))hm_hook(caLayer, "setContents:", (IMP)hm_layer_contents);
    hm_layer_dirty_original = (void (*)(id, SEL))hm_hook(caLayer, "setContentsChanged", (IMP)hm_layer_dirty);
    hm_layer_hidden_original = (void (*)(id, SEL, BOOL))hm_hook(caLayer, "setHidden:", (IMP)hm_layer_hidden);
    hm_layer_opaque_original = (void (*)(id, SEL, BOOL))hm_hook(caLayer, "setOpaque:", (IMP)hm_layer_opaque);
    hm_layer_opacity_original = (void (*)(id, SEL, float))hm_hook(caLayer, "setOpacity:", (IMP)hm_layer_opacity);
    hm_tx_begin_original = (void (*)(id, SEL))hm_hook(object_getClass(tx), "begin", (IMP)hm_tx_begin);
    hm_tx_commit_original = (void (*)(id, SEL))hm_hook(object_getClass(tx), "commit", (IMP)hm_tx_commit);
    hm_tx_flush_original = (void (*)(id, SEL))hm_hook(object_getClass(tx), "flush", (IMP)hm_tx_flush);
}

#include "HakiosMetalDrawables.h"

@implementation HakiosMetalDevice

/* Declared at +load because Metal loads this bundle and is therefore already in the process; -initWithAcceleratorPort:
 * declares it again for a process that loaded the bundle by hand before asking Metal anything. */
static void
hm_ensure_spi(Class cls)
{
	hm_adopt(cls, objc_getProtocol("MTLDeviceSPI"), "MTLDeviceSPI");
}

+ (void)load
{
	hm_ensure_spi(self);
}

HM_REFUSES_OUT_LOUD

/* OpenGL ES's shaders (see hm_gles_air): Metal's own function object, with the AIR made of its GLES IR kept on it, or
 * nil with the reason -- a GL program that then fails to link, which GL applications check for. Each of the first 16
 * (then every power of two) is said, with its sizes and the inputs description's bytes. */
- (id)hakiosGLESFunction:(id)function ir:(const void *)ir inputs:(dispatch_data_t)inputs type:(NSUInteger)type
{
	static unsigned made;
	char why[256] = "";
	NSString *text = nil;
	const unsigned n = __atomic_fetch_add(&made, 1, __ATOMIC_RELAXED);
	const BOOL say = n < 16 || (n & (n - 1)) == 0;
	const double began = hm_now();
	NSData *air = function != nil ? hm_gles_air(ir, n < 64 ? &text : NULL, why, sizeof(why)) : nil;
	char described[80] = "none";

	hm_gles_active = YES;
	if (inputs != nil) {
		const void *bytes = NULL;
		size_t size = 0;
		dispatch_data_t map = dispatch_data_create_map(inputs, &bytes, &size);
		size_t at = (size_t)snprintf(described, sizeof(described), "%zu bytes", size);

		for (size_t i = 0; i < size && i < 16 && at + 4 < sizeof(described); i++) {
			at += (size_t)snprintf(described + at, sizeof(described) - at, "%s%02x", i ? "" : " ", ((const uint8_t *)bytes)[i]);
		}
		dispatch_release(map);
	}
	if (function == nil) {
		hm_print("gles: refused: function %u (type %lu): _MTLDevice made no function of the GLES IR\n", n, (unsigned long)type);
		return nil;
	}
	if (air == nil) {
		hm_print("gles: refused: function %u (type %lu, GLES IR %u bytes): %s; nil, the GL program will not link\n", n,
			 (unsigned long)type, ir != NULL ? *(const uint32_t *)ir : 0, why);
		[function release];
		return nil;
	}
	objc_setAssociatedObject(function, &hm_gles_key, air, OBJC_ASSOCIATION_RETAIN);
	if (text != nil) objc_setAssociatedObject(function, &hm_gles_text_key, text, OBJC_ASSOCIATION_RETAIN);
	if (say) {
		hm_print("gles: function %u: %s, GLES IR %u bytes (stream version %u) -> AIR %lu bytes in %.1f ms; inputs description %s\n", n,
			 type == MTLFunctionTypeVertex ? "vertex" : type == MTLFunctionTypeFragment ? "fragment" : "of another type",
			 *(const uint32_t *)ir, ((const uint32_t *)ir)[1], (unsigned long)[air length], (hm_now() - began) * 1e3, described);
	}
	return function;
}

- (id)newFunctionWithGLESIR:(const void *)ir inputsDescription:(dispatch_data_t)inputs functionType:(NSUInteger)type
{
	return [self hakiosGLESFunction:[super newFunctionWithGLESIR:ir inputsDescription:inputs functionType:type] ir:ir inputs:inputs type:type];
}

- (id)newFunctionWithGLESIR:(const void *)ir functionType:(NSUInteger)type
{
	return [self hakiosGLESFunction:[super newFunctionWithGLESIR:ir functionType:type] ir:ir inputs:nil type:type];
}

/* Apple's shader sampling (AppleMetalGLRenderer's profiling property): not here; NO, and the renderer says so to GL */
- (BOOL)mapShaderSampleBufferWithBuffer:(void *)buffer capacity:(NSUInteger)capacity size:(NSUInteger)size
{
	(void)buffer;
	(void)capacity;
	(void)size;
	HM_ONCE("Apple's shader sampling (-mapShaderSampleBufferWithBuffer:...) was asked for; not served\n");
	return NO;
}
- (void)unmapShaderSampleBuffer { }

/* An argument encoder for buffer INDEX of FUNCTION, from what the function's AIR says the set holds; nil, said, when it has
 * no set there or the front end refused it. */
static id
hm_function_argument_encoder(id function, NSUInteger index)
{
	NSData *air = hm_bitcode_for(function, nil, NO);
	NSString *name = [(id<MTLFunction>)function name];
	unsigned *ids, *offsets;
	int n;

	n = air != nil ? hakios_metal_argument_buffer_layout([air bytes], [air length], (unsigned)index, NULL, NULL, 0) : -1;
	if (n <= 0) {
		hm_print("refused: an argument encoder for buffer %lu of %s: %s; it returns nil\n", (unsigned long)index,
			 name != nil ? [name UTF8String] : "a function", air != nil ? hakios_metal_error() : "no bitcodeData");
		return nil;
	}
	ids = calloc((size_t)n, sizeof(unsigned));
	offsets = calloc((size_t)n, sizeof(unsigned));
	{
		const int filled = hakios_metal_argument_buffer_layout([air bytes], [air length], (unsigned)index, ids, offsets, (unsigned)n);

		if (filled != n) {
			hm_print("refused: an argument encoder for buffer %lu of %s: its layout read %d members, then %d: %s; it returns nil\n",
				 (unsigned long)index, name != nil ? [name UTF8String] : "a function", n, filled, filled < 0 ? hakios_metal_error() : "");
			free(ids);
			free(offsets);
			return nil;
		}
	}
	id encoder = [[HakiosMetalArgumentEncoder alloc] initWithDevice:[(id<MTLFunction>)function device] ids:ids offsets:offsets
								     count:(NSUInteger)n];
	char source[96];

	snprintf(source, sizeof(source), "buffer %lu of %s", (unsigned long)index, name != nil ? [name UTF8String] : "a function");
	[encoder hakiosSetSource:source];
	free(ids);
	free(offsets);
	return encoder;
}

/*
 * MTLFunction's -newArgumentEncoderWithBufferIndex: (and its reflection: form), for functions of this device. Metal's
 * own builds the encoder from the reflection Apple's GPU compiler writes beside a function; no function here has any,
 * so for every index it asserts "bufferIndex 0 does not identify an argument buffer" and aborts the process -- which
 * is how Resident Evil 4 ended, before its first frame. The class's two methods are wrapped once: a function whose
 * device is this one gets an encoder laid out by the metadata, any other the original's answer.
 */
static void
hm_functions_encode_from_metadata(void)
{
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		Class c = objc_getClass("_MTLFunction");
		SEL plain = sel_getUid("newArgumentEncoderWithBufferIndex:");
		SEL reflected = sel_getUid("newArgumentEncoderWithBufferIndex:reflection:");
		Method m;

		if (c == Nil) {
			hm_print("no _MTLFunction class: argument encoders from functions stay Metal's own\n");
			return;
		}
		if ((m = class_getInstanceMethod(c, plain)) != NULL) {
			id (*original)(id, SEL, NSUInteger) = (id (*)(id, SEL, NSUInteger))method_getImplementation(m);
			method_setImplementation(m, imp_implementationWithBlock(^id(id self, NSUInteger index) {
				if (![[(id<MTLFunction>)self device] isKindOfClass:[HakiosMetalDevice class]]) return original(self, plain, index);
				return hm_function_argument_encoder(self, index);
			}));
		}
		if ((m = class_getInstanceMethod(c, reflected)) != NULL) {
			id (*original)(id, SEL, NSUInteger, id *) = (id (*)(id, SEL, NSUInteger, id *))method_getImplementation(m);
			method_setImplementation(m, imp_implementationWithBlock(^id(id self, NSUInteger index, id *reflection) {
				if (![[(id<MTLFunction>)self device] isKindOfClass:[HakiosMetalDevice class]]) {
					return original(self, reflected, index, reflection);
				}
				if (reflection != NULL) *reflection = nil;   /* no reflection here: the encoder is the whole answer */
				return hm_function_argument_encoder(self, index);
			}));
		}
	});
}

/*
 * Functions CoreAnimation of iOS 16.5 asks its library for that the library given it does not have under that name,
 * each answered with the nearest one it has. iOS 16.5's own QuartzCore default.metallib (tools/ca-metallib.py) has
 * every function its CoreAnimation asks for, so with it nothing here is used; the entries answer an older ca-share
 * (a later CoreAnimation's library), whose luma_boost was missing. A function asked for that the library has is never
 * touched; an entry marked "always" would replace even that, and none is. (hakios)
 */
static const char *const hm_stand_ins[][3] = {
	/* asked for, given instead, "always" when the library's own is the wrong one (not just missing) */
	{ "luma_boost_lph", "inplace_copy_lph", "" },
	{ "luma_boost_lpf", "inplace_copy_lpf", "" },
};
static id (*hm_orig_fn_name)(id, SEL, NSString *);
static id (*hm_orig_fn_constants)(id, SEL, NSString *, MTLFunctionConstantValues *, NSError **);

static NSString *
hm_stand_in(NSString *name, BOOL found)
{
	for (size_t i = 0; name != nil && i < sizeof(hm_stand_ins) / sizeof(hm_stand_ins[0]); i++) {
		if (strcmp([name UTF8String], hm_stand_ins[i][0]) == 0 && (!found || hm_stand_ins[i][2][0] != 0)) {
			return [NSString stringWithUTF8String:hm_stand_ins[i][1]];
		}
	}
	return nil;
}

/* GCD copies the block (including self and the completion block). Mutable API
 * inputs are copied before enqueueing; all results/errors live through the callback. */
static void
hm_creation_async(dispatch_block_t work)
{
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		@autoreleasepool { work(); }
	});
}

static void
hm_fn_constants_async(id self, SEL sel, NSString *name, MTLFunctionConstantValues *values,
                      void (^handler)(id<MTLFunction>, NSError *))
{
	(void)sel;
	name = [name copy];
	values = [values copy];
	hm_creation_async(^{
		NSError *error = nil;
		id function = [(id<MTLLibrary>)self newFunctionWithName:name constantValues:values error:&error];
		if (handler != NULL) handler(function, error);
		[function release];
	});
	[name release];
	[values release];
}

static void
hm_fn_descriptor_async(id self, SEL sel, MTLFunctionDescriptor *descriptor,
                       void (^handler)(id<MTLFunction>, NSError *))
{
	const BOOL intersection = sel == @selector(newIntersectionFunctionWithDescriptor:completionHandler:);
	descriptor = [descriptor copy];
	hm_creation_async(^{
		NSError *error = nil;
		id function = intersection ? [(id<MTLLibrary>)self newIntersectionFunctionWithDescriptor:(id)descriptor error:&error]
		                           : [(id<MTLLibrary>)self newFunctionWithDescriptor:descriptor error:&error];
		if (handler != NULL) handler(function, error);
		[function release];
	});
	[descriptor release];
}

static id
hm_fn_name(id self, SEL sel, NSString *name)
{
	id f = hm_orig_fn_name(self, sel, name);
	NSString *other = hm_stand_in(name, f != nil);

	if (other != nil) {
		[f release];
		f = hm_orig_fn_name(self, sel, other);
	}
	if (other != nil && f != nil) {
		HM_ONCE("the library has no %s: %s stands in for it\n", [name UTF8String], [other UTF8String]);
	}
	return f;
}

static id
hm_fn_constants(id self, SEL sel, NSString *name, MTLFunctionConstantValues *values, NSError **error)
{
	id f = hm_orig_fn_constants(self, sel, name, values, error);
	NSString *other = hm_stand_in(name, f != nil);

	if (other != nil) {
		[f release];
		f = hm_orig_fn_constants(self, sel, other, values, error);
	}
	if (other != nil && f != nil) {
		if (error != NULL) *error = nil;
		HM_ONCE("the library has no %s: %s stands in for it (with constants)\n", [name UTF8String], [other UTF8String]);
	}
	return f;
}

#ifdef HAKIOS_UMI
static id (*hm_ca_url2)(id, SEL, id, id);
static id (*hm_ca_url3)(id, SEL, id, id, id);
static id hm_ca_default_url(id bundle, id name, id ext, id found) {
    if (found == nil && [name isEqual:@"default"] && [ext isEqual:@"metallib"] &&
        [[bundle bundlePath] rangeOfString:@"QuartzCore.framework"].location != NSNotFound) {
        return [NSURL fileURLWithPath:@"/redwood/share/ca-share/QuartzCore-default.metallib"];
    }
    return found;
}
static id hm_ca_get_url2(id self, SEL cmd, id name, id ext) {
    return hm_ca_default_url(self, name, ext, hm_ca_url2(self, cmd, name, ext));
}
static id hm_ca_get_url3(id self, SEL cmd, id name, id ext, id dir) {
    return hm_ca_default_url(self, name, ext, hm_ca_url3(self, cmd, name, ext, dir));
}
#endif

static void
hm_library_stand_ins(void)
{
	static dispatch_once_t once;

	dispatch_once(&once, ^{
#ifdef HAKIOS_UMI
        Method u2 = class_getInstanceMethod([NSBundle class], @selector(URLForResource:withExtension:));
        Method u3 = class_getInstanceMethod([NSBundle class], @selector(URLForResource:withExtension:subdirectory:));
        if (u2) hm_ca_url2 = (void *)method_setImplementation(u2, (IMP)hm_ca_get_url2);
        if (u3) hm_ca_url3 = (void *)method_setImplementation(u3, (IMP)hm_ca_get_url3);
#endif
		Class library = NSClassFromString(@"_MTLLibrary");
		Method a = library ? class_getInstanceMethod(library, @selector(newFunctionWithName:)) : NULL;
		Method b = library ? class_getInstanceMethod(library, @selector(newFunctionWithName:constantValues:error:)) : NULL;

		class_replaceMethod(library, @selector(newFunctionWithName:constantValues:completionHandler:),
		                    (IMP)hm_fn_constants_async, "v@:@@@?");
		class_replaceMethod(library, @selector(newFunctionWithDescriptor:completionHandler:),
		                    (IMP)hm_fn_descriptor_async, "v@:@@?");
		class_replaceMethod(library, @selector(newIntersectionFunctionWithDescriptor:completionHandler:),
		                    (IMP)hm_fn_descriptor_async, "v@:@@?");
		if (a != NULL) hm_orig_fn_name = (id (*)(id, SEL, NSString *))method_setImplementation(a, (IMP)hm_fn_name);
		if (b != NULL) hm_orig_fn_constants = (id (*)(id, SEL, NSString *, MTLFunctionConstantValues *, NSError **))
			method_setImplementation(b, (IMP)hm_fn_constants);
	});
}

/*
 * (hakios) boot-arg ca_prof=US, the window server: every US microseconds every thread of the process is looked at
 * -- running or waiting -- and its stack taken (the program counter, the link register, the frame chain); every
 * CA_PROF_DUMP looks the most frequent stacks of each named thread go to the log as "ca-prof: THREAD N%: ...", with
 * the image and offset of each address. Where CoreAnimation's render loop waits on the Metal road is what this is for.
 */
#define CA_PROF_SLOTS   4096
#define CA_PROF_DUMP    400
#define CA_PROF_DEPTH   10
static unsigned ca_prof_us;
static struct {
	char name[32];
	uint64_t stack[CA_PROF_DEPTH];
	unsigned count;
} ca_prof_table[CA_PROF_SLOTS];

static int
ca_prof_order(const void *a, const void *b)
{
	const typeof(ca_prof_table[0]) *x = a, *y = b;
	int byname = strcmp(x->name, y->name);

	return byname != 0 ? byname : (int)y->count - (int)x->count;
}

static void *
ca_prof_main(__unused void *argument)
{
	unsigned looks = 0;
	thread_t self = mach_thread_self();

	for (;;) {
		thread_act_array_t threads;
		mach_msg_type_number_t n = 0;

		usleep(ca_prof_us);
		if (task_threads(mach_task_self(), &threads, &n) != KERN_SUCCESS) {
			continue;
		}
		looks++;
		for (mach_msg_type_number_t t = 0; t < n; t++) {
			thread_extended_info_data_t ext;
			mach_msg_type_number_t count = THREAD_EXTENDED_INFO_COUNT;
			arm_thread_state64_t state;
			mach_msg_type_number_t state_count = ARM_THREAD_STATE64_COUNT;
			uint64_t stack[CA_PROF_DEPTH] = { 0 }, hash = 0;

			if (threads[t] == self || thread_info(threads[t], THREAD_EXTENDED_INFO, (thread_info_t)&ext, &count) != KERN_SUCCESS ||
			    thread_suspend(threads[t]) != KERN_SUCCESS) {
				mach_port_deallocate(mach_task_self(), threads[t]);
				continue;
			}
			kern_return_t got = thread_get_state(threads[t], ARM_THREAD_STATE64, (thread_state_t)&state, &state_count);
			if (got == KERN_SUCCESS) {
				uint64_t sp = arm_thread_state64_get_sp(state), fp = arm_thread_state64_get_fp(state), top = 0;
				pthread_t pt = pthread_from_mach_thread_np(threads[t]);

				/* the frame chain is followed only within the thread's own stack (another thread's frame pointer
				 * read blindly faulted the window server: SIGSEGV, logs/155201-run.log) */
				if (pt != NULL) top = (uint64_t)(uintptr_t)pthread_get_stackaddr_np(pt);
				stack[0] = arm_thread_state64_get_pc(state);
				stack[1] = arm_thread_state64_get_lr(state);
				for (unsigned d = 2; d < CA_PROF_DEPTH && top != 0 && fp >= sp && fp + 16 <= top && (fp & 15) == 0; d++) {
					const uint64_t *record = (const uint64_t *)(uintptr_t)fp;

					stack[d] = record[1];
					if (record[0] <= fp) break;
					fp = record[0];
				}
			}
			thread_resume(threads[t]);
			mach_port_deallocate(mach_task_self(), threads[t]);
			if (got != KERN_SUCCESS) continue;
			for (unsigned d = 0; d < CA_PROF_DEPTH; d++) hash = (hash ^ stack[d]) * 0x9e3779b97f4a7c15ull;
			for (size_t c = 0; ext.pth_name[c] != 0; c++) hash = (hash ^ (uint8_t)ext.pth_name[c]) * 0x100000001b3ull;
			for (unsigned i = (unsigned)(hash >> 32) % CA_PROF_SLOTS, probes = 0; probes < CA_PROF_SLOTS; i = (i + 1) % CA_PROF_SLOTS, probes++) {
				if (ca_prof_table[i].count == 0 || (memcmp(ca_prof_table[i].stack, stack, sizeof(stack)) == 0 &&
				    strncmp(ca_prof_table[i].name, ext.pth_name, sizeof(ca_prof_table[i].name)) == 0)) {
					memcpy(ca_prof_table[i].stack, stack, sizeof(stack));
					strlcpy(ca_prof_table[i].name, ext.pth_name[0] ? ext.pth_name : "(unnamed)", sizeof(ca_prof_table[i].name));
					ca_prof_table[i].count++;
					break;
				}
			}
		}
		vm_deallocate(mach_task_self(), (vm_address_t)threads, n * sizeof(thread_t));
		if (looks < CA_PROF_DUMP) continue;
		qsort(ca_prof_table, CA_PROF_SLOTS, sizeof(ca_prof_table[0]), ca_prof_order);
		hm_print("ca-prof: %u looks at every thread\n", looks);
		for (unsigned i = 0, shown = 0; i < CA_PROF_SLOTS; i++) {
			char line[1400];
			int at;

			if (ca_prof_table[i].count == 0 || (i > 0 && strcmp(ca_prof_table[i].name, ca_prof_table[i - 1].name) == 0 && ++shown > 4)) continue;
			if (i == 0 || strcmp(ca_prof_table[i].name, ca_prof_table[i - 1].name) != 0) shown = 0;
			if (strstr(ca_prof_table[i].name, "render") == NULL && strstr(ca_prof_table[i].name, "coreanimation") == NULL &&
			    strstr(ca_prof_table[i].name, "hakios") == NULL && strcmp(ca_prof_table[i].name, "(unnamed)") != 0) continue;
			at = snprintf(line, sizeof(line), "ca-prof: %s %.0f%%:", ca_prof_table[i].name, 100.0 * ca_prof_table[i].count / looks);
			for (unsigned d = 0; d < CA_PROF_DEPTH && ca_prof_table[i].stack[d] != 0 && at < (int)sizeof(line) - 80; d++) {
				Dl_info where = { 0 };
				const char *image = "?", *slash;
				uint64_t offset = ca_prof_table[i].stack[d];

				if (dladdr((void *)(uintptr_t)offset, &where) != 0 && where.dli_fname != NULL) {
					image = (slash = strrchr(where.dli_fname, '/')) != NULL ? slash + 1 : where.dli_fname;
					offset -= (uint64_t)(uintptr_t)where.dli_fbase;
				}
				at += snprintf(line + at, sizeof(line) - (size_t)at, " %s+0x%llx(%s)", image, (unsigned long long)offset,
					       where.dli_sname != NULL ? where.dli_sname : "?");
			}
			hm_print("%s\n", line);
		}
		memset(ca_prof_table, 0, sizeof(ca_prof_table));
		looks = 0;
	}
	return NULL;
}

static void
ca_prof_start(void)
{
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		char args[1024] = "";
		size_t size = sizeof(args) - 1;
		const char *at;
		pthread_t sampler;

		if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) != 0 || (at = strstr(args, "ca_prof=")) == NULL) return;
		ca_prof_us = (unsigned)atoi(at + 8);
		if (ca_prof_us == 0) return;
		pthread_create(&sampler, NULL, ca_prof_main, NULL);
		hm_print("ca-prof: every thread looked at every %u us\n", ca_prof_us);
	});
}

/* UniXNU's Metal on Vulkan (NativeBridgeMetalFrontend.h), there when the bundle is linked with it (M2V=1) */
extern id native_bridge_metal_open(const char *loader, const char *cache, uint64_t registryID,
				   void (*missing)(const char *, const char *)) __attribute__((weak_import));
extern uint64_t native_bridge_metal_first_problem(char *out, size_t size) __attribute__((weak_import));
extern size_t native_bridge_metal_status(char *out, size_t size) __attribute__((weak_import));
extern size_t native_bridge_metal_formats(char *out, size_t size) __attribute__((weak_import));
extern const void *(*native_bridge_metal_variant_hook)(const char *, const char *, const char *, int, size_t *) __attribute__((weak_import));
static const void *hm_m2v_variant(const char *name, const char *label, const char *pipeline, int vertex, size_t *length);

static char hm_m2v_last_stderr[400];   /* the last line of Turnip's or the runtime's that said error, refused or warning */

static void
hm_m2v_missing(const char *class, const char *selector)
{
	hm_print("metal2vulkan: no -[%s %s]\n", class, selector);
}

static bool
hm_boot_arg_set(const char *what)
{
	return hm_ca_arg(what);
}

- (instancetype)initWithAcceleratorPort:(io_service_t)port
{
	/* (hakios) every process is shown the device (2026-11-10, after the metal_all=1 trial: METAL-ALL-umi.md).
	 * The window-server-only whitelist made PencilKit (Notes) abort on a nil device. */
	/* (hakios) metal_m2v=1: the device is UniXNU's Metal on Vulkan instead (AdrenoMetal's frontend over metal2vulkan
	 * over Turnip, tools/mk-m2v.sh; linked in by userland/build.sh M2V=1): its own objects, from the device down */
	if (native_bridge_metal_open != NULL && hm_boot_arg_set("metal_m2v=1")) {
		/* boot-arg tu_debug=FLAGS[,FLAGS]: Turnip's TU_DEBUG in the window server (sysmem, gmem, forcebin, ...) */
		{
			char args[1024] = "", value[64] = "";
			size_t size = sizeof(args) - 1;
			const char *at;

			if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && (at = strstr(args, "tu_debug=")) != NULL) {
				strlcpy(value, at + 9, sizeof(value));
				value[strcspn(value, " ")] = 0;
				setenv("TU_DEBUG", value, 1);
				hm_print("metal2vulkan: TU_DEBUG=%s\n", value);
			}
		}
		/* Turnip's and the runtime's own messages (stderr) into this log: the first 200 lines */
		{
			static int pipe_fds[2];

			hm_print("metal2vulkan: stderr into this log\n");    /* (hm_print_fd decided first: then kept aside from fd 2) */
			if (hm_print_fd == 2) {
				hm_print_fd = dup(2);
			}
			if (pipe(pipe_fds) == 0 && dup2(pipe_fds[1], 2) >= 0) {
				dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
					FILE *in = fdopen(pipe_fds[0], "r");
					char line[400];
					int lines = 0;

					while (in != NULL && fgets(line, sizeof(line), in) != NULL) {
						/* each distinct line once (digits aside), at most 120 of them */
						static uint32_t seen[512];
						static int distinct;
						uint32_t h = 2166136261u;
						for (const char *c = line; *c; c++) {
							if (*c < '0' || *c > '9') h = (h ^ (uint8_t)*c) * 16777619u;
						}
						bool fresh = true;
						for (int i = 0; i < distinct; i++) {
							if (seen[i] == h) { fresh = false; break; }
						}
						if (fresh && distinct < 512) seen[distinct++] = h;
						if (fresh && (lines++ < 40 || ((strstr(line, "metal2vulkan:") != NULL || strstr(line, "TU: ") != NULL) && distinct < 160))) {
							hm_print("stderr: %s", line);
						}
						if (strcasestr(line, "error") || strcasestr(line, "refus") || strcasestr(line, "warn")) {
							strlcpy(hm_m2v_last_stderr, line, sizeof(hm_m2v_last_stderr));
						}
					}
				});
			}
		}
		/* boot-arg m2v_utrace=1: Turnip's GPU trace of every render pass (u_trace) into a file, printed during the run */
		if (hm_boot_arg_set("m2v_utrace=1")) {
			setenv("MESA_GPU_TRACES", "print", 1);
			setenv("MESA_GPU_TRACEFILE", "/private/var/tmp/m2v-utrace.txt", 1);
		}
		if (&native_bridge_metal_variant_hook != NULL) {
			native_bridge_metal_variant_hook = hm_m2v_variant;
		}
		mkdir("/private/var/db/m2v", 0700);
		id device = native_bridge_metal_open("/redwood/lib/libvulkan_freedreno.dylib",
		    access("/private/var/db/m2v", W_OK) == 0 ? "/private/var/db/m2v" : "/private/var/tmp/m2v", 0, hm_m2v_missing);
		if (device != nil) {
			hm_print("device: %s (metal2vulkan over Turnip, class %s)\n", [[device name] UTF8String],
				 object_getClassName(device));
			/* QuartzCore's pipeline library opened as for hakios-metal's device (this class's method, onto the
			 * metal2vulkan device's class: it calls _MTLDevice's own, both devices' base): its pipelines then
			 * carry the labels whose variants hm_m2v_variant() finds. Its cache wants the device's target, which
			 * the frontend leaves to _MTLDevice (NULL): the name without spaces, as Metal names a device's. */
			{
				Class nb = object_getClass(device);
				SEL open = @selector(newPipelineLibraryWithFilePath:error:);
				Method ours = class_getInstanceMethod([self class], open);
				static struct MTLTargetDeviceArch target;
				static char name[64];

				snprintf(name, sizeof(name), "%s", [[[device name] stringByReplacingOccurrencesOfString:@" " withString:@""] UTF8String]);
				target.name = name;
				if (ours != NULL) {
					class_replaceMethod(nb, open, method_getImplementation(ours), method_getTypeEncoding(ours));
				}
				class_replaceMethod(nb, @selector(targetDeviceInfo),
				    imp_implementationWithBlock(^const struct MTLTargetDeviceArch *(id me) { (void)me; return &target; }), "^v16@0:8");
			}
			/* what it did, every 5 s: commits, passes, draws, refusals; the textures and the surfaces imported */
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
				for (;;) {
					char status[600] = "", formats[300] = "";
					sleep(5);
					native_bridge_metal_status(status, sizeof(status));
					native_bridge_metal_formats(formats, sizeof(formats));
					hm_print("metal2vulkan: %s | %s\n", status, formats);
					if (hm_m2v_last_stderr[0] != 0) {
						hm_print("metal2vulkan: last stderr: %s", hm_m2v_last_stderr);
					}
					/* the GPU trace (m2v_utrace=1): each kind of event since the last status, counted, at the 16th to the
					 * 34th status (the gestures), the 30 commonest */
					{
						static int tick;
						static long read_to;
						FILE *trace = fopen("/private/var/tmp/m2v-utrace.txt", "r");
						++tick;
						if (trace != NULL) {
							char line[400];
							NSCountedSet *kinds = (tick >= 16 && tick <= 34) ? [NSCountedSet set] : nil;
							fseek(trace, read_to, SEEK_SET);
							while (fgets(line, sizeof(line), trace) != NULL) {
								char *at = strstr(line, ": ");
								if (kinds == nil || at == NULL) continue;
								at += 2;
								at[strcspn(at, "\n")] = 0;
								if (strncmp(at, "end_", 4) == 0) continue;
								[kinds addObject:@(at)];
							}
							read_to = ftell(trace);
							fclose(trace);
							if ([kinds count] > 0) {
								NSArray *sorted = [[kinds allObjects] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
									return [@([kinds countForObject:b]) compare:@([kinds countForObject:a])];
								}];
								for (NSUInteger i = 0; i < [sorted count] && i < 30; i++) {
									hm_print("utrace %d: %6lu %s\n", tick, (unsigned long)[kinds countForObject:sorted[i]],
										 [[sorted[i] substringToIndex:MIN([sorted[i] length], 200)] UTF8String]);
								}
							}
						}
					}
					/* the textures the runtime keeps a shadow image of, and why (its shadow.log): the first 40 */
					{
						static long read_to;
						static int told;
						FILE *log = fopen("/private/var/db/m2v/shadow.log", "r");
						char line[600];

						if (log == NULL) log = fopen("/private/var/tmp/m2v/shadow.log", "r");
						if (log != NULL) {
							fseek(log, read_to, SEEK_SET);
							while (told < 40 && fgets(line, sizeof(line), log) != NULL) {
								hm_print("metal2vulkan: shadow: %s", line);
								told++;
							}
							read_to = ftell(log);
							fclose(log);
						}
					}
				}
			});
			return [device retain];  /* (self not released: before -init, _MTLDevice's -dealloc reads what -init never set) */
		}
		char problem[256] = "";
		native_bridge_metal_first_problem(problem, sizeof(problem));
		hm_print("no metal2vulkan device (%s): hakios-metal's instead\n", problem);
	}
	hm_library_stand_ins();
	ca_prof_start();
	/* (hakios) the window server's compiled stages kept on disk (hakios-metal: compileStage's cache), so that a
	 * CoreAnimation shader compiled once is not compiled again by the next window server; and no listings.
	 * In /var/db, not /var/tmp: var_store (var_store=1 ufs_write=1) keeps /private/var across boots but leaves tmp
	 * out by design, so a cache in /var/tmp started empty at every boot and the first minute of every boot paid the
	 * 66 to 103 compiles again. A cache in the image (HM_CACHE_SEED, read-only, put there by
	 * tools/metal-cache-seed.sh from an earlier boot's) is looked in after it and never written. */
	/* (the skeleton makes HM_CACHE_DIR 1777, init.c from var.skel; an image without that line, or a process that may not
	 * write there, falls back on /var/tmp as before: a cache for this boot only is better than none) */
	mkdir(HM_CACHE_DIR, 01777);
	setenv("HAKIOS_METAL_CACHE", access(HM_CACHE_DIR, W_OK | X_OK) == 0 ? HM_CACHE_DIR : (mkdir("/var/tmp/hakios-metal-cache", 0755),
												 "/var/tmp/hakios-metal-cache"), 0);
	{
		struct stat st;

		if (stat(HM_CACHE_SEED, &st) == 0 && S_ISDIR(st.st_mode)) {
			setenv("HAKIOS_METAL_CACHE_SEED", HM_CACHE_SEED, 0);
		}
	}
	setenv("HAKIOS_METAL_LISTING", "0", 0);
	hakios_metal_perf_enable(hm_fps_on());
	hm_drawables_install();
	if (hm_fps_on()) {
		hm_print("stage-cache: build=%s writable=%s seed=%s\n", hakios_metal_stage_cache_build(),
			 getenv("HAKIOS_METAL_CACHE"), getenv("HAKIOS_METAL_CACHE_SEED") ?: "(none)");
	}
	{
		char executable[4096];
		uint32_t length = sizeof(executable);
		if (_NSGetExecutablePath(executable, &length) == 0 && hakios_metal_stage_cache_set_process(executable)) {
			hm_print("stage-prewarm: enabled, replay queued\n");
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
				@autoreleasepool { hakios_metal_stage_cache_prewarm(); }
			});
		}
	}
	hm_ensure_spi([self class]);
	hm_functions_encode_from_metadata();
	self = [super init];
	if (self == nil) {
		return nil;
	}
	_acceleratorService = port;
	if (port != IO_OBJECT_NULL) {
		IOObjectRetain(port);
	}
	/*
	 * No GPU, no device. hakios-metal opens the kernel's HakiosGPU client, which exists only when the kernel has
	 * started the Adreno (boot-arg gpu=1, firmware in fw/). Returning nil here makes Metal skip the service -- its
	 * MTLRegisterDevices does so silently, which is why the reason is printed first -- and every process then takes
	 * the software road it takes today. The alternative, a device that exists and refuses every buffer, was measured
	 * worse than none: it lets CoreAnimation choose the Metal road and abort on it.
	 */
	_gpu = hakios_metal_open();
	if (_gpu == NULL) {
		hm_print("no device: %s\n", hakios_metal_error());
		[self release];
		return nil;
	}
	/* Without this the device inherits _MTLDevice's own name, "Apple GPU": true of the code, false of the hardware.
	 * The chip id is asked of the kernel (hakios-metal reads it off the GPU's parameters), not written down. */
	_name = [[NSString alloc] initWithFormat:@"Adreno (hakios-metal, chip %#llx)", (unsigned long long)hakios_metal_gpu_id(_gpu)];
	/* The struct -targetDeviceInfo answers by pointer, filled once here where nobody can have asked yet: the name
	 * with its spaces removed is Apple's own rule for a device that does not answer, and the bytes are copied into
	 * the object because the pointer is handed out for as long as the device lives. */
	snprintf(_targetName, sizeof(_targetName), "%s",
		 [[_name stringByReplacingOccurrencesOfString:@" " withString:@""] UTF8String]);
	_target.target = 0;
	_target.version = 0;
	_target.name = _targetName;
	hm_print("device: %s on IOAcceleratorES service %#x; the compiler is %s; feature profile 1 (Apple1, Apple2 and "
		 "Common1); pipelines.%s is the precompiled pipeline library Metal will look for and not find\n",
		 [_name UTF8String], (unsigned)port,
		 hakios_metal_has_compiler() ? "in this build" : "NOT in this build (make ios MESA=1): every pipeline will be refused",
		 _targetName);
	hm_gles_gate(port);
	return self;
}

- (void)dealloc
{
	if (_gpu != NULL) {
		hakios_metal_close(_gpu);
	}
	if (_acceleratorService != IO_OBJECT_NULL) {
		IOObjectRelease(_acceleratorService);
	}
	[_name release];
	[super dealloc];
}

- (hakios_metal_device *)hakiosDevice { return _gpu; }

/* The profile is what -[_MTLDevice initLimits] switches on: measured on the phone, 0, 1 and 4 to 9 fill the limits
 * table and 2, 3 and 10 to 12 abort inside Apple on _limits.maxColorAttachments > 0. 0 claims only Apple1 and Common1
 * in -supportsFamily:, and that cost SpringBoard its life: MPSDevice::GetMPSDevice asks for Apple8 down to Apple2
 * (1008 .. 1002) and, with none, MPSKernel's init reports "device is not supported" through MTLReportFailure, which
 * aborts -- from the Siri orb SpringBoard builds at startup (logs/202838-run.log, seven crashes in a row). 1 claims
 * Apple1, Apple2 and Common1 (measured: the line at the first queue), the least that MPS takes; the render test passes
 * as with 0, and SpringBoard then finishes its startup and stays up (logs/203759-run.log). What Apple2 promises beyond
 * Apple1 that is not served -- ASTC, say -- is refused where it is asked for, by name, as everything else is. */
- (NSUInteger)featureProfile { return 1; }

/* Not measured: nothing has asked the kernel what one allocation may be. It only has to be non-zero for initLimits
 * to accept it; a buffer longer than the kernel gives is refused at -newBufferWithLength:options:, with the reason. */
- (uint64_t)maxBufferLength { return 256ULL << 20; }

/* Sysmem colour and depth/stencil attachments, with colour resolve on store. */
- (BOOL)supportsSampleCount:(NSUInteger)count { return count == 1 || count == 2 || count == 4; }

/* profile 0's own maxVertexAmplificationCount is 1 */
- (BOOL)supportsVertexAmplificationCount:(NSUInteger)count { return count <= 1; }

/* No render target here is rotated: the RB writes rows as they lie, and a turned framebuffer is drawn upright and laid
 * in by the 2D engine (-newTextureWithDescriptor:iosurface:plane:). backboardd does not ask this before it makes one --
 * it set rotation 3 over the display surface with NO answered here as well -- so the answer is the truth for whoever
 * does ask, not what keeps backboardd going. */
- (BOOL)supportsRenderTargetTextureRotation { return NO; }

/* The answer that cannot be nil: see the header. A zeroed struct with an empty name is what Metal's own second cache
 * (the one for `functions`) builds for itself, which is the measurement that says this shape is acceptable; the pipeline
 * cache file then fails to open, Metal fills an NSError "Could not open pipeline cache file" and QuartzCore carries on. */
- (const struct MTLTargetDeviceArch *)targetDeviceInfo
{
	if (_target.name == NULL) {
		_target.name = _targetName;   /* an object built with plain -init: the array is zeroed, so it spells "" */
	}
	HM_ONCE("targetDeviceInfo was asked for (pipelines.%s); answered with a real struct because _MTLDevice's own "
		"answer is a NULL its caller dereferences\n", _target.name);
	return &_target;
}

- (NSString *)name { return _name != nil ? _name : @"Adreno (hakios-metal; no GPU)"; }

/* what, then the images and offsets of the calls that led here: for finding whose object a refusal or a free is */
static void
hm_print_callers(const char *what)
{
	void *frames[12];
	int n = backtrace(frames, 12);
	char line[1024];
	size_t at = (size_t)snprintf(line, sizeof(line), "%s", what);

	for (int i = 2; i < n && at < sizeof(line) - 64; i++) {
		Dl_info info;
		if (dladdr(frames[i], &info) != 0 && info.dli_fname != NULL) {
			const char *base = strrchr(info.dli_fname, '/');
			at += (size_t)snprintf(line + at, sizeof(line) - at, " %s+%#lx", base != NULL ? base + 1 : info.dli_fname,
					       (unsigned long)((uintptr_t)frames[i] - (uintptr_t)info.dli_fbase));
		}
	}
	hm_print("%s\n", line);
}

/* A pipeline library (a .pipelinelib directory: pipelines.desc naming each pipeline's functions, formats and state, and
 * one file of compiled pipelines per Apple GPU) is how ActivityRingsUI -- the Fitness widget's rings -- and QuartzCore
 * build their pipelines: -newRenderPipelineStateWithName:... turns pipelines.desc into an ordinary descriptor and hands
 * it to -newRenderPipelineStateWithDescriptor:options:reflection:error:, which this plug-in serves from the functions.
 * Metal's loader will not get that far without a compiled-pipeline file for this GPU, which no library has: it fails
 * with "Could not open pipeline cache file: <path>", the widget gets nil and draws with no pipeline.
 *
 * So the library is opened again from a copy of its directory in this process's temporary directory: pipelines.desc,
 * functions and the .metallib files beside it as symbolic links, and as the missing file an empty cache that Metal's own
 * _MTLPipelineCache writes (readOnly:NO, then -write), so no byte of its format is spelled here. An empty cache answers
 * every lookup with a miss, which is the truth: nothing is precompiled for this GPU. */
- (id)newPipelineLibraryWithFilePath:(NSString *)path error:(NSError **)error
{
	NSError *first = nil;
	id library = [super newPipelineLibraryWithFilePath:path error:&first];
	NSString *message, *missing, *mirror, *parent;
	NSFileManager *fm = [NSFileManager defaultManager];
	NSRange at;
	Class cacheClass = NSClassFromString(@"_MTLPipelineCache");
	id cache;

	if (library != nil || path == nil) {
		if (error != NULL) *error = first;
		return library;
	}
	message = [first localizedDescription];
	at = message != nil ? [message rangeOfString:@"Could not open pipeline cache file: "] : NSMakeRange(NSNotFound, 0);
	if (at.location == NSNotFound || cacheClass == Nil) {
		/* no pipelines.desc is a directory that is no pipeline library (mediaserverd asks of a .bundle holding a
		 * default.metallib alone): Metal's own answer, as an Apple GPU would get, and nothing this device lacks */
		const BOOL notALibrary = message != nil && [message rangeOfString:@"pipelines.desc"].location != NSNotFound;
		hm_print("%s a pipeline library at %s: %s\n", notALibrary ? "no" : "refused:", [path fileSystemRepresentation],
			 message != nil ? [message UTF8String] : "no reason given");
		if (error != NULL) *error = first;
		return nil;
	}
	missing = [[message substringFromIndex:NSMaxRange(at)] lastPathComponent];
	parent = [path stringByDeletingLastPathComponent];
	mirror = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"hakios-pipelinelib"]
		  stringByAppendingPathComponent:[NSString stringWithFormat:@"%lx", (unsigned long)[path hash]]];
	NSString *frame = [mirror stringByAppendingPathComponent:[parent lastPathComponent]];
	NSString *copy = [frame stringByAppendingPathComponent:[path lastPathComponent]];
	[fm createDirectoryAtPath:copy withIntermediateDirectories:YES attributes:nil error:NULL];
	/* the library's own files, and the libraries its descriptions name, which are found beside it */
	for (NSString *entry in [fm contentsOfDirectoryAtPath:path error:NULL]) {
		if ([entry isEqualToString:@"pipelines.desc"] || [entry isEqualToString:@"functions"]) {
			[fm createSymbolicLinkAtPath:[copy stringByAppendingPathComponent:entry]
				 withDestinationPath:[path stringByAppendingPathComponent:entry] error:NULL];
		}
	}
	for (NSString *entry in [fm contentsOfDirectoryAtPath:parent error:NULL]) {
		if ([[entry pathExtension] isEqualToString:@"metallib"]) {
			[fm createSymbolicLinkAtPath:[frame stringByAppendingPathComponent:entry]
				 withDestinationPath:[parent stringByAppendingPathComponent:entry] error:NULL];
		}
	}
	/* QuartzCore's of this image (the iPhone X's) has no default.metallib beside it: the flash image leaves it out. The
	 * same IPSW's own (tools/ca-metallib.py copies it, unchanged) is put there, from where the image puts it */
	NSString *ours = @"/redwood/share/ca-share/QuartzCore-default.metallib";
	NSString *beside = [frame stringByAppendingPathComponent:@"default.metallib"];
	if ([path rangeOfString:@"QuartzCore.framework"].location != NSNotFound && ![fm fileExistsAtPath:beside] &&
	    [fm fileExistsAtPath:ours]) {
		[fm createSymbolicLinkAtPath:beside withDestinationPath:ours error:NULL];
		hm_print("QuartzCore's pipeline library is given %s as its default.metallib\n", [ours fileSystemRepresentation]);
	}
	NSString *cachePath = [copy stringByAppendingPathComponent:missing];
	if (![fm fileExistsAtPath:cachePath]) {
		cache = ((id (*)(id, SEL, NSString *, BOOL, const struct MTLTargetDeviceArch *))objc_msgSend)(
			[cacheClass alloc], sel_registerName("initWithFilePath:readOnly:deviceInfo:"), cachePath, NO, [self targetDeviceInfo]);
		if (cache != nil && [cache respondsToSelector:sel_registerName("write")]) {
			((void (*)(id, SEL))objc_msgSend)(cache, sel_registerName("write"));
		}
		[cache release];
	}
	NSError *second = nil;
	library = [super newPipelineLibraryWithFilePath:copy error:&second];
	hm_print("a pipeline library at %s had no %s; opened through %s with an empty cache Metal wrote: %s\n",
		 [path fileSystemRepresentation], [missing UTF8String], [copy fileSystemRepresentation],
		 library != nil ? "it opened" : (second != nil ? [[second localizedDescription] UTF8String] : "nil, no reason given"));
	if (error != NULL) *error = library != nil ? nil : (second != nil ? second : first);
	return library;
}

- (uint64_t)registryID
{
	uint64_t entry = 0;

	if (_acceleratorService != IO_OBJECT_NULL && IORegistryEntryGetRegistryEntryID(_acceleratorService, &entry) == KERN_SUCCESS) {
		return entry;
	}
	return 0;
}

/* true of this SoC: the GPU reads the same DRAM the processor does, and every buffer here is mapped on both sides */
- (BOOL)hasUnifiedMemory { return YES; }

- (BOOL)supportsTextureSampleCount:(NSUInteger)count { return count == 1 || count == 2 || count == 4; }


/* the GPU memory this device has allocated and not given back (hakios-metal counts every buffer it asks the kernel
 * for); Resident Evil 4 sizes what it keeps resident by it */
- (NSUInteger)currentAllocatedSize
{
	return _gpu != NULL ? (NSUInteger)hakios_metal_device_allocated_bytes(_gpu) : 0;
}

/* 1024 is the A6xx threadgroup limit and the NDRANGE fields' width (hakios-metal's compute::kMaxLocalThreads); each
 * dimension alone may be that large, the product may not, and the dispatch refuses one that is, by name */
- (MTLSize)maxThreadsPerThreadgroup { return MTLSizeMake(1024, 1024, 1024); }

/* --- command queues --- */

/* Apple's own -newCommandQueue and -newCommandQueueWithMaxCommandBufferCount: build a descriptor and end here. The
 * base class validates the descriptor and refuses nil, so a direct call with nil gets one made for it. The descriptor
 * class is private in iOS 16.5 (the SDK only forward-declares it), so it is taken from the runtime by name. */
- (id)newCommandQueueWithDescriptor:(id)descriptor
{
	{
		/* what the profile makes the base class claim, once: the families an MPS or a CoreAnimation decides by (asked at the
		 * first queue, not in init: the base class answers from limits MTLAddDevice has not filled yet there -- a NULL read) */
		static const NSInteger families[] = { 1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009, 2001, 2002, 3001, 3002, 3003, 5001 };
		char yes[160] = "";

		for (size_t i = 0; i < sizeof(families) / sizeof(families[0]); i++) {
			if ([(id<MTLDevice>)self supportsFamily:(MTLGPUFamily)families[i]]) {
				char one[8];

				snprintf(one, sizeof(one), " %ld", (long)families[i]);
				strlcat(yes, one, sizeof(yes));
			}
		}
		HM_ONCE("feature profile %lu: supportsFamily answers YES for%s; maxColorAttachments-limited features follow it\n",
			(unsigned long)[self featureProfile], yes[0] ? yes : " none");
	}
	id use = descriptor;

	if (use == nil) {
		Class cls = objc_getClass("MTLCommandQueueDescriptor");

		use = cls != Nil ? [[[cls alloc] init] autorelease] : nil;
		if (use == nil) {
			hm_print("refused: a command queue: no MTLCommandQueueDescriptor class in this Metal to build one from\n");
			return nil;
		}
	}
	return [[HakiosMetalCommandQueue alloc] initWithHakiosDevice:self descriptor:use];
}

- (id)newCommandQueue { return [self newCommandQueueWithDescriptor:nil]; }

- (id)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)count
{
	Class cls = objc_getClass("MTLCommandQueueDescriptor");
	id descriptor = cls != Nil ? [[[cls alloc] init] autorelease] : nil;

	if (descriptor != nil && [descriptor respondsToSelector:@selector(setMaxCommandBufferCount:)]) {
		((void (*)(id, SEL, NSUInteger))objc_msgSend)(descriptor, @selector(setMaxCommandBufferCount:), count);
	}
	return [self newCommandQueueWithDescriptor:descriptor];
}

/* --- buffers --- */

#include "hakios-metal/bo_cache.hpp"

/* Resource allocation only: queue-owned command/slab pools keep their own policy.
 * Cache completed BOs even when Metal's resource wrappers are short-lived. */
static uint64_t
hm_bo_begin(unsigned format, unsigned usage, unsigned kind)
{
	static int enabled = -1;
	int on = __atomic_load_n(&enabled, __ATOMIC_RELAXED);
	if (on < 0) {
		on = access("/var/db/hakios-metal-cache/bo-cache-off", F_OK) != 0;
		__atomic_store_n(&enabled, on, __ATOMIC_RELAXED);
	}
	return hakios_metal_bo_context(on ? hm_bo_key(format, usage, kind) : 0);
}

static void
hm_bo_end(uint64_t previous)
{
	hakios_metal_bo_context(previous);
	if (!hakios_metal_perf_enabled()) return;
	static uint64_t last;
	const uint64_t now = hm_perf_clock(CLOCK_MONOTONIC);
	uint64_t before = __atomic_load_n(&last, __ATOMIC_RELAXED);
	if (now - before < 2000000000ull ||
	    !__atomic_compare_exchange_n(&last, &before, now, NO, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) return;
	if (before == 0) return;
	uint64_t s[HM_BO_STAT_COUNT];
	hakios_metal_bo_cache_take(s);
	hm_print("bo-cache: window %.1f ms allocations %llu hits %llu new %llu fit %llu waste %llu KiB maps %llu unmaps %llu evictions %llu busy %llu "
		 "memoryless-hits %llu; new %.1f map %.1f unmap %.1f zero %.1f ms; cached %llu KiB memoryless %llu KiB objects %llu\n",
		 (now - before) / 1e6, s[HM_BO_ALLOCATIONS], s[HM_BO_HITS], s[HM_BO_NEW], s[HM_BO_FIT_HITS],
		 s[HM_BO_FIT_WASTE_BYTES] >> 10, s[HM_BO_MAPS], s[HM_BO_UNMAPS],
		 s[HM_BO_EVICTIONS], s[HM_BO_BUSY], s[HM_BO_MEMORYLESS_HITS], s[HM_BO_ALLOC_NS] / 1e6,
		 s[HM_BO_MAP_NS] / 1e6, s[HM_BO_UNMAP_NS] / 1e6, s[HM_BO_ZERO_NS] / 1e6,
		 s[HM_BO_CACHED_BYTES] >> 10, s[HM_BO_MEMORYLESS_BYTES] >> 10, s[HM_BO_CACHED_COUNT]);
}

/* every allocation here is one kind of memory -- shared, write-combined -- and the buffer says so; the options are
 * read for what cannot be given, so that a request for private storage is not silently given something else */
- (id)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{
	if ((options & MTLResourceStorageModeMask) == MTLResourceStorageModePrivate) {
		HM_ONCE("a buffer was asked for with private storage; every buffer here is shared memory, and that is what "
			"is given (the GPU reads the same pages the processor maps)\n");
	}
	uint64_t previous = hm_bo_begin(0, (unsigned)options, HM_BO_BUFFER);
	id buffer = [[HakiosMetalBuffer alloc] initWithHakiosDevice:self length:length];
	hm_bo_end(previous);
	return buffer;
}

- (id)newBufferWithBytes:(const void *)bytes length:(NSUInteger)length options:(MTLResourceOptions)options
{
	HakiosMetalBuffer *buffer = [self newBufferWithLength:length options:options];

	if (buffer != nil && bytes != NULL && [buffer contents] != NULL) {
		memcpy([buffer contents], bytes, length);
	}
	return buffer;
}

/* The GPU's memory is the kernel's allocation and nothing else: an application's own pages cannot be handed to it as
 * they are. So the bytes are copied into GPU memory as the buffer is made, and the deallocator is kept and called when
 * the buffer goes, as Metal promises. What the copy loses is the sharing: a write by the GPU is not seen in the caller's
 * pages, nor a later write by the caller in the GPU's. QuartzCore's one caller wraps a CPU image to make a linear
 * texture over it that it treats as the image's memory for good; that texture is refused (see
 * -newLinearTextureWithDescriptor:...), and QuartzCore then uploads the image itself. */
- (id)newBufferWithBytesNoCopy:(void *)bytes length:(NSUInteger)length options:(MTLResourceOptions)options
		   deallocator:(void (^)(void *, NSUInteger))deallocator
{
	HakiosMetalBuffer *buffer = [self newBufferWithBytes:bytes length:length options:options];

	HM_ONCE("a no-copy buffer was asked for; its bytes are copied into GPU memory, so neither side sees the other's later "
		"writes\n");
	if (buffer != nil) {
		[buffer hakiosSetDeallocator:deallocator bytes:bytes length:length];
	}
	return buffer;
}

/* the layout of a texture's bytes as -newTextureWithBytesNoCopy: here reads them (HakiosMetalTextureLayout says what) */
- (id)newTextureLayoutWithDescriptor:(MTLTextureDescriptor *)descriptor isHeapOrBufferBacked:(BOOL)backed
{
	unsigned bw, bh, bytes;

	(void)backed;
	if (descriptor == nil || !hakios_metal_format_block((unsigned)[descriptor pixelFormat], &bw, &bh, &bytes) ||
	    ([descriptor textureType] != MTLTextureType2D && [descriptor textureType] != MTLTextureType1D) || [descriptor arrayLength] != 1 ||
	    [descriptor depth] != 1) {
		hm_print("refused: a texture layout for pixel format %lu, type %lu: a 1D or 2D texture of a format this device serves\n",
			 (unsigned long)[descriptor pixelFormat], (unsigned long)[descriptor textureType]);
		return nil;
	}
	return [[HakiosMetalTextureLayout alloc] initWithDescriptor:descriptor blockW:bw blockH:bh bytes:bytes];
}

/* A texture over the caller's bytes (QuartzCore's, for an image it already holds in memory): copied into a texture of
 * the GPU's own, as a no-copy buffer is, with the rows LENGTH / height bytes apart -- the one layout the call can mean
 * without a bytesPerRow of its own. The caller's bytes are handed back to its deallocator when the texture goes. */
- (id)newTextureWithBytesNoCopy:(void *)bytes length:(NSUInteger)length descriptor:(MTLTextureDescriptor *)descriptor
		   deallocator:(void (^)(void *, NSUInteger))deallocator
{
	HakiosMetalTexture *texture = [self newTextureWithDescriptor:descriptor];
	NSUInteger height = [descriptor height], width = [descriptor width];
	NSUInteger pitch = height != 0 ? length / height : 0;
	unsigned bw = 1, bh = 1, bytesPer = 0;

	if (texture == nil) {
		return nil;   /* refused by name in -newTextureWithDescriptor: */
	}
	/* a compressed format, or levels: the bytes are in the layout -newTextureLayoutWithDescriptor: described (each level
	 * in turn, rows of blocks packed tight), as ImageIO staged them through it */
	if (hakios_metal_format_block((unsigned)[descriptor pixelFormat], &bw, &bh, &bytesPer) && (bw > 1 || bh > 1 || [descriptor mipmapLevelCount] > 1)) {
		const NSUInteger levels = MAX([descriptor mipmapLevelCount], (NSUInteger)1);
		NSUInteger offset, row, rows;

		hm_tight_level(width, height, levels, bw, bh, bytesPer, levels, &offset, &row, &rows);
		if (bytes == NULL || length < offset) {
			hm_print("refused: a no-copy %s texture of %lux%lu, %lu levels over %lu bytes: its layout takes %lu\n", bw > 1 ? "compressed" : "mipmapped",
				 (unsigned long)width, (unsigned long)height, (unsigned long)levels, (unsigned long)length, (unsigned long)offset);
			[texture release];
			return nil;
		}
		for (NSUInteger l = 0; l < levels; l++) {
			hm_tight_level(width, height, levels, bw, bh, bytesPer, l, &offset, &row, &rows);
			[(id<MTLTexture>)texture replaceRegion:MTLRegionMake2D(0, 0, MAX(width >> l, (NSUInteger)1), MAX(height >> l, (NSUInteger)1))
						   mipmapLevel:l withBytes:(const uint8_t *)bytes + offset bytesPerRow:row];
		}
		if (deallocator != nil) {
			[texture hakiosSetDeallocator:deallocator bytes:bytes length:length];
		}
		return texture;
	}
	if (bytes == NULL || pitch < width * hakios_metal_texture_bytes_per_pixel([texture hakiosTexture])) {
		hm_print("refused: a no-copy texture of %lux%lu over %lu bytes: rows of %lu bytes do not hold the width\n",
			 (unsigned long)width, (unsigned long)height, (unsigned long)length, (unsigned long)pitch);
		[texture release];
		return nil;
	}
	HM_ONCE("a no-copy texture was asked for; its bytes are copied into GPU memory, so neither side sees the other's later writes\n");
	[(id<MTLTexture>)texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:bytes bytesPerRow:pitch];
	if (deallocator != nil) {
		[texture hakiosSetDeallocator:deallocator bytes:bytes length:length];
	}
	return texture;
}

/* --- pipeline states: where hakios-metal's compiler is asked to work --- */

/* The nil this device returns, with the sentence that goes with it: an NSError for the caller and a printed line for the
 * log, because a caller that swallows the NSError (QuartzCore does) would otherwise swallow the reason with it. */
static void hm_note_constants(const void *program, NSString *constants);
static BOOL hm_tracing(void);

/* A function's specialization values, and the exact CA path that compiles from them (shared with the host test). */
#include "HakiosMetalCAExact.h"

- (id)hakiosRefuse:(NSError **)error what:(const char *)what why:(NSString *)why
{
	hm_print("refused: %s: %s\n", what, [why UTF8String]);
	if (error != NULL) {
		*error = [NSError errorWithDomain:@"HakiosMetal" code:1 userInfo:@{ NSLocalizedDescriptionKey: why }];
	}
	return nil;
}

- (id)hakiosPipelineForFunction:(id)function descriptor:(id)descriptor error:(NSError **)error
{
	hm_perf_mark pipelineBegan = hm_perf_begin();
	SEL bitcode = sel_getUid("bitcodeData");
	NSData *air;
	hakios_metal_kernel *kernel;

	if (function == nil) {
		return [self hakiosRefuse:error what:"a compute pipeline" why:@"the descriptor names no compute function"];
	}
	if (!hakios_metal_has_compiler()) {
		return [self hakiosRefuse:error what:"a compute pipeline"
				      why:@"libhakios-metal was built without the compiler (make ios MESA=1)"];
	}
	if (![function respondsToSelector:bitcode]) {
		return [self hakiosRefuse:error what:"a compute pipeline"
				      why:@"the function does not answer bitcodeData, so its AIR cannot be read"];
	}
	air = hm_bitcode_for(function, nil, NO);
	if (air == nil || [air length] == 0) {
		return [self hakiosRefuse:error what:"a compute pipeline" why:@"the function has no bitcode"];
	}
	{
		hakios_metal_constant constants[64];
		unsigned count = hm_function_constants(function, constants, 64);

		kernel = hakios_metal_kernel_compile_bitcode_constants([air bytes], [air length], constants, count);
		if (kernel != NULL) {
			hm_dump_function("cs", function, "metal_dump=fn", constants, count);
		}
	}
	if (kernel == NULL) {
		/* the compiler's own sentence, passed through: it names the construct it refused */
		hm_dump_refused("cs", function);
		return [self hakiosRefuse:error what:"a compute pipeline"
				      why:[NSString stringWithFormat:@"%@: %s", [function name], hakios_metal_error()]];
	}
	hm_print("compiled %s: %u resources, %u threads a threadgroup at most, execution width %u, %u bytes of threadgroup memory\n",
		 hakios_metal_kernel_name(kernel), hakios_metal_kernel_resource_count(kernel), hakios_metal_kernel_max_threads(kernel),
		 hakios_metal_kernel_execution_width(kernel), hakios_metal_kernel_threadgroup_memory(kernel));
	id state = [[HakiosMetalComputePipelineState alloc] initWithHakiosDevice:self kernel:kernel descriptor:descriptor];
	hm_perf_end(HM_PERF_COMPUTE_PIPELINE, pipelineBegan, 0);
	if (pipelineBegan.wall && hm_perf_clock(CLOCK_MONOTONIC) - pipelineBegan.wall >= 50000000ull)
		hm_print("slow-pipeline: compute %s %.1f ms at %.0f us\n", [[function name] UTF8String],
		         (hm_perf_clock(CLOCK_MONOTONIC) - pipelineBegan.wall) / 1e6, hm_now() * 1e6);
	return state;
}

/* The base class demands a descriptor; Apple's own -newComputePipelineStateWithFunction: builds a
 * MTLComputePipelineDescriptorInternal, so that class is used when it is there and the public one otherwise. */
- (id)newComputePipelineStateWithFunction:(id)function error:(NSError **)error
{
	Class internal = objc_getClass("MTLComputePipelineDescriptorInternal");
	id descriptor = internal != Nil ? [[internal alloc] init] : (id)[[MTLComputePipelineDescriptor alloc] init];
	id state;

	if (descriptor == nil) {
		return [self hakiosRefuse:error what:"a compute pipeline" why:@"no pipeline descriptor class to build one from"];
	}
	[descriptor setComputeFunction:function];
	state = [self hakiosPipelineForFunction:function descriptor:descriptor error:error];
	[descriptor release];
	return state;
}

- (id)newComputePipelineStateWithFunction:(id)function options:(MTLPipelineOption)options
			       reflection:(MTLComputePipelineReflection **)reflection error:(NSError **)error
{
	(void)options;
	if (reflection != NULL) {
		*reflection = nil;   /* reflection comes out of Metal's compiler, which this device has not got */
	}
	return [self newComputePipelineStateWithFunction:function error:error];
}

- (void)newComputePipelineStateWithFunction:(id)function completionHandler:(MTLNewComputePipelineStateCompletionHandler)handler
{
	hm_creation_async(^{
		NSError *error = nil;
		id state = [self newComputePipelineStateWithFunction:function error:&error];

		if (handler != NULL) {
			handler(state, error);
		}
		[state release];
	});
}

- (void)newComputePipelineStateWithFunction:(id)function options:(MTLPipelineOption)options
			  completionHandler:(MTLNewComputePipelineStateWithReflectionCompletionHandler)handler
{
	hm_creation_async(^{
		NSError *error = nil;
		MTLComputePipelineReflection *reflection = nil;
		id state = [self newComputePipelineStateWithFunction:function options:options reflection:&reflection error:&error];

		if (handler != NULL) {
			handler(state, reflection, error);
		}
		[state release];
	});
}

- (id)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)descriptor options:(MTLPipelineOption)options
				 reflection:(MTLComputePipelineReflection **)reflection error:(NSError **)error
{
	(void)options;
	if (reflection != NULL) {
		*reflection = nil;
	}
	return [self hakiosPipelineForFunction:[descriptor computeFunction] descriptor:descriptor error:error];
}

- (id)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)descriptor error:(NSError **)error
{
	return [self hakiosPipelineForFunction:[descriptor computeFunction] descriptor:descriptor error:error];
}

- (void)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)descriptor options:(MTLPipelineOption)options
			    completionHandler:(MTLNewComputePipelineStateWithReflectionCompletionHandler)handler
{
	descriptor = [descriptor copy];
	hm_creation_async(^{
		NSError *error = nil;
		MTLComputePipelineReflection *reflection = nil;
		id state = [self newComputePipelineStateWithDescriptor:descriptor options:options reflection:&reflection error:&error];

		if (handler != NULL) {
			handler(state, reflection, error);
		}
		[state release];
	});
	[descriptor release];
}

- (void)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)descriptor
                           completionHandler:(MTLNewComputePipelineStateCompletionHandler)handler
{
	descriptor = [descriptor copy];
	hm_creation_async(^{
		NSError *error = nil;
		id state = [self newComputePipelineStateWithDescriptor:descriptor error:&error];
		if (handler != NULL) handler(state, error);
		[state release];
	});
	[descriptor release];
}

/* --- render pipeline states: a vertex and a fragment function linked for one colour attachment --- */

/* Metal's buffer tables have 31 entries (profile 0's maxVertexBuffers) and a vertex descriptor as many attribute and
 * layout slots; the SDK's MTLVertexDescriptor arrays are indexed up to that. */
#define HM_MAX_VERTEX_ATTRIBUTES 31

/* A vertex descriptor that fetches nothing: nil, or one whose attributes are all MTLVertexFormatInvalid and whose layouts
 * all have stride 0 (what -[MTLVertexDescriptor init] gives). Metal hands the pipeline a copy of whatever the application
 * set, so "no vertex descriptor" arrives in either shape. Anything else names a vertex fetch ([[stage_in]] attributes
 * through VFD_DECODE/VFD_FETCH); the first such attribute is named, for the log line that says a pipeline fetches. */
static NSString *
hm_vertex_descriptor_fetch(MTLVertexDescriptor *vd)
{
	if (vd == nil) {
		return nil;
	}
	for (NSUInteger i = 0; i < HM_MAX_VERTEX_ATTRIBUTES; i++) {
		MTLVertexAttributeDescriptor *a = [[vd attributes] objectAtIndexedSubscript:i];
		MTLVertexBufferLayoutDescriptor *l = [[vd layouts] objectAtIndexedSubscript:i];

		if (a != nil && [a format] != MTLVertexFormatInvalid) {
			return [NSString stringWithFormat:@"a vertex descriptor with attribute %lu (format %lu, offset %lu, buffer %lu)",
							  (unsigned long)i, (unsigned long)[a format], (unsigned long)[a offset], (unsigned long)[a bufferIndex]];
		}
		if (l != nil && [l stride] != 0) {
			return [NSString stringWithFormat:@"a vertex descriptor with layout %lu (stride %lu)", (unsigned long)i, (unsigned long)[l stride]];
		}
	}
	return nil;
}

/* The descriptor's attributes and layouts, Metal's numbers straight through (hakios_metal.h): every slot, described or
 * not, so that a pipeline state made from a reused descriptor carries no stale attribute. NO with the core's sentence. */
static BOOL
hm_set_vertex_descriptor(hakios_metal_program *program, MTLVertexDescriptor *vd)
{
	for (unsigned i = 0; i < HM_MAX_VERTEX_ATTRIBUTES; i++) {
		MTLVertexAttributeDescriptor *a = vd != nil ? [[vd attributes] objectAtIndexedSubscript:i] : nil;
		MTLVertexBufferLayoutDescriptor *l = vd != nil ? [[vd layouts] objectAtIndexedSubscript:i] : nil;

		if (hakios_metal_program_set_vertex_attribute(program, i, a != nil ? (unsigned)[a format] : 0, a != nil ? (unsigned)[a offset] : 0,
							      a != nil ? (unsigned)[a bufferIndex] : 0) != 0 ||
		    hakios_metal_program_set_vertex_layout(program, i, l != nil ? (unsigned)[l stride] : 0,
							   l != nil ? (unsigned)[l stepFunction] : 1, l != nil ? (unsigned)[l stepRate] : 1) != 0) {
			return NO;
		}
	}
	return YES;
}

/* The per-sample fetch is the default: a fragment that reads [[color(0)]] on a pipeline of more than one sample gets
 * txf_ms of the attachment with the pipeline's rasterSampleCount (compiler.cpp: lowerFbRead), which is what Metal's
 * framebuffer fetch means there -- and without it Maps' GlowAlpha and PatternedRibbon were refused outright (a 1-sample
 * txf of a 4-sample attachment, whose samples are interleaved in its memory). The file turns it back off for a bisect;
 * the descriptor read itself still needs a device pixel check. */
static BOOL
hm_msaa_fbfetch(void)
{
	static int on = -1;
	if (on < 0) on = access(HM_CACHE_DIR "/msaa-fbfetch-off", F_OK) != 0;
	return on != 0;
}

static BOOL
hm_maps_trace(void)
{
	static int on = -1;
	if (on < 0) on = access(HM_CACHE_DIR "/maps-trace", F_OK) == 0;
	return on != 0;
}

/* The draws the encoder refuses, deduplicated: one line the first time a (program, reason) is refused, and again only
 * when another reason of that program follows. Keyed by the program's function name and the WHOLE reason, both hashed:
 * the program's address is not stable (a freed program's address can come back with another), and a reason cut at a
 * fixed length merged two that only differed past it (its shape, not its numbers, is what a line says). The counter of
 * the period is reported as one aggregate, hm_refusal_report below, never a line a draw: Maps refused 1,961 draws of
 * two shaders in one run, 6.5 lines a second. */
#define HM_REFUSAL_KINDS 16
/* FNV-1a: the key has to survive an address being reused, so it is the text's hash, not a pointer. */
static uint64_t
hm_hash64(const char *text)
{
	uint64_t hash = 1469598103934665603ull;

	for (; text != NULL && *text != 0; text++) hash = (hash ^ (unsigned char)*text) * 1099511628211ull;
	return hash;
}

static struct {
	pthread_mutex_t lock;
	struct {
		BOOL used;
		uint64_t program;   /* its function name's hash: stable across a freed program's address being reused */
		uint64_t why;       /* the whole reason's hash */
		char name[80];
		unsigned count;     /* this period's */
	} kinds[HM_REFUSAL_KINDS];
	unsigned dropped;       /* past the table: counted in the aggregate, not named */
} hm_refusals = { .lock = PTHREAD_MUTEX_INITIALIZER };

/* YES: this (program, reason) is new to the table, so the caller says its line now. */
static BOOL
hm_refusal_first(hakios_metal_program *program, const char *why)
{
	const char *name = program != NULL ? hakios_metal_program_name(program) : NULL;
	const uint64_t programKey = hm_hash64(name != NULL ? name : "?");
	const uint64_t whyKey = hm_hash64(why);
	BOOL first = NO;
	int freeSlot = -1;

	pthread_mutex_lock(&hm_refusals.lock);
	for (int i = 0; i < HM_REFUSAL_KINDS; i++) {
		if (!hm_refusals.kinds[i].used) {
			if (freeSlot < 0) freeSlot = i;
			continue;
		}
		if (hm_refusals.kinds[i].program != programKey || hm_refusals.kinds[i].why != whyKey) continue;
		hm_refusals.kinds[i].count++;
		pthread_mutex_unlock(&hm_refusals.lock);
		return NO;
	}
	if (freeSlot >= 0) {
		hm_refusals.kinds[freeSlot].used = YES;
		hm_refusals.kinds[freeSlot].program = programKey;
		hm_refusals.kinds[freeSlot].why = whyKey;
		strlcpy(hm_refusals.kinds[freeSlot].name, name != NULL ? name : "?", sizeof hm_refusals.kinds[freeSlot].name);
		hm_refusals.kinds[freeSlot].count = 1;
		first = YES;
	} else {
		hm_refusals.dropped++;
	}
	pthread_mutex_unlock(&hm_refusals.lock);
	return first;
}

/* The period's refusals in one line (hm_fps_note's two-second report), the counters restarted; the keys stay, so the
 * first lines are not said again when the same reason comes back. */
static void
hm_refusal_report(void)
{
	char by[256] = "";
	size_t at = 0;
	unsigned total, kinds = 0;

	pthread_mutex_lock(&hm_refusals.lock);
	total = hm_refusals.dropped;   /* (under the same lock as hm_refusal_first's increment: no count lost or raced) */
	hm_refusals.dropped = 0;
	for (int i = 0; i < HM_REFUSAL_KINDS; i++) {
		if (!hm_refusals.kinds[i].used || hm_refusals.kinds[i].count == 0) continue;
		kinds++;
		total += hm_refusals.kinds[i].count;
		if (at < sizeof by - 1) {
			const int wrote = snprintf(by + at, sizeof by - at, "%s%s:%u", at != 0 ? " " : "", hm_refusals.kinds[i].name,
						   hm_refusals.kinds[i].count);

			if (wrote > 0) at += MIN((size_t)wrote, sizeof by - 1 - at);
		}
		hm_refusals.kinds[i].count = 0;
	}
	pthread_mutex_unlock(&hm_refusals.lock);
	if (total != 0) hm_print("refused: total %u kinds %u [%s]\n", total, kinds, by);
}

/* Preserve NSError on every call, but print a particular compiler failure once.
 * The core remembers the failed specialization for this process too. */
static BOOL
hm_first_compile_failure(NSString *why)
{
	static NSMutableSet *seen;
	@synchronized ([HakiosMetalDevice class]) {
		if (seen == nil) seen = [[NSMutableSet alloc] init];
		if ([seen containsObject:why]) return NO;
		[seen addObject:why];
		return YES;
	}
}

/*
 * Why a render pipeline descriptor cannot be served, or nil. Everything the base initialiser does not read is read here,
 * by name, BEFORE any compilation and before super is given the descriptor: the step-one contract (hakios_metal.h) is one
 * colour attachment of a served format, no depth, no stencil, one sample, no dual-source blend, and a vertex
 * plus a fragment function; a descriptor asking for more gets nil with the sentence that names the first thing it asked
 * for, rather than a pipeline that silently draws without it. Each check is one a client can trip on purpose (the test
 * program's blendingEnabled line is one of them).
 */
- (NSString *)hakiosRenderPipelineWhy:(MTLRenderPipelineDescriptor *)d
{

	if (d == nil || ![d isKindOfClass:[MTLRenderPipelineDescriptor class]]) {
		return [NSString stringWithFormat:@"the descriptor is %s, not an MTLRenderPipelineDescriptor (Metal's own init would abort on it)",
						  d != nil ? class_getName(object_getClass(d)) : "nil"];
	}
	if ([d vertexFunction] == nil) {
		return @"the descriptor names no vertex function";
	}
	if ([[d vertexFunction] functionType] != MTLFunctionTypeVertex) {
		return [NSString stringWithFormat:@"the vertex function %@ is of type %lu, not a vertex function (1)", [[d vertexFunction] name],
						  (unsigned long)[[d vertexFunction] functionType]];
	}
	/* no fragment function is a depth-only pipeline: hakios-metal draws a built-in one that writes nothing */
	if ([d fragmentFunction] != nil && [[d fragmentFunction] functionType] != MTLFunctionTypeFragment) {
		return [NSString stringWithFormat:@"the fragment function %@ is of type %lu, not a fragment function (2)", [[d fragmentFunction] name],
						  (unsigned long)[[d fragmentFunction] functionType]];
	}
	/* colour attachment 0 may be Invalid: a pipeline drawing depth alone (a shadow map's), or one whose first target is a
	 * later index -- its [[color(0)]], if the function writes one, goes nowhere, as Metal discards it */
	/* Attachments past 0 are hakios-metal's to judge at the draw: one the fragment function writes ([[color(n)]]) is
	 * drawn into, its output's class against the attachment's format; one it does not write -- QuartzCore's
	 * downsample_4_frag_lph pass names a second target and writes colour 0 alone -- is left unwritten, as Metal leaves
	 * an output the function does not write. Their blends are handed over after the compile. */
	/* blending and the write mask are hakios-metal's (hakios_metal_program_set_blend after the compile), dual-source
	 * factors included: the draw takes a stage's [[color(0), index(1)]] as the second source */
	if ([d depthAttachmentPixelFormat] != MTLPixelFormatInvalid && [d depthAttachmentPixelFormat] != MTLPixelFormatDepth32Float &&
	    [d depthAttachmentPixelFormat] != MTLPixelFormatDepth16Unorm &&
	    [d depthAttachmentPixelFormat] != MTLPixelFormatDepth32Float_Stencil8) {
		return [NSString stringWithFormat:@"a depth attachment pixel format of %lu; Depth16Unorm (250), Depth32Float (252) and Depth32Float_Stencil8 "
						  "(260) are the depth formats served", (unsigned long)[d depthAttachmentPixelFormat]];
	}
	/* A6xx uses a separate S8 plane, either standalone or following D32. */
	if ([d stencilAttachmentPixelFormat] != MTLPixelFormatInvalid && [d stencilAttachmentPixelFormat] != MTLPixelFormatStencil8 &&
	    [d stencilAttachmentPixelFormat] != MTLPixelFormatDepth32Float_Stencil8) {
		return [NSString stringWithFormat:@"a stencil attachment pixel format of %lu; Stencil8 (253) and Depth32Float_Stencil8 (260) are the stencil "
						  "format served", (unsigned long)[d stencilAttachmentPixelFormat]];
	}
	if ([d rasterSampleCount] != 1 && [d rasterSampleCount] != 2 && [d rasterSampleCount] != 4) {
		return [NSString stringWithFormat:@"rasterSampleCount %lu; 1, 2 and 4 samples are served", (unsigned long)[d rasterSampleCount]];
	}
	/* the vertex descriptor is not judged here: it is handed to hakios-metal after the compile (hm_set_vertex_descriptor),
	 * which knows which attributes the vertex function reads and refuses an unserved one at the draw, by name */
	if ([d isAlphaToCoverageEnabled] || [d isAlphaToOneEnabled]) {
		return @"alphaToCoverage or alphaToOne is enabled; neither is served (no MSAA, no blend state)";
	}
	if (![d isRasterizationEnabled]) {
		return @"rasterizationEnabled is NO; a pipeline that rasterizes nothing has nothing to draw here (no stream-out)";
	}
	if ([d inputPrimitiveTopology] != MTLPrimitiveTopologyClassUnspecified && [d inputPrimitiveTopology] != MTLPrimitiveTopologyClassTriangle) {
		return [NSString stringWithFormat:@"input primitive topology class %lu; triangles (3, or unspecified 0) are what step one draws",
						  (unsigned long)[d inputPrimitiveTopology]];
	}
	if ([d maxVertexAmplificationCount] > 1) {
		return [NSString stringWithFormat:@"maxVertexAmplificationCount %lu; profile 0 amplifies nothing (1)", (unsigned long)[d maxVertexAmplificationCount]];
	}
	if ([[[d vertexLinkedFunctions] functions] count] != 0 || [[[d vertexLinkedFunctions] binaryFunctions] count] != 0 ||
	    [[[d fragmentLinkedFunctions] functions] count] != 0 || [[[d fragmentLinkedFunctions] binaryFunctions] count] != 0) {
		return @"linked functions (dynamic linking, visible functions) are not served; each stage is one module compiled whole";
	}
	if ([[d vertexPreloadedLibraries] count] != 0 || [[d fragmentPreloadedLibraries] count] != 0) {
		return @"preloaded dynamic libraries are not served";
	}
	if ([d supportIndirectCommandBuffers]) {
		HM_ONCE("a render pipeline was asked to support indirect command buffers; the flag is kept by Metal's base class, and the "
			"encoder refuses -executeCommandsInBuffer: by name\n");
	}
	if ([[d binaryArchives] count] != 0) {
		HM_ONCE("a render pipeline descriptor carries %lu binary archives; none is consulted, the AIR is compiled here\n",
			(unsigned long)[[d binaryArchives] count]);
	}
	/* OpenGL ES's fixed-function leftovers, which Metal's descriptor keeps for Apple's GPU (AppleMetalGLRenderer sets
	 * them from GL state): each said once and not served -- the pipeline is made, and draws without it */
	{
		static const char *const gl[] = { "isAlphaTestEnabled", "isLogicOperationEnabled", "isPointSmoothEnabled" };

		for (size_t i = 0; i < sizeof(gl) / sizeof(gl[0]); i++) {
			SEL sel = sel_getUid(gl[i]);

			if ([d respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(d, sel)) {
				static BOOL said[3];

				if (!said[i]) {
					said[i] = YES;
					hm_print("gles: a render pipeline asks for %s; not served (GL ES 1's state): drawn without it\n", gl[i]);
				}
			}
		}
		if ([d respondsToSelector:sel_getUid("clipDistanceEnableMask")] &&
		    ((NSUInteger (*)(id, SEL))objc_msgSend)(d, sel_getUid("clipDistanceEnableMask")) != 0) {
			HM_ONCE("gles: a render pipeline enables user clip distances; not served: drawn unclipped\n");
		}
	}
	return nil;
}

/* What a function a pipeline is handed is made of, once per class: its class chain with each class's ivars, and the
 * public functionConstantsDictionary. Which of them carries the values a pipeline specialised the function with
 * (-[MTLLibrary newFunctionWithName:constantValues:error:]) is not known from the SDK, and the compiler here takes
 * every constant as unsupplied until it is: this is the reading that says where they are. */
static void
hm_describe_function(id f)
{
	static Class said[8];
	Class c = f != nil ? object_getClass(f) : Nil;

	if (c == Nil) {
		return;
	}
	for (int i = 0; i < 8; i++) {
		if (said[i] == c) {
			return;
		}
		if (said[i] == Nil) {
			said[i] = c;
			break;
		}
	}
	for (Class k = c; k != Nil && k != [NSObject class]; k = class_getSuperclass(k)) {
		unsigned n = 0;
		Ivar *ivars = class_copyIvarList(k, &n);
		char names[768] = "";

		for (unsigned i = 0; i < n; i++) {
			strlcat(names, i ? ", " : "", sizeof(names));
			strlcat(names, ivar_getName(ivars[i]), sizeof(names));
		}
		free(ivars);
		hm_print("a pipeline's function %s: class %s, ivars: %s\n", [[f name] UTF8String], class_getName(k), names);
	}
	if ([f respondsToSelector:@selector(functionConstantsDictionary)]) {
		NSDictionary *fc = [f functionConstantsDictionary];

		hm_print("  ... functionConstantsDictionary: %lu entries%s%s\n", (unsigned long)[fc count], [fc count] ? ", e.g. " : "",
			 [fc count] ? [[[[fc allKeys] firstObject] description] UTF8String] : "");
	}
}

/* A CoreAnimation pipeline (com.apple.coreanimation.draw.<spec>) whose fragment variant the pipeline library has not
 * got: CoreAnimation made it at run time, and its functions are compiled from their own AIR (hm_ca_exact_why_not). */
static BOOL hm_ca_missing(NSString *pipeline)
{
    if (![pipeline hasPrefix:@"com.apple.coreanimation.draw."]) return NO;
    hm_ca_load();
    NSString *spec = [pipeline substringFromIndex:[@"com.apple.coreanimation.draw." length]];
    NSRange under = [spec rangeOfString:@"_"];
    if (under.location == NSNotFound) return NO;
    NSString *frag = [@"com.apple.coreanimation.frag." stringByAppendingString:[spec substringFromIndex:NSMaxRange(under)]];
    return hm_ca_variants[frag] == nil;
}

/*
 * The one entry point every form below ends in. The order is: the descriptor's own rules (above), then the compiler
 * (hakios_metal_program_new_bitcode: AIR to NIR to ir3 for both stages, the link, the format against the fragment
 * output's class -- its refusals name the construct), then Metal's base initialiser with a descriptor already known to
 * pass its asserts. Nothing is asked of Metal's -compiler, which this device has not got.
 */
- (id)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)descriptor error:(NSError **)error
{
	hm_perf_mark pipelineBegan = hm_perf_begin();
	SEL bitcode = sel_getUid("bitcodeData");
	NSString *why = [self hakiosRenderPipelineWhy:descriptor];
	id vs, fs;
	NSData *vsAir, *fsAir;
	hakios_metal_program *program;
	unsigned format;

	hm_describe_function([descriptor fragmentFunction]);
	if (why != nil) {
		return [self hakiosRefuse:error what:"a render pipeline" why:why];
	}
	if (!hakios_metal_has_compiler()) {
		return [self hakiosRefuse:error what:"a render pipeline" why:@"libhakios-metal was built without the compiler (make ios MESA=1)"];
	}
	vs = [descriptor vertexFunction];
	fs = [descriptor fragmentFunction];
	if (![vs respondsToSelector:bitcode] || (fs != nil && ![fs respondsToSelector:bitcode])) {
		return [self hakiosRefuse:error what:"a render pipeline"
				      why:@"a function does not answer bitcodeData, so its AIR cannot be read (not an _MTLFunction of this Metal?)"];
	}
    BOOL missingCA = hm_ca_missing([descriptor label]);
    vsAir = missingCA ? ((id(*)(id,SEL))objc_msgSend)(vs, bitcode) : hm_bitcode_for(vs, [descriptor label], YES);
    fsAir = fs != nil ? (missingCA ? ((id(*)(id,SEL))objc_msgSend)(fs, bitcode) : hm_bitcode_for(fs, [descriptor label], NO)) : nil;   /* nil: the built-in fragment function */
	if (vsAir == nil || [vsAir length] == 0 || (fs != nil && (fsAir == nil || [fsAir length] == 0))) {
		return [self hakiosRefuse:error what:"a render pipeline"
				      why:[NSString stringWithFormat:@"%@ or %@ has no bitcode", [vs name], [fs name]]];
	}
	format = (unsigned)[[[descriptor colorAttachments] objectAtIndexedSubscript:0] pixelFormat];
	{
		hakios_metal_constant vsConstants[64], fsConstants[64];
		unsigned vsCount = hm_function_constants(vs, vsConstants, 64), fsCount = hm_function_constants(fs, fsConstants, 64);

        if (missingCA) {
            /* CoreAnimation's own functions (iOS 16.5's QuartzCore default.metallib) with the named values it set, as Metal
             * recorded them: the exact program. Anything else is said, with the reason, before a stand-in is used. */
            NSString *spec = [[descriptor label] substringFromIndex:[@"com.apple.coreanimation.draw." length]];
            NSString *whyNot = hm_ca_exact_why_not(vs, vsAir, vsConstants, vsCount);

            if (whyNot == nil) whyNot = hm_ca_exact_why_not(fs, fsAir, fsConstants, fsCount);
            if (whyNot == nil) {
                hm_print("CoreAnimation exact configuration: %s: %s (%u constants) + %s (%u constants), iOS 16.5 AIR\n", [spec UTF8String],
                         [[vs name] UTF8String], vsCount, fs != nil ? [[fs name] UTF8String] : "(built-in)", fsCount);
            } else {
                NSString *frag = [@"com.apple.coreanimation.frag." stringByAppendingString:[spec substringFromIndex:[spec rangeOfString:@"_"].location + 1]];
                NSString *chosen = hm_ca_nearest(frag);
                NSData *v = chosen ? hm_ca_variants[hm_ca_frag_vert[chosen]] : nil, *f = chosen ? hm_ca_variants[chosen] : nil;

                hm_print("exact CA configuration impossible for %s: %s; emergency paired fallback: %s\n", [spec UTF8String], [whyNot UTF8String],
                         v && f ? [chosen UTF8String] : "none, its own module with the values it has");
                if (v && f) { vsAir = v; fsAir = f; }
            }
        }
        program = hakios_metal_program_new_bitcode_samples([vsAir bytes], [vsAir length], vsConstants, vsCount, fsAir != nil ? [fsAir bytes] : NULL,
								     fsAir != nil ? [fsAir length] : 0,
								     fsConstants, fsCount, format,
								     hm_msaa_fbfetch() ? (unsigned)[descriptor rasterSampleCount] : 1);
		if (program != NULL && [descriptor rasterSampleCount] > 1 && hakios_metal_program_framebuffer_fetch(program)) {
			static unsigned said;
			if (__atomic_fetch_add(&said, 1, __ATOMIC_RELAXED) < 16) {
				hm_print("msaa-fetch: %s, %lu samples: %s\n", hakios_metal_program_name(program),
					 (unsigned long)[descriptor rasterSampleCount], hm_msaa_fbfetch() ? "current-sample texture read, per-sample shading (msaa-fbfetch-off turns it off)"
					 : "legacy single-sample read; /var/db/hakios-metal-cache/msaa-fbfetch-off is present");
			}
		}
		if (program != NULL) {
			hm_dump_function("vs", vs, "metal_dump=fn", vsConstants, vsCount);
			if (fs != nil) hm_dump_function("fs", fs, "metal_dump=fn", fsConstants, fsCount);
		}
		if (program != NULL && hm_gles_bitcode(vs) != nil) {
			static unsigned glPipelines;
			const unsigned k = __atomic_fetch_add(&glPipelines, 1, __ATOMIC_RELAXED);

			if (k < 16 || (k & (k - 1)) == 0) {
				hm_print("gles: pipeline %u compiled: %s; colour format %u, depth format %lu, %lu samples\n", k,
					 hakios_metal_program_name(program), format, (unsigned long)[descriptor depthAttachmentPixelFormat],
					 (unsigned long)[descriptor rasterSampleCount]);
			}
		}
		if (program == NULL) {
			/* the core's sentence, passed through: the stage and the construct it refused, or the format by name -- and the
			 * fragment function's constants, which decide what it is */
			NSMutableString *fc = [NSMutableString string];

			for (unsigned i = 0; i < fsCount; i++) {
				if (fsConstants[i].bits != 0) [fc appendFormat:@" %u=%llu", fsConstants[i].index, (unsigned long long)fsConstants[i].bits];
			}
			NSString *failure = [NSString stringWithFormat:@"%@ + %@ for pixel format %u (fragment constants not 0:%@): %s", [vs name], [fs name],
							       format, fc, hakios_metal_error()];
			if (!hm_first_compile_failure(failure)) {
				if (error != NULL) *error = [NSError errorWithDomain:@"HakiosMetal" code:1 userInfo:@{ NSLocalizedDescriptionKey: failure }];
				return nil;
			}
			hm_dump_refused("vs", vs);
			hm_dump_refused("fs", fs);
			hm_gles_dump_refused("vertex", vs);
			hm_gles_dump_refused("fragment", fs);
			return [self hakiosRefuse:error what:"a render pipeline"
					      why:failure];
		}
	}
	hakios_metal_program_set_samples(program, (unsigned)[descriptor rasterSampleCount]);   /* 1, 2 or 4: judged above */
	if (!hm_set_vertex_descriptor(program, [descriptor vertexDescriptor])) {
		NSString *why2 = [NSString stringWithFormat:@"the vertex descriptor: %s", hakios_metal_error()];
		hakios_metal_program_free(program);
		return [self hakiosRefuse:error what:"a render pipeline" why:why2];
	}
	{
		MTLRenderPipelineColorAttachmentDescriptor *c0 = [[descriptor colorAttachments] objectAtIndexedSubscript:0];

		hakios_metal_program_set_blend(program, [c0 isBlendingEnabled] ? 1 : 0, (unsigned)[c0 rgbBlendOperation], (unsigned)[c0 alphaBlendOperation],
					       (unsigned)[c0 sourceRGBBlendFactor], (unsigned)[c0 destinationRGBBlendFactor],
					       (unsigned)[c0 sourceAlphaBlendFactor], (unsigned)[c0 destinationAlphaBlendFactor], (unsigned)[c0 writeMask]);
		for (unsigned i = 1; i < 8; i++) {
			MTLRenderPipelineColorAttachmentDescriptor *c = [[descriptor colorAttachments] objectAtIndexedSubscript:i];

			if (c == nil || [c pixelFormat] == MTLPixelFormatInvalid) {
				continue;
			}
			hakios_metal_program_set_blend_at(program, i, [c isBlendingEnabled] ? 1 : 0, (unsigned)[c rgbBlendOperation],
							  (unsigned)[c alphaBlendOperation], (unsigned)[c sourceRGBBlendFactor],
							  (unsigned)[c destinationRGBBlendFactor], (unsigned)[c sourceAlphaBlendFactor],
							  (unsigned)[c destinationAlphaBlendFactor], (unsigned)[c writeMask]);
		}
	}
	{
		NSString *fetches = hm_vertex_descriptor_fetch([descriptor vertexDescriptor]);

		if (fetches != nil) {
			hm_print("%s fetches through %s\n", hakios_metal_program_name(program), [fetches UTF8String]);
		}
	}
	{
		/* the fragment function's constants beside the line: one function (fixed_frag_lph_cph) is most of what
		 * CoreAnimation draws, and its constants are what tell one of its pipelines from another in a log */
		hakios_metal_constant fc[64];
		unsigned count = hm_function_constants([descriptor fragmentFunction], fc, 64);
		NSMutableString *set = [NSMutableString string];
		NSMutableString *zero = [NSMutableString string];

		for (unsigned i = 0; i < count; i++) {
			if (fc[i].bits != 0) [set appendFormat:@" %u=%llu", fc[i].index, (unsigned long long)fc[i].bits];
			else [zero appendFormat:@",%u", fc[i].index];
		}
		hm_note_constants(program, set);
		if (hm_tracing()) {
			/* the module this Metal hands over is the function already specialised (a few KB, not the library's
			 * 100), so its size and hash, not the library's, say which code a pipeline runs */
			NSData *air = hm_bitcode_for([descriptor fragmentFunction], [descriptor label], NO);
			uint32_t h = 2166136261u;
			const uint8_t *b = (const uint8_t *)[air bytes];

			for (NSUInteger i = 0; i < [air length]; i++) h = (h ^ b[i]) * 16777619u;
			hm_print("trace: %s (%p) defines %u constants; the zero ones%s; fragment bitcode %lu bytes, fnv %08x\n", hakios_metal_program_name(program),
				 (void *)program, count, [zero UTF8String], (unsigned long)[air length], h);
			/* boot-arg metal_dump=FNV (a diagnostic): that module's bytes into the log in hex, for the host's own
			 * front end and compiler to take apart. What it prints is the system's code: it stays in the log. */
			{
				char args[1024] = {0}, *at;
				size_t size = sizeof(args) - 1;

				if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && (at = strstr(args, "metal_dump=")) != NULL &&
				    (uint32_t)strtoul(at + 11, NULL, 16) == h) {
					for (NSUInteger o = 0; o < [air length]; o += 64) {
						char line[160];
						size_t n = 0;

						for (NSUInteger i = o; i < o + 64 && i < [air length]; i++) n += (size_t)snprintf(line + n, sizeof(line) - n, "%02x", b[i]);
						hm_print("dump %08x %06lx %s\n", h, (unsigned long)o, line);
					}
				}
			}
		}
		hm_print("linked %s (%p) for pixel format %u: the vertex stage binds %u resources, the fragment stage %u; fragment constants not 0:%s\n",
			 hakios_metal_program_name(program), (void *)program, format, hakios_metal_program_resource_count(program, 0),
			 hakios_metal_program_resource_count(program, 1), [set UTF8String]);
	}
	{
		HakiosMetalRenderPipelineState *state = [[HakiosMetalRenderPipelineState alloc] initWithHakiosDevice:self program:program descriptor:descriptor];
		hakios_metal_constant fc[64];
		unsigned count = fs != nil ? hm_function_constants(fs, fc, 64) : 0;

		if (state != nil && fsAir != nil && !missingCA) [state hakiosKeepFragment:fsAir constants:fc count:count];
		hm_perf_end(HM_PERF_RENDER_PIPELINE, pipelineBegan, 0);
		if (pipelineBegan.wall && hm_perf_clock(CLOCK_MONOTONIC) - pipelineBegan.wall >= 50000000ull)
			hm_print("slow-pipeline: render %s %.1f ms at %.0f us\n", [[descriptor label] UTF8String],
			         (hm_perf_clock(CLOCK_MONOTONIC) - pipelineBegan.wall) / 1e6, hm_now() * 1e6);
		return state;
	}
}

/* reflection comes out of Metal's compiler, which this device has not got; nil, as for compute */
- (id)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options
				reflection:(MTLAutoreleasedRenderPipelineReflection *)reflection error:(NSError **)error
{
	(void)options;
	if (reflection != NULL) {
		*reflection = nil;
	}
	return [self newRenderPipelineStateWithDescriptor:descriptor error:error];
}

/* Handler forms enqueue the build and callback off the caller's thread. Each
 * descriptor is snapshotted; the returned +1 state is released after the handler. */
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)descriptor
			   completionHandler:(MTLNewRenderPipelineStateCompletionHandler)handler
{
	descriptor = [descriptor copy];
	hm_creation_async(^{
		NSError *error = nil;
		id state = [self newRenderPipelineStateWithDescriptor:descriptor error:&error];

		if (handler != NULL) {
			handler(state, error);
		}
		[state release];
	});
	[descriptor release];
}

- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options
			   completionHandler:(MTLNewRenderPipelineStateWithReflectionCompletionHandler)handler
{
	descriptor = [descriptor copy];
	hm_creation_async(^{
		NSError *error = nil;
		id state = [self newRenderPipelineStateWithDescriptor:descriptor options:options reflection:NULL error:&error];

		if (handler != NULL) {
			handler(state, nil, error);
		}
		[state release];
	});
	[descriptor release];
}

/* The mesh and tile forms are _MTLDevice's own, and the mesh ones RE-ENTER the plain forms above on self with a render
 * descriptor derived from the mesh descriptor (the earlier plug-in read those four entry points): inherited, they would
 * hand a mesh pipeline to the vertex-plus-fragment builder and get something compiled rather than a refusal. Overridden
 * to refuse by name, every form, handlers enqueued with the error. */
- (id)newRenderPipelineStateWithMeshDescriptor:(MTLMeshRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options
				    reflection:(MTLAutoreleasedRenderPipelineReflection *)reflection error:(NSError **)error
{
	(void)descriptor; (void)options;
	if (reflection != NULL) {
		*reflection = nil;
	}
	return [self hakiosRefuse:error what:"a mesh render pipeline" why:@"mesh and object stages are not served; vertex + fragment pipelines are"];
}

- (id)newRenderPipelineStateWithMeshDescriptor:(MTLMeshRenderPipelineDescriptor *)descriptor error:(NSError **)error
{
	return [self newRenderPipelineStateWithMeshDescriptor:descriptor options:0 reflection:NULL error:error];
}

- (void)newRenderPipelineStateWithMeshDescriptor:(MTLMeshRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options
			       completionHandler:(MTLNewRenderPipelineStateWithReflectionCompletionHandler)handler
{
	descriptor = [descriptor copy];
	hm_creation_async(^{
		NSError *error = nil;
		id state = [self newRenderPipelineStateWithMeshDescriptor:descriptor options:options reflection:NULL error:&error];

		if (handler != NULL) {
			handler(state, nil, error);
		}
		[state release];
	});
	[descriptor release];
}

- (void)newRenderPipelineStateWithMeshDescriptor:(MTLMeshRenderPipelineDescriptor *)descriptor
			       completionHandler:(MTLNewRenderPipelineStateCompletionHandler)handler
{
	descriptor = [descriptor copy];
	hm_creation_async(^{
		NSError *error = nil;
		id state = [self newRenderPipelineStateWithMeshDescriptor:descriptor options:0 reflection:NULL error:&error];

		if (handler != NULL) {
			handler(state, error);
		}
		[state release];
	});
	[descriptor release];
}

- (id)newRenderPipelineStateWithTileDescriptor:(MTLTileRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options
				    reflection:(MTLAutoreleasedRenderPipelineReflection *)reflection error:(NSError **)error
{
	(void)descriptor; (void)options;
	if (reflection != NULL) {
		*reflection = nil;
	}
	return [self hakiosRefuse:error what:"a tile render pipeline"
			      why:@"tile shaders and imageblocks are Apple-GPU tile memory; this GPU draws straight to memory (sysmem) and has none"];
}

- (id)newRenderPipelineStateWithTileDescriptor:(MTLTileRenderPipelineDescriptor *)descriptor error:(NSError **)error
{
	return [self newRenderPipelineStateWithTileDescriptor:descriptor options:0 reflection:NULL error:error];
}

- (void)newRenderPipelineStateWithTileDescriptor:(MTLTileRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options
			       completionHandler:(MTLNewRenderPipelineStateWithReflectionCompletionHandler)handler
{
	descriptor = [descriptor copy];
	hm_creation_async(^{
		NSError *error = nil;
		id state = [self newRenderPipelineStateWithTileDescriptor:descriptor options:options reflection:NULL error:&error];

		if (handler != NULL) {
			handler(state, nil, error);
		}
		[state release];
	});
	[descriptor release];
}

- (void)newRenderPipelineStateWithTileDescriptor:(MTLTileRenderPipelineDescriptor *)descriptor
			       completionHandler:(MTLNewRenderPipelineStateCompletionHandler)handler
{
	descriptor = [descriptor copy];
	hm_creation_async(^{
		NSError *error = nil;
		id state = [self newRenderPipelineStateWithTileDescriptor:descriptor options:0 reflection:NULL error:&error];

		if (handler != NULL) {
			handler(state, error);
		}
		[state release];
	});
	[descriptor release];
}

/* Metal source needs Metal's own compiler service, which this device has not got; what it compiles is AIR out of a
 * .metallib, and that road (newLibraryWithData:, newLibraryWithFile:) is the base class's and works */
/* Metal Shading Language source is Metal's own to compile into AIR: _MTLDevice sends it to MTLCompilerService, which
 * runs under launchd, and the library that comes back holds AIR like any .metallib, which this plug-in's compiler then
 * takes function by function (bitcodeData). Without the service -- a program run before launchd -- there is no library,
 * and the base's NSError says so. */
- (id)newLibraryWithSource:(NSString *)source options:(MTLCompileOptions *)options error:(NSError **)error
{
	NSError *mine = nil;
	id library = [super newLibraryWithSource:source options:options error:&mine];

	if (library == nil) {
		hm_print("refused: a library from source: Metal's compiler service gave none: %s\n",
			 mine != nil ? [[mine localizedDescription] UTF8String] : "no error said");
	}
	if (error != NULL) {
		*error = mine;
	}
	return library;
}

- (void)newLibraryWithSource:(NSString *)source options:(MTLCompileOptions *)options
	   completionHandler:(MTLNewLibraryCompletionHandler)handler
{
	source = [source copy];
	options = [options copy];
	hm_creation_async(^{
		NSError *error = nil;
		id library = [self newLibraryWithSource:source options:options error:&error];

		if (handler != NULL) {
			handler(library, error);
		}
		[library release];
	});
	[source release];
	[options release];
}

- (void)newLibraryWithStitchedDescriptor:(MTLStitchedLibraryDescriptor *)descriptor
                     completionHandler:(MTLNewLibraryCompletionHandler)handler
{
	descriptor = [descriptor copy];
	hm_creation_async(^{
		NSError *error = nil;
		id library = [self newLibraryWithStitchedDescriptor:descriptor error:&error];
		if (handler != NULL) handler(library, error);
		[library release];
	});
	[descriptor release];
}

/* --- textures --- */

/* The number a texture (gpuResourceID, uniqueIdentifier, gpuHandle) is told apart by for as long as it lives. A counter,
 * never the object's address: the allocator reuses addresses, and UIKit's image caches key on this number, so a texture
 * at a dead one's address would be served the dead one's picture. From 1, so that 0 stays "never set". */
static uint64_t
hm_next_resource_id(void)
{
	static uint64_t next;

	return __atomic_add_fetch(&next, 1, __ATOMIC_RELAXED);
}

/* the nil this device returns for a texture it cannot make, with the sentence that says why: Metal validates nothing before
 * this call (the base class has no -newTextureWithDescriptor: at all), so this line is the only account of the refusal */
static id
hm_refuse_texture(NSString *why)
{
	hm_print("refused: a texture: %s\n", [why UTF8String]);
	return nil;
}

/*
 * Whether a texture is made compressed (UBWC, hakios_metal_texture_new_compressed): one the GPU only samples, which the
 * CPU fills through -replaceRegion: and reads through -getBytes: -- a 2D, one-level, single-sampled RGBA8 or BGRA8
 * texture of shared storage, used for ShaderRead alone, of 256x256 pixels or more. CoreAnimation's large
 * read-only textures are most of what its heavy frames read, and compressed they read in half the time (probe "UBWC").
 * Boot-arg metal_noubwc makes every texture linear as before.
 */
static BOOL
hm_compress_ok(void)
{
	static int off = -1;

	if (off < 0) {
		char args[1024] = {0};
		size_t size = sizeof(args) - 1;

		off = sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "metal_noubwc") != NULL;
	}
	return !off;
}

static BOOL
hm_compress(MTLTextureDescriptor *descriptor, MTLTextureUsage usage)
{
	return hm_compress_ok() && [descriptor textureType] == MTLTextureType2D && [descriptor mipmapLevelCount] == 1 && [descriptor sampleCount] == 1 &&
	       ([descriptor pixelFormat] == MTLPixelFormatRGBA8Unorm || [descriptor pixelFormat] == MTLPixelFormatBGRA8Unorm) &&
	       usage == MTLTextureUsageShaderRead &&
	       [descriptor storageMode] == MTLStorageModeShared &&
	       [descriptor width] * [descriptor height] >= 65536;
}

/*
 * The one gate a texture descriptor passes here, by hand. Metal's own validator (-[MTLTextureDescriptorInternal
 * validateWithDevice:]) is an assert that ends in abort(), like every validation context of this Metal, so it is never
 * called; and _MTLDevice has no -newTextureWithDescriptor: of its own to fall back on. What is served is what hakios-metal's
 * texture.hpp serves: one 2D level, one slice, one sample, shared memory, read and/or written by a kernel. The type, the
 * pixel format and the usage bits go to hakios_metal_texture_new as Metal's own numbers, so a format outside its table is
 * refused by the core with the format's name, and nothing here translates them a second time.
 */
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor
{
	hakios_metal_texture *texture;
	MTLTextureUsage usage;
	MTLTextureSwizzleChannels swizzle;

	if (hm_timeline_on() && descriptor != nil && [descriptor width] * [descriptor height] >= 500000) {
		hm_print("timeline: a texture of %lux%lu, format %lu, storage %lu, usage %#lx (not a surface)\n", (unsigned long)[descriptor width],
			 (unsigned long)[descriptor height], (unsigned long)[descriptor pixelFormat], (unsigned long)[descriptor storageMode],
			 (unsigned long)[descriptor usage]);
	}
	if (descriptor == nil || ![descriptor isKindOfClass:[MTLTextureDescriptor class]]) {
		return hm_refuse_texture([NSString stringWithFormat:@"the descriptor is %s, not an MTLTextureDescriptor",
							    descriptor != nil ? class_getName(object_getClass(descriptor)) : "nil"]);
	}
	if ([descriptor textureType] > MTLTextureType3D) {
		return hm_refuse_texture([NSString stringWithFormat:@"texture type %lu is past 3D (7): a multisample array or a texture buffer, "
							    "not served", (unsigned long)[descriptor textureType]]);
	}
	if ([descriptor arrayLength] != 1 && [descriptor textureType] != MTLTextureType2DArray && [descriptor textureType] != MTLTextureType1DArray &&
	    [descriptor textureType] != MTLTextureTypeCubeArray) {
		return hm_refuse_texture([NSString stringWithFormat:@"an array of %lu slices; one slice is served",
							    (unsigned long)[descriptor arrayLength]]);
	}
	/* a multisample texture is a render target of 2 or 4 samples a pixel, resolved at the end of its pass (the core's
	 * hakios_metal_texture_new_multisample refuses another count or use by name) */
	if (([descriptor sampleCount] != 1) != ([descriptor textureType] == MTLTextureType2DMultisample)) {
		return hm_refuse_texture([NSString stringWithFormat:@"%lu samples for texture type %lu; a count past 1 is a 2D multisample "
							    "texture's (4) alone", (unsigned long)[descriptor sampleCount], (unsigned long)[descriptor textureType]]);
	}
	if ([descriptor depth] != 1 && [descriptor textureType] != MTLTextureType3D) {
		return hm_refuse_texture([NSString stringWithFormat:@"depth %lu for a 2D texture (it has depth 1)", (unsigned long)[descriptor depth]]);
	}
	if ([descriptor textureType] == MTLTextureType1D && [descriptor height] != 1) {
		return hm_refuse_texture([NSString stringWithFormat:@"a 1D texture %lu high (it has height 1)", (unsigned long)[descriptor height]]);
	}
	if ([descriptor width] > 0xffffffffUL || [descriptor height] > 0xffffffffUL) {
		return hm_refuse_texture([NSString stringWithFormat:@"%lux%lu does not fit the core's 32-bit sizes",
							    (unsigned long)[descriptor width], (unsigned long)[descriptor height]]);
	}
	usage = [descriptor usage];
	/* the right to make views of it later: the view that changes nothing is made, one that reinterprets the format is
	 * refused by name where it is asked for (-newTextureViewWithPixelFormat:...), so the bit is nothing to refuse here */
	usage &= ~(MTLTextureUsage)MTLTextureUsagePixelFormatView;
	/* ShaderRead, ShaderWrite and RenderTarget (4) all go to hakios_metal_texture_new as Metal's bits: the layout is the
	 * same linear one for all three, and the usage decides what a dispatch (write) or a draw (render target) may do to
	 * the texture, each refused by name without its bit */
	if (usage & ~(MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget)) {
		return hm_refuse_texture([NSString stringWithFormat:@"usage %#lx has bits this plug-in does not know", (unsigned long)usage]);
	}
	if (usage == MTLTextureUsageUnknown) {
		/* Metal's pre-iOS 9 default, which lets a texture be used every way; here that is read and written by a
		 * kernel and drawn into by a render pass */
		HM_ONCE("a texture was asked for with usage Unknown (0); it is given shader read, shader write and render target, the "
			"three uses one has here\n");
		usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
		if ([descriptor pixelFormat] == MTLPixelFormatDepth16Unorm || [descriptor pixelFormat] == MTLPixelFormatStencil8 ||
	    [descriptor pixelFormat] == MTLPixelFormatDepth32Float || [descriptor pixelFormat] == MTLPixelFormatDepth32Float_Stencil8) {
			usage = MTLTextureUsageRenderTarget;   /* a depth texture is tiled and is an attachment alone (hakios-metal's texture.hpp) */
		}
		{
			unsigned bw = 1, bh = 1, bytes = 0;

			if (hakios_metal_format_block((unsigned)[descriptor pixelFormat], &bw, &bh, &bytes) && (bw > 1 || bh > 1)) {
				usage = MTLTextureUsageShaderRead;   /* a compressed format is sampled alone */
			} else if ([descriptor textureType] == MTLTextureTypeCube || [descriptor textureType] == MTLTextureTypeCubeArray ||
				   [descriptor textureType] == MTLTextureType1DArray) {
				/* their faces and layers are drawn into and sampled; a kernel does not store into them here */
				usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
			}
		}
	}
	/* Whole-pass sysmem replay needs backing even for a pass which never stores.
	 * Retain it in the fence-safe BO pool, capped at 256 MiB per device. */
	if ([descriptor storageMode] == MTLStorageModeMemoryless) {
		HM_ONCE("memoryless attachments retain backing for whole-pass sysmem replay\n");
	}
	if ([descriptor storageMode] == MTLStorageModePrivate) {
		HM_ONCE("a texture was asked for with private storage; every texture here is shared memory, and that is what is "
			"given (the GPU reads the same pages the processor maps)\n");
	}
	if ([descriptor compressionType] != MTLTextureCompressionTypeLossless) {
		return hm_refuse_texture([NSString stringWithFormat:@"compression type %ld; this GPU's linear layout is not compressed "
							    "(lossless, 0, is what every texture here is)", (long)[descriptor compressionType]]);
	}
	swizzle = [descriptor swizzle];
	/* A swizzle in the descriptor (AppleMetalGLRenderer's -setSwizzleKey:, the same field: GL_LUMINANCE as R8 read
	 * (r, r, r, 1), GL_ALPHA as (0, 0, 0, r)...): the texture is made plain and handed out as a swizzled view of itself,
	 * the core composing the swizzle into the view's descriptors as -newTextureViewWithPixelFormat:...swizzle: does. A key
	 * of four zeros, which no caller means (every channel 0), is taken as the identity. */
	if ((swizzle.red != MTLTextureSwizzleRed || swizzle.green != MTLTextureSwizzleGreen || swizzle.blue != MTLTextureSwizzleBlue ||
	     swizzle.alpha != MTLTextureSwizzleAlpha) &&
	    !(swizzle.red == 0 && swizzle.green == 0 && swizzle.blue == 0 && swizzle.alpha == 0)) {
		MTLTextureDescriptor *plain = [[descriptor copy] autorelease];
		HakiosMetalTexture *base, *view;

		[plain setSwizzle:MTLTextureSwizzleChannelsDefault];
		base = [self newTextureWithDescriptor:plain];
		if (base == nil) {
			return nil;   /* (said by the call above) */
		}
		view = [base newTextureViewWithPixelFormat:[plain pixelFormat] textureType:[plain textureType]
						    levels:NSMakeRange(0, [plain mipmapLevelCount])
						    slices:NSMakeRange(0, [plain textureType] == MTLTextureType3D ? 1 : [base arrayLength] *
								       ([plain textureType] == MTLTextureTypeCube || [plain textureType] == MTLTextureTypeCubeArray ? 6 : 1))
						   swizzle:swizzle];
		[base release];   /* (the view keeps it) */
		if (view == nil) {
			return hm_refuse_texture([NSString stringWithFormat:@"a swizzle of (%u %u %u %u) over pixel format %lu", swizzle.red, swizzle.green,
								    swizzle.blue, swizzle.alpha, (unsigned long)[plain pixelFormat]]);
		}
		HM_ONCE("a texture with a swizzle in its descriptor (%u %u %u %u) is a swizzled view of a texture of its own\n", swizzle.red,
			swizzle.green, swizzle.blue, swizzle.alpha);
		return view;
	}
	/* the mip levels are the core's (texture.hpp: fdl6_layout's rule, which the TP follows): it refuses a count past the
	 * bottom of the chain with the numbers */
	uint64_t previous = hm_bo_begin((unsigned)[descriptor pixelFormat],
		(unsigned)usage | ((unsigned)[descriptor sampleCount] << 8) | ((unsigned)[descriptor textureType] << 16),
		[descriptor storageMode] == MTLStorageModeMemoryless ? HM_BO_MEMORYLESS : HM_BO_TEXTURE);
	if ([descriptor textureType] == MTLTextureType2DMultisample) {
		/* drawn into and resolved, never read or written by a shader here: the shader bits Metal's Unknown default
		 * gives are dropped rather than refused */
		texture = hakios_metal_texture_new_multisample(_gpu, (unsigned)[descriptor pixelFormat], (unsigned)[descriptor width],
							       (unsigned)[descriptor height], (unsigned)[descriptor sampleCount],
							       (unsigned)(usage & ~(MTLTextureUsage)MTLTextureUsageShaderWrite));
	} else if ([descriptor textureType] == MTLTextureType1DArray || [descriptor textureType] == MTLTextureTypeCubeArray ||
		   [descriptor textureType] == MTLTextureTypeCube || [descriptor textureType] == MTLTextureType2DArray) {
		/* the layered types, with their mip levels (each layer the chain of them). A cube's and a cube array's slices
		 * are its faces, six a cube, as Metal's slice numbering has them; a 1D array is one row high */
		const MTLTextureType type = [descriptor textureType];
		const BOOL faces = type == MTLTextureTypeCube || type == MTLTextureTypeCubeArray;
		const NSUInteger layers = type == MTLTextureTypeCube ? 6 : [descriptor arrayLength] * (faces ? 6 : 1);
		texture = hakios_metal_texture_new_layered(_gpu, (unsigned)type, (unsigned)[descriptor pixelFormat], (unsigned)[descriptor width],
							   faces ? (unsigned)[descriptor width] : type == MTLTextureType1DArray ? 1 : (unsigned)[descriptor height],
							   (unsigned)layers, (unsigned)[descriptor mipmapLevelCount], (unsigned)usage);
	} else if ([descriptor textureType] == MTLTextureType3D) {
		texture = hakios_metal_texture_new_3d(_gpu, (unsigned)[descriptor pixelFormat], (unsigned)[descriptor width], (unsigned)[descriptor height],
						      (unsigned)[descriptor depth], (unsigned)usage);
	} else if (hm_compress(descriptor, usage)) {
		texture = hakios_metal_texture_new_compressed(_gpu, (unsigned)[descriptor pixelFormat], (unsigned)[descriptor width],
							      (unsigned)[descriptor height], (unsigned)usage);
		if (hm_timeline_on()) {
			hm_print("timeline: a compressed texture of %lux%lu, format %lu: %s\n", (unsigned long)[descriptor width], (unsigned long)[descriptor height],
				 (unsigned long)[descriptor pixelFormat], texture != NULL ? "made" : hakios_metal_error());
		}
	} else {
		texture = hakios_metal_texture_new_levels(_gpu, (unsigned)[descriptor textureType], (unsigned)[descriptor pixelFormat],
							  (unsigned)[descriptor width], (unsigned)[descriptor height],
							  (unsigned)[descriptor mipmapLevelCount], (unsigned)usage);
	}
	hm_bo_end(previous);
	if (texture == NULL) {
		/* the core's own sentence: the format by name, a size outside 1..32767, or no memory */
		return hm_refuse_texture([NSString stringWithFormat:@"%lux%lu, pixel format %lu, usage %#lx: %s", (unsigned long)[descriptor width],
							    (unsigned long)[descriptor height], (unsigned long)[descriptor pixelFormat],
							    (unsigned long)usage, hakios_metal_error()]);
	}
	return [[HakiosMetalTexture alloc] initWithHakiosDevice:self texture:texture descriptor:descriptor usage:usage];
}

/* An IOSurface is the window server's memory, and what CAMetalLayer makes its drawables of: the texture is the
 * surface's own pixels (hakios-metal asks the kernel for the surface's memory as a GPU buffer), so drawing into it is
 * drawing into what the compositor reads. A refusal here is LOUD and named, never a quiet nil: the earlier plug-in's
 * nil became a drawable with a nil texture that CoreAnimation asserted on somewhere else. */
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor iosurface:(IOSurfaceRef)surface plane:(NSUInteger)plane
{
	hm_drawables_install();
	if (hm_timeline_on() && descriptor != nil && [descriptor width] * [descriptor height] >= 500000) {
		hm_print("timeline: a texture of %lux%lu, format %lu, usage %#lx, over surface %u\n", (unsigned long)[descriptor width],
			 (unsigned long)[descriptor height], (unsigned long)[descriptor pixelFormat], (unsigned long)[descriptor usage],
			 surface != NULL ? IOSurfaceGetID(surface) : 0);
	}
	MTLTextureUsage usage;
	hakios_metal_texture *texture;
	HakiosMetalTexture *t;

	/* The kernel hands the surface's memory to the GPU by its ID (hakios-metal: Texture::wrapSurface), so the texture's
	 * rows are the surface's: what the display or another process reads is what is drawn. Only the descriptor's shape is
	 * checked here; the rows, the FourCC against the format and the size are hakios-metal's to judge, by name. */
	if (descriptor == nil || ![descriptor isKindOfClass:[MTLTextureDescriptor class]] || surface == NULL) {
		return hm_refuse_texture(@"an IOSurface texture needs an MTLTextureDescriptor and a surface");
	}
	if ([descriptor textureType] != MTLTextureType2D || [descriptor mipmapLevelCount] != 1 || [descriptor sampleCount] != 1 ||
	    [descriptor arrayLength] != 1) {
		return hm_refuse_texture([NSString stringWithFormat:@"an IOSurface texture of type %lu, %lu levels, %lu samples, %lu slices: a "
							    "single-level 2D texture is what a surface takes", (unsigned long)[descriptor textureType],
							    (unsigned long)[descriptor mipmapLevelCount], (unsigned long)[descriptor sampleCount],
							    (unsigned long)[descriptor arrayLength]]);
	}
	usage = [descriptor usage];
	if (usage == MTLTextureUsageUnknown) {
		usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
	}
	usage &= MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
	/*
	 * A framebuffer with a rotation (MTLTextureDescriptor's private -rotation, 1 to 3 quarter turns): backboardd makes
	 * one when an application turns the screen, a 2436 x 1125 texture over the 1125 x 2436 display surface, and draws
	 * it landscape whatever the device answers for render target rotation. The RB writes rows as they lie, so it draws
	 * into a texture of its own of the descriptor's size, kept with the surface's texture so that a pass loading the
	 * last frame finds it there, and the 2D engine lays it into the surface turned (-hakiosTurnInto:, at the command
	 * buffer's commit).
	 */
	{
		const NSUInteger rotation = [descriptor respondsToSelector:sel_getUid("rotation")] ?
						    ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, sel_getUid("rotation")) : 0;

		if (rotation >= 1 && rotation <= 3 && IOSurfaceGetPlaneCount(surface) <= 1 && plane == 0) {
			const BOOL quarter = rotation != 2;
			const size_t sw = IOSurfaceGetWidth(surface), sh = IOSurfaceGetHeight(surface);

			if (quarter ? ([descriptor width] == sh && [descriptor height] == sw) : ([descriptor width] == sw && [descriptor height] == sh)) {
				hakios_metal_texture *upright = hakios_metal_texture_new_iosurface(_gpu, IOSurfaceGetID(surface), 0, (unsigned)[descriptor pixelFormat],
												   (unsigned)sw, (unsigned)sh,
												   (unsigned)(MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget));
				uint64_t previous = hm_bo_begin((unsigned)[descriptor pixelFormat],
					MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget, HM_BO_TEXTURE);
				hakios_metal_texture *drawn = upright == NULL ? NULL :
							      hakios_metal_texture_new_levels(_gpu, 2, (unsigned)[descriptor pixelFormat], (unsigned)[descriptor width],
											      (unsigned)[descriptor height], 1,
											      (unsigned)(MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget));
				hm_bo_end(previous);

				if (drawn != NULL) {
					HM_ONCE("a framebuffer turned by rotation %lu over IOSurface %u (%zux%zu) is drawn %lux%lu and turned into the "
						"surface by the 2D engine at each commit\n", (unsigned long)rotation, IOSurfaceGetID(surface), sw, sh,
						(unsigned long)[descriptor width], (unsigned long)[descriptor height]);
					t = [[HakiosMetalTexture alloc] initWithHakiosDevice:self texture:drawn descriptor:descriptor
										       usage:MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget];
					[t hakiosSetIOSurface:surface plane:0];
					/* Metal's rotation n is the 2D engine's a6xx_rotation n (a guess the display settles: see the
					 * screenshots of a turned screen) */
					[t hakiosSetTurned:upright rotation:(unsigned)rotation];
					return t;
				}
				if (upright != NULL) {
					hakios_metal_texture_free(upright);
				}
			}
		}
	}
	if (([descriptor pixelFormat] == 500 || [descriptor pixelFormat] == 540) && IOSurfaceGetPlaneCount(surface) == 2 && plane == 0) {
		/* the private two-plane formats a decoded picture is sampled through, read and never drawn into: 500,
		 * CoreAnimation's for a photo, sampled as RGB; and 540 (MTLPixelFormatRGB8_420_2P by the descriptor's own
		 * description), VideoToolbox's for the live wallpaper's 512x512 '420f' frames, sampled as the planes'
		 * own values (-hakiosConvertYCbCr) */
		/* as an RGBA8 copy converted from the planes (-hakiosShadowYCbCr:): the texture unit here does not convert
		 * as Apple's does */
		/* (compressed where it is large enough, as hm_compress decides for a texture of its own: the copy is sampled
		 * and only ever written through replace, and SpringBoard's heavy frames read a 1105x1160 one most after the
		 * wallpaper) */
		hakios_metal_texture *copy = NULL;
		/* The conversion pass writes this shadow as an image.  Compressed textures are
		 * read-only in hakios-metal, so YCbCr shadows always use a linear RGBA8 target. */
		copy = hakios_metal_texture_new_levels(_gpu, 2, 70, (unsigned)[descriptor width], (unsigned)[descriptor height], 1,
							(unsigned)(MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite));
		if (copy == NULL) {
			return hm_refuse_texture([NSString stringWithFormat:@"a %lux%lu RGBA8 copy of a two-plane surface: %s",
							    (unsigned long)[descriptor width], (unsigned long)[descriptor height], hakios_metal_error()]);
		}
		HM_ONCE("a two-plane YCbCr surface sampled as format %lu is read through an RGBA8 copy converted from it, made again "
			"when the surface changes\n", (unsigned long)[descriptor pixelFormat]);
		t = [[HakiosMetalTexture alloc] initWithHakiosDevice:self texture:copy descriptor:descriptor usage:MTLTextureUsageShaderRead];
		[t hakiosShadowYCbCr:surface format:[descriptor pixelFormat]];
		return t;
	} else if (IOSurfaceGetPlaneCount(surface) > 1) {
		const OSType fourcc = IOSurfaceGetPixelFormat(surface);
		if (IOSurfaceGetPlaneCount(surface) != 2 || plane >= 2 || (fourcc != 0x34323066 && fourcc != 0x34323076)) {
			return hm_refuse_texture(@"a raw plane texture needs plane 0 or 1 of a two-plane 420f/420v IOSurface");
		}
		const size_t pw = IOSurfaceGetWidthOfPlane(surface, plane), ph = IOSurfaceGetHeightOfPlane(surface, plane);
		const size_t pitch = IOSurfaceGetBytesPerRowOfPlane(surface, plane);
		const size_t element = IOSurfaceGetBytesPerElementOfPlane(surface, plane);
		const uintptr_t base = (uintptr_t)IOSurfaceGetBaseAddress(surface), start = (uintptr_t)IOSurfaceGetBaseAddressOfPlane(surface, plane);
		const size_t offset = start - base, alloc = IOSurfaceGetAllocSize(surface);
		unsigned bw, bh, bytes;
		/* VideoToolbox writes four Y bytes (or two CbCr pairs) through each RGBA8 texel.
		 * This is a raw packed view, not an RGB image to convert as private format 500. */
		if (base == 0 || start < base || element != (plane == 0 ? 1u : 2u) ||
		    !hakios_metal_format_block((unsigned)[descriptor pixelFormat], &bw, &bh, &bytes) || bw != 1 || bh != 1 ||
		    bytes < element || [descriptor width] == 0 || [descriptor height] == 0 || [descriptor width] > pw ||
		    [descriptor height] > ph || (uint64_t)[descriptor width] * bytes > (uint64_t)pw * element ||
		    (uint64_t)pw * element > pitch || offset > alloc || (uint64_t)pitch * ph > alloc - offset) {
			return hm_refuse_texture([NSString stringWithFormat:@"IOSurface %u plane %lu: format %lu, %lux%lu does not fit %zux%zu, %zu-byte elements, pitch %zu",
				IOSurfaceGetID(surface), (unsigned long)plane, (unsigned long)[descriptor pixelFormat],
				(unsigned long)[descriptor width], (unsigned long)[descriptor height], pw, ph, element, pitch]);
		}
		const BOOL shadow = pitch % 64 != 0 || offset % 64 != 0;
		texture = shadow ? hakios_metal_texture_new_levels(_gpu, 2, (unsigned)[descriptor pixelFormat],
			(unsigned)[descriptor width], (unsigned)[descriptor height], 1, (unsigned)usage) :
			hakios_metal_texture_new_iosurface_plane(_gpu, IOSurfaceGetID(surface), (unsigned)plane, (unsigned)[descriptor pixelFormat],
				(unsigned)[descriptor width], (unsigned)[descriptor height], (unsigned)usage, offset, (unsigned)pitch, (unsigned)pw, (unsigned)ph);
		if (texture != NULL) {
			t = [[HakiosMetalTexture alloc] initWithHakiosDevice:self texture:texture descriptor:descriptor usage:usage];
			if (shadow) [t hakiosShadow:surface plane:plane];
			else [t hakiosSetIOSurface:surface plane:plane];
			if (hm_handoff_on()) hm_diag_add(&hm_diag.planeImports);
			static unsigned imports;
			if (__atomic_fetch_add(&imports, 1, __ATOMIC_RELAXED) < 32) {
				hm_print("iosurface-plane: IOSurface %u '%c%c%c%c' plane %lu, format %lu, texture %lux%lu, plane %zux%zu, offset %zu, pitch %zu, usage %#lx: %s\n",
					IOSurfaceGetID(surface), (char)(fourcc >> 24), (char)(fourcc >> 16), (char)(fourcc >> 8), (char)fourcc,
					(unsigned long)plane, (unsigned long)[descriptor pixelFormat], (unsigned long)[descriptor width],
					(unsigned long)[descriptor height], pw, ph, offset, pitch, (unsigned long)usage,
					shadow ? "raw plane shadow" : "shared plane");
			}
			return t;
		}
	} else {
		/* A surface is drawn into whatever usage its texture was asked with: CoreAnimation renders a material's
		 * snapshot (the App Library's blurred wallpaper) into a texture it made with ShaderRead alone, and Apple's
		 * driver does not hold it to the usage. A surface's rows are linear, so a render target costs nothing here;
		 * one is added wherever the core takes it for the format, and the usage asked for is the fallback. */
		texture = NULL;
		if ((usage & MTLTextureUsageRenderTarget) == 0) {
			texture = hakios_metal_texture_new_iosurface(_gpu, IOSurfaceGetID(surface), (unsigned)plane, (unsigned)[descriptor pixelFormat],
								     (unsigned)[descriptor width], (unsigned)[descriptor height],
								     (unsigned)(usage | MTLTextureUsageRenderTarget));
			if (texture != NULL) {
				usage |= MTLTextureUsageRenderTarget;
			}
		}
		if (texture == NULL) {
			texture = hakios_metal_texture_new_iosurface(_gpu, IOSurfaceGetID(surface), (unsigned)plane, (unsigned)[descriptor pixelFormat],
								     (unsigned)[descriptor width], (unsigned)[descriptor height], (unsigned)usage);
		}
	}
	if (texture == NULL && IOSurfaceGetPlaneCount(surface) <= 1 && IOSurfaceGetBytesPerRow(surface) % 64 != 0 &&
	    ([descriptor usage] == MTLTextureUsageUnknown ||
	     ([descriptor usage] & ~MTLTextureUsagePixelFormatView & ~MTLTextureUsageShaderRead & ~MTLTextureUsageRenderTarget &
	      ~MTLTextureUsageShaderWrite) == 0) &&
	    plane == 0) {
		/* rows the GPU cannot take where they lie: a copy of them (-hakiosShadow:), made again when the surface
		 * changes. Whatever writes the copy -- a kernel, or a pass drawing into it, which backboardd does with the
		 * App Library's snapshot (4512-byte rows) whatever usage it asked for -- goes back into the surface when its
		 * command buffer completes (-hakiosWriteBackShadow); a render target is given wherever the format takes one,
		 * as over an aligned surface above */
		const MTLTextureUsage writes = [descriptor usage] & MTLTextureUsageShaderWrite;
		MTLTextureUsage copyUsage = MTLTextureUsageShaderRead | writes | MTLTextureUsageRenderTarget;
		hakios_metal_texture *copy = hakios_metal_texture_new_levels(_gpu, 2, (unsigned)[descriptor pixelFormat], (unsigned)[descriptor width],
									     (unsigned)[descriptor height], 1, (unsigned)copyUsage);

		if (copy == NULL) {
			copyUsage = MTLTextureUsageShaderRead | writes;
			copy = hakios_metal_texture_new_levels(_gpu, 2, (unsigned)[descriptor pixelFormat], (unsigned)[descriptor width],
							       (unsigned)[descriptor height], 1, (unsigned)copyUsage);
		}
		if (copy != NULL) {
			HM_ONCE("a texture over an IOSurface of rows the GPU cannot take (%zu bytes) is a copy of them, made again when the "
				"surface changes\n", IOSurfaceGetBytesPerRow(surface));
			t = [[HakiosMetalTexture alloc] initWithHakiosDevice:self texture:copy descriptor:descriptor usage:copyUsage];
			[t hakiosShadow:surface];
			if (hm_handoff_on()) hm_diag_add(&hm_diag.imports);
			return t;
		}
	}
	if (texture == NULL) {
		/* what the surface is, beside the core's sentence: a format the core does not take is most often a layout of
		 * the surface's (a FourCC and its planes) that it has not been taught, and these are what teach it */
		OSType fourcc = IOSurfaceGetPixelFormat(surface);
		size_t planes = IOSurfaceGetPlaneCount(surface);
		char shape[160];

		snprintf(shape, sizeof(shape), "'%c%c%c%c', %zux%zu, %zu rows of %zu bytes, %zu plane(s)", (char)(fourcc >> 24), (char)(fourcc >> 16),
			 (char)(fourcc >> 8), (char)fourcc, IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface), IOSurfaceGetHeight(surface),
			 IOSurfaceGetBytesPerRow(surface), planes);
		if (planes > 1) {
			size_t l = strlen(shape);

			snprintf(shape + l, sizeof(shape) - l, "; plane 1 %zux%zu, rows of %zu bytes", IOSurfaceGetWidthOfPlane(surface, 1),
				 IOSurfaceGetHeightOfPlane(surface, 1), IOSurfaceGetBytesPerRowOfPlane(surface, 1));
		}
		/* and the pixel format by Metal's own name for it: the private ones (500 and up) are numbered nowhere public,
		 * and the descriptor's description is the one place the system names them */
		NSString *named = @"";
		for (NSString *line in [[descriptor description] componentsSeparatedByString:@"\n"]) {
			if ([line rangeOfString:@"pixelFormat"].location != NSNotFound) {
				named = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
				break;
			}
		}
		const unsigned long rotation = [descriptor respondsToSelector:sel_getUid("rotation")] ?
						   ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, sel_getUid("rotation")) : 0;
		return hm_refuse_texture([NSString stringWithFormat:@"over IOSurface %u (%s), plane %lu, usage %#lx, %@, rotation %lu: %s",
								    IOSurfaceGetID(surface), shape, (unsigned long)plane, (unsigned long)[descriptor usage], named,
								    rotation, hakios_metal_error()]);
	}
	if (plane == 0 && IOSurfaceGetPlaneCount(surface) <= 1) {
		hm_flat_census("an IOSurface", hakios_metal_texture_resource_id(texture), (unsigned)[descriptor pixelFormat], [descriptor width],
			       [descriptor height], IOSurfaceGetBaseAddress(surface), IOSurfaceGetBytesPerRow(surface));
	}
	t = [[HakiosMetalTexture alloc] initWithHakiosDevice:self texture:texture descriptor:descriptor usage:usage];
	[t hakiosSetIOSurface:surface plane:plane];
	if (hm_handoff_on()) hm_diag_add(&hm_diag.imports);
	return t;
}

/* The other resource kinds, each refused by name: the base class answers these with nil-stubs that say nothing. */

/* --- samplers --- */

static id
hm_refuse_sampler(NSString *why)
{
	hm_print("refused: a sampler state: %s\n", [why UTF8String]);
	return nil;
}

/*
 * The descriptor's fields, checked against the ranges -[_MTLSamplerState initWithDevice:samplerDescriptor:] asserts on
 * (see its declaration above), BEFORE the sampler is made and before super is called: an invalid value handed to super
 * kills the process, and this method is the only gate in front of it (_MTLDevice has no -newSamplerStateWithDescriptor:
 * of its own). Then the fields go to hakios_metal_sampler_new in Metal's own numbering (MTLSampler.h, MTLDepthStencil.h),
 * and what the core does not serve -- a value outside Metal's enums, or ClampToZero beside a coloured border on one
 * sampler (its one BCOLOR) -- comes back as NULL with the core's sentence, which is printed and turned into nil. Only a
 * descriptor that passed both is given to super.
 */
- (id)newSamplerStateWithDescriptor:(MTLSamplerDescriptor *)descriptor
{
	struct hakios_metal_sampler_desc desc;
	hakios_metal_sampler *sampler;

	if (descriptor == nil || ![descriptor isKindOfClass:[MTLSamplerDescriptor class]]) {
		return hm_refuse_sampler([NSString stringWithFormat:@"the descriptor is %s, not an MTLSamplerDescriptor (Metal's own init would abort on it)",
							    descriptor != nil ? class_getName(object_getClass(descriptor)) : "nil"]);
	}
	memset(&desc, 0, sizeof(desc));
	desc.min_filter = (unsigned)[descriptor minFilter];
	desc.mag_filter = (unsigned)[descriptor magFilter];
	desc.mip_filter = (unsigned)[descriptor mipFilter];
	desc.s_address = (unsigned)[descriptor sAddressMode];
	desc.t_address = (unsigned)[descriptor tAddressMode];
	desc.r_address = (unsigned)[descriptor rAddressMode];
	desc.normalized_coordinates = [descriptor normalizedCoordinates] ? 1 : 0;
	desc.lod_min_clamp = [descriptor lodMinClamp];
	desc.lod_max_clamp = [descriptor lodMaxClamp];
	desc.max_anisotropy = (unsigned)[descriptor maxAnisotropy];
	desc.compare_function = (unsigned)[descriptor compareFunction];
	desc.border_color = (unsigned)[descriptor borderColor];
	if (desc.min_filter >= 3 || desc.mag_filter >= 3) {
		return hm_refuse_sampler([NSString stringWithFormat:@"min filter %u, mag filter %u: MTLSamplerMinMagFilter is Nearest 0 or "
							    "Linear 1 (Metal's own init asserts on anything from 3 up)", desc.min_filter, desc.mag_filter]);
	}
	if (desc.mip_filter >= 3) {
		return hm_refuse_sampler([NSString stringWithFormat:@"mip filter %u: MTLSamplerMipFilter is 0, 1 or 2", desc.mip_filter]);
	}
	if (desc.s_address >= 7 || desc.t_address >= 7 || desc.r_address >= 7) {
		return hm_refuse_sampler([NSString stringWithFormat:@"address modes %u %u %u: MTLSamplerAddressMode is 0 to 5 (Metal's own init "
							    "asserts from 7 up)", desc.s_address, desc.t_address, desc.r_address]);
	}
	if (desc.border_color >= 4) {
		return hm_refuse_sampler([NSString stringWithFormat:@"border colour %u: MTLSamplerBorderColor is 0, 1 or 2", desc.border_color]);
	}
	if (desc.compare_function > 7) {
		return hm_refuse_sampler([NSString stringWithFormat:@"compare function %u: MTLCompareFunction is Never 0 to Always 7", desc.compare_function]);
	}
	if ([descriptor supportArgumentBuffers]) {
		HM_ONCE("a sampler was asked for with supportArgumentBuffers; this plug-in has no argument buffers, and the sampler is "
			"made for the encoder's -setSamplerState: alone\n");
	}
	sampler = hakios_metal_sampler_new(_gpu, &desc);
	if (sampler == NULL) {
		/* the core's sentence names the mode it does not serve */
		return hm_refuse_sampler([NSString stringWithFormat:@"filters %u/%u/%u, address modes %u/%u/%u, border %u, compare %u, "
							    "anisotropy %u: %s", desc.min_filter, desc.mag_filter, desc.mip_filter, desc.s_address,
							    desc.t_address, desc.r_address, desc.border_color, desc.compare_function,
							    desc.max_anisotropy, hakios_metal_error()]);
	}
	return [[HakiosMetalSamplerState alloc] initWithHakiosDevice:self sampler:sampler descriptor:descriptor];
}

/* Both halves of a depth/stencil state are served (hakios-metal's DepthState and StencilState): the faces are read into
 * the state once and each draw that binds it carries them. */
- (id)newDepthStencilStateWithDescriptor:(MTLDepthStencilDescriptor *)descriptor
{
	if (descriptor == nil || ![descriptor isKindOfClass:[MTLDepthStencilDescriptor class]]) {
		hm_refusal(self, _cmd, "was given no MTLDepthStencilDescriptor; it returns nil");
		return nil;
	}
	return [[HakiosMetalDepthStencilState alloc] initWithDevice:(id<MTLDevice>)self descriptor:descriptor];
}

/* MTLArgumentDescriptor members, in the layout the front end reads back (HakiosMetalArgumentEncoder) */
- (id)newArgumentEncoderWithArguments:(NSArray *)arguments
{
	return [[HakiosMetalArgumentEncoder alloc] initWithDevice:self arguments:arguments];
}

/* What a heap has to hold a texture or a buffer made from it: the core's plan of the texture, the same one creation
 * allocates by, so a heap sized from these (MPS sizes its temporary-texture heaps so) has room for what it is then asked
 * to make; HakiosMetalHeap counts each resource's allocatedSize, which is the same number. 4 KiB alignment: every
 * layout here starts on a page. */
- (MTLSizeAndAlign)heapTextureSizeAndAlignWithDescriptor:(MTLTextureDescriptor *)descriptor
{
	MTLTextureUsage usage = [descriptor usage] & ~(MTLTextureUsage)MTLTextureUsagePixelFormatView;
	const MTLTextureType type = [descriptor textureType];
	const BOOL depth = [descriptor pixelFormat] == MTLPixelFormatDepth16Unorm || [descriptor pixelFormat] == MTLPixelFormatStencil8 ||
	    [descriptor pixelFormat] == MTLPixelFormatDepth32Float || [descriptor pixelFormat] == MTLPixelFormatDepth32Float_Stencil8;
	const unsigned layers = type == MTLTextureType2DArray || type == MTLTextureType1DArray ? (unsigned)[descriptor arrayLength] :
				type == MTLTextureTypeCubeArray ? (unsigned)[descriptor arrayLength] * 6 : type == MTLTextureTypeCube ? 6 :
				type == MTLTextureType3D ? (unsigned)[descriptor depth] : 1;
	uint64_t bytes = 0;

	/* (the usage only decides what the plan accepts, not its bytes: Unknown is resolved as creation resolves it) */
	if (usage == MTLTextureUsageUnknown) {
		usage = depth || type == MTLTextureType2DMultisample ? MTLTextureUsageRenderTarget : MTLTextureUsageShaderRead;
	}
	if (type == MTLTextureType2DMultisample) {
		usage &= ~(MTLTextureUsage)MTLTextureUsageShaderWrite;
	}
	if (hakios_metal_texture_plan_bytes((unsigned)type, (unsigned)[descriptor pixelFormat], (unsigned)[descriptor width],
					    (unsigned)[descriptor height], layers, (unsigned)[descriptor mipmapLevelCount],
					    (unsigned)[descriptor sampleCount], (unsigned)usage, &bytes) != 0) {
		hm_print("refused: -heapTextureSizeAndAlignWithDescriptor: of %lux%lu, pixel format %lu, type %lu: %s; it answers 0 bytes\n",
			 (unsigned long)[descriptor width], (unsigned long)[descriptor height], (unsigned long)[descriptor pixelFormat],
			 (unsigned long)type, hakios_metal_error());
		return (MTLSizeAndAlign){ 0, 4096 };
	}
	return (MTLSizeAndAlign){ (NSUInteger)bytes, 4096 };
}

- (MTLSizeAndAlign)heapBufferSizeAndAlignWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{
	(void)options;
	return (MTLSizeAndAlign){ length, 256 };   /* a buffer's allocatedSize is its length */
}

- (id)newHeapWithDescriptor:(MTLHeapDescriptor *)descriptor
{
	if (descriptor == nil || [descriptor type] == MTLHeapTypePlacement) {
		hm_print("refused: a heap of type %ld: a placement heap puts resources at offsets of one allocation, and every resource "
			 "here is an allocation of its own; it returns nil\n", descriptor != nil ? (long)[descriptor type] : -1L);
		return nil;
	}
	return [[HakiosMetalHeap alloc] initWithDevice:self descriptor:descriptor];
}

/* A resource group is a residency set of Apple's GPU drivers: what it names is made resident together through the
 * command buffer that is handed it. Every allocation here is resident for as long as it exists, so a group would say
 * nothing; and its protocol (MTLResourceGroupSPI) is the GPU bundle's, not in this process. nil is the answer callers
 * already take as "no group": AppleCVAPhoto in mediaserverd tests it before each use and skips the call. */
- (id)newResourceGroupFromResources:(const id *)resources count:(NSUInteger)count
{
	(void)resources; (void)count;
	return nil;
}

- (id)newFence
{
	return [[HakiosMetalFence alloc] initWithDevice:(id<MTLDevice>)self];
}

- (id)newEvent
{
	return [[HakiosMetalEvent alloc] initWithDevice:(id<MTLDevice>)self];
}

- (id)newSharedEvent
{
	return [[HakiosMetalEvent alloc] initWithDevice:(id<MTLDevice>)self];
}

@end

/* ============================================================================================================
 * The buffer: hakios-metal's GPU memory with its CPU mapping
 * ============================================================================================================ */

@implementation HakiosMetalBuffer

/* Conformance is a static property of the class and callers test it (MPS tests the command buffer's before anything
 * else); it is declared for the one protocol this class does answer. */
+ (void)load
{
	hm_adopt(self, @protocol(MTLBuffer), "MTLBuffer");
}

HM_REFUSES_OUT_LOUD

- (instancetype)initWithHakiosDevice:(HakiosMetalDevice *)device length:(NSUInteger)length
{
	self = [super init];
	if (self == nil) {
		return nil;
	}
	_buffer = hakios_metal_buffer_new([device hakiosDevice], length);
	if (_buffer == NULL) {
		hm_print("refused: a buffer of %lu bytes: %s\n", (unsigned long)length, hakios_metal_error());
		[self release];
		return nil;
	}
	_device = [device retain];
	return self;
}

- (void)dealloc
{
	if (_buffer != NULL) {
		hakios_metal_buffer_free(_buffer);   /* a command buffer still using it keeps its own reference */
	}
	if (_deallocator != nil) {
		_deallocator(_callerBytes, _callerLength);
		[_deallocator release];
	}
	[_device release];
	[super dealloc];
}

- (void)hakiosSetDeallocator:(void (^)(void *, NSUInteger))deallocator bytes:(void *)bytes length:(NSUInteger)length
{
	_deallocator = [deallocator copy];
	_callerBytes = bytes;
	_callerLength = length;
}

- (hakios_metal_buffer *)hakiosBuffer {
    static int refresh = -1;
    if (refresh < 0) refresh = hm_ca_arg("metal_nocopy_refresh=1");
    /* (in an OpenGL ES process too: AppleMetalGLRenderer wraps GL's own buffer storage with -newBufferWithBytesNoCopy:,
     * and GL writes that storage, not the copy, between draws) */
    if ((refresh || hm_gles_active) && _callerBytes && _callerLength) {
        memcpy(hakios_metal_buffer_contents(_buffer), _callerBytes, _callerLength);
        HM_ONCE("metal_nocopy_refresh=1: borrowed CPU upload bytes refreshed at binding (diagnostic)\n");
    }
    return _buffer;
}

- (void *)contents          { return hakios_metal_buffer_contents(_buffer); }
/* -[IOGPUMetalResource isComplete] and -waitUntilComplete (hm_use_*), and IOGPUMetalBuffer's -iosurface: a buffer here is
 * never over a surface */
- (BOOL)isComplete          { return hm_use_complete(_uses); }
- (void)waitUntilComplete   { hm_use_wait(_uses); }
- (void)hakiosUsedBy:(uint64_t)seq { hm_use_mark(_uses, &_usesAt, seq); }
- (IOSurfaceRef)iosurface   { return NULL; }
- (NSUInteger)length        { return (NSUInteger)hakios_metal_buffer_length(_buffer); }
- (uint64_t)gpuAddress      { return hakios_metal_buffer_gpu_address(_buffer); }
- (NSUInteger)allocatedSize { return [self length]; }
- (id)device                { return _device; }

/* Shared write-combined memory needs no cache push; pending GPU uses still have to finish before CPU reuse. */
- (void)didModifyRange:(NSRange)range
{
    (void)range;
    if (hakios_metal_buffer_sync(_buffer) != 0) hm_print("refused: buffer CPU synchronization: %s\n", hakios_metal_error());
}

/* what was asked for does not change what was given: one kind of memory, described as what it is */
- (MTLStorageMode)storageMode               { return MTLStorageModeShared; }
- (MTLCPUCacheMode)cpuCacheMode             { return MTLCPUCacheModeWriteCombined; }
- (MTLResourceOptions)resourceOptions       { return MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined; }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeDefault; }
- (id)heap                                  { return nil; }   /* every buffer is its own allocation; nil is Metal's answer for that */
- (NSUInteger)heapOffset                    { return 0; }
- (BOOL)isAliasable                         { return NO; }

/* the kernel holds the pages from allocation to release, so a buffer here is never volatile, whatever was asked */
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state
{
	if (state == MTLPurgeableStateVolatile || state == MTLPurgeableStateEmpty) {
		HM_ONCE("a buffer was asked to become purgeable; the kernel does not purge GPU memory here, so it stays non-volatile\n");
	}
	return MTLPurgeableStateNonVolatile;
}

/* A texture over the buffer's own bytes (hakios-metal: Texture::overBuffer), when the rows are ones the TP takes from
 * memory as they lie: a pitch and a start that are multiples of 64 bytes. Rows that are not -- QuartzCore's
 * copy_image_to_texture hands an image's own row bytes, whatever its width made them -- are copied into a texture of
 * the GPU's layout instead, as the texture is made: a copy then, not a view, so a later write to the buffer is not seen
 * through it. Its one caller writes the buffer before and never after. */
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow
{
	MTLTextureUsage usage;
	hakios_metal_texture *texture;

	if (descriptor == nil || ![descriptor isKindOfClass:[MTLTextureDescriptor class]]) {
		hm_refusal(self, _cmd, "was given no MTLTextureDescriptor; it returns nil");
		return nil;
	}
	usage = [descriptor usage] == MTLTextureUsageUnknown ? (MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget)
							      : [descriptor usage];
	usage &= MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
	texture = hakios_metal_texture_new_buffer(_buffer, (unsigned)[descriptor textureType], (unsigned)[descriptor pixelFormat],
						  (unsigned)[descriptor width], (unsigned)[descriptor height], (unsigned)usage, (uint64_t)offset,
						  (uint64_t)bytesPerRow);
	if (texture == NULL && (bytesPerRow % 64 != 0 || offset % 64 != 0)) {
		const uint8_t *from = (const uint8_t *)hakios_metal_buffer_contents(_buffer) + offset;

		HM_ONCE("a texture over a buffer's rows of %lu bytes from %lu, which the GPU cannot take as they lie, is a copy of them, "
			"made now\n", (unsigned long)bytesPerRow, (unsigned long)offset);
		texture = hakios_metal_texture_new_levels([_device hakiosDevice], (unsigned)[descriptor textureType], (unsigned)[descriptor pixelFormat],
							  (unsigned)[descriptor width], (unsigned)[descriptor height], 1, (unsigned)usage);
		if (texture != NULL && hakios_metal_texture_replace(texture, 0, 0, (unsigned)[descriptor width], (unsigned)[descriptor height], from,
								    (uint64_t)bytesPerRow) != 0) {
			hakios_metal_texture_free(texture);
			texture = NULL;
		}
	}
	if (texture == NULL) {
		hm_print("refused: a texture over a buffer (%lux%lu, pixel format %lu, rows of %lu bytes from %lu): %s; nil\n",
			 (unsigned long)[descriptor width], (unsigned long)[descriptor height], (unsigned long)[descriptor pixelFormat],
			 (unsigned long)bytesPerRow, (unsigned long)offset, hakios_metal_error());
		return nil;
	}
	hm_flat_census("a texture over a buffer", hakios_metal_texture_resource_id(texture), (unsigned)[descriptor pixelFormat], [descriptor width],
		       [descriptor height], (const uint8_t *)hakios_metal_buffer_contents(_buffer) + offset, bytesPerRow);
	return [[HakiosMetalTexture alloc] initWithHakiosDevice:_device texture:texture descriptor:descriptor usage:usage];
}

/* the SPI form QuartzCore sends: the image size beside the rows, which a single 2D level does not need.
 * Over a no-copy buffer it is refused. QuartzCore (iOS 16.5, the texture upload at 0x18834e7bc: 0x18847b410) asks for it
 * over a CPU image's own pages, marks the texture as that memory (bit 0x200 at +0x7b) and from then on never uploads
 * to it: when the image is drawn again in place (a CPU-drawn layer's backing store, Freeform's stroke) it only records
 * the new generation. Here the buffer is a copy taken when it was made (see -newBufferWithBytesNoCopy:...), so the
 * texture kept the empty first frame (logs/test-1110-183501: 640x640 and 640x516 "through a texture over a buffer",
 * every sample 0) while the stroke was drawn. Given nil, QuartzCore makes a texture of its own and uploads the image
 * with -replaceRegion: each time it changes. */
- (id)newLinearTextureWithDescriptor:(MTLTextureDescriptor *)descriptor offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow
			bytesPerImage:(NSUInteger)bytesPerImage
{
	(void)bytesPerImage;
	if (_callerBytes != NULL) {
		HM_ONCE("refused: a linear texture over a no-copy buffer (%lux%lu): the buffer is a copy, not the caller's memory; nil, "
			"so QuartzCore uploads the image itself\n", (unsigned long)[descriptor width], (unsigned long)[descriptor height]);
		return nil;
	}
	return [self newTextureWithDescriptor:descriptor offset:offset bytesPerRow:bytesPerRow];
}

/* debug markers name ranges for a GPU debugger; there is none here, and keeping nothing loses nothing */
- (void)addDebugMarker:(NSString *)marker range:(NSRange)range { (void)marker; (void)range; }
- (void)removeAllDebugMarkers { }

@end

/* ============================================================================================================
 * The texture: hakios-metal's GPU memory in the GPU's own layout, with Metal's vocabulary for a texture over it
 * ============================================================================================================ */

@implementation HakiosMetalTexture

- (unsigned)hakiosStorageKind
{
	return _iosurface != NULL ? 0 : 1 + (unsigned)((_askedOptions >> MTLResourceStorageModeShift) & 0xf);
}

/* The four protocols a texture answers, declared at runtime because no base class brings them: the public <MTLTexture>
 * (compiled into this image by the @protocol() reference) and three of Metal.framework's own, which are in every process
 * that loaded Metal. Where Metal tests a texture's conformance at all it tests MTLTextureImplementation, not MTLTexture
 * (-[MTLRenderPassColorAttachmentDescriptorInternal setTexture:], a render path); the compute path tests nothing. */
+ (void)load
{
	hm_adopt(self, @protocol(MTLTexture), "MTLTexture");
	hm_adopt(self, objc_getProtocol("MTLTextureSPI"), "MTLTextureSPI");
	hm_adopt(self, objc_getProtocol("MTLTextureImplementation"), "MTLTextureImplementation");
	hm_adopt(self, objc_getProtocol("MTLResourceSPI"), "MTLResourceSPI");
}

HM_REFUSES_OUT_LOUD

- (instancetype)initWithHakiosDevice:(HakiosMetalDevice *)device texture:(hakios_metal_texture *)texture
			  descriptor:(MTLTextureDescriptor *)descriptor usage:(MTLTextureUsage)usage
{
	/* -[_MTLObjectWithLabel init] is the designated initialiser of a resource: _MTLResource adds no ivars and no
	 * initialiser of its own, and Apple's own texture chain ends in the same init */
	self = [super init];
	if (self == nil) {
		hakios_metal_texture_free(texture);
		return nil;
	}
	_device = [device retain];
	_texture = texture;
	_usage = usage;
	_askedOptions = [descriptor resourceOptions];
	_allowGPUOptimizedContents = [descriptor allowGPUOptimizedContents];
	_uniqueIdentifier = hm_next_resource_id();
	_shadowLock = [[NSLock alloc] init];
	return self;
}

- (void)dealloc
{
	if (_texture != NULL && (_parent == nil || _ownsView)) {
		hakios_metal_texture_free(_texture);   /* a command buffer still using it keeps its memory */
	}
	if (_iosurface != NULL) {
		CFRelease(_iosurface);
	}
	free(_shadowBase);
	free(_ycbcrRows);
	if (_ycbcrGPULuma != NULL) hakios_metal_texture_free(_ycbcrGPULuma);
	if (_ycbcrGPUChroma != NULL) hakios_metal_texture_free(_ycbcrGPUChroma);
	if (_ycbcrGPUParams != NULL) hakios_metal_buffer_free(_ycbcrGPUParams);
	if (_ycbcrGPUKernel != NULL) hakios_metal_kernel_free(_ycbcrGPUKernel);
	if (_ycbcrGPUQueue != NULL) hakios_metal_queue_free(_ycbcrGPUQueue);
	[_shadowLock release];
	if (_turnedSurface != NULL) {
		hakios_metal_texture_free(_turnedSurface);
	}
	[_parent release];
	if (_deallocator != nil) {
		_deallocator(_deallocBytes, _deallocLength);
		Block_release(_deallocator);
	}
	[_device release];
	[super dealloc];
}

- (hakios_metal_texture *)hakiosTexture { return _texture; }

- (void)hakiosSetDeallocator:(void (^)(void *, NSUInteger))deallocator bytes:(void *)bytes length:(NSUInteger)length
{
	_deallocator = Block_copy(deallocator);
	_deallocBytes = bytes;
	_deallocLength = length;
}

/* --- <MTLResource>: one kind of memory, described as what it is (the buffer says the same) --- */

- (id)device                                { return _device; }
- (MTLStorageMode)storageMode               { return MTLStorageModeShared; }
- (MTLCPUCacheMode)cpuCacheMode             { return MTLCPUCacheModeWriteCombined; }
- (MTLResourceOptions)resourceOptions       { return MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined; }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeDefault; }
- (id)heap                                  { return nil; }
- (NSUInteger)heapOffset                    { return 0; }
- (BOOL)isAliasable                         { return NO; }

/* the layout's own bytes, every level and slice of it (the core's plan, which -heapTextureSizeAndAlignWithDescriptor:
 * answers with too, so that a heap counts a texture as it sized it); a view's are its parent's memory */
- (NSUInteger)allocatedSize
{
	return (NSUInteger)hakios_metal_texture_allocated_bytes(_texture);
}

/* a texture is its own kernel allocation, as a buffer is; there is no heap to alias within */
- (void)makeAliasable
{
	HM_ONCE("a texture was asked to become aliasable; every texture here is its own allocation and none aliases another\n");
}

- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state
{
	if (state == MTLPurgeableStateVolatile || state == MTLPurgeableStateEmpty) {
		HM_ONCE("a texture was asked to become purgeable; the kernel does not purge GPU memory here, so it stays non-volatile\n");
	}
	return MTLPurgeableStateNonVolatile;
}

/* --- <MTLResourceSPI> --- */

/* QuartzCore's finish_image waits on the texture, including render targets and other wrappers of its IOSurface.
 * The core's backing-use list includes those writes; a per-Objective-C-object binding stamp does not. */
- (BOOL)isComplete
{
	if (_parent != nil) return [_parent isComplete];
	return hakios_metal_texture_is_complete(_texture) &&
	       (!_shadow || hm_use_complete(_uses));
}
- (void)waitUntilComplete
{
	const BOOL profile = hm_fps_on();
	const double began = profile ? hm_now() : 0;
	if (hm_handoff_on()) hm_diag_add(&hm_diag.textureWaits);
	if (hakios_metal_texture_sync(_texture) != 0) hm_print("texture completion failed: %s\n", hakios_metal_error());
	/* A shadow's IOSurface is ready only after driver writeback, not at its GPU fence.
	 * Its producer runs that publication inline, independently of CA's completion queue. */
	HakiosMetalTexture *root = self;
	while (root->_parent != nil) root = root->_parent;
	if (root->_shadow) hm_use_wait(root->_uses);
	if (profile) hm_fps_texture_waited(hm_now() - began);
}
- (void)hakiosUsedBy:(uint64_t)seq
{
	hm_use_mark(_uses, &_usesAt, seq);
	if (_parent != nil) [_parent hakiosUsedBy:seq];
}
- (MTLResourceOptions)unfilteredResourceOptions  { return _askedOptions; }
- (NSUInteger)protectionOptions                  { return 0; }   /* no protected memory on this port */
- (BOOL)isPurgeable                              { return NO; }
- (BOOL)doesAliasResource:(id)resource           { (void)resource; return NO; }
- (BOOL)doesAliasAnyResources:(const id *)resources count:(NSUInteger)count { (void)resources; (void)count; return NO; }
- (BOOL)doesAliasAllResources:(const id *)resources count:(NSUInteger)count { (void)resources; (void)count; return NO; }
- (int)responsibleProcess                        { return 0; }   /* no accounting of GPU memory by process in this kernel */
- (void)setResponsibleProcess:(int)pid           { (void)pid; }

/* --- <MTLTexture>: the shape --- */

- (NSUInteger)width                 { return hakios_metal_texture_width(_texture); }
- (NSUInteger)height                { return hakios_metal_texture_height(_texture); }
- (NSUInteger)depth                 { return hakios_metal_texture_type(_texture) == MTLTextureType3D ? hakios_metal_texture_depth(_texture) : 1; }
- (MTLPixelFormat)pixelFormat       { return _ycbcr != 0 ? _ycbcrFormat : (MTLPixelFormat)hakios_metal_texture_format(_texture); }
- (MTLTextureType)textureType       { return (MTLTextureType)hakios_metal_texture_type(_texture); }
- (MTLTextureUsage)usage            { return _usage; }
- (NSUInteger)mipmapLevelCount      { return hakios_metal_texture_levels(_texture); }
- (NSUInteger)arrayLength
{
	const unsigned type = hakios_metal_texture_type(_texture);

	return type == MTLTextureType2DArray || type == MTLTextureType1DArray ? hakios_metal_texture_depth(_texture) :
	       type == MTLTextureTypeCubeArray ? hakios_metal_texture_depth(_texture) / 6 : 1;
}
- (NSUInteger)sampleCount           { return hakios_metal_texture_samples(_texture); }
- (BOOL)isFramebufferOnly           { return NO; }    /* every texture here can be read back and written by the processor */
- (BOOL)allowGPUOptimizedContents   { return _allowGPUOptimizedContents; }
- (id)parentTexture                 { return _parent; }
/* AppleMetalGLRenderer's glGenerateMipmap asks the texture first (Apple's GPU fills a level from the one above it in
 * place); NO sends it to the blit encoder's -generateMipmapsForTexture:, which is served */
- (BOOL)canGenerateMipmapLevels     { return NO; }
- (void)generateMipmapLevel:(NSUInteger)level slice:(NSUInteger)slice
{
	HM_ONCE("gles: -generateMipmapLevel:%lu slice:%lu asked though -canGenerateMipmapLevels says NO; nothing is generated\n",
		(unsigned long)level, (unsigned long)slice);
}
- (NSUInteger)parentRelativeLevel   { return _parentLevel; }
- (NSUInteger)parentRelativeSlice   { return _parentSlice; }
- (id)rootResource                  { return self; }
- (id)buffer                        { return nil; }   /* not a view of an MTLBuffer either: the memory is the texture's own */
- (NSUInteger)bufferOffset          { return 0; }
- (NSUInteger)bufferBytesPerRow     { return (NSUInteger)hakios_metal_texture_bytes_per_row(_texture); }   /* the GPU's pitch */
- (IOSurfaceRef)iosurface           { return _iosurface; }
- (NSUInteger)iosurfacePlane        { return _iosurfacePlane; }
/* A surface whose rows the GPU cannot take as they lie (a pitch that is not a multiple of 64 bytes: a client that chose
 * its own bytesPerRow, 480 for a 120-pixel BGRA picture) is read through a copy of its rows in a texture of the GPU's
 * layout. The copy is made again whenever the surface's seed has moved, which IOSurface does on every unlock after a
 * write, at the moment the texture is bound for a draw -- so a draw sees the surface as it was when the draw was encoded,
 * which is what a sample of a surface another program is still writing could show anyway. */
- (BOOL)hakiosIsShadow { return _parent != nil ? [_parent hakiosIsShadow] : _shadow; }
- (BOOL)hakiosIsTurned { return _turnedSurface != NULL; }

- (void)hakiosSetTurned:(hakios_metal_texture *)surface rotation:(unsigned)rotation
{
	_turnedSurface = surface;
	_turn = rotation;
}

/* the framebuffer as drawn, turned into the surface the display scans out */
- (void)hakiosTurnInto:(hakios_metal_cb *)cb
{
	if (_turnedSurface != NULL && hakios_metal_cb_blit_rotated(cb, _texture, _turnedSurface, _turn) != 0) {
		HM_ONCE("refused: a turned framebuffer's copy into its surface: %s\n", hakios_metal_error());
	}
}

/* A copy a kernel or a pass may have written: its rows back into the surface, the surface's seed moving as for any
 * write, and the copy then current with it (the next refresh does not read back what was just written). */
- (void)hakiosWriteBackShadow
{
	if (_parent != nil) {
		[_parent hakiosWriteBackShadow];
		return;
	}
	if (_shadow && __atomic_load_n(&_shadowWrites, __ATOMIC_RELAXED) != 0) {
		__atomic_sub_fetch(&_shadowWrites, 1, __ATOMIC_RELAXED);
		if (_iosurface != NULL) hm_shadow_surface_done(IOSurfaceGetID(_iosurface));
	}
	if (!_shadow || _iosurface == NULL || (_usage & (MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget)) == 0) {
		return;
	}
	/* Only the bytes the GPU changed from the base go back. CoreAnimation draws one surface (the App Library's
	 * snapshot) in several passes through several textures, each a copy of its own, and the next pass's copy is taken
	 * when it is encoded -- before the last one's command buffer has written back when the GPU is busy. Writing a
	 * whole copy back then put its stale rows over what the other pass drew: black bands that moved from frame to
	 * frame. Against the base, each copy carries only its own drawing, and passes into different parts merge. */
	const BOOL planar = IOSurfaceGetPlaneCount(_iosurface) > 1;
	const size_t pitch = planar ? IOSurfaceGetBytesPerRowOfPlane(_iosurface, _iosurfacePlane) : IOSurfaceGetBytesPerRow(_iosurface);
	const size_t bytes = pitch * hakios_metal_texture_height(_texture);
	const double began = hm_now();
	uint8_t *now = malloc(bytes);

	/* under the copy's lock: a refresh between this lock's seed and the end of the write-back read the surface half
	 * written back, replaced the copy this reads, and freed the base this compares with */
	[_shadowLock lock];
	if (now == NULL || IOSurfaceLock(_iosurface, 0, NULL) != kIOReturnSuccess) {
		[_shadowLock unlock];
		free(now);
		return;
	}
	uint8_t *surface = planar ? IOSurfaceGetBaseAddressOfPlane(_iosurface, _iosurfacePlane) : IOSurfaceGetBaseAddress(_iosurface);

	/* A copy whose base was never taken from its surface (the refresh that makes one could not lock it) has rows of its
	 * own that are whatever memory it was made in, so publishing the whole copy would put those over the surface: the
	 * App Library's background, black, before the first write-back (v29u). Nothing is published; the next refresh takes
	 * the surface and the next write-back merges into it. (Every copy a pass can draw into is given its base when it is
	 * made -- -hakiosShadow: refreshes at once -- so this is the failure path, said once.) */
	if (_shadowBase == NULL) {
		HM_ONCE("a shadow copy was written back with no base taken from its surface: not published, its untouched rows are "
			"not the surface's\n");
		IOSurfaceUnlock(_iosurface, 0, NULL);
		[_shadowLock unlock];
		free(now);
		return;
	}
	memcpy(now, _shadowBase, bytes);
	(void)hakios_metal_texture_read(_texture, 0, 0, hakios_metal_texture_width(_texture), hakios_metal_texture_height(_texture), now,
					(uint64_t)pitch);
	for (size_t i = 0; i < bytes; i++) {
		if (now[i] != _shadowBase[i]) {
			surface[i] = now[i];
		}
	}
	IOSurfaceUnlock(_iosurface, 0, &_shadowSeed);
	free(_shadowBase);
	_shadowBase = now;
	[_shadowLock unlock];
	hm_fps_shadow(NO, hm_now() - began);
}

- (void)hakiosShadowWriteQueued
{
	if (_parent != nil) {
		[_parent hakiosShadowWriteQueued];
		return;
	}
	if (_shadow) {
		__atomic_add_fetch(&_shadowWrites, 1, __ATOMIC_RELAXED);
		if (_iosurface != NULL) hm_shadow_surface_add(IOSurfaceGetID(_iosurface));   /* a sample of the surface waits for it */
	}
}

/* A command buffer released without completing (never committed) queued a write it will never write back: without
 * this the copy's pending count stays up and -hakiosRefreshShadow keeps the copy for good. */
- (void)hakiosShadowWriteDropped
{
	if (_parent != nil) {
		[_parent hakiosShadowWriteDropped];
		return;
	}
	if (_shadow && __atomic_load_n(&_shadowWrites, __ATOMIC_RELAXED) != 0) {
		__atomic_sub_fetch(&_shadowWrites, 1, __ATOMIC_RELAXED);
		if (_iosurface != NULL) hm_shadow_surface_done(IOSurfaceGetID(_iosurface));
	}
}

- (void)hakiosShadow:(IOSurfaceRef)surface
{
	[self hakiosShadow:surface plane:0];
}

- (void)hakiosShadow:(IOSurfaceRef)surface plane:(NSUInteger)plane
{
	[self hakiosSetIOSurface:surface plane:plane];
	_shadow = YES;
	_shadowSeed = IOSurfaceGetSeed(surface) + 1;   /* (not the surface's seed: the first refresh copies) */
	[self hakiosRefreshShadow];
}

/* A '420f' or '420v' surface sampled as Metal's private format 500. Apple's texture unit converts YCbCr to RGB as it
 * samples, and CoreAnimation's shader (fixed_frag_lph_cph) takes the sample as the colour: it does no conversion of
 * its own (its own YCbCr path, fc_has_ycbcr_matrix with fc_plane_count 2, is for two textures, which nothing here asks
 * for: every pipeline of logs/test-1109-215741 has plane count 1). The A6xx texture unit has no such conversion -- it
 * returns (Y, Cb, Cr) as they are (probe 9m2), which drew the home screen's wallpaper with its orange pink and its teal
 * olive. So such a texture is an RGBA8 copy converted here (HakiosMetalPixels.h: hm_ycc_convert), from the matrix the
 * surface declares (CoreVideo's CVImageBufferYCbCrMatrix attachment -- BT.709 for an HD video -- or IOSurfaceYCbCrMatrix;
 * BT.601 when it declares none, which is what the wallpaper's own HEIC gives) and its range, made again when the
 * surface's seed moves as the other copies are. Each 2x2 block of luma takes its one chroma sample (the 4:2:0 siting). */
- (void)hakiosShadowYCbCr:(IOSurfaceRef)surface format:(MTLPixelFormat)format
{
	const char *from;
	const int matrix = hm_surface_ycc_matrix(surface, &from);

	_ycbcr = matrix != HM_YCC_UNKNOWN ? matrix : HM_YCC_601;
	_ycbcrDeclared = matrix != HM_YCC_UNKNOWN;
	_ycbcrFormat = format;
	_ycbcrFull = IOSurfaceGetPixelFormat(surface) != 0x34323076;   /* not '420v' */
	[self hakiosShadow:surface];
}

/* Copy each plane once using IOSurface's byte stride into an aligned GPU texture.
 * No source pitch/offset restriction, and no use of the raw import's luma pitch. */
- (BOOL)hakiosConvertYCbCrGPU:(const hm_ycc_planes *)planes width:(size_t)w height:(size_t)h
{
	if (_ycbcrFormat != (MTLPixelFormat)500 || (_ycbcr != HM_YCC_601 && _ycbcr != HM_YCC_709)) return NO;
	const double began = hm_now();
	if (_ycbcrGPUQueue == NULL) _ycbcrGPUQueue = hakios_metal_queue_new([_device hakiosDevice]);
	if (_ycbcrGPUKernel == NULL) _ycbcrGPUKernel = hakios_metal_kernel_compile_bitcode(ycbcr_convert_bc, ycbcr_convert_bc_size);
	if (_ycbcrGPUParams == NULL) _ycbcrGPUParams = hakios_metal_buffer_new([_device hakiosDevice], 32);
	if (_ycbcrGPULuma == NULL) _ycbcrGPULuma = hakios_metal_texture_new_levels([_device hakiosDevice], 2, 10,
		(unsigned)w, (unsigned)h, 1, MTLTextureUsageShaderRead);
	if (_ycbcrGPUChroma == NULL) _ycbcrGPUChroma = hakios_metal_texture_new_levels([_device hakiosDevice], 2, 30,
		(unsigned)planes->cw, (unsigned)planes->ch, 1, MTLTextureUsageShaderRead);
	if (_ycbcrGPUQueue == NULL || _ycbcrGPUKernel == NULL || _ycbcrGPUParams == NULL ||
	    _ycbcrGPULuma == NULL || _ycbcrGPUChroma == NULL) {
		hm_print("ycbcr: GPU setup failed: %s; converting current frame on CPU\n", hakios_metal_error());
		return NO;
	}
	if (hakios_metal_texture_replace(_ycbcrGPULuma, 0, 0, (unsigned)w, (unsigned)h, planes->luma, planes->lumaRow) != 0 ||
	    hakios_metal_texture_replace(_ycbcrGPUChroma, 0, 0, (unsigned)planes->cw, (unsigned)planes->ch,
		planes->chroma, planes->chromaRow) != 0) {
		hm_print("ycbcr: GPU plane copy failed: %s; converting current frame on CPU\n", hakios_metal_error());
		return NO;
	}
	struct { float yBias, yScale, cBias, cBiasCr, rCr, gCb, gCr, bCb; } p;
	p.yBias = _ycbcrFull ? 0.0f : 16.0f / 255.0f;
	p.yScale = _ycbcrFull ? 1.0f : 255.0f / 219.0f;
	p.cBias = p.cBiasCr = 128.0f / 255.0f;
	if (_ycbcr == HM_YCC_709) {
		p.rCr = 1.574800f; p.gCb = 0.187324f; p.gCr = 0.468124f; p.bCb = 1.855600f;
	} else {
		p.rCr = 1.402000f; p.gCb = 0.344136f; p.gCr = 0.714136f; p.bCb = 1.772000f;
	}
	const float chromaScale = _ycbcrFull ? 1.0f : 255.0f / 224.0f;
	p.rCr *= chromaScale; p.gCb *= chromaScale; p.gCr *= chromaScale; p.bCb *= chromaScale;
	memcpy(hakios_metal_buffer_contents(_ycbcrGPUParams), &p, sizeof p);
	hakios_metal_cb *cb = hakios_metal_cb_new(_ycbcrGPUQueue);
	if (cb == NULL) {
		hm_print("ycbcr: GPU command buffer failed: %s; converting current frame on CPU\n", hakios_metal_error());
		return NO;
	}
	const unsigned groups[3] = {(unsigned)w, (unsigned)h, 1};
	const unsigned threads[3] = {1, 1, 1};
	hakios_metal_buffer *buffers[1] = {_ycbcrGPUParams};
	const uint64_t offsets[1] = {0};
	hakios_metal_texture *textures[3] = {_ycbcrGPULuma, _ycbcrGPUChroma, _texture};
	const int refused = hakios_metal_cb_dispatch2(cb, _ycbcrGPUKernel, groups, threads, buffers, offsets, 1, textures, 3, NULL, 0);
	if (refused == 0) {
		hakios_metal_cb_commit(cb, NULL, NULL);
		hakios_metal_cb_wait(cb);
	}
	const BOOL ok = refused == 0 && hakios_metal_cb_status(cb) == HAKIOS_METAL_COMPLETED;
	if (!ok) {
		hm_print("ycbcr: GPU conversion failed: %s; converting current frame on CPU\n",
			refused != 0 ? hakios_metal_error() : hakios_metal_cb_error(cb));
	} else {
		if (!_ycbcrGPUReported) {
			hm_print("ycbcr: GPU conversion v8: aligned plane copies, format 500 (BT.601/709, video/full range); IOSurface %u\n",
				IOSurfaceGetID(_iosurface));
			_ycbcrGPUReported = YES;
		}
		hm_fps_ycbcr_gpu(hm_now() - began);
	}
	hakios_metal_cb_free(cb);
	return ok;
}

/* CA has received this surface from its producer. Convert its current pixels;
 * pixel values are never used to infer whether a frame is ready. */
- (BOOL)hakiosConvertYCbCr
{
	const size_t w = hakios_metal_texture_width(_texture), h = hakios_metal_texture_height(_texture);
	const BOOL raw = _ycbcrFormat == (MTLPixelFormat)540;
	const hm_ycc_planes planes = {
		IOSurfaceGetBaseAddressOfPlane(_iosurface, 0), IOSurfaceGetBytesPerRowOfPlane(_iosurface, 0),
		IOSurfaceGetBaseAddressOfPlane(_iosurface, 1), IOSurfaceGetBytesPerRowOfPlane(_iosurface, 1),
		IOSurfaceGetWidthOfPlane(_iosurface, 1), IOSurfaceGetHeightOfPlane(_iosurface, 1),
	};
	if (!_ycbcrDeclared) {
		const char *from;
		const int matrix = hm_surface_ycc_matrix(_iosurface, &from);
		if (matrix != HM_YCC_UNKNOWN) {
			_ycbcr = matrix;
			_ycbcrDeclared = YES;
		}
	}
	if (!_ycbcrTold) {
		hm_print("ycbcr: IOSurface %u %zux%zu as format %lu: Y stride %zu, CbCr %zux%zu stride %zu at +%td; %s, %s range; current seed %u\n",
			IOSurfaceGetID(_iosurface), w, h, (unsigned long)_ycbcrFormat, planes.lumaRow, planes.cw, planes.ch, planes.chromaRow,
			planes.chroma - planes.luma, hm_ycc_matrix_name(_ycbcr), _ycbcrFull ? "full" : "video", IOSurfaceGetSeed(_iosurface));
		_ycbcrTold = YES;
	}
	if (!_ycbcrFull) hm_ycc_report_unwritten(_iosurface, &planes, w, h, IOSurfaceGetSeed(_iosurface));
	if ([self hakiosConvertYCbCrGPU:&planes width:w height:h]) {
		hm_fps_ycbcr();
		return YES;
	}
	const size_t bytes = w * h * 4;
	if (_ycbcrRowsBytes < bytes) {
		uint8_t *rows = realloc(_ycbcrRows, bytes);
		if (rows == NULL) return NO;
		_ycbcrRows = rows;
		_ycbcrRowsBytes = bytes;
	}
	uint8_t *rows = _ycbcrRows;
	if (h < 256) {
		hm_ycc_convert(&planes, w, h, _ycbcr, _ycbcrFull, raw, rows, w * 4);
	} else {
		const size_t band = ((h + 3) / 4 + 1) & ~(size_t)1;
		hm_ycc_lut lut;
		hm_ycc_make_lut(&lut, _ycbcr, _ycbcrFull);
		const hm_ycc_planes *const in = &planes;
		dispatch_apply(4, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(size_t b) {
			hm_ycc_convert_rows_lut(in, w, h, b * band, MIN((b + 1) * band, h), &lut, raw, rows, w * 4);
		});
	}
	const BOOL replaced = hakios_metal_texture_replace(_texture, 0, 0, (unsigned)w, (unsigned)h, rows, (uint64_t)w * 4) == 0;
	if (replaced) hm_fps_ycbcr();
	return replaced;
}

- (void)hakiosRefreshShadow
{
	if (_parent != nil) {
		[_parent hakiosRefreshShadow];   /* the rows a view reads are its parent's, copy included */
		return;
	}
	uint32_t seed;

    static int forceRefresh = -1;
    if (forceRefresh < 0) forceRefresh = hm_ca_arg("metal_shadow_refresh=1");
    const BOOL forceRead = forceRefresh && (_usage & (MTLTextureUsageRenderTarget | MTLTextureUsageShaderWrite)) == 0;
    /* /var/db/hakios-metal-cache/shadow-refresh-old: the refresh as it was before the two rules below, for a bisect */
    static int oldRule = -1;
    if (oldRule < 0) oldRule = access("/var/db/hakios-metal-cache/shadow-refresh-old", F_OK) == 0;
    if (!_shadow || _iosurface == NULL || ((seed = IOSurfaceGetSeed(_iosurface)) == _shadowSeed && !forceRead)) {
		return;
	}
	/* This copy has GPU draws a command buffer writes back at its completion, and has not yet: it is newer than the
	 * surface. Copying the surface over it loses them, and -hakiosWriteBackShadow's difference against the base then
	 * calls those bytes unchanged, so they never reach the surface -- and CoreAnimation redraws only dirty rects while
	 * the page is still, so they never come back (the App Library's black lower half). Written back here instead would
	 * read the texture the GPU may still be drawing into, so the refresh is what gives way: the completion that writes
	 * them back moves the surface's seed, and the next binding refreshes from it. */
	if (!oldRule && __atomic_load_n(&_shadowWrites, __ATOMIC_RELAXED) != 0) {
		hm_fps_shadow_kept(NO);
		return;
	}
	if (_shadowLock != nil) {
		[_shadowLock lock];
	}
	uint32_t lockSeed = 0;
	const double began = hm_now();
	seed = IOSurfaceGetSeed(_iosurface);
	if ((forceRead || seed != _shadowSeed) && IOSurfaceLock(_iosurface, kIOSurfaceLockReadOnly, &lockSeed) == kIOReturnSuccess) {
		BOOL copied;
		{
			/* flicker-diag: the copy taken over a copy the GPU is still drawing into (its write-back to come), or taken
			 * from a surface a writer moved under it (see the seed test below; the old even-seed guess is not one: this
			 * kernel's seed moves by one at each write lock and never at the unlock, so its parity counts write cycles
			 * and does not mark a held lock -- MiniIOSurface.cpp's lockCommon) */
			static unsigned torn, overdrawn;
			const unsigned pending = __atomic_load_n(&_shadowWrites, __ATOMIC_RELAXED);

			if (!oldRule && lockSeed != seed && hm_flicker_say(&torn)) {
				hm_print("flicker-diag: shadow copy of IOSurface %u (%zux%zu) not taken, written under it (seed %u, copy's %u); %u such\n",
					 IOSurfaceGetID(_iosurface), IOSurfaceGetWidth(_iosurface), IOSurfaceGetHeight(_iosurface), lockSeed, seed, torn);
			}
			if (pending != 0 && hm_flicker_say(&overdrawn)) {
				hm_print("flicker-diag: shadow copy of IOSurface %u (%zux%zu) replaced while %u GPU write(s) into it are not written "
					 "back (seed %u, copy's %u); %u such\n", IOSurfaceGetID(_iosurface), IOSurfaceGetWidth(_iosurface),
					 IOSurfaceGetHeight(_iosurface), pending, lockSeed, _shadowSeed, overdrawn);
			}
		}
		/* The seed moved between the read above and the lock: a writer wrote the surface in between, and this kernel's
		 * locks exclude nobody, so the rows we would take may be half written -- and half written rows become the base
		 * -hakiosWriteBackShadow tells this copy's own drawing by. Take none: keep the copy, leave its seed where it is,
		 * and the next binding tries again (a frame late is what the refresh is for; a torn base is permanent). */
		if (!oldRule && lockSeed != seed) {
			copied = NO;
			hm_fps_shadow_kept(YES);
		} else if (_ycbcr != 0) {
			copied = [self hakiosConvertYCbCr];
			hm_fps_ycbcr_time(hm_now() - began);
		} else {
			const BOOL planar = IOSurfaceGetPlaneCount(_iosurface) > 1;
			const void *source = planar ? IOSurfaceGetBaseAddressOfPlane(_iosurface, _iosurfacePlane) : IOSurfaceGetBaseAddress(_iosurface);
			const size_t pitch = planar ? IOSurfaceGetBytesPerRowOfPlane(_iosurface, _iosurfacePlane) : IOSurfaceGetBytesPerRow(_iosurface);
			copied = hakios_metal_texture_replace(_texture, 0, 0, hakios_metal_texture_width(_texture), hakios_metal_texture_height(_texture),
									source, (uint64_t)pitch) == 0;
			/* a copy something writes keeps what it took, for -hakiosWriteBackShadow to tell its own drawing from */
			if ((_usage & (MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget)) != 0) {
				const size_t bytes = pitch * hakios_metal_texture_height(_texture);

				if (_shadowBase == NULL) {
					_shadowBase = malloc(bytes);
				}
				if (_shadowBase != NULL) {
					memcpy(_shadowBase, source, bytes);
				}
			}
		}
		IOSurfaceUnlock(_iosurface, kIOSurfaceLockReadOnly, NULL);
		if (copied) {
			/* This texture retains one IOSurface. A changed seed always converts
			 * again; never label these pixels with a newer post-copy seed. */
			_shadowSeed = lockSeed;
			if (_ycbcr != 0) {
				static unsigned converted;
				const unsigned n = __atomic_fetch_add(&converted, 1, __ATOMIC_RELAXED);
				if (n < 32 || n % 128 == 0)
					hm_print("ycbcr: converted IOSurface %u seed %u (current frame)\n", IOSurfaceGetID(_iosurface), lockSeed);
			}
			if (hm_handoff_on()) hm_diag_add(&hm_diag.shadowImports);
			hm_fps_shadow(YES, hm_now() - began);
		}
	}
	if (_shadowLock != nil) {
		[_shadowLock unlock];
	}
}

- (void)hakiosSetIOSurface:(IOSurfaceRef)surface plane:(NSUInteger)plane
{
	if (surface != NULL) {
		CFRetain(surface);
	}
	if (_iosurface != NULL) {
		CFRelease(_iosurface);
	}
	_iosurface = surface;
	_iosurfacePlane = plane;
	_shadowSeed = surface != NULL ? IOSurfaceGetSeed(surface) + 1 : 0;
}
- (BOOL)isShareable                 { return NO; }
- (BOOL)isSparse                    { return NO; }
- (NSUInteger)firstMipmapInTail     { return 0; }
- (NSUInteger)tailSizeInBytes       { return 0; }
- (MTLTextureCompressionType)compressionType { return MTLTextureCompressionTypeLossless; }
/* the identity: red 2, green 3, blue 4, alpha 5 (MTLTextureSwizzle). The catch-all's zeros would be four
 * MTLTextureSwizzleZero, a texture every channel of which reads 0. */
- (MTLTextureSwizzleChannels)swizzle { return _swizzled ? _swizzle : MTLTextureSwizzleChannelsDefault; }

/* what an argument buffer holds for this texture: the core's id, which a draw or dispatch reading the buffer finds the
 * texture by (a view of a level or slices is a texture of its own, with its own) */
- (MTLResourceID)gpuResourceID
{
	MTLResourceID rid = { hakios_metal_texture_resource_id(_texture) };

	return rid;
}

/* A shared texture handle names GPU memory to another process; the kernel's allocations are per client here. */
- (id)newSharedTextureHandle
{
	hm_refusal(self, _cmd, "has no shared textures to hand across processes; it returns nil");
	return nil;
}

/* A view is a second descriptor over the same memory. The one this plug-in makes is the view that changes nothing --
 * same format, type, every level, every slice -- which is what sokol-gfx asks for every image it samples (it binds
 * views, never images): such a view IS the texture under a second object, so it shares the parent's hakios texture and
 * keeps the parent alive. A view that reinterprets the format or picks out levels needs a descriptor of its own, which
 * hakios-metal does not make yet; LOUD because of what a quiet nil did in the earlier plug-in: CoreAnimation's
 * update_image stored it, unchecked, over a texture it already had, and images composited as nothing. */
- (id)hakiosViewWithPixelFormat:(MTLPixelFormat)pixelFormat textureType:(MTLTextureType)type levels:(NSRange)levels
			 slices:(NSRange)slices asked:(SEL)cmd
{
	HakiosMetalTexture *view;
	hakios_metal_texture *own = NULL;
	/* the texture's slices, as Metal counts a view's: a 2D array's layers, a cube's six faces, one for the rest */
	const NSUInteger allSlices = [self textureType] == MTLTextureType2DArray || [self textureType] == MTLTextureType1DArray ? [self arrayLength] :
				     [self textureType] == MTLTextureTypeCubeArray ? 6 * [self arrayLength] : [self textureType] == MTLTextureTypeCube ? 6 : 1;

	/* the whole texture as it is shares its handle; anything else (a level, a slice, another format of the same size a
	 * pixel -- MPS takes each level of a pyramid so) is the core's own view of the same memory */
	if (pixelFormat != [self pixelFormat] || type != [self textureType] || levels.location != 0 ||
	    levels.length != [self mipmapLevelCount] || slices.location != 0 || slices.length != allSlices) {
		own = hakios_metal_texture_new_view(_texture, (unsigned)pixelFormat, (unsigned)type, (unsigned)levels.location, (unsigned)levels.length,
						    (unsigned)slices.location, (unsigned)slices.length);
		if (own == NULL) {
			hm_print("refused: -[%s %s] format %lu type %lu levels %lu+%lu slices %lu+%lu of a texture of format %lu type %lu "
				 "with %lu levels: %s; it returns nil\n",
				 class_getName(object_getClass(self)), sel_getName(cmd), (unsigned long)pixelFormat, (unsigned long)type,
				 (unsigned long)levels.location, (unsigned long)levels.length, (unsigned long)slices.location,
				 (unsigned long)slices.length, (unsigned long)[self pixelFormat], (unsigned long)[self textureType],
				 (unsigned long)[self mipmapLevelCount], hakios_metal_error());
			return nil;
		}
	}
	view = [[HakiosMetalTexture alloc] init];   /* -[_MTLObjectWithLabel init], as the designated initialiser above */
	if (view == nil) {
		if (own != NULL) hakios_metal_texture_free(own);
		return nil;
	}
	view->_parent = [self retain];
	view->_device = [_device retain];
	view->_texture = own != NULL ? own : _texture;
	view->_ownsView = own != NULL;
	view->_parentLevel = levels.location;
	view->_parentSlice = slices.location;
	view->_usage = _usage;
	view->_askedOptions = _askedOptions;
	view->_allowGPUOptimizedContents = _allowGPUOptimizedContents;
	view->_uniqueIdentifier = hm_next_resource_id();
	if (_iosurface != NULL) {
		view->_iosurface = (IOSurfaceRef)CFRetain(_iosurface);
		view->_iosurfacePlane = _iosurfacePlane;
	}
	return view;
}

- (id)newTextureViewWithPixelFormat:(MTLPixelFormat)pixelFormat
{
	return [self hakiosViewWithPixelFormat:pixelFormat textureType:[self textureType]
					levels:NSMakeRange(0, [self mipmapLevelCount]) slices:NSMakeRange(0, 1) asked:_cmd];
}

- (id)newTextureViewWithPixelFormat:(MTLPixelFormat)pixelFormat textureType:(MTLTextureType)type levels:(NSRange)levels slices:(NSRange)slices
{
	return [self hakiosViewWithPixelFormat:pixelFormat textureType:type levels:levels slices:slices asked:_cmd];
}

- (id)newTextureViewWithPixelFormat:(MTLPixelFormat)pixelFormat textureType:(MTLTextureType)type levels:(NSRange)levels slices:(NSRange)slices
			    swizzle:(MTLTextureSwizzleChannels)swizzle
{
	HakiosMetalTexture *view = [self hakiosViewWithPixelFormat:pixelFormat textureType:type levels:levels slices:slices asked:_cmd];
	hakios_metal_texture *swizzled;

	if (view == nil || (swizzle.red == MTLTextureSwizzleRed && swizzle.green == MTLTextureSwizzleGreen &&
			    swizzle.blue == MTLTextureSwizzleBlue && swizzle.alpha == MTLTextureSwizzleAlpha)) {
		return view;
	}
	/* the same memory through a descriptor of its own, its swizzle over the view's (the core composes them) */
	swizzled = hakios_metal_texture_new_swizzled(view->_texture, swizzle.red, swizzle.green, swizzle.blue, swizzle.alpha);
	if (swizzled == NULL) {
		hm_print("refused: a view swizzled (%u %u %u %u): %s; it returns nil\n", swizzle.red, swizzle.green, swizzle.blue, swizzle.alpha,
			 hakios_metal_error());
		[view release];
		return nil;
	}
	if (view->_ownsView) hakios_metal_texture_free(view->_texture);
	view->_texture = swizzled;
	view->_ownsView = YES;
	view->_swizzled = YES;
	view->_swizzle = swizzle;
	return view;
}

/* --- <MTLTexture>: the bytes --- */

/* a level or slice this texture has not got, a region with depth, or no bytes at all: refused by name and nothing is
 * copied, because a copy into level 0 instead would read as a result */
- (BOOL)hakiosRegion:(MTLRegion)region level:(NSUInteger)level slice:(NSUInteger)slice bytes:(const void *)bytes isFor:(const char *)what
{
	const BOOL layered = hm_layered(hakios_metal_texture_type(_texture));
	if (level >= hakios_metal_texture_levels(_texture) || (slice != 0 && !(layered && slice < hakios_metal_texture_depth(_texture)))) {
		hm_print("refused: %s of level %lu, slice %lu: this texture has %u level(s) and one slice; nothing is copied\n",
			 what, (unsigned long)level, (unsigned long)slice, hakios_metal_texture_levels(_texture));
		return NO;
	}
	if ((region.origin.z != 0 || region.size.depth != 1) && hakios_metal_texture_type(_texture) != MTLTextureType3D) {
		hm_print("refused: %s of a region at z %lu with depth %lu: a 2D texture has z 0 and depth 1; nothing is copied\n",
			 what, (unsigned long)region.origin.z, (unsigned long)region.size.depth);
		return NO;
	}
	if (bytes == NULL) {
		hm_print("refused: %s with no bytes; nothing is copied\n", what);
		return NO;
	}
	return YES;
}

/* The 4-argument form is Apple's own convenience over the 6-argument one: -[IOGPUMetalTexture replaceRegion:mipmapLevel:
 * withBytes:bytesPerRow:] sends the 6-argument form with slice 0 and bytesPerImage 0, and AGXTexture overrides only the
 * 6-argument forms. The same shape here, so that one implementation holds every rule. */
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level withBytes:(const void *)bytes bytesPerRow:(NSUInteger)bytesPerRow
{
	[self replaceRegion:region mipmapLevel:level slice:0 withBytes:bytes bytesPerRow:bytesPerRow bytesPerImage:0];
}

- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice withBytes:(const void *)bytes
	  bytesPerRow:(NSUInteger)bytesPerRow bytesPerImage:(NSUInteger)bytesPerImage
{
	if (![self hakiosRegion:region level:level slice:slice bytes:bytes isFor:"replaceRegion"]) {
		return;
	}
	if (hm_handoff_on()) hm_diag_add(&hm_diag.cpuWrites);
	/* a 2D array's layer SLICE, or a cube's face: the core's slice copy, one slice at the layer */
	if (hm_layered(hakios_metal_texture_type(_texture))) {
		if (hakios_metal_texture_replace_3d(_texture, (unsigned)level, (unsigned)region.origin.x, (unsigned)region.origin.y, (unsigned)slice, (unsigned)region.size.width,
						    (unsigned)region.size.height, 1, bytes, bytesPerRow, bytesPerImage) != 0) {
			hm_print("refused: replaceRegion of %lux%lu of layer %lu of a 2D array: %s; nothing is copied\n", (unsigned long)region.size.width,
				 (unsigned long)region.size.height, (unsigned long)slice, hakios_metal_error());
		}
		return;
	}
	/* a 3D texture's slices, each image BYTES_PER_IMAGE further on in the caller's memory (ignored for one image) */
	if (hakios_metal_texture_type(_texture) == MTLTextureType3D) {
		if (hakios_metal_texture_replace_3d(_texture, (unsigned)level, (unsigned)region.origin.x, (unsigned)region.origin.y, (unsigned)region.origin.z,
						    (unsigned)region.size.width, (unsigned)region.size.height, (unsigned)region.size.depth, bytes,
						    bytesPerRow, bytesPerImage) != 0) {
			hm_print("refused: replaceRegion of %lux%lux%lu of a 3D texture: %s; nothing is copied\n", (unsigned long)region.size.width,
				 (unsigned long)region.size.height, (unsigned long)region.size.depth, hakios_metal_error());
		}
			return;
	}
	/* BYTES_PER_ROW is the CALLER's stride for the caller's memory; the texture's rows are hakios-metal's pitch apart, and
	 * the core copies row by row between the two (a region outside the texture, or a stride shorter than its rows, is
	 * its refusal, with the numbers) */
	if (hakios_metal_texture_replace_level(_texture, (unsigned)level, (unsigned)region.origin.x, (unsigned)region.origin.y,
					       (unsigned)region.size.width, (unsigned)region.size.height, bytes, bytesPerRow) != 0) {
		hm_print("refused: replaceRegion of %lux%lu at (%lu, %lu), the caller's rows %lu bytes apart: %s; nothing is copied\n",
			 (unsigned long)region.size.width, (unsigned long)region.size.height, (unsigned long)region.origin.x,
			 (unsigned long)region.origin.y, (unsigned long)bytesPerRow, hakios_metal_error());
	} else if (level == 0) {
		hm_flat_census("replaceRegion", hakios_metal_texture_resource_id(_texture), hakios_metal_texture_format(_texture), region.size.width,
			       region.size.height, bytes, bytesPerRow);
	}
}

- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)bytesPerRow fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level
{
	[self getBytes:bytes bytesPerRow:bytesPerRow bytesPerImage:0 fromRegion:region mipmapLevel:level slice:0];
}

- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)bytesPerRow bytesPerImage:(NSUInteger)bytesPerImage fromRegion:(MTLRegion)region
     mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice
{
	if (![self hakiosRegion:region level:level slice:slice bytes:bytes isFor:"getBytes"]) {
		return;
	}
	if (hm_handoff_on()) hm_diag_add(&hm_diag.cpuReads);
	if (hm_layered(hakios_metal_texture_type(_texture))) {
		if (hakios_metal_texture_read_3d(_texture, (unsigned)level, (unsigned)region.origin.x, (unsigned)region.origin.y, (unsigned)slice, (unsigned)region.size.width,
						 (unsigned)region.size.height, 1, bytes, bytesPerRow, bytesPerImage) != 0) {
			hm_print("refused: getBytes of %lux%lu of layer %lu of a 2D array: %s; nothing is copied\n", (unsigned long)region.size.width,
				 (unsigned long)region.size.height, (unsigned long)slice, hakios_metal_error());
		}
		return;
	}
	if (hakios_metal_texture_type(_texture) == MTLTextureType3D) {
		if (hakios_metal_texture_read_3d(_texture, (unsigned)level, (unsigned)region.origin.x, (unsigned)region.origin.y, (unsigned)region.origin.z,
						 (unsigned)region.size.width, (unsigned)region.size.height, (unsigned)region.size.depth, bytes, bytesPerRow,
						 bytesPerImage) != 0) {
			hm_print("refused: getBytes of %lux%lux%lu of a 3D texture: %s; nothing is copied\n", (unsigned long)region.size.width,
				 (unsigned long)region.size.height, (unsigned long)region.size.depth, hakios_metal_error());
		}
			return;
	}
	if (hakios_metal_texture_read_level(_texture, (unsigned)level, (unsigned)region.origin.x, (unsigned)region.origin.y,
					    (unsigned)region.size.width, (unsigned)region.size.height, bytes, bytesPerRow) != 0) {
		hm_print("refused: getBytes of %lux%lu at (%lu, %lu), the caller's rows %lu bytes apart: %s; nothing is copied\n",
			 (unsigned long)region.size.width, (unsigned long)region.size.height, (unsigned long)region.origin.x,
			 (unsigned long)region.origin.y, (unsigned long)bytesPerRow, hakios_metal_error());
	}
}

/* --- <MTLTextureSPI> --- */

- (BOOL)isCompressed                      { return NO; }   /* linear rows; no lossless compression on this GPU's path */
- (NSInteger)compressionFeedback          { return 0; }
- (BOOL)isDrawable                        { return NO; }   /* no CAMetalLayer hands these out */
/* the packed MTLTextureSwizzleChannels (red in the low byte), the field MTLTextureDescriptor's -swizzleKey and -swizzle
 * share: 0x05040302 for the identity. AppleMetalGLRenderer compares it with the swizzle GL's state wants and makes a view
 * (-newTextureViewWithPixelFormat:...swizzle:) when they differ, so a wrong identity key is a new view at every bind */
- (unsigned)swizzleKey
{
	const MTLTextureSwizzleChannels c = [self swizzle];

	return (unsigned)c.red | (unsigned)c.green << 8 | (unsigned)c.blue << 16 | (unsigned)c.alpha << 24;
}
- (NSUInteger)numFaces                    { return 1; }    /* a cube has six; this is not one */
- (NSUInteger)rotation                    { return 0; }
- (uint64_t)uniqueIdentifier              { return _uniqueIdentifier; }
- (uint64_t)gpuHandle                     { return _uniqueIdentifier; }
- (uint64_t)gpuAddress                    { return hakios_metal_texture_gpu_address(_texture); }   /* real: the Bo's */
- (uint64_t)sparseSurfaceDefaultValue     { return 0; }    /* nothing is sparse, so nothing is unmapped */

/* the index in a resource table, for argument buffers: there is no table here (the dispatch binds by descriptor), so the
 * answer is 0 and the line is what makes a caller that writes it somewhere readable in the log */
- (NSUInteger)resourceIndex
{
	HM_ONCE("a texture's resourceIndex was asked for; this plug-in has no resource table (no argument buffers), and answers 0\n");
	return 0;
}

/* --- <MTLTextureImplementation> --- */

/* what Metal's diagnostics print for this texture; the argument is Apple's indent level */
- (NSString *)formattedDescription:(NSUInteger)level
{
	(void)level;
	return [NSString stringWithFormat:@"<%s %p \"%@\": %lux%lu, pixel format %lu, usage %#lx, rows %lu bytes apart (the GPU's "
					  "pitch), GPU address %#llx, id %llu>", class_getName(object_getClass(self)), self, [self label],
					  (unsigned long)[self width], (unsigned long)[self height], (unsigned long)[self pixelFormat],
					  (unsigned long)_usage, (unsigned long)[self bufferBytesPerRow],
					  (unsigned long long)hakios_metal_texture_gpu_address(_texture), (unsigned long long)_uniqueIdentifier];
}

@end

/* ============================================================================================================
 * The sampler state: four TEX_SAMP words of hakios-metal's, under Metal's own base class
 * ============================================================================================================ */

@implementation HakiosMetalDepthStencilState

- (instancetype)initWithDevice:(id<MTLDevice>)device descriptor:(MTLDepthStencilDescriptor *)descriptor
{
	self = [super init];
	if (self == nil) {
		return nil;
	}
	_device = [device retain];
	_label = [[descriptor label] copy];
	_compare = (unsigned)[descriptor depthCompareFunction];
	_write = [descriptor isDepthWriteEnabled];
	/* a face Metal leaves nil is its default, Always / Keep / Keep / Keep with all-ones masks; the test is on only when
	 * some face can change a pixel's fate or the stencil, so that a state with the default faces costs no stencil
	 * registers and binds on a pass with no stencil attachment as Metal lets it */
	{
		MTLStencilDescriptor *faces[2] = { [descriptor frontFaceStencil], [descriptor backFaceStencil] };
		struct hakios_metal_stencil_face *out[2] = { &_front, &_back };

		for (int i = 0; i < 2; i++) {
			MTLStencilDescriptor *f = faces[i];
			struct hakios_metal_stencil_face *o = out[i];

			o->compare = f != nil ? (unsigned)[f stencilCompareFunction] : (unsigned)MTLCompareFunctionAlways;
			o->stencil_fail = f != nil ? (unsigned)[f stencilFailureOperation] : (unsigned)MTLStencilOperationKeep;
			o->depth_fail = f != nil ? (unsigned)[f depthFailureOperation] : (unsigned)MTLStencilOperationKeep;
			o->pass = f != nil ? (unsigned)[f depthStencilPassOperation] : (unsigned)MTLStencilOperationKeep;
			o->read_mask = f != nil ? (unsigned)[f readMask] & 0xff : 0xff;
			o->write_mask = f != nil ? (unsigned)[f writeMask] & 0xff : 0xff;
			if (o->compare != (unsigned)MTLCompareFunctionAlways || o->stencil_fail != (unsigned)MTLStencilOperationKeep ||
			    o->depth_fail != (unsigned)MTLStencilOperationKeep || o->pass != (unsigned)MTLStencilOperationKeep) {
				_stencil = YES;
			}
		}
	}
	return self;
}

- (void)dealloc
{
	[_device release];
	[_label release];
	[super dealloc];
}

- (NSString *)label { return _label; }
- (id<MTLDevice>)device { return _device; }
- (MTLResourceID)gpuResourceID { MTLResourceID r = { 0 }; return r; }   /* argument buffers are not served */
- (unsigned)hakiosDepthCompare { return _compare; }
- (BOOL)hakiosDepthWrite { return _write; }
- (BOOL)hakiosStencil { return _stencil; }
/* <MTLDepthStencilState>'s SPI, which AppleMetalGLRenderer asks to decide its load actions: a depth test that is not
 * Always reads depth, one that writes writes it; a stencil test reads and (with a write mask) writes stencil */
- (BOOL)readsDepth { return _compare != MTLCompareFunctionAlways || _write; }
- (BOOL)writesDepth { return _write; }
- (BOOL)readsStencil { return _stencil; }
- (BOOL)writesStencil { return _stencil && (_front.write_mask != 0 || _back.write_mask != 0); }
- (const struct hakios_metal_stencil_face *)hakiosStencilFront { return &_front; }
- (const struct hakios_metal_stencil_face *)hakiosStencilBack { return &_back; }

@end

@implementation HakiosMetalSamplerState

/* the base declares <MTLSamplerStateSPI>, which adopts the public protocol; declared again here so that a
 * conformsToProtocol: on the public name is a static yes whatever the SPI's adoption list says in this Metal */
+ (void)load
{
	hm_adopt(self, @protocol(MTLSamplerState), "MTLSamplerState");
}

HM_REFUSES_OUT_LOUD

- (instancetype)initWithHakiosDevice:(HakiosMetalDevice *)device sampler:(hakios_metal_sampler *)sampler descriptor:(MTLSamplerDescriptor *)descriptor
{
	/* the designated initialiser, given only what -newSamplerStateWithDescriptor: has already checked it accepts: it
	 * keeps the device (retained), the label (copied) and the pixel format, and answers <MTLSamplerState> from them */
	self = [super initWithDevice:device samplerDescriptor:descriptor];
	if (self == nil) {
		hakios_metal_sampler_free(sampler);
		return nil;
	}
	_hakiosSampler = sampler;
	_hakiosUniqueIdentifier = hm_next_resource_id();
	return self;
}

- (void)dealloc
{
	if (_hakiosSampler != NULL) {
		hakios_metal_sampler_free(_hakiosSampler);   /* a dispatch copied its four words; nothing in flight points at it */
	}
	[super dealloc];
}

- (hakios_metal_sampler *)hakiosSampler { return _hakiosSampler; }

/* The base's -gpuResourceID is -gpuHandle is -uniqueIdentifier, and the last is a nil-stub: a sampler would have
 * gpuResourceID 0, which an argument-buffer encoder would write as a handle. uniqueIdentifier is answered from the
 * textures' counter (never 0, never an address); gpuResourceID is the core's id, what an argument buffer holds for the
 * sampler and a draw or dispatch reading it finds the sampler by. */
- (uint64_t)uniqueIdentifier { return _hakiosUniqueIdentifier; }
- (MTLResourceID)gpuResourceID
{
	MTLResourceID rid = { hakios_metal_sampler_resource_id(_hakiosSampler) };

	return rid;
}

@end

/* ============================================================================================================
 * The compute pipeline state: one compiled kernel
 * ============================================================================================================ */

@implementation HakiosMetalComputePipelineState

+ (void)load
{
	hm_adopt(self, @protocol(MTLComputePipelineState), "MTLComputePipelineState");
}

HM_REFUSES_OUT_LOUD

- (instancetype)initWithHakiosDevice:(HakiosMetalDevice *)device kernel:(hakios_metal_kernel *)kernel descriptor:(id)descriptor
{
	self = [super initWithDevice:device pipelineStateDescriptor:descriptor];
	if (self == nil) {
		hakios_metal_kernel_free(kernel);
		return nil;
	}
	_device = [device retain];
	_kernel = kernel;
	_label = [[descriptor label] copy];
	return self;
}

- (void)dealloc
{
	if (_kernel != NULL) {
		hakios_metal_kernel_free(_kernel);   /* a dispatch in flight keeps its own reference */
	}
	[_device release];
	[_label release];
	[super dealloc];
}

- (hakios_metal_kernel *)hakiosKernel { return _kernel; }

/* the three numbers the base class answers with nothing: they come from whoever compiled the kernel */
- (NSUInteger)maxTotalThreadsPerThreadgroup { return hakios_metal_kernel_max_threads(_kernel); }
- (NSUInteger)threadExecutionWidth          { return hakios_metal_kernel_execution_width(_kernel); }
- (NSUInteger)staticThreadgroupMemoryLength { return hakios_metal_kernel_threadgroup_memory(_kernel); }
- (id)device                                { return _device; }
- (NSString *)label                         { return _label; }
- (BOOL)supportIndirectCommandBuffers       { return NO; }   /* a dispatch's grid is read here, not by the GPU */

@end

/* ============================================================================================================
 * The command queue
 * ============================================================================================================ */

/* Apple's own semaphore on the queue, by name. A Metal that keeps it elsewhere is said out loud: the right answer then
 * is to find out, not to run with a queue that blocks on its 64th command buffer without a word. */
static dispatch_semaphore_t
hm_queue_semaphore(id queue)
{
	static Ivar ivar;
	static BOOL looked;

	if (!looked) {
		looked = YES;
		ivar = hm_ivar("_MTLCommandQueue", "_commandBufferSemaphore");
		if (ivar == NULL) {
			hm_print("_MTLCommandQueue has no _commandBufferSemaphore in this Metal: the slot every command buffer "
				 "takes cannot be given back, and a queue will block on its maxCommandBufferCount'th buffer\n");
		}
	}
	return ivar != NULL ? (dispatch_semaphore_t)object_getIvar(queue, ivar) : nil;
}

/* Apple's own completion-queue ivar, for the same reason: the base class's getter reads it, so a queue made from a
 * descriptor that carried one must read back as what it is */
static Ivar
hm_completion_ivar(void)
{
	static Ivar ivar;
	static BOOL looked;

	if (!looked) {
		looked = YES;
		ivar = hm_ivar("_MTLCommandQueue", "_completionQueue");
		if (ivar == NULL) {
			hm_print("_MTLCommandQueue has no _completionQueue in this Metal; -setCompletionQueue: keeps it in the plug-in's own field\n");
		}
	}
	return ivar;
}

@implementation HakiosMetalCommandQueue

+ (void)load
{
	hm_adopt(self, @protocol(MTLCommandQueue), "MTLCommandQueue");
}

HM_REFUSES_OUT_LOUD

- (instancetype)initWithHakiosDevice:(HakiosMetalDevice *)device descriptor:(id)descriptor
{
	/* the initialiser IOGPUMetalCommandQueue sends to super; the descriptor must not be nil (the base asserts) */
	self = [super initWithDevice:device descriptor:descriptor];
	if (self == nil) {
		return nil;
	}
	_queue = hakios_metal_queue_new([device hakiosDevice]);
	if (_queue == NULL) {
		hm_print("refused: a command queue: %s\n", hakios_metal_error());
		[self release];
		return nil;
	}
	{
		/* boot-arg metal_defer=1: this queue's command buffers recorded by a thread of hakios-metal's own (deferred
		 * recording), so that the window server's render thread does not wait for each draw's encoding (some 40 us a
		 * draw on the phone, 2 November) */
		char args[1024] = "";
		size_t size = sizeof(args) - 1;

		if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "metal_defer=1") != NULL) {
			hakios_metal_queue_set_deferred(_queue, 1);
			HM_ONCE("command buffers recorded deferred, by a thread of hakios-metal's (metal_defer=1)\n");
		}
	}
	_device = [device retain];
	HM_ONCE("a command queue takes %lu command buffers at a time (maxCommandBufferCount); each one waits on the queue's "
		"semaphore in -[_MTLCommandBuffer initWithQueue:...], and this plug-in gives the slot back when the buffer "
		"completes%s\n", (unsigned long)[self maxCommandBufferCount],
		hm_queue_semaphore(self) != nil ? "" : ", EXCEPT that the semaphore was not found and it cannot");
	return self;
}

- (void)dealloc
{
	if (_queue != NULL) {
		hakios_metal_queue_free(_queue);
	}
	[_device release];
	[_completionQueue release];   /* only the plug-in's own copy; Apple's ivar is -[_MTLCommandQueue dealloc]'s */
	[_pending release];
	if (_deferred != NULL) {
		dispatch_release(_deferred);   /* every block on it holds a command buffer, which holds this queue: none is left */
	}
	[super dealloc];
}

- (hakios_metal_queue *)hakiosQueue { return _queue; }
- (id)device { return _device; }

- (id)commandBuffer
{
	return [[[HakiosMetalCommandBuffer alloc] initWithHakiosQueue:self] autorelease];
}

/* retained and unretained references are the same here: hakios-metal keeps every buffer and kernel a command buffer
 * names alive until the GPU is done with it, whatever the application releases meanwhile */
- (id)commandBufferWithUnretainedReferences { return [self commandBuffer]; }

- (id)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)descriptor
{
	if (descriptor != nil && [descriptor errorOptions] != MTLCommandBufferErrorOptionNone) {
		HM_ONCE("a command buffer was asked for with error options %lu (encoder execution status); the error this "
			"plug-in reports is hakios-metal's sentence, without per-encoder status\n", (unsigned long)[descriptor errorOptions]);
	}
	return [self commandBuffer];
}

- (void)insertDebugCaptureBoundary { }   /* there is no GPU capture tool to mark a boundary for */

/*
 * What the system's daemons send a queue first (backboardd and mediaserverd: 58 -setGPUPriority: and 30
 * -setCompletionQueue: in a hundred seconds, each one an unrecognized-selector abort until answered). Both are required
 * members of <MTLCommandQueueSPI>, which is declared in the AGX bundle and so in no process here. -setGPUPriority: is
 * not bookkeeping in Apple's driver -- the number goes to the GPU's scheduler -- but hakios-metal has one ring and one
 * priority, so the number is remembered, reported back and said once not to schedule anything. The range check is
 * Apple's own (0..5, and 3 is background-only), and like Apple's it reports rather than refuses.
 */
- (BOOL)setGPUPriority:(NSUInteger)priority
{
	if (priority > 5 || priority == 3) {
		HM_ONCE("GPU priority %lu is outside what Apple's _validateGPUPriority allows (0..5, 3 background-only); kept as asked\n",
			(unsigned long)priority);
	}
	HM_ONCE("a GPU priority of %lu was asked for; this plug-in has one ring and one priority, so the number is remembered "
		"and reported back but nothing schedules by it\n", (unsigned long)priority);
	_gpuPriority = priority;
	return YES;
}

- (BOOL)setGPUPriority:(NSUInteger)priority offset:(unsigned short)offset
{
	if (offset != 0) {
		HM_ONCE("a GPU priority offset of %u is ignored: one ring has no bands to be placed in\n", (unsigned)offset);
	}
	return [self setGPUPriority:priority];
}

- (BOOL)setBackgroundGPUPriority:(NSUInteger)priority
{
	HM_ONCE("a background GPU priority of %lu was asked for; remembered, not honoured, as the foreground one\n",
		(unsigned long)priority);
	_backgroundGPUPriority = priority;
	return YES;
}

- (BOOL)setBackgroundGPUPriority:(NSUInteger)priority offset:(unsigned short)offset
{
	(void)offset;
	return [self setBackgroundGPUPriority:priority];
}

- (NSUInteger)getGPUPriority           { return _gpuPriority; }
- (NSUInteger)getBackgroundGPUPriority { return _backgroundGPUPriority; }

/* SERVED: the dispatch queue a daemon wants its completion handlers on, so that none runs on its render thread. Kept
 * in Apple's own ivar so that the base class's getter and this plug-in read the same thing. */
- (void)setCompletionQueue:(dispatch_queue_t)queue
{
	Ivar ivar = hm_completion_ivar();
	dispatch_queue_t held = ivar != NULL ? (dispatch_queue_t)object_getIvar(self, ivar) : _completionQueue;

	if (held == queue) {
		return;
	}
	[queue retain];
	[held release];
	if (ivar != NULL) {
		object_setIvar(self, ivar, queue);
	} else {
		_completionQueue = queue;
	}
}

- (dispatch_queue_t)hakiosCompletionQueue
{
	Ivar ivar = hm_completion_ivar();

	return ivar != NULL ? (dispatch_queue_t)object_getIvar(self, ivar) : _completionQueue;
}

/* Reserve at enqueue, not commit. Only a committed prefix may reach the GPU: B's commit must return without
 * submitting B when A was enqueued first but is still being encoded. No worker waits for an uncommitted buffer. */
- (void)hakiosEnqueue:(HakiosMetalCommandBuffer *)buffer
{
	@synchronized (self) {
		if (_pending == nil) _pending = [[NSMutableArray alloc] init];
		[_pending addObject:buffer];
	}
}

/* The queue still reserves enqueue order. The core retains committed private work until a dependency drains it. */
static void hm_completed(hakios_metal_cb *cb, void *context);
static void hm_scheduled(hakios_metal_cb *cb, void *context)
{
    (void)cb;
    @autoreleasepool { [(HakiosMetalCommandBuffer *)context hakiosDeliverScheduled]; }
}

/* Install on the actual committing thread, including secondary CA render runloops. No timer or frame inference. */
static void hm_batch_idle(void)
{
    static _Thread_local BOOL armed;
    if (armed) return;
    armed = YES;
    CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
        kCFRunLoopBeforeWaiting | kCFRunLoopExit, false, LONG_MAX, ^(CFRunLoopObserverRef o, CFRunLoopActivity activity) {
            (void)o; (void)activity;
            armed = NO;
            hakios_metal_drain_all(HAKIOS_METAL_DRAIN_IDLE);
        });
    CFRunLoopAddObserver(CFRunLoopGetCurrent(), observer, kCFRunLoopCommonModes);
    CFRelease(observer);
}

/* a command buffer that presents a drawable: its work must be in the kernel before CoreAnimation's display can put
 * the drawable on the panel (the framebuffer waits for the surface's fence, and a submission that is not in the
 * kernel yet is not waited for: v29 App Library, the frame went to the panel half drawn and stayed). Off with
 * /var/db/hakios-metal-cache/defer-present-off, the old behaviour */
static BOOL hm_present_flush_off(void)
{
	static int off = -1;

	if (off < 0) off = access("/var/db/hakios-metal-cache/defer-present-off", F_OK) == 0;
	return off != 0;
}

- (void)hakiosDrain:(unsigned)reason
{
    @synchronized (self) { hakios_metal_queue_drain(_queue, reason); }
}

- (void)hakiosSendBuffers:(NSArray *)buffers
{
    @synchronized (self) {
        const unsigned count = (unsigned)[buffers count];
        struct hakios_metal_commit *entries = malloc(count * sizeof(*entries));
        unsigned *reasons = malloc(count * sizeof(*reasons));
        for (unsigned i = 0; i < count; i++) {
            HakiosMetalCommandBuffer *buffer = [buffers objectAtIndex:i];
            [buffer hakiosPrepareSend];
            entries[i] = (struct hakios_metal_commit){[buffer hakiosCommandBuffer], hm_completed, buffer};
            reasons[i] = [buffer hakiosDrainReason];
        }
        static BOOL off;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ off = access("/var/db/hakios-metal-cache/batch-commit-off", F_OK) == 0; });
        hm_perf_mark phase = hm_perf_begin();
        if (off) {
            for (unsigned i = 0; i < count; i++)
                hakios_metal_cb_commit(entries[i].cb, entries[i].callback, entries[i].context);
        } else {
            hakios_metal_queue_stage_batch(_queue, entries, count, hm_scheduled, reasons);
            CFStringRef mode = CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent());
            if (mode != NULL || pthread_main_np()) {
                hm_batch_idle();
            } else if (!_idlePending) {
                /* PencilKit also commits from dispatch work items: those threads do not run a CFRunLoop. */
                _idlePending = YES;
                if (_deferred == NULL) _deferred = dispatch_queue_create("hakios.metal.ordered-submissions", DISPATCH_QUEUE_SERIAL);
                dispatch_async(_deferred, ^{
                    @autoreleasepool {
                        @synchronized (self) {
                            _idlePending = NO;
                            hakios_metal_queue_drain(_queue, HAKIOS_METAL_DRAIN_IDLE);
                        }
                    }
                });
            }
            if (mode != NULL) CFRelease(mode);
        }
        hm_perf_end(HM_PERF_COMMIT_CORE, phase, 0);
        free(reasons);
        free(entries);
    }
}

- (void)hakiosCommit:(HakiosMetalCommandBuffer *)buffer
{
	NSArray *sent = nil;
	dispatch_queue_t flush = NULL;

	/* Before it is submitted, and before this queue's lock: a surface the buffer samples through a copy of its rows may
	 * have an earlier command buffer's GPU writes still on their way back to it, and the copies this buffer samples are
	 * taken again once they land (v29u: the App Library's background). The wait is bounded, and it is not held under
	 * the lock that a submission made here takes once its buffer reaches the GPU. */
	[buffer hakiosShadowSampleSync];
	@synchronized (self) {
		[buffer hakiosMarkReady];
		if ([_pending firstObject] != buffer) {
			HM_ONCE("queue-order: commit held behind an earlier enqueue\n");
		}
		if (_onDeferred == 0) {
			NSMutableArray *ready = [NSMutableArray array];
			while ([[_pending firstObject] hakiosReadyToSubmit] && ![[_pending firstObject] hakiosWaits]) {
				[ready addObject:[_pending firstObject]];
				[_pending removeObjectAtIndex:0];
			}
			if ([ready count] != 0) {
				sent = [ready copy];
				/* Submit under the queue lock so a concurrent commit cannot overtake this prefix. */
				[self hakiosSendBuffers:sent];
			}
		}
		if (_deferred == NULL) _deferred = dispatch_queue_create("hakios.metal.ordered-submissions", DISPATCH_QUEUE_SERIAL);
		while ([[_pending firstObject] hakiosReadyToSubmit]) {
			NSMutableArray *ready = [NSMutableArray arrayWithObject:[_pending firstObject]];
			BOOL waits = [[_pending firstObject] hakiosWaits];
			[_pending removeObjectAtIndex:0];
			while (!waits && [[_pending firstObject] hakiosReadyToSubmit] && ![[_pending firstObject] hakiosWaits]) {
				[ready addObject:[_pending firstObject]];
				[_pending removeObjectAtIndex:0];
			}
			NSArray *batch = [ready copy];
			_onDeferred++;
			dispatch_async(_deferred, ^{
				@autoreleasepool {
					if (waits) [[batch firstObject] hakiosSubmit];
					else {
						[self hakiosSendBuffers:batch];
						hakios_metal_queue_drain(_queue, HAKIOS_METAL_DRAIN_IDLE);
                        for (HakiosMetalCommandBuffer *next in batch) [next hakiosSent];
					}
				}
				@synchronized (self) { _onDeferred--; }
			});
			[batch release];
		}
		/*
		 * A buffer that presents a drawable is submitted before -commit returns, whatever queue the batches above
		 * were put on: the display is handed the drawable as soon as CoreAnimation presents it, and the kernel can
		 * only wait for work it has. (The queue is serial and the flush is outside the lock the deferred blocks
		 * take; the synchronous path above has sent it already, and then the empty block costs a wakeup.)
		 */
		if ([buffer hakiosDrainReason] == HAKIOS_METAL_DRAIN_SURFACE && !hm_present_flush_off()) {
			flush = _deferred;
		}
	}
	/* hm_ca_sync and rollback scheduling run outside the queue lock. Staged callbacks run on the core worker. */
	for (HakiosMetalCommandBuffer *next in sent) [next hakiosSent];
	[sent release];
	if (flush != NULL) dispatch_sync(flush, ^{});
}

@end

/* flicker-diag, in the window server alone: the surfaces it samples straight from their rows (applications' drawing),
 * looked at when the command buffer goes to the GPU and when the GPU is done with it */
static BOOL
hm_read_race_on(void)
{
	static int on = -1;

	if (on < 0) on = strcmp(getprogname(), "backboardd") == 0;
	return on != 0;
}

/* ============================================================================================================
 * The command buffer: hakios-metal's, with Metal's handlers and slot bookkeeping around it
 * ============================================================================================================ */

@implementation HakiosMetalCommandBuffer

/* _MTLCommandBuffer declares conformance to nothing, and MPSCommandBufferImageCache tests conformsToProtocol: before it
 * asks the buffer anything else; a NO there ended mediaserverd 59 times. */
+ (void)load
{
	hm_adopt(self, @protocol(MTLCommandBuffer), "MTLCommandBuffer");
}

HM_REFUSES_OUT_LOUD

- (instancetype)initWithHakiosQueue:(HakiosMetalCommandQueue *)queue
{
	hm_big_hint();
	/* what IOGPUMetalCommandBuffer sends to super. THIS CALL BLOCKS when the queue's semaphore is empty, so by the
	 * time it returns a slot is held and owed (see -hakiosPaySlot) */
	hm_perf_mark slotBegan = hm_perf_begin();
	self = [super initWithQueue:queue retainedReferences:YES synchronousDebugMode:NO];
	hm_perf_end(HM_PERF_CB_SLOT, slotBegan, 0);
	if (self == nil) {
		return nil;
	}
	_queue = [queue retain];
	_cb = hakios_metal_cb_new([queue hakiosQueue]);
	_createdAt = hm_now();
	_useSeq = hm_use_begin();
	if (_cb != NULL) {
		hakios_metal_cb_skip_refused(_cb, !hm_strict());
		hakios_metal_cb_set_profile(_cb, hm_fps_on());
		hakios_metal_cb_set_gmem(_cb, hm_gmem_on() || hm_gmem_draws() != 0);
		hakios_metal_cb_set_gmem_min_draws(_cb, hm_gmem_draws());
		hakios_metal_cb_set_gmem_binning(_cb, (hm_gmem_off() & 16) == 0);   /* metal_gmem_off's 16: every draw in every tile */
		/* 64: multisample and depth/stencil passes left in sysmem (otherwise tiled when memoryless, the resolve from the tiles) */
		hakios_metal_cb_set_gmem_msaa_zs(_cb, (hm_gmem_off() & 64) == 0);
		hakios_metal_cb_set_null_fs_textures(_cb, (hm_gmem_off() & 32) != 0);   /* 32: no texture reads, to time the shaders alone */
		hakios_metal_cb_set_gmem_off(_cb, hm_gmem_off());
		hakios_metal_cb_set_gmem_tuned(_cb, (hm_gmem_off() & 8) == 0);   /* metal_gmem_off's 8: GMEM wherever a pass can have it */
		hakios_metal_cb_set_profile_draws(_cb, hm_fps_draws());
		hakios_metal_cb_set_pass_wfi(_cb, hm_pass_wfi());
	}
	_owesSlot = YES;
	return self;
}

/*
 * Give the queue's slot back, exactly once: at completion, which is when Metal's own drivers give it back, or at
 * -dealloc for a buffer that was never committed. Apple's own "this buffer still owes a signal" flag is cleared at the
 * same time, so that its bookkeeping and this one cannot disagree about a debt that has been settled.
 */
- (void)hakiosPaySlot
{
	static Ivar flag;
	static BOOL looked;
	dispatch_semaphore_t semaphore;

	if (!_owesSlot) {
		return;
	}
	_owesSlot = NO;
	if (!looked) {
		looked = YES;
		flag = hm_ivar("_MTLCommandBuffer", "_needsCommandBufferSemaphoreSignal");
	}
	if (flag != NULL) {
		*(unsigned char *)((char *)self + ivar_getOffset(flag)) = 0;
	}
	semaphore = hm_queue_semaphore(_queue);
	if (semaphore != nil) {
		dispatch_semaphore_signal(semaphore);
	}
}

- (void)dealloc
{
	[self hakiosPaySlot];
	if (_cb != NULL) {
		hakios_metal_cb_free(_cb);   /* one in flight is waited for inside; one completed is not */
	}
	[_scheduled release];
	[_completed release];
	for (HakiosMetalTexture *texture in _shadowTargets) [texture hakiosShadowWriteDropped];   /* completed ones were emptied */
	[_shadowTargets release];
	[_shadowSamples release];
	[_probeReads release];
	[_probeWrites release];
	[_signals release];
	[_turned release];
	[_waits release];
	for (unsigned i = 0; i < _readCount; i++) CFRelease(_reads[i]);   /* (never sent) */
	if (_sent != NULL) {
		dispatch_release(_sent);
	}
	[_error release];
	[_queue release];
	[super dealloc];
}

- (hakios_metal_cb *)hakiosCommandBuffer { return _cb; }
- (uint64_t)hakiosUseSeq { return _useSeq; }

/* AppleMetalGLRenderer's profiling pass (a GL renderer property, after -[device mapShaderSampleBufferWithBuffer:...], which
 * says NO here): the program-info buffer is Apple's shader sampler's; the pass is an ordinary one */
- (id)sampledRenderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor programInfoBuffer:(void *)buffer capacity:(NSUInteger)capacity
{
	(void)buffer;
	(void)capacity;
	HM_ONCE("a sampled render encoder (Apple's shader sampling) was asked for: an ordinary one is given\n");
	return [self renderCommandEncoderWithDescriptor:descriptor];
}

- (id)device               { return [_queue device]; }
- (id)commandQueue         { return _queue; }
- (BOOL)retainedReferences { return YES; }
- (MTLCommandBufferErrorOption)errorOptions { return MTLCommandBufferErrorOptionNone; }

/* Metal's own numbers, which hakios_metal_status copies: not enqueued 0, enqueued 1, committed 2, scheduled 3,
 * completed 4, error 5 */
- (MTLCommandBufferStatus)status
{
	MTLCommandBufferStatus status = (MTLCommandBufferStatus)hakios_metal_cb_status(_cb);
	if (status >= MTLCommandBufferStatusCommitted) return status;
	return _committed ? MTLCommandBufferStatusCommitted : _enqueued ? MTLCommandBufferStatusEnqueued : status;
}

- (NSError *)error
{
	@synchronized (self) {
		if (_error == nil && hakios_metal_cb_status(_cb) == HAKIOS_METAL_ERROR) {
			NSString *why = [NSString stringWithUTF8String:hakios_metal_cb_error(_cb)];

			_error = [[NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorInternal
						  userInfo:@{ NSLocalizedDescriptionKey: why != nil ? why : @"(no reason recorded)" }] retain];
		}
		return _error;
	}
}

/* no logs: the kernels this plug-in runs have no logging to collect; said once rather than answered nil quietly */
- (id)logs
{
	HM_ONCE("a command buffer's logs were asked for; there is no shader logging here, and nil is answered\n");
	return nil;
}

/* The times Metal reports: the start is when the work was committed (host clock), the end that plus what the GPU
 * says it took (hakios_metal_cb_gpu_nanoseconds: commit to fence). The kernel's times are the same two numbers --
 * there is no separate kernel scheduler clock to read on this port. */
- (CFTimeInterval)GPUStartTime    { return _committedAt; }
- (double)hakiosCreatedAt         { return _createdAt; }
- (CFTimeInterval)GPUEndTime      { return _committedAt + (double)hakios_metal_cb_gpu_nanoseconds(_cb) / 1e9; }
- (CFTimeInterval)kernelStartTime { return [self GPUStartTime]; }
- (CFTimeInterval)kernelEndTime   { return [self GPUEndTime]; }

/* --- the encoders --- */

- (id)computeCommandEncoder
{
	return [[[HakiosMetalComputeCommandEncoder alloc] initWithHakiosCommandBuffer:self] autorelease];
}

/* serial and concurrent dispatch are the same thing on one ring that runs a buffer's commands in order */
- (id)computeCommandEncoderWithDispatchType:(MTLDispatchType)type
{
	(void)type;
	return [self computeCommandEncoder];
}

- (id)computeCommandEncoderWithDescriptor:(MTLComputePassDescriptor *)descriptor
{
	(void)descriptor;   /* its sample buffer attachments name counters this GPU does not publish */
	return [self computeCommandEncoder];
}

- (id)blitCommandEncoder
{
	return [[[HakiosMetalBlitCommandEncoder alloc] initWithHakiosCommandBuffer:self] autorelease];
}

- (id)blitCommandEncoderWithDescriptor:(MTLBlitPassDescriptor *)descriptor
{
	(void)descriptor;
	return [self blitCommandEncoder];
}

/*
 * The pass descriptor, read in full and once: colour attachment 0 (texture, load action, store action, clear colour)
 * becomes hakios-metal's render pass, and everything else the descriptor can carry is either harmless here or refused by
 * name. Metal reads none of it on this road (IOGPUMetalRenderCommandEncoder's init drops the descriptor), and the one
 * place Metal does look is -[MTLRenderPassColorAttachmentDescriptorInternal setTexture:], which asserts conformance to
 * MTLTextureImplementation -- declared by HakiosMetalTexture at +load for exactly this. NO: *why says what, and the pass
 * is not begun.
 */
/* A colour attachment's store action as the core takes it, and its resolve. MultisampleResolve (2) resolves and keeps
 * nothing of the samples (DontCare), StoreAndMultisampleResolve (3) keeps them too (Store); Unknown (4) is a Store until
 * -setColorStoreAction: decides. The resolve itself is a copy of the samples into RESOLVE at the end of the pass
 * (-endEncoding, hakios_metal_cb_blit reading SAMPLES a pixel): a texture of one sample, the attachment's size. */
static BOOL
hm_store_of(MTLRenderPassColorAttachmentDescriptor *c, NSUInteger i, unsigned *store, char *why, size_t size)
{
	MTLStoreAction a = [c storeAction];
	id<MTLTexture> r = [c resolveTexture], t = [c texture];
	BOOL resolves = a == MTLStoreActionMultisampleResolve || a == MTLStoreActionStoreAndMultisampleResolve;

	if (r != nil || resolves) {
		if (r == nil || ![r isKindOfClass:[HakiosMetalTexture class]] || [r sampleCount] != 1 || [t sampleCount] < 2 ||
		    [c resolveSlice] != 0 || [c resolveDepthPlane] != 0 || [r pixelFormat] != [t pixelFormat] ||
		    [c resolveLevel] >= [r mipmapLevelCount] ||
		    MAX((NSUInteger)1, [r width] >> [c resolveLevel]) != [t width] ||
		    MAX((NSUInteger)1, [r height] >> [c resolveLevel]) != [t height]) {
			snprintf(why, size, "colour attachment %lu asks for a resolve (store action %lu) %s; a multisample attachment resolved into a "
				 "texture of this device of one sample, its size, one slice, is what is served", (unsigned long)i, (unsigned long)a,
				 r == nil ? "with no resolveTexture" : "of an attachment or into a texture that does not fit");
			return NO;
		}
	}
	*store = a == MTLStoreActionMultisampleResolve ? (unsigned)MTLStoreActionDontCare
	       : a == MTLStoreActionStoreAndMultisampleResolve || a == MTLStoreActionUnknown ? (unsigned)MTLStoreActionStore : (unsigned)a;
	return YES;
}

/*
 * OpenGL ES's passes: AppleMetalGLRenderer sets the pass's (and each pipeline's) private openGLModeEnabled, and GL's
 * clip volume comes with it -- z from -w to w (HAKIOS_METAL_GL_DEPTH). GL's y is not the pass's business: the renderer
 * turns a GL framebuffer over itself, drawing through a viewport of negative height (its viewport function, 0x2093b8e24:
 * originY = GL's top edge, height = -GL's, unless the drawable is yInverted, when it hands the rectangle top-down), and
 * flips the scissor and the front face to match; every value is taken as given (v26 measured the negative heights:
 * "a viewport of 1125 x 0", refused before the core took them). What turns a drawable the right way up for the
 * compositor is its attachment's yInvert, which Apple's GPU applies when it stores the target: hm_yinvert_size.
 */
static unsigned
hm_gl_mode(MTLRenderPassDescriptor *d)
{
	SEL gl = sel_getUid("openGLModeEnabled");

	if (d == nil || ![d respondsToSelector:gl] || !((BOOL (*)(id, SEL))objc_msgSend)(d, gl)) {
		return 0;
	}
	HM_ONCE("gles: an OpenGL ES pass (openGLModeEnabled): GL's clip depth\n");
	return HAKIOS_METAL_GL_DEPTH;
}

/*
 * A yInverted attachment (the private yInvert of MTLRenderPass{Color,Depth}AttachmentDescriptorInternal, which
 * AppleMetalGLRenderer sets from its texture's flag, 0x2093ae050). Apple's GPU stores such a target upside down: AGX's
 * pass setup hands pbeState (the tile store) a mask of the yInverted colour attachments (AGXMetalA11 0x20928d75c..790),
 * as -setColorResolveTexture:...yInvert: hands it its own yInvert (0x2092f2a50). The renderer draws every GL framebuffer
 * the same way, bottom-up through a viewport of negative height (0x2093b8e24), and marks the drawable that the compositor
 * reads top row first -- a CAEAGLLayer's -- yInverted, for the GPU to turn it on the way out. Without that turn an app's
 * GL view is shown upside down (bilibili's ijkplayer video, v27). Here there is no store to turn, so the pass is drawn
 * turned instead -- each draw's viewport and scissor about the target's height, its front face the other way -- which
 * leaves the rows in memory where Apple's GPU leaves them. Not served the same: a draw in window coordinates
 * (-setViewportTransformEnabled:NO, the renderer's own blits and clears) is drawn as it lies, and gl_FragCoord.y and
 * dFdy read the turned rows. /var/db/hakios-metal-cache/gles-yinvert-off takes yInvert as it was taken before (not at all).
 * SIZE: the target's width and height at its level, or 0 x 0 when the pass is not turned.
 */
#define HM_YINVERT_OFF HM_CACHE_DIR "/gles-yinvert-off"

static void
hm_yinvert_size(MTLRenderPassDescriptor *d, unsigned size[2])
{
	static int off = -1;
	static unsigned said;
	SEL yi = sel_getUid("yInvert");
	id attachment, texture;
	NSUInteger level;

	size[0] = size[1] = 0;
	if (d == nil) {
		return;
	}
	attachment = [[d colorAttachments] objectAtIndexedSubscript:0];
	if (attachment == nil || [attachment texture] == nil) {
		attachment = [d depthAttachment];   /* (a pass of depth alone: its first attachment is what the viewport covers) */
	}
	texture = attachment != nil ? [attachment texture] : nil;
	if (texture == nil || ![attachment respondsToSelector:yi] || !((BOOL (*)(id, SEL))objc_msgSend)(attachment, yi)) {
		return;
	}
	if (off < 0) {
		off = access(HM_YINVERT_OFF, F_OK) == 0;
		hm_print("gles: a yInverted attachment (%lux%lu, %s): %s\n", (unsigned long)[texture width], (unsigned long)[texture height],
			 [d respondsToSelector:sel_getUid("openGLModeEnabled")] &&
				 ((BOOL (*)(id, SEL))objc_msgSend)(d, sel_getUid("openGLModeEnabled")) ? "an OpenGL ES pass" : "not an OpenGL ES pass",
			 off ? HM_YINVERT_OFF " exists: drawn as it lies, not turned (the old way)"
			     : "drawn turned about its height, as Apple's GPU stores it");
	}
	if (off) {
		return;
	}
	level = [attachment level];
	size[0] = (unsigned)MAX((NSUInteger)1, [texture width] >> level);
	size[1] = (unsigned)MAX((NSUInteger)1, [texture height] >> level);
	if (said < 4) {
		said++;
		hm_print("gles: yInvert pass %u: %ux%u (level %lu) turned about its height\n", said, size[0], size[1], (unsigned long)level);
	}
}

static BOOL
hm_read_render_pass(MTLRenderPassDescriptor *d, struct hakios_metal_render_pass *pass, HakiosMetalTexture **texture, char *why, size_t size)
{
	MTLRenderPassColorAttachmentDescriptor *c0;
	id t0, depth, stencil;
	MTLClearColor clear;

	memset(pass, 0, sizeof(*pass));
	*texture = nil;
	if (d == nil || ![d isKindOfClass:[MTLRenderPassDescriptor class]]) {
		snprintf(why, size, "the pass descriptor is %s, not an MTLRenderPassDescriptor", d != nil ? class_getName(object_getClass(d)) : "nil");
		return NO;
	}
	c0 = [[d colorAttachments] objectAtIndexedSubscript:0];
	t0 = c0 != nil ? [c0 texture] : nil;   /* nil: a pass of depth alone, or one whose first target is a later index */
	pass->gl_mode = hm_gl_mode(d);
	/* the targets past 0, read as attachment 0 is (hakios-metal draws into the ones the function writes and clears the
	 * ones that ask for a Clear; the ones it does not write it leaves as they are) */
	for (NSUInteger i = 1; i < 8; i++) {
		MTLRenderPassColorAttachmentDescriptor *c = [[d colorAttachments] objectAtIndexedSubscript:i];
		id t = c != nil ? [c texture] : nil;

		if (t == nil) {
			continue;
		}
		if (![t isKindOfClass:[HakiosMetalTexture class]] || ([t usage] & MTLTextureUsageRenderTarget) == 0) {
			snprintf(why, size, "colour attachment %lu is a %s%s", (unsigned long)i, class_getName(object_getClass(t)),
				 [t isKindOfClass:[HakiosMetalTexture class]] ? " made without MTLTextureUsageRenderTarget" : ", not a texture of this device");
			return NO;
		}
		/* (a 2D array's layer or a cube's face is its slice, a 3D texture's plane its depth plane: hakios-metal draws
		 * into that one, and refuses one past the texture's) */
		{
			MTLClearColor cc = [c clearColor];
			struct hakios_metal_color_attachment *m = &pass->more[i - 1];
			unsigned store;

			if (!hm_store_of(c, i, &store, why, size)) {
				return NO;
			}
			m->texture = [(HakiosMetalTexture *)t hakiosTexture];
			m->level = (unsigned)[c level];
			m->slice = (unsigned)([t textureType] == MTLTextureType3D ? [c depthPlane] : [c slice]);
			m->load_action = (unsigned)[c loadAction];
			m->store_action = store;
			m->clear_color[0] = cc.red;
			m->clear_color[1] = cc.green;
			m->clear_color[2] = cc.blue;
			m->clear_color[3] = cc.alpha;
		}
	}
	if (t0 != nil && ![t0 isKindOfClass:[HakiosMetalTexture class]]) {
		snprintf(why, size, "the texture of colour attachment 0 is a %s, not a texture of this device", class_getName(object_getClass(t0)));
		return NO;
	}
	if (t0 != nil && ([t0 usage] & MTLTextureUsageRenderTarget) == 0) {
		snprintf(why, size, "the texture of colour attachment 0 was made with usage %#lx, without MTLTextureUsageRenderTarget (4); a "
			 "draw into it is refused", (unsigned long)[t0 usage]);
		return NO;
	}
	/* (colour attachment 0's slice or depth plane as the others', below) */
	if (t0 != nil && !hm_store_of(c0, 0, &pass->store_action, why, size)) {
		return NO;
	}
	if ([c0 storeAction] == MTLStoreActionCustomSampleDepthStore) {
		snprintf(why, size, "colour attachment 0 has store action CustomSampleDepthStore (5), a depth store action, on a colour attachment");
		return NO;
	}
	if ([c0 storeActionOptions] != MTLStoreActionOptionNone) {
		HM_ONCE("a colour attachment carries store action options %#lx (custom sample positions); one sample here, nothing to position\n",
			(unsigned long)[c0 storeActionOptions]);
	}
	depth = [[d depthAttachment] texture];
	stencil = [[d stencilAttachment] texture];
	if (stencil != nil && ![stencil isKindOfClass:[HakiosMetalTexture class]]) {
		snprintf(why, size, "the stencil attachment is not a texture of this device");
		return NO;
	}
	if (stencil != nil && ([[d stencilAttachment] level] != 0 || [[d stencilAttachment] slice] != 0 || [[d stencilAttachment] depthPlane] != 0)) {
		snprintf(why, size, "a stencil attachment requires level 0, slice 0");
		return NO;
	}
	if (depth != nil && ![depth isKindOfClass:[HakiosMetalTexture class]]) {
		snprintf(why, size, "the depth attachment is a %s, not a texture of this device", class_getName(object_getClass(depth)));
		return NO;
	}
	if ([d visibilityResultBuffer] != nil) {
		/* occlusion queries: each draw's -setVisibilityResultMode:offset: counts into it (hakios-metal's draw) */
		if (![[d visibilityResultBuffer] isKindOfClass:[HakiosMetalBuffer class]]) {
			snprintf(why, size, "the visibility result buffer is a %s, not a buffer of this device",
				 class_getName(object_getClass([d visibilityResultBuffer])));
			return NO;
		}
		pass->visibility = [(HakiosMetalBuffer *)[d visibilityResultBuffer] hakiosBuffer];
	}
	if ([d renderTargetArrayLength] > 1) {
		snprintf(why, size, "renderTargetArrayLength %lu (layered rendering); one layer is served", (unsigned long)[d renderTargetArrayLength]);
		return NO;
	}
	if ([d rasterizationRateMap] != nil) {
		snprintf(why, size, "a rasterization rate map is set (variable rate shading); not served");
		return NO;
	}
	if ([d imageblockSampleLength] != 0 || [d threadgroupMemoryLength] != 0 || [d tileWidth] != 0 || [d tileHeight] != 0) {
		HM_ONCE("a render pass asks for tile shading state (imageblock %lu bytes, threadgroup memory %lu, tile %lux%lu); this GPU has no "
			"tile memory and no tile pipeline can be made, so the numbers decide nothing\n", (unsigned long)[d imageblockSampleLength],
			(unsigned long)[d threadgroupMemoryLength], (unsigned long)[d tileWidth], (unsigned long)[d tileHeight]);
	}
	/* Unknown (4) is Metal's "decided later by -setColorStoreAction:"; until then it is a store, which is what sysmem does
	 * anyway: the RB writes the memory as it draws, there is no tile to store from */
	if (t0 == nil && depth == nil && stencil == nil && pass->more[0].texture == NULL && pass->more[1].texture == NULL && pass->more[2].texture == NULL &&
	    pass->more[3].texture == NULL && pass->more[4].texture == NULL && pass->more[5].texture == NULL && pass->more[6].texture == NULL) {
		snprintf(why, size, "the pass has no attachment at all (no colour texture, no depth); nothing to draw into");
		return NO;
	}
	pass->color0 = t0 != nil ? [(HakiosMetalTexture *)t0 hakiosTexture] : NULL;
	pass->color0_level = (unsigned)[c0 level];   /* the core refuses a level past the texture's, with the numbers */
	pass->color0_slice = t0 != nil ? (unsigned)([t0 textureType] == MTLTextureType3D ? [c0 depthPlane] : [c0 slice]) : 0;
	/* (with no texture at 0 its actions say nothing; a Load spends no Clear on an attachment that is not there) */
	pass->load_action = t0 != nil ? (unsigned)[c0 loadAction] : (unsigned)MTLLoadActionLoad;
	if (t0 != nil && hm_timeline_on() && [t0 width] >= 1000 && [t0 height] >= 2000) {
		static unsigned seen[3], told, formats[8][2];
		if (pass->load_action < 3) seen[pass->load_action]++;
		for (unsigned f = 0; f < 8; f++) {
			if (formats[f][0] == (unsigned)[t0 pixelFormat] || formats[f][1] == 0) {
				formats[f][0] = (unsigned)[t0 pixelFormat];
				formats[f][1]++;
				break;
			}
		}
		static unsigned acts[3][2];
		if (pass->more[0].texture != NULL && pass->more[0].load_action < 3) acts[pass->more[0].load_action][pass->more[0].store_action ? 1 : 0]++;
		if (told % 200 == 199) {
			hm_print("timeline: attachment 1's load/store: dontcare %u/%u, load %u/%u, clear %u/%u (not stored/stored)\n", acts[0][0], acts[0][1], acts[1][0],
				 acts[1][1], acts[2][0], acts[2][1]);
		}
		static unsigned more[4];
		unsigned extra = 0;
		for (unsigned i = 0; i < 7; i++) extra += pass->more[i].texture != NULL;
		more[extra < 3 ? extra : 3]++;
		if (told % 200 == 199) hm_print("timeline: full-screen passes with 0, 1, 2, 3+ more colour attachments: %u %u %u %u\n", more[0], more[1], more[2], more[3]);
		if (++told % 200 == 0) {
			hm_print("timeline: full-screen passes by load action: dontcare %u load %u clear %u; by format: %u x%u, %u x%u, %u x%u, %u x%u\n", seen[0], seen[1],
				 seen[2], formats[0][0], formats[0][1], formats[1][0], formats[1][1], formats[2][0], formats[2][1], formats[3][0], formats[3][1]);
		}
	}
	/* (pass->store_action is hm_store_of's, read above with the resolve) */
	clear = [c0 clearColor];
	pass->clear_color[0] = clear.red;
	pass->clear_color[1] = clear.green;
	pass->clear_color[2] = clear.blue;
	pass->clear_color[3] = clear.alpha;
	if (depth != nil) {
		/* the depth attachment: Metal's actions passed through (Unknown, 4, is a store until -setDepthStoreAction: says
		 * otherwise, as for colour), the clear depth read only for a Clear; hakios-metal judges the format and size */
		MTLRenderPassDepthAttachmentDescriptor *da = [d depthAttachment];

		pass->depth = [(HakiosMetalTexture *)depth hakiosTexture];
		pass->depth_level = (unsigned)[da level];   /* the core refuses one past the texture's */
		pass->depth_slice = (unsigned)[da slice];   /* a depth 2D array's layer (a shadow cascade); the core refuses one past them */
		pass->depth_load_action = (unsigned)[da loadAction];
		pass->depth_store_action = [da storeAction] == MTLStoreActionUnknown ? (unsigned)MTLStoreActionStore : (unsigned)[da storeAction];
		pass->clear_depth = [da clearDepth];
	}
	if (stencil != nil) {
		MTLRenderPassStencilAttachmentDescriptor *sa = [d stencilAttachment];

		pass->stencil = [(HakiosMetalTexture *)stencil hakiosTexture];
		pass->stencil_load_action = (unsigned)[sa loadAction];
		pass->stencil_store_action = [sa storeAction] == MTLStoreActionUnknown ? (unsigned)MTLStoreActionStore : (unsigned)[sa storeAction];
		pass->clear_stencil = [sa clearStencil] & 0xff;
	}
	if (hm_maps_trace() && [t0 sampleCount] > 1 && [t0 width] >= 1000) {
		static unsigned said;
		const unsigned n = __atomic_fetch_add(&said, 1, __ATOMIC_RELAXED);
		if (n < 24) {
			hm_print("maps-pass %u: colour %p %lux%lu samples %lu storage %lu load %u store %lu clear %.4g %.4g %.4g %.4g resolve %p; "
				 "depth %p load/store %u/%u clear %.4g; stencil %p load/store %u/%u clear %u; GL %u yInvert %u\n", n,
				 t0, (unsigned long)[t0 width], (unsigned long)[t0 height], (unsigned long)[t0 sampleCount], (unsigned long)[t0 storageMode],
				 pass->load_action, (unsigned long)[c0 storeAction], clear.red, clear.green, clear.blue, clear.alpha, [c0 resolveTexture],
				 depth, pass->depth_load_action, pass->depth_store_action, pass->clear_depth,
				 stencil, pass->stencil_load_action, pass->stencil_store_action, pass->clear_stencil, pass->gl_mode,
				 [c0 respondsToSelector:sel_getUid("yInvert")] ? (unsigned)((BOOL(*)(id,SEL))objc_msgSend)(c0, sel_getUid("yInvert")) : 0);
		}
	}
	*texture = t0;
	return YES;
}

/* whether a pass still owes a Clear -- of any colour attachment or of the depth -- and its Clears spent (made Loads) once
 * a draw or the pass's own clear has recorded them: one fill per attachment and pass, however many draws follow */
static BOOL
hm_owes_clear(const struct hakios_metal_render_pass *pass)
{
	if (pass->load_action == (unsigned)MTLLoadActionClear || (pass->depth != NULL && pass->depth_load_action == (unsigned)MTLLoadActionClear) ||
	    (pass->stencil != NULL && pass->stencil_load_action == (unsigned)MTLLoadActionClear)) {
		return YES;
	}
	for (int i = 0; i < 7; i++) {
		if (pass->more[i].texture != NULL && pass->more[i].load_action == (unsigned)MTLLoadActionClear) {
			return YES;
		}
	}
	return NO;
}

static void
hm_spend_clears(struct hakios_metal_render_pass *pass)
{
	pass->load_action = (unsigned)MTLLoadActionLoad;
	pass->depth_load_action = (unsigned)MTLLoadActionLoad;
	pass->stencil_load_action = (unsigned)MTLLoadActionLoad;
	for (int i = 0; i < 7; i++) {
		pass->more[i].load_action = (unsigned)MTLLoadActionLoad;
	}
}

/* A surface drawn into through a copy of its rows (-hakiosShadow:): the copy as the surface is now, for a Load, and
 * what the pass drew back into the surface once the command buffer is done -- as for a kernel's writes */
static void
hm_shadow_targets(MTLRenderPassDescriptor *d, id<MTLCommandBuffer> cb)
{
	for (NSUInteger i = 0; i < 8; i++) {
		MTLRenderPassColorAttachmentDescriptor *a = [[d colorAttachments] objectAtIndexedSubscript:i];
		id t = [a texture];
		/* only this driver's own textures are asked anything: an attachment may be a view, a
		 * placeholder or another device's texture */
		if (t == nil || ![t isKindOfClass:[HakiosMetalTexture class]]) continue;
		id resolve = [a resolveTexture];
		[(HakiosMetalCommandBuffer *)cb hakiosTrackTexture:t write:YES];
		if ([a loadAction] == MTLLoadActionLoad) [(HakiosMetalCommandBuffer *)cb hakiosTrackTexture:t write:NO];
		if ([resolve isKindOfClass:[HakiosMetalTexture class]]) [(HakiosMetalCommandBuffer *)cb hakiosTrackTexture:resolve write:YES];
		if (hm_handoff_on()) hm_diag_add(&hm_diag.passAttachments);
		if ([(HakiosMetalTexture *)t hakiosIsTurned]) {
			[(HakiosMetalCommandBuffer *)cb hakiosTurnAtCommit:t];
			continue;
		}
		if (![(HakiosMetalTexture *)t hakiosIsShadow]) continue;
		[(HakiosMetalTexture *)t hakiosRefreshShadow];
		[(HakiosMetalCommandBuffer *)cb hakiosWriteShadowAtCompletion:t];
	}
}

/* A pass that cannot be served ends the command buffer in error and gives NO encoder: a caller then sends its draws
 * to nil, and -commit reports the sentence. (The alternative, an encoder that fails its draws one by one, was measured
 * no clearer in the earlier plug-in, and a nil texture in a drawable was what cost it most -- here the nil is said.) */
- (id)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor
{
	struct hakios_metal_render_pass pass;
	HakiosMetalTexture *texture = nil;
	char why[256];

	if (!hm_read_render_pass(descriptor, &pass, &texture, why, sizeof(why))) {
		hm_print("refused: a render pass: %s; the command buffer is failed and no encoder is returned\n", why);
		hakios_metal_cb_refuse(_cb, why);
		return nil;
	}
	{
		HakiosMetalRenderCommandEncoder *encoder = [[[HakiosMetalRenderCommandEncoder alloc] initWithHakiosCommandBuffer:self pass:&pass
													     colorTexture:texture] autorelease];

		unsigned turned[2];

		hm_shadow_targets(descriptor, (id<MTLCommandBuffer>)self);

		[encoder hakiosTakeResolves:descriptor];   /* hm_read_render_pass judged them */
		hm_yinvert_size(descriptor, turned);
		[encoder hakiosSetYInvertWidth:turned[0] height:turned[1]];
		return encoder;
	}
}

/* a parallel encoder splits one pass across threads, each sub-encoder its own object (HakiosMetalParallelRenderCommandEncoder) */
- (id)parallelRenderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor
{
	struct hakios_metal_render_pass pass;
	HakiosMetalTexture *texture = nil;
	char why[256];

	if (!hm_read_render_pass(descriptor, &pass, &texture, why, sizeof(why))) {
		hm_print("refused: a parallel render pass: %s; the command buffer is failed and no encoder is returned\n", why);
		hakios_metal_cb_refuse(_cb, why);
		return nil;
	}
	hm_shadow_targets(descriptor, (id<MTLCommandBuffer>)self);
	return [[[HakiosMetalParallelRenderCommandEncoder alloc] initWithHakiosCommandBuffer:self pass:&pass colorTexture:texture
											descriptor:descriptor] autorelease];
}

- (id)resourceStateCommandEncoder
{
	hm_refusal(self, _cmd, "has no sparse textures to map; it returns nil");
	return nil;
}

- (id)accelerationStructureCommandEncoder
{
	hm_refusal(self, _cmd, "has no ray tracing; it returns nil");
	return nil;
}

/* --- ordering --- */

/* Explicit enqueue and commit's implicit enqueue share the same reservation. */
- (void)enqueue
{
	@synchronized (self) {
		if (_enqueued) return;
		_enqueued = YES;
		_sent = dispatch_semaphore_create(0);
		[_queue hakiosEnqueue:self];
	}
	HM_ONCE("queue-order: enqueue reservations honoured; scheduled handlers precede completion\n");
}

/* Private commits are retained until a dependency or idle drain. Surface writes publish a real fence before
 * returning. Completion/error callbacks run in queue order and release the object's flight reference. */
/*
 * boot-arg metal_fps (a diagnostic): every two seconds of a process's command buffers, how many frames it presented, how
 * many buffers it committed, how long the GPU was busy with them, how long -commit kept the caller's thread and how
 * long a buffer took from commit to completion. Which of the three is near the two seconds says where a low frame
 * rate comes from: the GPU, the driver's own work on the caller's thread, or the waiting between them.
 */
static struct {
	pthread_mutex_t lock;
	double since;
	unsigned presents, buffers;
	double gpu, commit, latency, latencyMax;
	unsigned passes, draws, dispatches, copies, gmemPasses, tiles;
	double shadowIn, shadowOut;   /* seconds in surface copies: taken from the surface, written back into it */
	unsigned shadowIns, shadowOuts;
	struct { unsigned kind, width, height, draws, tiles; double us; char why[96]; } slowest[4];   /* the slowest passes of the period (WHY: a sysmem pass's reason) */
	double passUs;                /* all passes timed, together */
	char gmemWhy[160];            /* the last reason a pass stayed in sysmem */
	struct { char name[96]; unsigned count; double us; } programs[48];   /* metal_fps=draws: GPU time by program */
	BOOL heavyShown;              /* metal_fps=draws: a heavy pass's draws printed this period */
	/* the gaps between one commit and the next, where something moves (under 0.25 s): on time for 60 Hz (20 ms at
	 * most), a frame missed (to 50), a stall (past 50) -- what a user sees as smooth or not, which the GPU's busy
	 * time alone does not say */
	double lastCommit;
	unsigned gapsOnTime, gapsLate, gapsStall;
	double encode, encodeMax;
	unsigned held;
	double waited;
	unsigned waits;
	double drawCpu, coreCpu;
	unsigned drawCalls;
	unsigned drawsOn[8];   /* the draw calls on each processor (TPIDR_EL0's number), and their time there */
	double drawUsOn[8];
	uint64_t lastTpidr;
	double sampledBytes[6];   /* metal_fps=timeline: the bound fragment textures' sizes, by hakiosStorageKind */
	struct { unsigned w, h, origin; double bytes; } bySize[16];
	unsigned flushes, barriers, warWaits, chained;   /* the passes' synchronization (hakios_metal_cb_sync_counts) */
	unsigned ycbcrFrames;   /* successfully converted current frames */
	unsigned shadowKeptWrites, shadowKeptTorn;   /* refreshes that took no copy: GPU writes pending, surface written under it */
	/* samples of a shadow copy that found GPU writes into its surface still queued, the waits that drained them and the
	 * waits that ran out (-[HakiosMetalCommandBuffer hakiosShadowSampleSync]) */
	unsigned shadowSamplePending, shadowSampleWaits, shadowSampleTimeouts;
} hm_fps = { PTHREAD_MUTEX_INITIALIZER, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, {{0, 0, 0, 0, 0, 0}}, 0, "", {{"", 0, 0}}, NO, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, {0}, {0}, 0, {0}, {{0, 0, 0, 0}} };
static struct {
    unsigned textureCalls, blitSources, blitDestinations;
    double textureWall, textureMax;
} hm_handoff;
static unsigned hm_ycbcrAttempts;
static double hm_ycbcrCpu;
static unsigned hm_ycbcrGPUCount;
static double hm_ycbcrGPUTime;
static double hm_ycbcrSummarySince;
static unsigned hm_ycbcrSummaryGPUCount;
static double hm_ycbcrSummaryGPUTime;

/* The words the three GMEM switches below are read from: the boot-args, then a file -- /var/db/hakios-metal-cache/gmem-args
 * if it is there and readable (written over SSH; a sandboxed app may not reach /var/db), else
 * /redwood/share/metal-gmem/args if the payload has it (EXTRA_SHARE=<dir named metal-gmem>) -- so that a bisect of
 * metal_gmem, metal_gmem_draws and metal_gmem_off needs no room in the boot-args (XNU keeps 607 characters, and they
 * are full). A switch in the boot-args wins: it is found first. Read once a process: a new file takes effect when the
 * process starts again (killall backboardd). */
static const char *
hm_gmem_args(void)
{
	static char args[1536];
	static int done = 0;

	if (!done) {
		size_t size = 1023;
		int fd;

		if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) != 0) {
			size = 0;
		}
		args[size < 1023 ? size : 1023] = '\0';
		const char *path = "/var/db/hakios-metal-cache/gmem-args";
		fd = open(path, O_RDONLY);
		if (fd < 0) {
			path = "/redwood/share/metal-gmem/args";
			fd = open(path, O_RDONLY);
		}
		if (fd >= 0) {
			size_t at = strlen(args);
			ssize_t n;

			args[at++] = ' ';
			n = read(fd, args + at, sizeof(args) - at - 1);
			args[at + (n > 0 ? (size_t)n : 0)] = '\0';
			close(fd);
			hm_print("gmem: switches from %s: %s\n", path, args + at);
		}
		done = 1;
	}
	return args;
}

/* boot-arg metal_gmem=1: tiled rendering (render::Options::gmem) for a pass that can have it, GMEM or sysmem chosen by
 * what each cost such passes before (hakios_metal_cb_set_gmem_tuned). Off by default: for CoreAnimation it won nothing
 * -- a pass of 23 draws took the GPU 5 ms in GMEM against 0.13 in sysmem, and SpringBoard's tour as a whole 7.1 ms a
 * command buffer against 6.5 -- since its passes touch little of the screen and read it back through framebuffer fetch,
 * which the texture unit does from GMEM at a quarter of its rate from memory. A game blending whole screens gains. */
static BOOL
hm_gmem_on(void)
{
	static int on = -1;

	if (on < 0) {
		on = strstr(hm_gmem_args(), "metal_gmem=1") != NULL;
	}
	return on != 0;
}

/* boot-arg metal_pass_wfi=1: every pass with its own full tail and batch start, each a wait for idle on the GPU, as
 * before 9 November (hakios_metal_cb_set_pass_wfi). Without it draw passes are chained: the full tail once before
 * anything else and the barriers their hazards ask for (a CCU flush, CACHE_INVALIDATE and a WFI where a pass samples
 * what an earlier one wrote; a WFI where it writes what an earlier one sampled). For an A/B on the phone. */
static BOOL
hm_pass_wfi(void)
{
	static int on = -1;

	if (on < 0) {
		char args[1024] = {0};
		size_t size = sizeof(args) - 1;

		on = sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "metal_pass_wfi=1") != NULL;
	}
	return on != 0;
}

/* metal_fps=draws: each draw of a sysmem pass timed alone, by program (only sysmem passes are: without metal_gmem=1).
 * In the boot-args or the GMEM switches' file (hm_gmem_args): with metal_gmem_draws=0 beside it there, which full-screen
 * draws cost v25's 10 ms passes of 18 draws, with no room taken in the boot-args. */
static BOOL
hm_fps_draws(void)
{
	static int on = -1;

	if (on < 0) {
		on = strstr(hm_gmem_args(), "metal_fps=draws") != NULL;
	}
	return on != 0;
}

/* boot-arg metal_gmem_off=N: GMEM's refinements off by the bits of N (hakios_metal_cb_set_gmem_off; 8: the choice of GMEM
 * or sysmem by what each costs, hakios_metal_cb_set_gmem_tuned; 16: the hardware's binning,
 * hakios_metal_cb_set_gmem_binning; 32: every fragment texture the null one, wrong pictures but each draw's time without
 * its texture reads, hakios_metal_cb_set_null_fs_textures; 64: multisample and depth/stencil passes kept in sysmem,
 * hakios_metal_cb_set_gmem_msaa_zs), for a bisect */
static unsigned
hm_gmem_off(void)
{
	static int bits = -1;

	if (bits < 0) {
		const char *at;

		bits = 0;
		if ((at = strstr(hm_gmem_args(), "metal_gmem_off=")) != NULL) {
			bits = atoi(at + strlen("metal_gmem_off="));
		}
	}
	return (unsigned)bits;
}

/* boot-arg metal_gmem_draws=N: GMEM for a pass whose like had at least N draws in the frame before
 * (hakios_metal_cb_set_gmem_min_draws), sysmem for the rest; 56 when not given, 0 turns it off. SpringBoard's tour: its
 * heavy passes in GMEM 14 ms where 80 draws took 12 to 32 in sysmem, 18 where 141 took 19 to 23, the light ones left
 * in sysmem, the GPU's whole time the same (4.48 s against 4.43). */
static unsigned
hm_gmem_draws(void)
{
	static int draws = -1;

	if (draws < 0) {
		const char *at;

#ifdef HAKIOS_UMI
        draws = 0;   /* A650 GMEM hung on the first unlock; explicit opt-in only. */
#else
        draws = 56;
#endif
		if ((at = strstr(hm_gmem_args(), "metal_gmem_draws=")) != NULL) {
			draws = atoi(at + strlen("metal_gmem_draws="));
		}
	}
	return (unsigned)draws;
}

static BOOL
hm_fps_on(void)
{
	static int on = -1;

	if (on < 0) {
		char args[1024] = {0};
		size_t size = sizeof(args) - 1;

		on = sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "metal_fps") != NULL;
	}
	return on != 0;
}

static BOOL
hm_panel_presents(uint64_t *count)
{
	/* Other clients' drawable rates must not include the window server's frames. */
	if (strcmp(getprogname(), "backboardd") != 0) return NO;
	size_t size = sizeof(*count);
	return sysctlbyname("kern.hakios.fb_presented", count, &size, NULL, 0) == 0 && size == sizeof(*count);
}

/* one buffer done (GPU seconds, commit-to-completion seconds, what it held) or one frame presented (present set) */
static void
hm_fps_note(BOOL present, double gpu, double latency, hakios_metal_cb *cb)
{
	const double now = hm_now();
	static uint64_t panelLast;
	static BOOL panelValid;

	if (!hm_fps_on()) {
		return;
	}
	pthread_mutex_lock(&hm_fps.lock);
	if (hm_fps.since == 0) {
		hm_fps.since = now;
		panelValid = hm_panel_presents(&panelLast);
	}
	if (present) {
		hm_fps.presents++;
	} else {
		hm_fps.buffers++;
		hm_fps.gpu += gpu;
		hm_fps.latency += latency;
		hm_fps.latencyMax = MAX(hm_fps.latencyMax, latency);
		if (cb != NULL) {
			unsigned passes = 0, draws = 0, dispatches = 0, copies = 0, clears = 0;

			hakios_metal_cb_counts(cb, &passes, &draws, &dispatches, &copies, &clears);
			hm_fps.passes += passes + copies + clears + dispatches;
			{
				unsigned fl = 0, ba = 0, wa = 0, ch = 0;

				hakios_metal_cb_sync_counts(cb, &fl, &ba, &wa, &ch);
				hm_fps.flushes += fl;
				hm_fps.barriers += ba;
				hm_fps.warWaits += wa;
				hm_fps.chained += ch;
			}
			hm_fps.draws += draws;
			hm_fps.dispatches += dispatches;
			hm_fps.copies += copies + clears;
			{
				unsigned gp = 0, tl = 0;

				hakios_metal_cb_gmem_counts(cb, &gp, &tl);
				hm_fps.gmemPasses += gp;
				hm_fps.tiles += tl;
				if (hakios_metal_cb_gmem_refusal(cb)[0] != 0) {
					strlcpy(hm_fps.gmemWhy, hakios_metal_cb_gmem_refusal(cb), sizeof(hm_fps.gmemWhy));
				}
			}
			/* (diagnostic, metal_fps=passes) every pass of one command buffer in 200 that took the GPU 4 ms or more: what a
			 * frame in motion is made of, pass by pass */
			{
				static int passesOn = -1;
				static unsigned seen;
				if (passesOn < 0) {
					/* (read where the GMEM switches are, so that the args file can turn it on without boot-arg room) */
					passesOn = strstr(hm_gmem_args(), "metal_fps=passes") != NULL;
				}
				int n = passesOn ? hakios_metal_cb_pass_time(cb, 0, NULL, NULL, NULL, NULL, NULL) : 0;
				double total = 0, us;
				unsigned kind, width, height, draws;
				for (int i = 0; i < n; i++) {
					hakios_metal_cb_pass_time(cb, (unsigned)i, &kind, &width, &height, &draws, &us);
					total += us;
				}
				if (n > 0 && total >= 4000 && seen++ % 200 == 0) {
					hm_print("passes: %d passes, %.2f ms on the GPU\n", n, total / 1e3);
					for (int i = 0; i < n; i++) {
						hakios_metal_cb_pass_time(cb, (unsigned)i, &kind, &width, &height, &draws, &us);
						unsigned attached = 0, touched = 0;
						hakios_metal_cb_pass_attachments(cb, (unsigned)i, &attached, &touched);
						hm_print("passes:   %2d kind %u %ux%u draws %u tiles %d attached %#x touched %#x %.3f ms\n", i, kind, width, height,
							 draws, hakios_metal_cb_pass_tiles(cb, (unsigned)i), attached, touched, us / 1e3);
					}
				}
			}
			/* the draws of the slowest pass over 20 ms, once a period: what a heavy frame is made of */
			/* (and with metal_fps=timeline every pass of a few draws over 8 ms, 15 of them: a few draws that cost so much
			 * are a shader's doing, not the pass's) */
			static unsigned fewShown;
			if (hm_fps_draws() && (!hm_fps.heavyShown || hm_timeline_on())) {
				unsigned slow = 0, kind, width, height, draws, slowDraws = 0;
				double slowUs = 0, us;
				int n = hakios_metal_cb_pass_time(cb, 0, NULL, NULL, NULL, NULL, NULL);

				for (int i = 0; i < n; i++) {
					hakios_metal_cb_pass_time(cb, (unsigned)i, &kind, &width, &height, &draws, &us);
					if (us > slowUs) slowUs = us, slow = (unsigned)i, slowDraws = draws;
				}
				const BOOL few = hm_timeline_on() && slowUs > 8000 && slowDraws <= 20 && fewShown < 15;
				fewShown += few ? 1 : 0;
				/* (metal_fps=mainpass: the draws of a pass of 40 draws or more over 4 ms, 6 of them -- a frame in motion's
				 * full-screen pass, which is under the 20 ms a heavy pass is shown from) */
				static int mainOn = -1;
				static unsigned mainShown;
				if (mainOn < 0) {
					char args[1024] = "";
					size_t size = sizeof(args) - 1;
					mainOn = sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "metal_fps=mainpass") != NULL;
				}
				const BOOL main = mainOn && slowUs > 4000 && slowDraws >= 40 && mainShown < 6;
				mainShown += main ? 1 : 0;
				if ((slowUs > 20000 && !hm_fps.heavyShown) || few || main) {
					hm_fps.heavyShown = YES;
					hm_print("fps: ... a heavy pass, %.1f ms%s%s; its draws:\n", slowUs / 1e3,
						 hakios_metal_cb_pass_sysmem_why(cb, slow)[0] != 0 ? ", in sysmem: " : "", hakios_metal_cb_pass_sysmem_why(cb, slow));
					for (unsigned i = 0;; i++) {
						const char *name = NULL;
						unsigned pass, area[4];
						double dus = 0;

						if (hakios_metal_cb_draw_place(cb, i, &pass, area) <= (int)i || hakios_metal_cb_draw_time(cb, i, &name, &dus) <= (int)i) {
							break;
						}
						if (pass == slow) {
							hm_print("fps: ...   %s %.0f us over %ux%u at (%u,%u)\n", name, dus, area[2] - area[0] + 1, area[3] - area[1] + 1, area[0], area[1]);
						}
					}
				}
			}
			for (unsigned i = 0; hm_fps_draws(); i++) {
				const char *name = NULL;
				double us = 0;
				int k;

				if (hakios_metal_cb_draw_time(cb, i, &name, &us) <= (int)i || name == NULL) {
					break;
				}
				for (k = 0; k < 48 && hm_fps.programs[k].name[0] != 0 && strcmp(hm_fps.programs[k].name, name) != 0; k++) {
				}
				if (k == 48) {
					continue;
				}
				if (hm_fps.programs[k].name[0] == 0) {
					strlcpy(hm_fps.programs[k].name, name, sizeof(hm_fps.programs[k].name));
				}
				hm_fps.programs[k].count++;
				hm_fps.programs[k].us += us;
			}
			/* metal_fps=timeline: a heavy buffer's every pass, the first 12 such buffers */
			static unsigned heavyListed;
			const BOOL listAll = gpu > 0.015 && heavyListed < 80 && hm_timeline_on();
			NSMutableString *all = listAll ? [NSMutableString string] : nil;

			heavyListed += listAll ? 1 : 0;
			for (unsigned i = 0;; i++) {
				unsigned kind, width, height, draws;
				double us;

				if (hakios_metal_cb_pass_time(cb, i, &kind, &width, &height, &draws, &us) <= (int)i) {
					if (all != nil) hm_print("timeline: a buffer of %.1f ms on the GPU:%s\n", gpu * 1e3, [all UTF8String]);
					break;
				}
				if (all != nil) {
					unsigned attached = 0, touched = 0;
					hakios_metal_cb_pass_attachments(cb, i, &attached, &touched);
					const char *sysWhy = hakios_metal_cb_pass_sysmem_why(cb, i);

					[all appendFormat:@" [%u %ux%u %u draws%@ %.2f ms]", kind, width, height, draws,
							  hakios_metal_cb_pass_tiles(cb, i) > 0 ? [NSString stringWithFormat:@" %d tiles (attachments %#x, touched %#x)",
														      hakios_metal_cb_pass_tiles(cb, i), attached, touched] :
							  kind == 0 && sysWhy[0] != 0 ? [NSString stringWithFormat:@" in sysmem: %s", sysWhy] : @"",
							  us / 1e3];
				}
				hm_fps.passUs += us;
				for (int k = 0; k < 4; k++) {
					if (us > hm_fps.slowest[k].us) {
						memmove(&hm_fps.slowest[k + 1], &hm_fps.slowest[k], (size_t)(3 - k) * sizeof(hm_fps.slowest[0]));
						hm_fps.slowest[k].kind = kind;
						hm_fps.slowest[k].width = width;
						hm_fps.slowest[k].height = height;
						hm_fps.slowest[k].draws = draws;
						hm_fps.slowest[k].tiles = (unsigned)MAX(hakios_metal_cb_pass_tiles(cb, i), 0);
						strlcpy(hm_fps.slowest[k].why, hakios_metal_cb_pass_sysmem_why(cb, i), sizeof(hm_fps.slowest[k].why));
						hm_fps.slowest[k].us = us;
						break;
					}
				}
			}
		}
	}
	if (now - hm_fps.since >= 2.0) {
		const double span = now - hm_fps.since;

		const double per = hm_fps.buffers ? (double)hm_fps.buffers : 1.0;
		uint64_t panelNow = 0, presented = hm_fps.presents;
		const BOOL havePanel = hm_panel_presents(&panelNow);
		const BOOL usePanel = havePanel && panelValid && panelNow >= panelLast;
		if (usePanel) presented = panelNow - panelLast;
		panelLast = panelNow;
		panelValid = havePanel;

		hm_print("fps: %.1f frames/s over %.1f s (%llu presented via %s, %u drawable presents, %u command buffers); commit-to-fence wall %.0f ms (%.0f%% of window, not GPU occupancy), -commit on the "
			 "caller's thread %.0f ms, commit to completion %.1f ms on average, %.1f at most; a buffer holds %.1f passes "
			 "(%.1f full flushes with a wait for idle, %.1f barriers, %.1f WAR waits, %.1f chained%s), %.1f draws, %.1f dispatches, "
			 "%.1f copies or clears; %.1f passes in GMEM (%.1f tiles)\n",
			 presented / span, span, (unsigned long long)presented,
			 usePanel ? "panel" : "command-buffer presentDrawable only (panel count unavailable)", hm_fps.presents, hm_fps.buffers,
			 hm_fps.gpu * 1e3, 100.0 * hm_fps.gpu / span,
			 hm_fps.commit * 1e3, hm_fps.buffers ? hm_fps.latency * 1e3 / hm_fps.buffers : 0.0, hm_fps.latencyMax * 1e3,
			 hm_fps.passes / per, hm_fps.flushes / per, hm_fps.barriers / per, hm_fps.warWaits / per, hm_fps.chained / per,
			 hm_pass_wfi() ? ", metal_pass_wfi=1" : "", hm_fps.draws / per, hm_fps.dispatches / per, hm_fps.copies / per,
			 hm_fps.gmemPasses / per, hm_fps.tiles / per);
		hm_drawables_report();
		hm_refusal_report();   /* the period's refused draws, counted: the lines themselves are deduplicated */
		if (hm_handoff_on()) {
			/* every handoff probe of the period, in one line: per-frame and per-texture
			 * events are counted, never printed one by one */
			hm_print("handoff: cb=%u encode=%u/%u submit=%u/%u fence=%u/%u visible=%u shadow=%u/%u pass-attach=%u "
				 "imports=%u/%u/%u cpu=%u/%u waits=%u notes=%u/%u/%u tx=%u/%u/%u signals=%u pool=%u "
				 "drawable=%u/%u/%u/%u/%u/%u/%u/%u/%u/%u\n",
				 hm_diag_take(&hm_diag.cb), hm_diag_take(&hm_diag.encodeReads), hm_diag_take(&hm_diag.encodeWrites),
				 hm_diag_take(&hm_diag.submitReads), hm_diag_take(&hm_diag.submitWrites),
				 hm_diag_take(&hm_diag.fenceReads), hm_diag_take(&hm_diag.fenceWrites), hm_diag_take(&hm_diag.visibleWrites),
				 hm_diag_take(&hm_diag.shadowQueued), hm_diag_take(&hm_diag.shadowPublished),
				 hm_diag_take(&hm_diag.passAttachments),
				 hm_diag_take(&hm_diag.imports), hm_diag_take(&hm_diag.planeImports), hm_diag_take(&hm_diag.shadowImports),
				 hm_diag_take(&hm_diag.cpuWrites), hm_diag_take(&hm_diag.cpuReads), hm_diag_take(&hm_diag.textureWaits),
				 hm_diag_take(&hm_diag.contentsChanges), hm_diag_take(&hm_diag.dirtyMarks), hm_diag_take(&hm_diag.appearanceChanges),
				 hm_diag_take(&hm_diag.txBegin), hm_diag_take(&hm_diag.txCommit), hm_diag_take(&hm_diag.txFlush),
				 hm_diag_take(&hm_diag.signals), hm_diag_take(&hm_diag.poolReuses),
				 hm_diag_take(&hm_diag.steps[0]), hm_diag_take(&hm_diag.steps[1]), hm_diag_take(&hm_diag.steps[2]),
				 hm_diag_take(&hm_diag.steps[3]), hm_diag_take(&hm_diag.steps[4]), hm_diag_take(&hm_diag.steps[5]),
				 hm_diag_take(&hm_diag.steps[6]), hm_diag_take(&hm_diag.steps[7]), hm_diag_take(&hm_diag.steps[8]),
				 hm_diag_take(&hm_diag.steps[9]));
		}
		hm_print("texture-completion: calls=%u wall=%.1f ms max=%.1f ms; shadow-blit: sources=%u destinations=%u\n",
		         hm_handoff.textureCalls, hm_handoff.textureWall * 1e3, hm_handoff.textureMax * 1e3,
		         hm_handoff.blitSources, hm_handoff.blitDestinations);
		memset(&hm_handoff, 0, sizeof(hm_handoff));
		if (hm_fps.gapsOnTime + hm_fps.gapsLate + hm_fps.gapsStall != 0) {
			hm_print("fps: ... gaps between commits (includes idle updates): %u <=20 ms, %u 20..50 ms, "
				 "%u >50 ms; a buffer made to committed %.1f ms on average, %.1f at most; %u held for an event; "
				 "%u waits for completion, %.0f ms in them; %u draw calls, %.0f us of ours each (%.0f of them the core's)\n",
				 hm_fps.gapsOnTime, hm_fps.gapsLate, hm_fps.gapsStall, hm_fps.encode * 1e3 / per, hm_fps.encodeMax * 1e3, hm_fps.held,
				 hm_fps.waits, hm_fps.waited * 1e3, hm_fps.drawCalls, hm_fps.drawCalls ? hm_fps.drawCpu * 1e6 / hm_fps.drawCalls : 0.0,
				 hm_fps.drawCalls ? hm_fps.coreCpu * 1e6 / hm_fps.drawCalls : 0.0);
		}
		if (hm_sampling()) hm_sample_report();
		{
			static const char *names[HM_PERF_COUNT] = {
				"newBo", "new-ioctl", "iova", "map", "pool-hit", "pool-miss",
				"closePass", "commandBo", "upload", "queue-lock", "fault-query", "Gpu-submit",
				"queue-submit", "bo-list", "submit-ioctl", "turn", "events", "commit-core", "sync",
				"scheduled", "commit-total", "render-pipeline", "compute-pipeline", "cb-slot"
			};
			hm_perf_stat p[HM_PERF_COUNT];
			hakios_metal_perf_take(p);
			for (unsigned i = 0; i < HM_PERF_COUNT; i += 4) {
				char line[900] = ""; size_t used = 0;
				for (unsigned j = i; j < MIN(i + 4, HM_PERF_COUNT); ++j) {
					if (!p[j].count) continue;
					used += (size_t)snprintf(line + used, sizeof(line) - used, " %s=%llu/%.1f/%.1f/%.1f/%llu", names[j],
					    (unsigned long long)p[j].count, p[j].wall / 1e6, p[j].cpu / 1e6, p[j].max / 1e6,
					    (unsigned long long)(p[j].bytes >> 10));
				}
				if (used) hm_print("fps: perf count/wall-ms/cpu-ms/max-ms/KB:%s\n", line);
			}
		}
		{
			hakios_metal_stage_cache_stats s;
			hakios_metal_stage_cache_take_stats(&s);
			hm_print("fps: ... stage-cache: %llu disk hits, %llu seed hits, %llu compiled (%llu failed); "
				 "lookup %.1f ms, compiler wait %.1f ms, compile %.1f ms (max %.1f); %llu saved, %llu save failures\n",
				 (unsigned long long)s.hits, (unsigned long long)s.seed_hits, (unsigned long long)s.misses,
				 (unsigned long long)s.failures, s.lookup_ns / 1e6, s.wait_ns / 1e6, s.compile_ns / 1e6, s.compile_max_ns / 1e6,
				 (unsigned long long)s.writes, (unsigned long long)s.write_failures);
			hm_print("pipeline-queue: foreground-wait-ms=%.1f queue-depth=%llu queue-peak=%llu prewarm-hits=%llu "
			         "prewarm-loaded=%llu prewarm-compiles=%llu prewarm-failures=%llu recipe-write-failures=%llu "
			         "recipes-written=%llu recipes-skipped=%llu\n",
			         s.foreground_wait_ns / 1e6, (unsigned long long)s.queue_depth, (unsigned long long)s.queue_peak,
			         (unsigned long long)s.prewarm_hits, (unsigned long long)s.prewarm_loaded,
			         (unsigned long long)s.prewarm_compiles, (unsigned long long)s.prewarm_failures,
			         (unsigned long long)s.warm_write_failures, (unsigned long long)s.warm_writes,
			         (unsigned long long)s.warm_write_skips);
		}
		if (hm_timeline_on() && hm_fps.sampledBytes[0] + hm_fps.sampledBytes[1] + hm_fps.sampledBytes[2] + hm_fps.sampledBytes[3] + hm_fps.sampledBytes[4] +
		    hm_fps.sampledBytes[5] > 0) {
			hm_print("fps: ... textures bound to draws (MB, by their size): surfaces %.0f, shared %.0f, over buffers %.0f, private %.0f, memoryless %.0f, "
				 "compressed %.0f\n",
				 hm_fps.sampledBytes[0] / 1e6, hm_fps.sampledBytes[1] / 1e6, hm_fps.sampledBytes[2] / 1e6, hm_fps.sampledBytes[3] / 1e6,
				 hm_fps.sampledBytes[4] / 1e6, hm_fps.sampledBytes[5] / 1e6);
			memset(hm_fps.sampledBytes, 0, sizeof(hm_fps.sampledBytes));
			for (unsigned k = 0; k < 16 && hm_fps.bySize[k].bytes != 0; k++) {
				hm_print("fps: ... sampled: %ux%u origin %u: %.0f MB\n", hm_fps.bySize[k].w, hm_fps.bySize[k].h, hm_fps.bySize[k].origin,
					 hm_fps.bySize[k].bytes / 1e6);
			}
			memset(hm_fps.bySize, 0, sizeof(hm_fps.bySize));
		}
		{
			unsigned made, reused, attachments;
			unsigned long long bytes, attachmentBytes;

			hakios_metal_buffer_counts(&made, &reused, &bytes);
			hakios_metal_attachment_counts(&attachments, &attachmentBytes);
			hm_print("fps: ... logical buffer requests: %u (%llu KB), %u queue-pool reuses; %u attachment requests "
				 "(%llu KB, includes BO-cache hits; not live memory); actual BO allocations/reuses in bo-cache\n",
				 made, bytes >> 10, reused, attachments, attachmentBytes >> 10);
			{
				unsigned longest, cut;

				hakios_metal_stream_counts(&longest, &cut);
				hm_print("fps: ... command streams: the longest %u words, %u cut into pieces of at most 0xfffff words\n", longest, cut);
			}
		}
		if (hm_fps.drawCalls != 0) {
			char by[200] = "";
			size_t at = 0;

			for (unsigned c = 0; c < 8; c++) {
				if (hm_fps.drawsOn[c] != 0 && at < sizeof(by)) {
					at += (size_t)snprintf(by + at, sizeof(by) - at, " cpu%u %u at %.0f us", c, hm_fps.drawsOn[c], hm_fps.drawUsOn[c] / hm_fps.drawsOn[c]);
				}
			}
			hm_print("fps: ... draw calls by processor:%s (TPIDR_EL0 %#llx)\n", by, (unsigned long long)hm_fps.lastTpidr);
			memset(hm_fps.drawsOn, 0, sizeof(hm_fps.drawsOn));
			memset(hm_fps.drawUsOn, 0, sizeof(hm_fps.drawUsOn));
		}
		if (hm_fps.slowest[0].us > 0) {
			static const char *const kinds[] = {"draw", "copy", "clear", "dispatch"};
			char line[1024];
			size_t n = 0;

			for (int k = 0; k < 4 && hm_fps.slowest[k].us > 0 && n < sizeof(line) - 1; k++) {
				char tiles[128] = "";

				if (hm_fps.slowest[k].tiles != 0) {
					snprintf(tiles, sizeof(tiles), " in %u tiles", hm_fps.slowest[k].tiles);
				} else if (hm_fps.slowest[k].kind == 0 && hm_fps.slowest[k].why[0] != 0) {
					/* (why it stayed in sysmem: SpringBoard's "home" pass, 1127x2438 and 33 draws, did with no reason seen) */
					snprintf(tiles, sizeof(tiles), " in sysmem (%s)", hm_fps.slowest[k].why);
				}
				n += (size_t)snprintf(line + n, sizeof(line) - n, "%s %s %ux%u%s%u%s %.2f ms", k ? ";" : "",
						      kinds[hm_fps.slowest[k].kind & 3], hm_fps.slowest[k].width, hm_fps.slowest[k].height,
						      hm_fps.slowest[k].kind == 0 ? " draws " : " ", hm_fps.slowest[k].kind == 0 ? hm_fps.slowest[k].draws : 0,
						      tiles, hm_fps.slowest[k].us / 1e3);
				n = MIN(n, sizeof(line) - 1);   /* (snprintf says what it would have written: never past the line) */
			}
			hm_print("fps: ... passes timed by the GPU: %.0f ms in all; the slowest:%s\n", hm_fps.passUs / 1e3, line);
		}
		for (int shown = 0; shown < 8; shown++) {
			int best = -1;

			for (int k = 0; k < 48 && hm_fps.programs[k].name[0] != 0; k++) {
				if (hm_fps.programs[k].count != 0 && (best < 0 || hm_fps.programs[k].us > hm_fps.programs[best].us)) {
					best = k;
				}
			}
			if (best < 0) {
				break;
			}
			hm_print("fps: ... draws of %s: %u, %.2f ms on the GPU (%.0f us each)\n", hm_fps.programs[best].name,
				 hm_fps.programs[best].count, hm_fps.programs[best].us / 1e3, hm_fps.programs[best].us / hm_fps.programs[best].count);
			hm_fps.programs[best].count = 0;
		}
		memset(hm_fps.programs, 0, sizeof(hm_fps.programs));
		hm_fps.heavyShown = NO;
		if (hm_fps.gmemWhy[0] != 0) {
			hm_print("fps: ... a pass left in sysmem: %s\n", hm_fps.gmemWhy);
			hm_fps.gmemWhy[0] = 0;
		}
		memset(hm_fps.slowest, 0, sizeof(hm_fps.slowest));
		hm_fps.passUs = 0;
		if (hm_fps.shadowIns + hm_fps.shadowOuts != 0) {
			hm_print("fps: ... surface copies on the processor: %u taken from their surfaces in %.0f ms, %u written back in %.0f ms; "
				 "YCbCr frames: %u converted\n",
				 hm_fps.shadowIns, hm_fps.shadowIn * 1e3, hm_fps.shadowOuts, hm_fps.shadowOut * 1e3, hm_fps.ycbcrFrames);
		}
		if (hm_fps.shadowKeptWrites + hm_fps.shadowKeptTorn != 0) {
			hm_print("fps: ... shadow refreshes kept back: %u with GPU writes not yet written back, %u for a surface written under the copy\n",
				 hm_fps.shadowKeptWrites, hm_fps.shadowKeptTorn);
			hm_fps.shadowKeptWrites = hm_fps.shadowKeptTorn = 0;
		}
		if (hm_fps.shadowSamplePending + hm_fps.shadowSampleWaits + hm_fps.shadowSampleTimeouts != 0) {
			hm_print("fps: ... shadow-sampled pending=%u waited=%u timeouts=%u\n", hm_fps.shadowSamplePending,
				 hm_fps.shadowSampleWaits, hm_fps.shadowSampleTimeouts);
			hm_fps.shadowSamplePending = hm_fps.shadowSampleWaits = hm_fps.shadowSampleTimeouts = 0;
		}
		if (hm_ycbcrAttempts != 0) {
			hm_print("fps: ... YCbCr conversion wall time: %u attempts, %.1f ms total (%.2f ms each)\n", hm_ycbcrAttempts, hm_ycbcrCpu * 1e3,
				 hm_ycbcrCpu * 1e3 / hm_ycbcrAttempts);
			hm_ycbcrAttempts = 0;
			hm_ycbcrCpu = 0;
		}
		if (hm_ycbcrGPUCount != 0) {
			hm_print("fps: ... YCbCr GPU path: %u conversions, %.1f ms total (%.2f ms each)\n", hm_ycbcrGPUCount,
				 hm_ycbcrGPUTime * 1e3, hm_ycbcrGPUTime * 1e3 / hm_ycbcrGPUCount);
			hm_ycbcrGPUCount = 0;
			hm_ycbcrGPUTime = 0;
		}
		hm_fps.ycbcrFrames = 0;
		hm_fps.passes = hm_fps.draws = hm_fps.dispatches = hm_fps.copies = hm_fps.gmemPasses = hm_fps.tiles = 0;
		hm_fps.flushes = hm_fps.barriers = hm_fps.warWaits = hm_fps.chained = 0;
		hm_fps.shadowIn = hm_fps.shadowOut = 0;
		hm_fps.shadowIns = hm_fps.shadowOuts = 0;
		hm_fps.since = now;
		hm_fps.presents = hm_fps.buffers = 0;
		hm_fps.gpu = hm_fps.commit = hm_fps.latency = hm_fps.latencyMax = 0;
		hm_fps.gapsOnTime = hm_fps.gapsLate = hm_fps.gapsStall = hm_fps.held = 0;
		hm_fps.encode = hm_fps.encodeMax = hm_fps.waited = 0;
		hm_fps.waits = hm_fps.drawCalls = 0;
		hm_fps.drawCpu = hm_fps.coreCpu = 0;
	}
	pthread_mutex_unlock(&hm_fps.lock);
}

static void
hm_fps_ycbcr(void)
{
	if (!hm_fps_on()) return;
	pthread_mutex_lock(&hm_fps.lock);
	hm_fps.ycbcrFrames++;
	pthread_mutex_unlock(&hm_fps.lock);
}

static void
hm_fps_ycbcr_time(double seconds)
{
	if (!hm_fps_on()) {
		return;
	}
	pthread_mutex_lock(&hm_fps.lock);
	hm_ycbcrAttempts++;
	hm_ycbcrCpu += seconds;
	pthread_mutex_unlock(&hm_fps.lock);
}

static void
hm_fps_ycbcr_gpu(double seconds)
{
	if (!hm_fps_on()) return;
	pthread_mutex_lock(&hm_fps.lock);
	hm_ycbcrGPUCount++;
	hm_ycbcrGPUTime += seconds;
	hm_ycbcrSummaryGPUCount++;
	hm_ycbcrSummaryGPUTime += seconds;
	const double now = hm_now();
	if (hm_ycbcrSummarySince == 0) hm_ycbcrSummarySince = now;
	if (now - hm_ycbcrSummarySince >= 1.0) {
		hm_print("ycbcr: GPU conversions %u, %.1f ms\n", hm_ycbcrSummaryGPUCount,
				hm_ycbcrSummaryGPUTime * 1e3);
		hm_ycbcrSummaryGPUCount = 0;
		hm_ycbcrSummaryGPUTime = 0;
		hm_ycbcrSummarySince = now;
	}
	pthread_mutex_unlock(&hm_fps.lock);
}

/* time spent copying a surface's rows into its copy (IN) or back (OUT) */
static void
hm_fps_shadow(BOOL in, double seconds)
{
	if (!hm_fps_on()) {
		return;
	}
	pthread_mutex_lock(&hm_fps.lock);
	if (in) {
		hm_fps.shadowIn += seconds;
		hm_fps.shadowIns++;
	} else {
		hm_fps.shadowOut += seconds;
		hm_fps.shadowOuts++;
	}
	pthread_mutex_unlock(&hm_fps.lock);
}

/* a refresh that took no copy: the copy has GPU writes not yet written back (NO), or a writer moved the surface's
 * seed under the copy (YES) -- see -[HakiosMetalTexture hakiosRefreshShadow] */
static void
hm_fps_shadow_kept(BOOL torn)
{
	if (!hm_fps_on()) {
		return;
	}
	pthread_mutex_lock(&hm_fps.lock);
	if (torn) {
		hm_fps.shadowKeptTorn++;
	} else {
		hm_fps.shadowKeptWrites++;
	}
	pthread_mutex_unlock(&hm_fps.lock);
}

/* a sample of a shadow copy found GPU writes into its surface still queued: PENDING such samples, WAITED of them
 * drained before the write-back (and their copies taken again), TIMEOUTS that ran out -- see
 * -[HakiosMetalCommandBuffer hakiosShadowSampleSync] */
static void
hm_fps_shadow_sample(unsigned pending, unsigned waited, unsigned timeouts)
{
	if (!hm_fps_on()) {
		return;
	}
	pthread_mutex_lock(&hm_fps.lock);
	hm_fps.shadowSamplePending += pending;
	hm_fps.shadowSampleWaits += waited;
	hm_fps.shadowSampleTimeouts += timeouts;
	pthread_mutex_unlock(&hm_fps.lock);
}

/*
 * boot-arg metal_fps=sample (a diagnostic): where a draw call's time goes on this phone, sampled. A thread of its own
 * stops the thread that is inside a draw call every 200 us, reads its program counter and lets it go on; the counts by
 * function (dladdr) are printed with metal_fps's lines. The host's run of the same encoding takes 5 us a draw where
 * this phone took 40 on a fast core, so the difference is something the host does not show.
 */
static volatile mach_port_t hm_sample_thread;   /* the thread inside a draw call, or 0 */
static uint64_t hm_samples[16384], hm_samplesBy[16384], hm_samplesBy2[16384];   /* the PC, and the first caller outside the system's libraries */
static volatile unsigned hm_sampled;

static BOOL
hm_sampling(void)
{
	static int on = -1;

	if (on < 0) {
		char args[1024] = {0};
		size_t size = sizeof(args) - 1;

		on = sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "metal_fps=sample") != NULL;
	}
	return on != 0;
}

static void *
hm_sampler(void *unused)
{
	(void)unused;
	for (;;) {
		usleep(200);
		const mach_port_t t = hm_sample_thread;
		if (t == 0 || hm_sampled >= sizeof(hm_samples) / sizeof(hm_samples[0])) continue;
		if (thread_suspend(t) != KERN_SUCCESS) continue;
		arm_thread_state64_t st;
		mach_msg_type_number_t n = ARM_THREAD_STATE64_COUNT;
		if (thread_get_state(t, ARM_THREAD_STATE64, (thread_state_t)&st, &n) == KERN_SUCCESS && hm_sample_thread == t) {
			/* (the frame chain, for the first return address in this plug-in: who called into the system) */
			static uintptr_t lo, hi;
			if (hi == 0) {
				Dl_info me;
				if (dladdr((const void *)hm_sampler, &me)) lo = (uintptr_t)me.dli_fbase, hi = lo + (64u << 20);
			}
			uint64_t by = 0, by2 = 0, fp = __darwin_arm_thread_state64_get_fp(st), lr = __darwin_arm_thread_state64_get_lr(st);
			if (lr >= lo && lr < hi) by = lr;
			for (int d = 0; d < 24 && by2 == 0 && fp != 0 && (fp & 7) == 0; d++) {
				const uint64_t *f = (const uint64_t *)fp;
				const uint64_t ret = f[1] & 0x0000007fffffffffull;
				if (ret >= lo && ret < hi && ret != by) {
					if (by == 0) by = ret;
					else by2 = ret;
				}
				fp = f[0];
			}
			hm_samplesBy[hm_sampled] = by;
			hm_samplesBy2[hm_sampled] = by2;
			hm_samples[hm_sampled++] = __darwin_arm_thread_state64_get_pc(st);
		}
		thread_resume(t);
	}
	return NULL;
}

/* the samples so far by function, the 12 most, into the log; then from nothing again */
static void
hm_sample_report(void)
{
	static struct { const char *name; unsigned count; } by[256];
	unsigned kinds = 0, total = hm_sampled;

	if (total == 0) return;
	for (unsigned i = 0; i < total; i++) {
		Dl_info info;
		const char *name = dladdr((const void *)hm_samples[i], &info) && info.dli_sname ? info.dli_sname : "?";
		/* (in the system's code: named by the caller of ours it was reached from) */
		static char named[256][160];
		Dl_info caller;
		if (hm_samplesBy[i] != 0 && (strcmp(name, "<redacted>") == 0 || strncmp(name, "mach_", 5) == 0 || strncmp(name, "_kernelrpc", 10) == 0) &&
		    dladdr((const void *)hm_samplesBy[i], &caller) && caller.dli_sname) {
			char buf[160];
			Dl_info caller2;
			const char *n2 = hm_samplesBy2[i] != 0 && dladdr((const void *)hm_samplesBy2[i], &caller2) && caller2.dli_sname ? caller2.dli_sname : "";
			snprintf(buf, sizeof(buf), "%.24s <- %.60s <- %.60s", name, caller.dli_sname, n2);
			unsigned k = 0;
			while (k < 256 && named[k][0] != 0 && strcmp(named[k], buf) != 0) k++;
			if (k < 256) {
				if (named[k][0] == 0) strlcpy(named[k], buf, sizeof(named[k]));
				name = named[k];
			}
		}
		unsigned k = 0;
		while (k < kinds && by[k].name != name && strcmp(by[k].name, name) != 0) k++;
		if (k == kinds) {
			if (kinds == 256) continue;
			by[kinds].name = name, by[kinds].count = 0, kinds++;
		}
		by[k].count++;
	}
	for (unsigned r = 0; r < 12 && r < kinds; r++) {
		unsigned best = r;
		for (unsigned k = r + 1; k < kinds; k++) if (by[k].count > by[best].count) best = k;
		const typeof(by[0]) t = by[r]; by[r] = by[best]; by[best] = t;
		hm_print("fps: ... sampled in draw calls: %4.1f%% %s\n", 100.0 * by[r].count / total, by[r].name);
	}
	hm_sampled = 0;
}

/* the driver's own time in a draw call (the plug-in's and the core's encoding), of the caller's thread */
static void
hm_fps_drew(double seconds, unsigned cpu)
{
	pthread_mutex_lock(&hm_fps.lock);
	hm_fps.drawCpu += seconds;
	hm_fps.drawCalls++;
	if (cpu < 8) {
		hm_fps.drawsOn[cpu]++;
		hm_fps.drawUsOn[cpu] += seconds * 1e6;
	}
	pthread_mutex_unlock(&hm_fps.lock);
}

/* ...and of that, the core's (hakios_metal_cb_draw*) */
static void
hm_fps_core(double seconds)
{
	pthread_mutex_lock(&hm_fps.lock);
	hm_fps.coreCpu += seconds;
	pthread_mutex_unlock(&hm_fps.lock);
}

/* Separate from CB waits: QuartzCore finish_image and the CA surface handoff
 * wait through the resource SPI. Wall includes dependency/lock work, not GPU occupancy. */
static void hm_fps_texture_waited(double seconds)
{
    pthread_mutex_lock(&hm_fps.lock);
    hm_handoff.textureCalls++;
    hm_handoff.textureWall += seconds;
    hm_handoff.textureMax = MAX(hm_handoff.textureMax, seconds);
    pthread_mutex_unlock(&hm_fps.lock);
}

static void hm_fps_shadow_blit(BOOL write)
{
    if (!hm_fps_on()) return;
    pthread_mutex_lock(&hm_fps.lock);
    if (write) hm_handoff.blitDestinations++;
    else hm_handoff.blitSources++;
    pthread_mutex_unlock(&hm_fps.lock);
}

/* time a client spent in -waitUntilCompleted: a renderer that waits there cannot draw its next frame meanwhile */
static void
hm_fps_waited(double seconds)
{
	if (!hm_fps_on()) {
		return;
	}
	pthread_mutex_lock(&hm_fps.lock);
	hm_fps.waited += seconds;
	hm_fps.waits++;
	pthread_mutex_unlock(&hm_fps.lock);
}

/* a command buffer's life from its making to -commit (the client's encoding, ours included), and whether it was held
 * for an event it waits on */
static void
hm_fps_encoded(double seconds, BOOL held)
{
	if (!hm_fps_on()) {
		return;
	}
	pthread_mutex_lock(&hm_fps.lock);
	hm_fps.encode += seconds;
	if (seconds > hm_fps.encodeMax) hm_fps.encodeMax = seconds;
	hm_fps.held += held ? 1 : 0;
	pthread_mutex_unlock(&hm_fps.lock);
}

static void
hm_fps_commit(double seconds)
{
	if (!hm_fps_on()) {
		return;
	}
	pthread_mutex_lock(&hm_fps.lock);
	hm_fps.commit += seconds;
	{
		const double now = hm_now(), gap = now - hm_fps.lastCommit;

		if (hm_fps.lastCommit != 0 && gap < 0.25) {
			if (gap <= 0.020) hm_fps.gapsOnTime++;
			else if (gap <= 0.050) hm_fps.gapsLate++;
			else hm_fps.gapsStall++;
		}
		hm_fps.lastCommit = now;
	}
	pthread_mutex_unlock(&hm_fps.lock);
}

/* boot-arg metal_fps=timeline (a diagnostic): each command buffer of the first 400 after the 30th second, as when it was
 * made, committed and completed (ms of this process's clock) and what the GPU spent on it -- where a frame's time goes
 * between the client, the driver and the GPU */
static BOOL
hm_timeline_on(void)
{
	static int on = -1;

	if (on < 0) {
		char args[1024] = {0};
		size_t size = sizeof(args) - 1;

		on = sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "metal_fps=timeline") != NULL;
	}
	return on != 0;
}

static void
hm_timeline(double created, double committed, double completed, double gpu)
{
	static unsigned printed;
	static double first;

	if (first == 0) first = hm_now();
	if (!hm_timeline_on() || created - first < 30.0 || printed >= 400) return;
	printed++;
	hm_print("timeline: made %.1f committed %.1f done %.1f gpu %.2f\n", created * 1e3, committed * 1e3, completed * 1e3, gpu * 1e3);
}

static void
hm_completed(hakios_metal_cb *cb, void *context)
{
	HakiosMetalCommandBuffer *self = (HakiosMetalCommandBuffer *)context;

	hm_timeline([self hakiosCreatedAt], [self GPUStartTime], hm_now(), (double)hakios_metal_cb_gpu_nanoseconds(cb) / 1e9);
	{
		/* (hakios) boot-arg touch_lat=1: "tl: M made US committed US done US gpu US" of every command buffer, in
		 * the microseconds of mach_absolute_time the other "tl:" lines use (the display's tl: v and tl: y beside it) */
		static int lines = -1;

		if (lines < 0) {
			char args[1024] = "";
			size_t size = sizeof(args) - 1;

			lines = sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "touch_lat=1") != NULL;
		}
		if (lines) {
			fprintf(stderr, "tl: M made %.0f committed %.0f done %.0f gpu %.0f\n", [self hakiosCreatedAt] * 1e6,
				[self GPUStartTime] * 1e6, hm_now() * 1e6, (double)hakios_metal_cb_gpu_nanoseconds(cb) / 1e3);
		}
	}
	hm_fps_note(NO, (double)hakios_metal_cb_gpu_nanoseconds(cb) / 1e9, hm_now() - [self GPUStartTime], cb);
	/* every program's, not only those that log a command buffer's error themselves (CoreAnimation does, Impeller
	 * does not): which program's work a GPU reset gave up -- the one the GPU hung on -- or any other that ended so */
	if (hakios_metal_cb_status(cb) == HAKIOS_METAL_ERROR) {
		hm_print("command buffer '%s' ended in error: %s\n", [[self label] UTF8String] ?: "", hakios_metal_cb_error(cb));
	}
	[self hakiosCheckReads:YES];
	/* hakios-metal's queue thread has no autorelease pool of its own, and the NSError built here and whatever a
	 * handler autoreleases would otherwise leak, silently, once per command buffer */
	@autoreleasepool {
		[self hakiosCompletedNow];
	}
	[self release];
}

- (void)hakiosTurnAtCommit:(id)texture
{
	if (_turned == nil) _turned = [[NSMutableArray alloc] init];
	if (![_turned containsObject:texture]) [_turned addObject:texture];
}

- (void)hakiosNoteRead:(IOSurfaceRef)surface
{
	@synchronized (self) {   /* (a parallel encoder's sub-encoders draw on several threads) */
		for (unsigned i = 0; i < _readCount; i++) {
			if (_reads[i] == surface) return;
		}
		if (_readCount < 8) {
			_reads[_readCount] = (IOSurfaceRef)CFRetain(surface);
			_readSeeds[_readCount++] = IOSurfaceGetSeed(surface);
		}
	}
}

/* flicker-diag: at the send (done NO), a writer inside its lock of a surface this buffer samples; at completion (done
 * YES), a seed that moved between the send and the end of the GPU's work: the surface written while it was read */
- (void)hakiosCheckReads:(BOOL)done
{
	static unsigned inside, moved;

	for (unsigned i = 0; i < _readCount; i++) {
		IOSurfaceRef s = _reads[i];
		const uint32_t seed = IOSurfaceGetSeed(s);

		if (!done) {
			if ((seed & 1) == 0 && hm_flicker_say(&inside)) {
				hm_print("flicker-diag: IOSurface %u (%zux%zu, %zu bytes a row) sent to the GPU to be sampled while a writer holds it "
					 "(seed %u, %u when sampled); in use %d; %u such\n", IOSurfaceGetID(s), IOSurfaceGetWidth(s), IOSurfaceGetHeight(s),
					 IOSurfaceGetBytesPerRow(s), seed, _readSeeds[i], hm_surface_in_use(s), inside);
			}
			_readSeeds[i] = seed;
			continue;
		}
		if (seed != _readSeeds[i] && hm_flicker_say(&moved)) {
			hm_print("flicker-diag: IOSurface %u (%zux%zu, %zu bytes a row) written while the GPU sampled it: seed %u when sent, %u at "
				 "completion %.1f ms later; in use %d; %u such\n", IOSurfaceGetID(s), IOSurfaceGetWidth(s), IOSurfaceGetHeight(s),
				 IOSurfaceGetBytesPerRow(s), _readSeeds[i], seed, (hm_now() - _sentAt) * 1e3, hm_surface_in_use(s), moved);
		}
		CFRelease(s);
	}
	if (done) _readCount = 0;
}

- (BOOL)hakiosReadyToSubmit { return _readyToSubmit; }   /* under the queue's lock */
- (void)hakiosMarkReady { _readyToSubmit = YES; }
- (BOOL)hakiosWaits { return [_waits count] != 0; }

- (void)commit
{
	if (_committed) {
		HM_ONCE("a command buffer was committed twice; Metal asserts on that, this plug-in does nothing the second time\n");
		return;
	}
	const double beganAt = hm_now();
	hm_perf_mark began = hm_perf_begin();
	[self enqueue];
	_committed = YES;
	_committedAt = hm_now();
	/* Finish recording before publishing readiness to the queue. */
	hm_perf_mark phase = hm_perf_begin();
	for (HakiosMetalTexture *t in _turned) [t hakiosTurnInto:_cb];
	hm_perf_end(HM_PERF_TURN, phase, 0);
	hm_fps_encoded(_committedAt - _createdAt, [_waits count] != 0);
	[self retain];   /* hm_completed releases the flight reference, even for a synchronous error */
	hm_use_set(_useSeq, HM_USE_COMMITTED);   /* before the queue can complete it */
	[_queue hakiosCommit:self];
	hm_fps_commit(hm_now() - beganAt);
	hm_perf_end(HM_PERF_COMMIT, began, 0);
}

/* Only the queue's committed prefix gets here, serially, in enqueue order. Event waits hold later submissions too. */
- (void)hakiosSubmit
{
	hm_perf_mark phase = hm_perf_begin();
	for (NSArray *w in _waits) {
		[[w objectAtIndex:0] hakiosWaitFor:[[w objectAtIndex:1] unsignedLongLongValue]];
	}
	hm_perf_end(HM_PERF_EVENTS, phase, 0);
	[self hakiosSend];
	[self hakiosSent];
}

- (unsigned)hakiosDrainReason
{
    const unsigned reason = __atomic_load_n(&_drainReason, __ATOMIC_ACQUIRE);
    return reason ? reason - 1 : hm_ca_sync() ? HAKIOS_METAL_DRAIN_CPU_SYNC : HAKIOS_METAL_DRAIN_IDLE;
}

- (void)hakiosRequireSync:(unsigned)reason
{
    if (reason == HAKIOS_METAL_DRAIN_SURFACE) {
        __atomic_store_n(&_drainReason, reason + 1, __ATOMIC_RELEASE);
    } else {
        unsigned expected = 0;
        __atomic_compare_exchange_n(&_drainReason, &expected, reason + 1, false, __ATOMIC_RELEASE, __ATOMIC_RELAXED);
    }
    if (_committed) [_queue hakiosDrain:reason];
}

- (void)hakiosPrepareSend
{
	if (hm_handoff_on()) {
		__atomic_fetch_add(&hm_diag.submitReads, (unsigned)[_probeReads count], __ATOMIC_RELAXED);
		__atomic_fetch_add(&hm_diag.submitWrites, (unsigned)[_probeWrites count], __ATOMIC_RELAXED);
	}
	if (_readCount != 0) {
		_sentAt = hm_now();
		[self hakiosCheckReads:NO];
	}
}

- (void)hakiosSend
{
	hm_perf_mark phase = hm_perf_begin();
	[self hakiosPrepareSend];
	hakios_metal_cb_commit(_cb, hm_completed, self);
	hm_perf_end(HM_PERF_COMMIT_CORE, phase, 0);
}

- (void)hakiosSent
{
	/* Completion may already have delivered these (including a synchronous submission error). */
	hm_perf_mark phase = hm_perf_begin();
	if (hakios_metal_cb_status(_cb) >= HAKIOS_METAL_SCHEDULED) [self hakiosDeliverScheduled];
	hm_perf_end(HM_PERF_SCHEDULED, phase, 0);
	if (hm_ca_sync()) {
		phase = hm_perf_begin();
		hakios_metal_cb_wait(_cb);
		hm_perf_end(HM_PERF_SYNC, phase, 0);
	}
}

/* abstract in _MTLCommandBuffer (its body is doesNotRecognizeSelector:), so inheriting it aborts. The deadline is
 * for a GPU scheduler to order by; there is one ring here and nothing to tell, but the COMMIT must happen: a late
 * frame is a late frame, a frame never committed is a daemon waiting for ever. */
- (void)commitWithDeadline:(NSUInteger)deadline
{
	(void)deadline;
	HM_ONCE("a command buffer was committed with a deadline; one ring, no scheduler to tell: committed, deadline not promised\n");
	[self commit];
}

- (void)waitUntilScheduled
{
	if (!_committed) {
		HM_ONCE("a command buffer was waited on for scheduling before it was committed; Metal would wait for ever, "
			"this plug-in returns\n");
		return;
	}
	[self hakiosRequireSync:HAKIOS_METAL_DRAIN_CPU_SYNC];
	dispatch_semaphore_wait(_sent, DISPATCH_TIME_FOREVER);
	dispatch_semaphore_signal(_sent);
}

- (void)waitUntilCompleted
{
	if (!_committed) {
		HM_ONCE("a command buffer was waited on before it was committed; Metal would wait for ever, this plug-in returns\n");
		return;
	}
	[self waitUntilScheduled];
	{
		const double began = hm_now();

		hakios_metal_cb_wait(_cb);   /* returns after the completion callback has run: the handlers are delivered by then */
		hm_fps_waited(hm_now() - began);
	}
}

/* --- handlers --- */

/* where a handler runs: on the completion queue the daemon named, if it named one, else right here */
- (void)hakiosDeliver:(MTLCommandBufferHandler)handler
{
	dispatch_queue_t queue = [_queue hakiosCompletionQueue];

	if (queue != nil) {
		dispatch_async(queue, ^{ handler((id<MTLCommandBuffer>)self); });   /* the block retains the buffer and the handler */
		return;
	}
	handler((id<MTLCommandBuffer>)self);
}

- (void)hakiosDeliverScheduled
{
	/* Serialize both delivery attempts, not just taking the array: completion must not overtake its handlers. */
	@synchronized (self) {
		if (_scheduledDelivered) return;
		_scheduledDelivered = YES;
		NSArray *scheduled = _scheduled;
		_scheduled = nil;
        dispatch_semaphore_signal(_sent);
		if (hakios_metal_cb_status(_cb) != HAKIOS_METAL_ERROR)
            for (id handler in scheduled) [self hakiosDeliver:(MTLCommandBufferHandler)handler];
		[scheduled release];
	}
}

- (void)hakiosTrackTexture:(HakiosMetalTexture *)texture write:(BOOL)write
{
	/* anything but this driver's own texture is not asked a thing: a view, a placeholder,
	 * another device's texture */
	if (!hm_handoff_on() || texture == nil || ![texture isKindOfClass:[HakiosMetalTexture class]]) return;
	@synchronized (self) {
		NSMutableSet **set = write ? &_probeWrites : &_probeReads;
		if (*set == nil) *set = [[NSMutableSet alloc] init];
		if ([*set containsObject:texture]) return;
		[*set addObject:texture];
		hm_diag_add(write ? &hm_diag.encodeWrites : &hm_diag.encodeReads);
	}
}

- (void)hakiosWriteShadowAtCompletion:(HakiosMetalTexture *)texture
{
	while ([texture parentTexture] != nil) texture = [texture parentTexture];
	@synchronized (self) {
		if (_shadowTargets == nil) _shadowTargets = [[NSMutableArray alloc] init];
		if ([_shadowTargets containsObject:texture]) return;
		[_shadowTargets addObject:texture];
		[texture hakiosUsedBy:_useSeq];
		[texture hakiosShadowWriteQueued];
		if (hm_handoff_on()) hm_diag_add(&hm_diag.shadowQueued);
	}
}

/* A texture bound to be sampled: one that is a copy of a surface's rows is the surface as of its last refresh, and
 * another command buffer may have drawn into that surface through a copy of its own since -- those rows reach the
 * surface only when that buffer completes. The copies this buffer samples are kept (the root copy: the write-back is
 * the root's work) for -hakiosShadowSampleSync, which is run before this buffer is submitted. */
- (void)hakiosTrackSample:(HakiosMetalTexture *)texture
{
	if (texture == nil || ![texture isKindOfClass:[HakiosMetalTexture class]] || ![texture hakiosIsShadow] ||
	    [texture iosurface] == NULL) {
		return;
	}
	while ([texture parentTexture] != nil) texture = [texture parentTexture];
	@synchronized (self) {
		if (_shadowSamples == nil) _shadowSamples = [[NSMutableArray alloc] init];
		if ([_shadowSamples containsObject:texture]) return;
		[_shadowSamples addObject:texture];
	}
}

/* Before this buffer is submitted: a surface it samples through a copy may have GPU writes into it still queued -- a
 * pass of an earlier command buffer drew into a copy of the same surface, and those rows reach the surface only when
 * that buffer completes (-hakiosWriteBackShadow). Wait for them, bounded, and take the copies this buffer samples from
 * the surface the write-back leaves. A sample of the surface before that is the App Library's background, black or a
 * frame old (v29u).
 *
 * Called before the queue's lock is taken and before the submission: the wait is for a completion, delivered on
 * hakios-metal's own thread, which needs neither this queue's lock nor anything postponed here (completion handlers go
 * to CoreAnimation's queue). This buffer's own queued writes are not waited for: it is not submitted yet, and its own
 * passes run in order within it. /var/db/hakios-metal-cache/shadow-sample-sync-off returns the old behaviour. */
- (void)hakiosShadowSampleSync
{
	static int off = -1;
	IOSurfaceID ids[8];
	unsigned own[8] = {0}, count = 0, pending = 0, waited = 0, timeouts = 0;
	NSArray *samples = nil;

	if (_shadowSamples == nil) return;
	if (off < 0) off = access("/var/db/hakios-metal-cache/shadow-sample-sync-off", F_OK) == 0;
	if (off != 0) return;
	@synchronized (self) {
		samples = [[_shadowSamples copy] autorelease];
		/* what this buffer writes back itself: a copy is one queued write, and those are not waited for */
		for (HakiosMetalTexture *t in _shadowTargets) {
			IOSurfaceRef s = [t iosurface];
			unsigned i = 0;

			if (s == NULL) continue;
			const IOSurfaceID id = IOSurfaceGetID(s);
			while (i < count && ids[i] != id) i++;
			if (i == count) {
				if (count == 8) continue;
				ids[count++] = id;
				own[i] = 0;
			}
			own[i]++;
		}
	}
	for (HakiosMetalTexture *t in samples) {
		IOSurfaceRef s = [t iosurface];
		unsigned i = 0, ownHere = 0, queued;

		if (s == NULL) continue;
		{
			const IOSurfaceID id = IOSurfaceGetID(s);

			while (i < count && ids[i] != id) i++;
			if (i < count) ownHere = own[i];
			queued = hm_shadow_surface_pending(id);
			if (queued <= ownHere) continue;   /* nothing another command buffer owes this surface */
			pending++;
			if (hm_shadow_surface_wait(id, ownHere, 0.020)) {
				waited++;
				[t hakiosRefreshShadow];   /* the write-back moved the surface's seed: take it again, before submission */
			} else {
				timeouts++;                /* no copy taken: a half-written surface is never a base (today's behaviour) */
			}
		}
	}
	if (pending != 0) hm_fps_shadow_sample(pending, waited, timeouts);
}

- (void)hakiosCompletedNow
{
	NSArray *completed;

	/* These copies are part of the driver's work, not application completion handlers.
	 * CA's completion queue may itself be waiting for this image's completion/event.
	 * The probes are counters: this is the completion thread, and it lets go at once. */
	if (hm_handoff_on()) {
		hm_diag_add(&hm_diag.cb);
		__atomic_fetch_add(&hm_diag.fenceWrites, (unsigned)[_probeWrites count], __ATOMIC_RELAXED);
		__atomic_fetch_add(&hm_diag.fenceReads, (unsigned)[_probeReads count], __ATOMIC_RELAXED);
		__atomic_fetch_add(&hm_diag.visibleWrites, (unsigned)[_probeWrites count], __ATOMIC_RELAXED);
		__atomic_fetch_add(&hm_diag.shadowPublished, (unsigned)[_shadowTargets count], __ATOMIC_RELAXED);
	}
	for (HakiosMetalTexture *texture in _shadowTargets) [texture hakiosWriteBackShadow];
	[_shadowTargets removeAllObjects];
	[_probeWrites removeAllObjects];
	[_probeReads removeAllObjects];
	hm_use_set(_useSeq, HM_USE_DONE);   /* its resources' -isComplete, before any handler runs */
	[self hakiosDeliverScheduled];
	[self error];   /* built now, on the completing thread, so that a handler reading -error gets the sentence */
	/* the events this buffer signals, now that its work is done: before its handlers, which may read them */
	for (NSArray *sg in _signals) {
		if (hm_handoff_on()) hm_diag_add(&hm_diag.signals);
		[[sg objectAtIndex:0] hakiosSignal:[[sg objectAtIndex:1] unsignedLongLongValue]];
	}
	@synchronized (self) {
		completed = _completed;
		_completed = nil;
        _completedDelivered = YES;
	}
	for (id handler in completed) {
		[self hakiosDeliver:(MTLCommandBufferHandler)handler];
	}
	[completed release];
	[self hakiosPaySlot];
}

/* A handler added once the stage it is about has passed is delivered at once rather than dropped: Metal calls that
 * undefined, and losing it would be exactly the kind of silence this file exists to stop having. */
- (void)addScheduledHandler:(MTLCommandBufferHandler)handler
{
    if (handler == NULL) return;
    BOOL deliver;
    @synchronized (self) {
        deliver = _scheduledDelivered;
        if (!deliver) {
            if (_scheduled == nil) _scheduled = [[NSMutableArray alloc] init];
            [_scheduled addObject:[[handler copy] autorelease]];
        }
    }
    [self hakiosRequireSync:HAKIOS_METAL_DRAIN_CPU_SYNC];
    if (deliver && hakios_metal_cb_status(_cb) != HAKIOS_METAL_ERROR) [self hakiosDeliver:handler];
}

- (void)addCompletedHandler:(MTLCommandBufferHandler)handler
{
    if (handler == NULL) return;
    BOOL deliver;
    @synchronized (self) {
        deliver = _completedDelivered;
        if (!deliver) {
            if (_completed == nil) _completed = [[NSMutableArray alloc] init];
            [_completed addObject:[[handler copy] autorelease]];
        }
    }
    [self hakiosRequireSync:HAKIOS_METAL_DRAIN_CPU_SYNC];
    if (deliver) [self hakiosDeliver:handler];
}

/* --- presenting --- */

/* Metal's definition is a scheduled handler that sends the drawable -present (MTLCommandBuffer.h): its display then
 * waits for the GPU's work on the surface before it shows it. Nothing here waits so: the compositor and the display
 * read the surface as soon as it is presented, and a drawable presented when its buffer was merely scheduled was
 * shown half resolved -- sokol's clear sample, a band of black rows in some frames. So it is presented when the
 * buffer has COMPLETED, which is what Metal's display waits for anyway; the drawable is kept until then */
- (void)presentDrawable:(id)drawable
{
	if (drawable == nil) {
		return;
	}
	if (![drawable respondsToSelector:@selector(present)]) {
		hm_print("refused: -presentDrawable: of a %s, which does not answer -present; nothing is presented\n", class_getName(object_getClass(drawable)));
		return;
	}
	[self hakiosRequireSync:HAKIOS_METAL_DRAIN_SURFACE];
	[drawable retain];
	[self addCompletedHandler:^(id<MTLCommandBuffer> cb) {
		(void)cb;
		[drawable present];
		[drawable release];
		hm_fps_note(YES, 0, 0, NULL);
	}];
}

- (void)presentDrawable:(id)drawable atTime:(CFTimeInterval)time
{
	(void)time;
	[self presentDrawable:drawable];
}

- (void)presentDrawable:(id)drawable afterMinimumDuration:(CFTimeInterval)duration
{
	(void)duration;
	[self presentDrawable:drawable];
}

/* MTLEvent orders work across command buffers and queues (HakiosMetalEvent): a signal is applied when this buffer
 * completes, a wait holds the buffer back from the GPU until the value has come. An event of another kind -- another
 * device's, another process's handle -- has no value here to wait for, and fails the buffer by name. */
- (void)encodeSignalEvent:(id)event value:(uint64_t)value
{
	if (![event isKindOfClass:[HakiosMetalEvent class]]) {
		hm_print("refused: a signal of a %s, not an event of this device; the command buffer is failed\n", class_getName(object_getClass(event)));
		hakios_metal_cb_refuse(_cb, "a signal of an event that is not this device's");
		return;
	}
	if (_signals == nil) _signals = [[NSMutableArray alloc] init];
	[_signals addObject:@[ event, @(value) ]];
    [self hakiosRequireSync:HAKIOS_METAL_DRAIN_CPU_SYNC];
}

- (void)encodeWaitForEvent:(id)event value:(uint64_t)value
{
	if (![event isKindOfClass:[HakiosMetalEvent class]]) {
		hm_print("refused: a wait for a %s, not an event of this device; the command buffer is failed\n", class_getName(object_getClass(event)));
		hakios_metal_cb_refuse(_cb, "a wait for an event that is not this device's");
		return;
	}
	if (_waits == nil) _waits = [[NSMutableArray alloc] init];
	[_waits addObject:@[ event, @(value) ]];
}

/* Sent by the window server to every command buffer it makes (78 unrecognized-selector aborts in one boot): declared on
 * IOGPUMetalCommandBuffer, a class and not a protocol. Protected content is memory the GPU reads and the processor
 * cannot, which this port has none of, so the value is kept and not honoured -- the window server asks for it on
 * buffers that carry no protected content at all. */
- (void)setProtectionOptions:(NSUInteger)options
{
	if (options != 0 && _protectionOptions != options) {
		HM_ONCE("a command buffer was asked for protection options %lu; there is no protected memory here, so the "
			"request is kept and not honoured\n", (unsigned long)options);
	}
	_protectionOptions = options;
}

- (NSUInteger)protectionOptions { return _protectionOptions; }

@end

/* ============================================================================================================
 * The blit encoder: copy and fill, by the GPU's command processor
 * ============================================================================================================ */

@implementation HakiosMetalBlitCommandEncoder

+ (void)load
{
	hm_adopt(self, @protocol(MTLBlitCommandEncoder), "MTLBlitCommandEncoder");
}

HM_REFUSES_OUT_LOUD

- (instancetype)initWithHakiosCommandBuffer:(HakiosMetalCommandBuffer *)commandBuffer
{
	self = [super initWithCommandBuffer:commandBuffer];   /* retains the buffer; -endEncoding gives it back */
	if (self == nil) {
		return nil;
	}
	_commandBuffer = commandBuffer;
	return self;
}

- (id)device { return [_commandBuffer device]; }
- (uint64_t)hakiosUseSeq { return [_commandBuffer hakiosUseSeq]; }

/* the SPI form with MTLBlitOptions (AppleMetalGLRenderer's resolves and texture copies send it): a texture copy's
 * options name row-linear PVRTC and depth/stencil planes, none of which a texture here has */
- (void)copyFromTexture:(id)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel
	   sourceOrigin:(MTLOrigin)sourceOrigin sourceSize:(MTLSize)sourceSize toTexture:(id)destinationTexture
       destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel
      destinationOrigin:(MTLOrigin)destinationOrigin options:(MTLBlitOption)options
{
	if (options != MTLBlitOptionNone) {
		HM_ONCE("a texture copy with blit options %#lx: copied without them\n", (unsigned long)options);
	}
	[self copyFromTexture:sourceTexture sourceSlice:sourceSlice sourceLevel:sourceLevel sourceOrigin:sourceOrigin sourceSize:sourceSize
		    toTexture:destinationTexture destinationSlice:destinationSlice destinationLevel:destinationLevel
		destinationOrigin:destinationOrigin];
}

/* a buffer of another device, or an object standing in for one, cannot be bound here; said by name */
static hakios_metal_buffer *
hm_buffer_of(id self, id object, const char *what)
{
	if (object == nil) {
		hm_print("refused: a blit on %s without a %s buffer\n", class_getName(object_getClass(self)), what);
		return NULL;
	}
	if (![object isKindOfClass:[HakiosMetalBuffer class]]) {
		hm_print("refused: the %s buffer is a %s, not a buffer of this device\n", what, class_getName(object_getClass(object)));
		return NULL;
	}
	[(HakiosMetalBuffer *)object hakiosUsedBy:[self hakiosUseSeq]];
	return [(HakiosMetalBuffer *)object hakiosBuffer];
}

- (void)copyFromBuffer:(id)source sourceOffset:(NSUInteger)sourceOffset toBuffer:(id)destination
     destinationOffset:(NSUInteger)destinationOffset size:(NSUInteger)size
{
	hakios_metal_buffer *from = hm_buffer_of(self, source, "source");
	hakios_metal_buffer *to = hm_buffer_of(self, destination, "destination");
	hakios_metal_cb *cb = [_commandBuffer hakiosCommandBuffer];

	if (from == NULL || to == NULL) {
		hakios_metal_cb_refuse(cb, "a buffer copy named a buffer that is not this device's");
		return;
	}
	if (hakios_metal_cb_copy(cb, from, sourceOffset, to, destinationOffset, size) != 0) {
		hm_print("refused: a copy of %lu bytes: %s\n", (unsigned long)size, hakios_metal_error());   /* the buffer ends in error */
	}
}

- (void)fillBuffer:(id)buffer range:(NSRange)range value:(uint8_t)value
{
	hakios_metal_buffer *target = hm_buffer_of(self, buffer, "fill");
	hakios_metal_cb *cb = [_commandBuffer hakiosCommandBuffer];

	if (target == NULL) {
		hakios_metal_cb_refuse(cb, "a fill named a buffer that is not this device's");
		return;
	}
	if (hakios_metal_cb_fill(cb, target, range.location, range.length, value) != 0) {
		hm_print("refused: a fill of %lu bytes: %s\n", (unsigned long)range.length, hakios_metal_error());
	}
}

/* Correct as nothing, and a statement about this device rather than a shortcut: a fence orders passes within a queue,
 * and this queue runs every command buffer, and every command in it, in order -- hakios-metal invalidates the GPU's
 * caches before a dispatch and flushes them after it, so what a blit wrote is what the next dispatch reads. */
- (void)updateFence:(id)fence  { (void)fence; [_commandBuffer hakiosRequireSync:HAKIOS_METAL_DRAIN_CPU_SYNC]; }
- (void)waitForFence:(id)fence { (void)fence; [_commandBuffer hakiosRequireSync:HAKIOS_METAL_DRAIN_CPU_SYNC]; }

/* A blit reads the same refreshed IOSurface rows as a sampled binding. Partial
 * writes first preserve the other pixels, then publish the shadow at completion,
 * as render and compute encoders do. PencilKit uses this for its canvas snapshot. */
static hakios_metal_texture *
hm_blit_texture(id self, HakiosMetalCommandBuffer *commandBuffer, hakios_metal_cb *cb, id object, const char *what, BOOL write)
{
	if (object == nil || ![object isKindOfClass:[HakiosMetalTexture class]]) {
		char why[160];

		snprintf(why, sizeof(why), "a texture copy's %s is %s, not a texture of this device", what,
			 object != nil ? class_getName(object_getClass(object)) : "nil");
		hm_print("refused: %s\n", why);
		hakios_metal_cb_refuse(cb, why);
		return NULL;
	}
	HakiosMetalTexture *texture = object;
	[texture hakiosRefreshShadow];
	if ([texture hakiosIsShadow]) hm_fps_shadow_blit(write);
	if (write && [texture hakiosIsShadow]) {
		[commandBuffer hakiosWriteShadowAtCompletion:texture];
	}
	if (!write) [commandBuffer hakiosTrackSample:texture];   /* a surface another buffer may still be writing back */
	[commandBuffer hakiosTrackTexture:texture write:write];
	[texture hakiosUsedBy:[self hakiosUseSeq]];
	return [texture hakiosTexture];
}

/* Texture copies are hakios-metal's 2D engine (hakios_metal_cb_blit: turnip's r2d copy, one pixel format, texel for
 * texel). One slice is what a texture here has; a region with depth other than 1 is refused by name. */
- (void)copyFromTexture:(id)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel
	   sourceOrigin:(MTLOrigin)sourceOrigin sourceSize:(MTLSize)sourceSize toTexture:(id)destinationTexture
       destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel
      destinationOrigin:(MTLOrigin)destinationOrigin
{
	hakios_metal_cb *cb = [_commandBuffer hakiosCommandBuffer];
	hakios_metal_texture *from = hm_blit_texture(self, _commandBuffer, cb, sourceTexture, "source", NO);
	hakios_metal_texture *to = from != NULL ? hm_blit_texture(self, _commandBuffer, cb, destinationTexture, "destination", YES) : NULL;

	if (to == NULL) {
		return;
	}
	if (sourceSlice != 0 || destinationSlice != 0 || sourceOrigin.z != 0 || destinationOrigin.z != 0 || sourceSize.depth != 1) {
		char why[160];

		snprintf(why, sizeof(why), "a texture copy of slice %lu into slice %lu, depth %lu at z %lu: one slice and depth 1 are served",
			 (unsigned long)sourceSlice, (unsigned long)destinationSlice, (unsigned long)sourceSize.depth, (unsigned long)sourceOrigin.z);
		hm_print("refused: %s\n", why);
		hakios_metal_cb_refuse(cb, why);
		return;
	}
	if (hakios_metal_cb_blit(cb, from, (unsigned)sourceLevel, (unsigned)sourceOrigin.x, (unsigned)sourceOrigin.y, (unsigned)sourceSize.width,
				 (unsigned)sourceSize.height, to, (unsigned)destinationLevel, (unsigned)destinationOrigin.x,
				 (unsigned)destinationOrigin.y, (unsigned)sourceSize.width, (unsigned)sourceSize.height, 0) != 0) {
		/* the buffer ends in error; what was asked, for telling a copy of a texture onto itself from two textures that
		 * share their memory */
		hm_print("refused: a texture copy: %s (%s texture %p, level %lu, %lux%lu at (%lu, %lu), into %p level %lu at (%lu, %lu))\n",
			 hakios_metal_error(), sourceTexture == destinationTexture ? "one" : "two", (void *)sourceTexture,
			 (unsigned long)sourceLevel, (unsigned long)sourceSize.width, (unsigned long)sourceSize.height,
			 (unsigned long)sourceOrigin.x, (unsigned long)sourceOrigin.y, (void *)destinationTexture,
			 (unsigned long)destinationLevel, (unsigned long)destinationOrigin.x, (unsigned long)destinationOrigin.y);
	}
}

/* levelCount levels from sourceLevel, each whole, into the same levels from destinationLevel */
- (void)copyFromTexture:(id)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel
	      toTexture:(id)destinationTexture destinationSlice:(NSUInteger)destinationSlice
       destinationLevel:(NSUInteger)destinationLevel sliceCount:(NSUInteger)sliceCount levelCount:(NSUInteger)levelCount
{
	if (sliceCount != 1) {
		hakios_metal_cb_refuse([_commandBuffer hakiosCommandBuffer], "a texture copy of several slices: one slice is served");
		hm_print("refused: a texture copy of %lu slices: one slice is served\n", (unsigned long)sliceCount);
		return;
	}
	for (NSUInteger l = 0; l < levelCount; l++) {
		NSUInteger w = [sourceTexture width] >> (sourceLevel + l), h = [sourceTexture height] >> (sourceLevel + l);

		[self copyFromTexture:sourceTexture sourceSlice:sourceSlice sourceLevel:sourceLevel + l sourceOrigin:MTLOriginMake(0, 0, 0)
			   sourceSize:MTLSizeMake(w ? w : 1, h ? h : 1, 1) toTexture:destinationTexture destinationSlice:destinationSlice
		     destinationLevel:destinationLevel + l destinationOrigin:MTLOriginMake(0, 0, 0)];
	}
}

/* every level, each whole: the two textures of one size and level count (Metal's own rule for this form) */
- (void)copyFromTexture:(id)sourceTexture toTexture:(id)destinationTexture
{
	NSUInteger levels = MIN([sourceTexture mipmapLevelCount], [destinationTexture mipmapLevelCount]);

	[self copyFromTexture:sourceTexture sourceSlice:0 sourceLevel:0 toTexture:destinationTexture destinationSlice:0 destinationLevel:0
		   sliceCount:1 levelCount:levels];
}

/* each level from the one above, halved with linear filtering (hakios_metal_cb_generate_mipmaps) */
- (void)generateMipmapsForTexture:(id)texture
{
	hakios_metal_cb *cb = [_commandBuffer hakiosCommandBuffer];
	hakios_metal_texture *t = hm_blit_texture(self, _commandBuffer, cb, texture, "texture", YES);

	if (t != NULL && hakios_metal_cb_generate_mipmaps(cb, t) != 0) {
		hm_print("refused: generateMipmaps of a %lux%lu texture of %lu levels: %s\n", (unsigned long)[texture width],
			 (unsigned long)[texture height], (unsigned long)[texture mipmapLevelCount], hakios_metal_error());
	}
}

/* Buffer-texture copies go through the 2D engine too: the buffer's rows are a texture of the other side's format over the
 * same memory (hakios_metal_texture_new_buffer), and that texture is blitted. The GPU takes such rows only at a pitch and
 * a start that are multiples of 64 bytes; rows that are not are first copied, one GPU copy per row in the same command
 * buffer, through a staging buffer laid out that way -- sokol-gfx uploads a 320-byte-wide picture from wherever its
 * staging ring puts it. The command buffer keeps every buffer and texture it names, so the handles go at once. */
static hakios_metal_texture *
hm_rows_texture(HakiosMetalBlitCommandEncoder *self, hakios_metal_cb *cb, hakios_metal_buffer *buffer, uint64_t offset,
		uint64_t bytesPerRow, hakios_metal_texture *like, MTLSize size, hakios_metal_buffer **staging, uint64_t *stagedPitch)
{
	hakios_metal_texture *rows;

	*staging = NULL;
	*stagedPitch = bytesPerRow;
	if (offset % 64 != 0 || bytesPerRow % 64 != 0) {
		*stagedPitch = (bytesPerRow + 63) & ~(uint64_t)63;
		*staging = hakios_metal_buffer_new([(HakiosMetalDevice *)[self device] hakiosDevice], *stagedPitch * size.height);
		if (*staging == NULL) {
			return NULL;
		}
		offset = 0;
	}
	rows = hakios_metal_texture_new_buffer(*staging != NULL ? *staging : buffer, MTLTextureType2D, hakios_metal_texture_format(like),
					       (unsigned)size.width, (unsigned)size.height, 1 | 2 | 4, offset, *stagedPitch);
	(void)cb;
	return rows;
}

/* the same copy with blit options: MTLBlitOptionNone is the copy above; the others (a depth or stencil plane of a
 * combined format, PVRTC rows) are layouts this device does not have, refused by name */
- (void)copyFromBuffer:(id)sourceBuffer sourceOffset:(NSUInteger)sourceOffset sourceBytesPerRow:(NSUInteger)sourceBytesPerRow
   sourceBytesPerImage:(NSUInteger)sourceBytesPerImage sourceSize:(MTLSize)sourceSize toTexture:(id)destinationTexture
      destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel
     destinationOrigin:(MTLOrigin)destinationOrigin options:(MTLBlitOption)options
{
	if (options != MTLBlitOptionNone) {
		char why[120];

		snprintf(why, sizeof(why), "a buffer-to-texture copy with blit options %#lx: only MTLBlitOptionNone is served", (unsigned long)options);
		hm_print("refused: %s\n", why);
		hakios_metal_cb_refuse([_commandBuffer hakiosCommandBuffer], why);
		return;
	}
	[self copyFromBuffer:sourceBuffer sourceOffset:sourceOffset sourceBytesPerRow:sourceBytesPerRow sourceBytesPerImage:sourceBytesPerImage
		  sourceSize:sourceSize toTexture:destinationTexture destinationSlice:destinationSlice destinationLevel:destinationLevel
	   destinationOrigin:destinationOrigin];
}

- (void)copyFromBuffer:(id)sourceBuffer sourceOffset:(NSUInteger)sourceOffset sourceBytesPerRow:(NSUInteger)sourceBytesPerRow
   sourceBytesPerImage:(NSUInteger)sourceBytesPerImage sourceSize:(MTLSize)sourceSize toTexture:(id)destinationTexture
      destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel
     destinationOrigin:(MTLOrigin)destinationOrigin
{
	hakios_metal_cb *cb = [_commandBuffer hakiosCommandBuffer];
	hakios_metal_buffer *from = hm_buffer_of(self, sourceBuffer, "source");
	hakios_metal_texture *to = from != NULL ? hm_blit_texture(self, _commandBuffer, cb, destinationTexture, "destination", YES) : NULL;
	hakios_metal_buffer *staging;
	hakios_metal_texture *rows;
	uint64_t pitch;
	int failed = 0;

	(void)sourceBytesPerImage;   /* one image: depth 1 is all a texture here has */
	if (from == NULL) {
		hakios_metal_cb_refuse(cb, "a buffer-to-texture copy named a buffer that is not this device's");
		return;
	}
	if (to == NULL) {
		return;
	}
	/* a layer of an array or cube, or planes of a 3D texture: the processor copies them out of the buffer's shared memory
	 * when the copy is encoded, as for block formats below -- the 2D copy writes one 2D image, and Resident Evil 4 fills
	 * its 64-layer and 3D tables so */
	if ((destinationSlice != 0 || destinationOrigin.z != 0 || sourceSize.depth != 1 ||
	     hm_layered(hakios_metal_texture_type(to)) || hakios_metal_texture_type(to) == MTLTextureType3D) &&
	    sourceSize.width != 0 && sourceSize.height != 0 && sourceSize.depth != 0) {
		const uint8_t *base = hakios_metal_buffer_contents(from);
		const BOOL planes = hakios_metal_texture_type(to) == MTLTextureType3D;

		if (base == NULL || (!planes && sourceSize.depth != 1) ||
		    hakios_metal_texture_replace_3d(to, (unsigned)destinationLevel, (unsigned)destinationOrigin.x, (unsigned)destinationOrigin.y,
						    (unsigned)(planes ? destinationOrigin.z : destinationSlice), (unsigned)sourceSize.width,
						    (unsigned)sourceSize.height, (unsigned)sourceSize.depth, base + sourceOffset, sourceBytesPerRow,
						    sourceBytesPerImage) != 0) {
			char why[200];

			snprintf(why, sizeof(why), "a buffer-to-texture copy of %lux%lux%lu into slice %lu at z %lu: %s", (unsigned long)sourceSize.width,
				 (unsigned long)sourceSize.height, (unsigned long)sourceSize.depth, (unsigned long)destinationSlice,
				 (unsigned long)destinationOrigin.z, base == NULL ? "the buffer is mapped nowhere" :
				 (!planes && sourceSize.depth != 1) ? "several slices in one copy are not served" : hakios_metal_error());
			hm_print("refused: %s\n", why);
			hakios_metal_cb_refuse(cb, why);
		}
		return;
	}
	if (sourceSize.width == 0 || sourceSize.height == 0) {
		char why[160];

		snprintf(why, sizeof(why), "a buffer-to-texture copy of %lux%lux%lu into slice %lu at z %lu: one slice, depth 1 and a size are served",
			 (unsigned long)sourceSize.width, (unsigned long)sourceSize.height, (unsigned long)sourceSize.depth,
			 (unsigned long)destinationSlice, (unsigned long)destinationOrigin.z);
		hm_print("refused: %s\n", why);
		hakios_metal_cb_refuse(cb, why);
		return;
	}
	/* A block-compressed format (BC 130-143, PVRTC 160-167, ETC2/EAC 170-183, ASTC 186-236): the 2D engine copies texels,
	 * and a buffer's rows of blocks are no texture it can read, so the blocks are copied by the processor out of the
	 * buffer's memory, which it shares with the GPU -- PVRTC decoded to the RGBA8 its texture holds -- when the copy is
	 * encoded, not when it runs: what an engine wrote into its staging buffer before encoding the upload, as engines do.
	 * Resident Evil 4 loads its ASTC and ETC2 textures so, and drew its missing-texture magenta while these were refused. */
	{
		const unsigned format = hakios_metal_texture_format(to);

		if (format >= 130 && format <= 236) {
			const uint8_t *base = hakios_metal_buffer_contents(from);

			if (base == NULL || hakios_metal_texture_replace_level(to, (unsigned)destinationLevel, (unsigned)destinationOrigin.x,
									       (unsigned)destinationOrigin.y, (unsigned)sourceSize.width,
									       (unsigned)sourceSize.height, base + sourceOffset, sourceBytesPerRow) != 0) {
				hm_print("refused: a buffer-to-texture copy of %lux%lu at (%lu, %lu) into block format %u: %s\n", (unsigned long)sourceSize.width,
					 (unsigned long)sourceSize.height, (unsigned long)destinationOrigin.x, (unsigned long)destinationOrigin.y, format,
					 base == NULL ? "the buffer is mapped nowhere" : hakios_metal_error());
				hakios_metal_cb_refuse(cb, "a buffer-to-texture copy into a block-compressed texture");
			} else if (destinationLevel == 0) {
				hm_flat_census("a buffer-to-texture copy", hakios_metal_texture_resource_id(to), format, sourceSize.width, sourceSize.height,
					       base + sourceOffset, sourceBytesPerRow);
			}
			return;
		}
	}
	rows = hm_rows_texture(self, cb, from, sourceOffset, sourceBytesPerRow, to, sourceSize, &staging, &pitch);
	if (rows == NULL) {
		hm_print("refused: a buffer-to-texture copy of %lux%lu from offset %lu, %lu bytes a row: %s\n", (unsigned long)sourceSize.width,
			 (unsigned long)sourceSize.height, (unsigned long)sourceOffset, (unsigned long)sourceBytesPerRow, hakios_metal_error());
		hakios_metal_cb_refuse(cb, "a buffer-to-texture copy's rows could not be made a texture");
		if (staging != NULL) {
			hakios_metal_buffer_free(staging);
		}
		return;
	}
	if (staging != NULL) {
		uint64_t length = hakios_metal_buffer_length(from);

		for (NSUInteger y = 0; y < sourceSize.height && !failed; y++) {
			uint64_t at = sourceOffset + (uint64_t)y * sourceBytesPerRow;
			uint64_t n = at < length ? MIN((uint64_t)sourceBytesPerRow, length - at) : 0;   /* the last row may end early */

			failed = hakios_metal_cb_copy(cb, from, at, staging, (uint64_t)y * pitch, n) != 0;
		}
	}
	if (!failed) {
		failed = hakios_metal_cb_blit(cb, rows, 0, 0, 0, (unsigned)sourceSize.width, (unsigned)sourceSize.height, to,
					      (unsigned)destinationLevel, (unsigned)destinationOrigin.x, (unsigned)destinationOrigin.y,
					      (unsigned)sourceSize.width, (unsigned)sourceSize.height, 0) != 0;
	}
	if (failed) {
		hm_print("refused: a buffer-to-texture copy of %lux%lu: %s\n", (unsigned long)sourceSize.width,
			 (unsigned long)sourceSize.height, hakios_metal_error());   /* the buffer ends in error */
	}
	hakios_metal_texture_free(rows);
	if (staging != NULL) {
		hakios_metal_buffer_free(staging);
	}
}

- (void)copyFromTexture:(id)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel
	   sourceOrigin:(MTLOrigin)sourceOrigin sourceSize:(MTLSize)sourceSize toBuffer:(id)destinationBuffer
      destinationOffset:(NSUInteger)destinationOffset destinationBytesPerRow:(NSUInteger)destinationBytesPerRow
    destinationBytesPerImage:(NSUInteger)destinationBytesPerImage
{
	hakios_metal_cb *cb = [_commandBuffer hakiosCommandBuffer];
	hakios_metal_texture *from = hm_blit_texture(self, _commandBuffer, cb, sourceTexture, "source", NO);
	hakios_metal_buffer *to = from != NULL ? hm_buffer_of(self, destinationBuffer, "destination") : NULL;
	hakios_metal_buffer *staging;
	hakios_metal_texture *rows;
	uint64_t pitch;
	int failed;

	(void)destinationBytesPerImage;
	if (from == NULL) {
		return;
	}
	if (to == NULL) {
		hakios_metal_cb_refuse(cb, "a texture-to-buffer copy named a buffer that is not this device's");
		return;
	}
	if (sourceSlice != 0 || sourceOrigin.z != 0 || sourceSize.depth != 1 || sourceSize.width == 0 || sourceSize.height == 0) {
		char why[160];

		snprintf(why, sizeof(why), "a texture-to-buffer copy of %lux%lux%lu from slice %lu at z %lu: one slice, depth 1 and a size are served",
			 (unsigned long)sourceSize.width, (unsigned long)sourceSize.height, (unsigned long)sourceSize.depth,
			 (unsigned long)sourceSlice, (unsigned long)sourceOrigin.z);
		hm_print("refused: %s\n", why);
		hakios_metal_cb_refuse(cb, why);
		return;
	}
	rows = hm_rows_texture(self, cb, to, destinationOffset, destinationBytesPerRow, from, sourceSize, &staging, &pitch);
	if (rows == NULL) {
		hm_print("refused: a texture-to-buffer copy of %lux%lu to offset %lu, %lu bytes a row: %s\n", (unsigned long)sourceSize.width,
			 (unsigned long)sourceSize.height, (unsigned long)destinationOffset, (unsigned long)destinationBytesPerRow, hakios_metal_error());
		hakios_metal_cb_refuse(cb, "a texture-to-buffer copy's rows could not be made a texture");
		if (staging != NULL) {
			hakios_metal_buffer_free(staging);
		}
		return;
	}
	failed = hakios_metal_cb_blit(cb, from, (unsigned)sourceLevel, (unsigned)sourceOrigin.x, (unsigned)sourceOrigin.y,
				      (unsigned)sourceSize.width, (unsigned)sourceSize.height, rows, 0, 0, 0, (unsigned)sourceSize.width,
				      (unsigned)sourceSize.height, 0) != 0;
	if (staging != NULL) {
		uint64_t length = hakios_metal_buffer_length(to);

		/* only the row's own bytes: what lies between rows in the destination is the caller's and is not written */
		uint64_t rowBytes = (uint64_t)hakios_metal_texture_bytes_per_pixel(from) * sourceSize.width;

		for (NSUInteger y = 0; y < sourceSize.height && !failed; y++) {
			uint64_t at = destinationOffset + (uint64_t)y * destinationBytesPerRow;
			uint64_t n = at < length ? MIN(MIN(rowBytes, (uint64_t)destinationBytesPerRow), length - at) : 0;

			failed = hakios_metal_cb_copy(cb, staging, (uint64_t)y * pitch, to, at, n) != 0;
		}
	}
	if (failed) {
		hm_print("refused: a texture-to-buffer copy of %lux%lu: %s\n", (unsigned long)sourceSize.width,
			 (unsigned long)sourceSize.height, hakios_metal_error());
	}
	hakios_metal_texture_free(rows);
	if (staging != NULL) {
		hakios_metal_buffer_free(staging);
	}
}

/* indirect command buffers: every one of those selectors is declared by <MTLBlitCommandEncoder>, so each is refused
 * through -forwardInvocation: with its name and its caller */

/* the base class retains the command buffer in its initialiser and releases it only here; its -dealloc aborts on an
 * encoder released without this */
- (void)endEncoding
{
	[super endEncoding];
}

@end

/* ============================================================================================================
 * The compute encoder: bindings and dispatches, each dispatch recorded into hakios-metal's command buffer
 * ============================================================================================================ */

@implementation HakiosMetalComputeCommandEncoder

+ (void)load
{
	hm_adopt(self, @protocol(MTLComputeCommandEncoder), "MTLComputeCommandEncoder");
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
	NSMethodSignature *s = [super methodSignatureForSelector:sel];

	return s != nil ? s : hm_protocol_signature([self class], sel);
}

/* A refused binding (a function table, a stage-in region, an acceleration structure ...) is remembered, and the next
 * dispatch is FAILED by it: a kernel run without one of its inputs computes something, and that something would look
 * like a result. Textures and samplers no longer come this way: they have methods below. */
- (void)forwardInvocation:(NSInvocation *)invocation
{
	hm_forward(self, invocation);
	if (_refused[0] == '\0') {
		snprintf(_refused, sizeof(_refused), "-%s was refused on this encoder", sel_getName([invocation selector]));
	}
}

- (void)doesNotRecognizeSelector:(SEL)sel
{
	hm_refusal(self, sel, "is declared by no protocol in this process and implemented by nothing in its class chain; it raises");
	[super doesNotRecognizeSelector:sel];
}

- (instancetype)initWithHakiosCommandBuffer:(HakiosMetalCommandBuffer *)commandBuffer
{
	self = [super initWithCommandBuffer:commandBuffer];
	if (self == nil) {
		return nil;
	}
	_commandBuffer = commandBuffer;
	return self;
}

- (void)dealloc
{
	[_pipeline release];
	for (unsigned i = 0; i < HM_MAX_BUFFERS; i++) {
		[_buffers[i] release];
	}
	for (unsigned i = 0; i < HM_MAX_TEXTURES; i++) {
		[_textures[i] release];
	}
	for (unsigned i = 0; i < HM_MAX_SAMPLERS; i++) {
		[_samplers[i] release];
	}
	[_scratch release];
	[super dealloc];
}

- (id)device { return [_commandBuffer device]; }
- (MTLDispatchType)dispatchType { return MTLDispatchTypeSerial; }

- (void)setComputePipelineState:(id)state
{
	if (state != nil && ![state isKindOfClass:[HakiosMetalComputePipelineState class]]) {
		hm_print("refused: a pipeline state of class %s is not this device's\n", class_getName(object_getClass(state)));
		snprintf(_refused, sizeof(_refused), "the pipeline state is not this device's");
		return;
	}
	[state retain];
	[_pipeline release];
	_pipeline = state;
}

- (void)setBuffer:(id)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	if (index >= HM_MAX_BUFFERS) {
		hm_print("refused: buffer index %lu is past Metal's table of %d\n", (unsigned long)index, HM_MAX_BUFFERS);
		snprintf(_refused, sizeof(_refused), "a buffer index past %d", HM_MAX_BUFFERS);
		return;
	}
	if (buffer != nil && ![buffer isKindOfClass:[HakiosMetalBuffer class]]) {
		hm_print("refused: the buffer at index %lu is a %s, not a buffer of this device\n", (unsigned long)index,
			 class_getName(object_getClass(buffer)));
		snprintf(_refused, sizeof(_refused), "the buffer at index %lu is not this device's", (unsigned long)index);
		return;
	}
	[buffer retain];
	[_buffers[index] release];
	_buffers[index] = buffer;
	_offsets[index] = offset;
	if (buffer != nil && index + 1 > _highest) {
		_highest = (unsigned)index + 1;
	}
}

/* Metal's rule: this moves a buffer already bound at the index, so with nothing bound there is nothing to move */
- (void)setBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	if (index < HM_MAX_BUFFERS && _buffers[index] != nil) {
		_offsets[index] = offset;
	}
}

- (void)setBuffers:(const id *)buffers offsets:(const NSUInteger *)offsets withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setBuffer:buffers[i] offset:offsets[i] atIndex:range.location + i];
	}
}

/* Metal's shorthand for small constant data: a buffer here, because that is what the kernel's binding is. The scratch
 * buffer is the encoder's until -endEncoding; hakios-metal keeps it alive past that until the GPU is done with it. */
- (void)setBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index
{
	HakiosMetalBuffer *buffer = [[self device] newBufferWithBytes:bytes length:length options:0];

	if (buffer == nil) {
		snprintf(_refused, sizeof(_refused), "no scratch buffer for %lu bytes at index %lu", (unsigned long)length, (unsigned long)index);
		return;
	}
	if (_scratch == nil) {
		_scratch = [[NSMutableArray alloc] init];
	}
	[_scratch addObject:buffer];
	[self setBuffer:buffer offset:0 atIndex:index];
	[buffer release];
}

/*
 * Textures and samplers, stored BY INDEX and nothing more: Metal allows -setTexture: before -setComputePipelineState:, so
 * the kernel cannot be consulted here, and it is the dispatch (hakios_metal_cb_dispatch2, from the kernel's own declaration
 * of each index as a sampled texture or a written image) that routes a Metal texture index to a TEX_CONST slot or an IBO
 * slot, matches the texture's format against the kernel's element class and refuses by name what does not fit. The class
 * check is the one -setBuffer: makes: an object of another device, or one standing in for a texture, fails the dispatch.
 * Bound objects are retained until the encoder goes, as the buffers are; the dispatch keeps its own references past that.
 */
- (void)setTexture:(id)texture atIndex:(NSUInteger)index
{
	if (index >= HM_MAX_TEXTURES) {
		hm_print("refused: texture index %lu is past Metal's table of %d\n", (unsigned long)index, HM_MAX_TEXTURES);
		snprintf(_refused, sizeof(_refused), "a texture index past %d", HM_MAX_TEXTURES);
		return;
	}
	if (texture != nil && ![texture isKindOfClass:[HakiosMetalTexture class]]) {
		hm_print("refused: the texture at index %lu is a %s, not a texture of this device\n", (unsigned long)index,
			 class_getName(object_getClass(texture)));
		snprintf(_refused, sizeof(_refused), "the texture at index %lu is not this device's", (unsigned long)index);
		return;
	}
	[texture retain];
	[_textures[index] release];
	_textures[index] = texture;
	/* a surface read through a copy: the copy as the surface is now, and what a kernel writes back into the surface
	 * once the command buffer is done */
	[(HakiosMetalTexture *)texture hakiosRefreshShadow];
	[_commandBuffer hakiosTrackSample:texture];   /* a surface another buffer may still be writing back */
	if ([(HakiosMetalTexture *)texture hakiosIsShadow] && ([(HakiosMetalTexture *)texture usage] & MTLTextureUsageShaderWrite) != 0) {
		[_commandBuffer hakiosWriteShadowAtCompletion:texture];
	}
	if (texture != nil && index + 1 > _highestTexture) {
		_highestTexture = (unsigned)index + 1;
	}
}

- (void)setTextures:(const id *)textures withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setTexture:textures[i] atIndex:range.location + i];
	}
}

- (void)setSamplerState:(id)sampler atIndex:(NSUInteger)index
{
	if (index >= HM_MAX_SAMPLERS) {
		hm_print("refused: sampler index %lu is past Metal's table of %d\n", (unsigned long)index, HM_MAX_SAMPLERS);
		snprintf(_refused, sizeof(_refused), "a sampler index past %d", HM_MAX_SAMPLERS);
		return;
	}
	if (sampler != nil && ![sampler isKindOfClass:[HakiosMetalSamplerState class]]) {
		hm_print("refused: the sampler at index %lu is a %s, not a sampler state of this device\n", (unsigned long)index,
			 class_getName(object_getClass(sampler)));
		snprintf(_refused, sizeof(_refused), "the sampler at index %lu is not this device's", (unsigned long)index);
		return;
	}
	[sampler retain];
	[_samplers[index] release];
	_samplers[index] = sampler;
	if (sampler != nil && index + 1 > _highestSampler) {
		_highestSampler = (unsigned)index + 1;
	}
}

- (void)setSamplerStates:(const id *)samplers withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setSamplerState:samplers[i] atIndex:range.location + i];
	}
}

/* The LOD clamps narrow a sampler's range per binding; on this GPU they are TEX_SAMP_1's MIN_LOD/MAX_LOD (Mesa
 * fd6_texture.cc:285-286), which hakios-metal computes once per sampler state and the C interface takes no per-binding
 * variant of yet. So the sampler is bound as made, and the clamps are applied only when they ask for nothing the default
 * does not already give: a minimum of 0 and a maximum at or beyond 1000 (Metal's FLT_MAX default, far past any level a
 * one-level texture has). Anything narrower is said once, not silently dropped. */
- (void)setSamplerState:(id)sampler lodMinClamp:(float)lodMinClamp lodMaxClamp:(float)lodMaxClamp atIndex:(NSUInteger)index
{
	if (!(lodMinClamp == 0.0f && lodMaxClamp >= 1000.0f)) {
		HM_ONCE("a sampler was bound with LOD clamps %g..%g at index %lu; this plug-in binds the sampler as it was made and "
			"does NOT apply per-binding clamps yet (the textures here have one level, which the clamps could only hide)\n",
			(double)lodMinClamp, (double)lodMaxClamp, (unsigned long)index);
	}
	[self setSamplerState:sampler atIndex:index];
}

- (void)setSamplerStates:(const id *)samplers lodMinClamps:(const float *)lodMinClamps lodMaxClamps:(const float *)lodMaxClamps withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setSamplerState:samplers[i] lodMinClamp:lodMinClamps[i] lodMaxClamp:lodMaxClamps[i] atIndex:range.location + i];
	}
}

/*
 * Threadgroup memory a kernel declares without a size, for the encoder to supply ([[threadgroup(n)]] with no bound).
 * Index 0 is the argument the front end places past the kernel's static arrays, and each dispatch that follows is
 * given that much past them (hakios_metal_cb_set_threadgroup_length). A second index would start where the first one's
 * length ends, a layout the front end does not make, so a real length there fails the encoder's dispatches rather than
 * have the kernel read memory nobody gave it. (The compositor sends this for its display-dimming kernel.)
 */
- (void)setThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index
{
	if (index == 0) {
		_threadgroupLength = length;
		return;
	}
	if (length != 0) {
		hm_print("refused: %lu bytes of threadgroup memory at index %lu: one threadgroup argument (index 0) is served; "
			 "this encoder's dispatches are failed\n", (unsigned long)length, (unsigned long)index);
		snprintf(_refused, sizeof(_refused), "%lu bytes of dynamic threadgroup memory at index %lu cannot be given",
			 (unsigned long)length, (unsigned long)index);
	}
}

- (void)dispatchThreadgroups:(MTLSize)groups threadsPerThreadgroup:(MTLSize)threads
{
	[self hakiosDispatch:groups indirect:nil offset:0 threads:threads];
}

/* both dispatches: GROUPS, or (ARGS not nil) the counts three words at OFFSET of ARGS, read by the GPU as it runs */
- (void)hakiosDispatch:(MTLSize)groups indirect:(id)args offset:(NSUInteger)offset threads:(MTLSize)threads
{
	hakios_metal_cb *cb = [_commandBuffer hakiosCommandBuffer];
	hakios_metal_buffer *buffers[HM_MAX_BUFFERS];
	uint64_t offsets[HM_MAX_BUFFERS];
	hakios_metal_texture *textures[HM_MAX_TEXTURES];
	hakios_metal_sampler *samplers[HM_MAX_SAMPLERS];
	const unsigned g[3] = { (unsigned)groups.width, (unsigned)groups.height, (unsigned)groups.depth };
	const unsigned t[3] = { (unsigned)threads.width, (unsigned)threads.height, (unsigned)threads.depth };

	if (_pipeline == nil) {
		hm_print("refused: a dispatch with no pipeline state; the command buffer is failed\n");
		hakios_metal_cb_refuse(cb, "a dispatch with no pipeline state");
		return;
	}
	if (_refused[0] != '\0') {
		hm_print("refused: this dispatch, because %s; the command buffer is failed\n", _refused);
		hakios_metal_cb_refuse(cb, _refused);
		return;
	}
	for (unsigned i = 0; i < _highest; i++) {
		buffers[i] = _buffers[i] != nil ? [_buffers[i] hakiosBuffer] : NULL;
		[_buffers[i] hakiosUsedBy:[_commandBuffer hakiosUseSeq]];
		offsets[i] = _offsets[i];
	}
	for (unsigned i = 0; i < _highestTexture; i++) {
		textures[i] = _textures[i] != nil ? [_textures[i] hakiosTexture] : NULL;
		[_textures[i] hakiosUsedBy:[_commandBuffer hakiosUseSeq]];
	}
	if (hm_handoff_on()) {
		hakios_metal_kernel *kernel = [_pipeline hakiosKernel];
		for (unsigned i = 0; i < hakios_metal_kernel_resource_count(kernel); i++) {
			unsigned kind, index, type, access;
			hakios_metal_kernel_resource(kernel, i, &kind, &index, NULL);
			if (hakios_metal_kernel_resource_texture(kernel, i, &type, NULL, &access) != 0 || type == ~0u || index >= _highestTexture) continue;
			if (access & 1) [_commandBuffer hakiosTrackTexture:_textures[index] write:NO];
			if (access & 2) [_commandBuffer hakiosTrackTexture:_textures[index] write:YES];
		}
	}
	for (unsigned i = 0; i < _highestSampler; i++) {
		samplers[i] = _samplers[i] != nil ? [_samplers[i] hakiosSampler] : NULL;
	}
	/* hakios-metal judges the bindings against the kernel's own declaration (a missing buffer, texture or sampler, an
	 * offset that is not a multiple of 4, a size the metadata contradicts, a texture whose format is not the kernel's
	 * element class or that was made without write usage where the kernel writes) and refuses by name; the command
	 * buffer then ends in error with that sentence, and it is printed here as well. The arrays go up to their
	 * watermarks: an entry past what the kernel declares is ignored there, as Metal ignores it. */
	hakios_metal_cb_set_threadgroup_length(cb, (unsigned)_threadgroupLength);
	if (args != nil && ![args respondsToSelector:@selector(hakiosBuffer)]) {
		hm_print("refused: an indirect dispatch whose argument buffer is not this device's; the command buffer is failed\n");
		hakios_metal_cb_refuse(cb, "an indirect dispatch's argument buffer from another device");
		return;
	}
	if (args != nil ? hakios_metal_cb_dispatch_indirect(cb, [_pipeline hakiosKernel], [(HakiosMetalBuffer *)args hakiosBuffer], (uint64_t)offset, t,
							    buffers, offsets, _highest, textures, _highestTexture, samplers, _highestSampler) != 0
			: hakios_metal_cb_dispatch2(cb, [_pipeline hakiosKernel], g, t, buffers, offsets, _highest, textures, _highestTexture,
						    samplers, _highestSampler) != 0) {
		hm_print("refused: a dispatch of %s over %ux%ux%u groups of %ux%ux%u with %u buffer, %u texture and %u sampler slots: %s\n",
			 hakios_metal_kernel_name([_pipeline hakiosKernel]), g[0], g[1], g[2], t[0], t[1], t[2], _highest, _highestTexture,
			 _highestSampler, hakios_metal_error());
		hakios_metal_cb_refuse(cb, hakios_metal_error());
	}
}

/* Metal counts threads here and threadgroups above; a grid that does not divide evenly is refused rather than rounded,
 * because rounding would run threads the application did not ask for (hakios-metal has no partial-group support) */
- (void)dispatchThreads:(MTLSize)threads threadsPerThreadgroup:(MTLSize)size
{
	MTLSize groups;

	if (size.width == 0 || size.height == 0 || size.depth == 0 || threads.width % size.width != 0 ||
	    threads.height % size.height != 0 || threads.depth % size.depth != 0) {
		hm_print("refused: %lux%lux%lu threads do not divide into groups of %lux%lux%lu; the command buffer is failed\n",
			 (unsigned long)threads.width, (unsigned long)threads.height, (unsigned long)threads.depth,
			 (unsigned long)size.width, (unsigned long)size.height, (unsigned long)size.depth);
		hakios_metal_cb_refuse([_commandBuffer hakiosCommandBuffer], "a thread grid that does not divide into its threadgroups");
		return;
	}
	groups = MTLSizeMake(threads.width / size.width, threads.height / size.height, threads.depth / size.depth);
	[self dispatchThreadgroups:groups threadsPerThreadgroup:size];
}

/* An indirect dispatch reads its grid out of GPU memory as it runs (CP_EXEC_CS_INDIRECT): an earlier dispatch may
 * write it, so nothing here reads it; the core copies it where the kernel's own grid constants load from */
- (void)dispatchThreadgroupsWithIndirectBuffer:(id)buffer indirectBufferOffset:(NSUInteger)offset threadsPerThreadgroup:(MTLSize)size
{
	[self hakiosDispatch:MTLSizeMake(0, 0, 0) indirect:buffer offset:offset threads:size];
}

/*
 * Served by construction, every one of these: hakios-metal invalidates the GPU's caches before each dispatch and
 * flushes them after it, one queue runs its command buffers in commit order, and every allocation is resident for its
 * whole life. A barrier, a fence or a residency request asks for an ordering that is already the only one there is.
 */
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope { (void)scope; }
- (void)memoryBarrierWithResources:(const id *)resources count:(NSUInteger)count { (void)resources; (void)count; }
- (void)updateFence:(id)fence  { (void)fence; [_commandBuffer hakiosRequireSync:HAKIOS_METAL_DRAIN_CPU_SYNC]; }
- (void)waitForFence:(id)fence { (void)fence; [_commandBuffer hakiosRequireSync:HAKIOS_METAL_DRAIN_CPU_SYNC]; }
- (void)useResource:(id)resource usage:(MTLResourceUsage)usage { (void)resource; (void)usage; }
- (void)useResources:(const id *)resources count:(NSUInteger)count usage:(MTLResourceUsage)usage { (void)resources; (void)count; (void)usage; }
- (void)useHeap:(id)heap { (void)heap; }
- (void)useHeaps:(const id *)heaps count:(NSUInteger)count { (void)heaps; (void)count; }

/* abstract in _MTLCommandEncoder (inheriting it aborts); a packing hint the compiler decides for itself here */
- (void)setThreadgroupPackingDisabled:(BOOL)disabled { (void)disabled; }

/* The three the AGX compute context answers and <MTLComputeCommandEncoderSPI> declares (a protocol not in this
 * process): substreams are an Apple GPU's several independent streams, ordered by progress counters. There is one
 * stream here, replayed in record order, so selecting another cannot move work, a signal has nobody to reach and a
 * wait is already satisfied -- stricter ordering than asked for, which is the safe direction. A non-zero substream is
 * the case where that argument stops being true, hence the line. */
- (void)setSubstream:(unsigned)substream
{
	if (substream != 0) {
		HM_ONCE("a dispatch was directed to substream %u; one stream here, so it runs in record order instead\n", substream);
	}
}
- (void)signalProgress:(unsigned)value { (void)value; }
- (void)waitForProgress:(unsigned)value { (void)value; }

/* function tables, acceleration structures, stage-in regions, imageblocks and indirect command buffers are declared by
 * <MTLComputeCommandEncoder> and refused through -forwardInvocation: above, by name */

- (void)endEncoding
{
	/* the bindings were handed to hakios-metal at each dispatch, which holds them until the GPU is done */
	[_scratch release];
	_scratch = nil;
	[super endEncoding];   /* MUST: the base class retains the command buffer and this is what releases it */
}

@end

/* ============================================================================================================
 * The render pipeline state: one linked vertex + fragment program
 * ============================================================================================================ */

@implementation HakiosMetalRenderPipelineState

/* the base declares the public protocol itself; declared again so that a conformsToProtocol: is a static yes whatever
 * this Metal's adoption list says, as the sampler does */
+ (void)load
{
	hm_adopt(self, @protocol(MTLRenderPipelineState), "MTLRenderPipelineState");
}

/* boot-arg metal_trace_release (a diagnostic): the release that frees a render pipeline state says so, with its label
 * and who called -- each frame as its image and the offset in it, for the host to name (ipsw dyld a2s). A state freed
 * while a client still draws with it is otherwise seen only as some other object at its address. */
- (oneway void)release
{
	static int traced = -1;

	if (traced < 0) {
		char args[1024] = {0};
		size_t size = sizeof(args) - 1;
		traced = sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "metal_trace_release") != NULL;
	}
	if (traced && [self retainCount] == 1) {
		char what[128];
		NSString *label = [(id<MTLRenderPipelineState>)self label];
		snprintf(what, sizeof(what), "trace: freeing render pipeline state %p \"%s\":", (void *)self,
			 label != nil ? [label UTF8String] : "-");
		hm_print_callers(what);
	}
	[super release];
}

HM_REFUSES_OUT_LOUD

/* AppleMetalGLRenderer's shader debug info (with -[device setShaderDebugInfoCaching:YES], a GL renderer property): Apple's
 * compiler's; there is none here */
- (id)newVertexShaderDebugInfo   { return nil; }
- (id)newFragmentShaderDebugInfo { return nil; }

- (instancetype)initWithHakiosDevice:(HakiosMetalDevice *)device program:(hakios_metal_program *)program
			  descriptor:(MTLRenderPipelineDescriptor *)descriptor
{
	/* the designated initialiser, given a descriptor -newRenderPipelineStateWithDescriptor:error: has already checked
	 * (non-nil, the right class, no tessellation-with-ICB): it keeps the label (copied) and the device, reads
	 * supportIndirectCommandBuffers, textureWriteRoundingMode and meshFunction (nil here), and answers <MTLRenderPipelineState> from them */
	self = [super initWithDevice:device pipelineStateDescriptor:descriptor];
	if (self == nil) {
		hakios_metal_program_free(program);
		return nil;
	}
	_hakiosDevice = [device retain];
	_program = program;
	/* no buffer decides this pipeline's program until -hakiosKeepFragment: says one does. Left at the allocator's 0, every
	 * draw of a pipeline it was never called for (the exact CA ones: fixed_vert_lph_spc+fixed_frag_lph_cph, 611 draws in
	 * logs/test-1111-100715-umi-v21) queued a specialisation with no bitcode that failed and printed a line */
	_specBinding = -1;
	_hakiosUniqueIdentifier = hm_next_resource_id();
	return self;
}

- (void)dealloc
{
	for (id v in [_specialised objectEnumerator]) {
		if ([v isKindOfClass:[NSValue class]]) hakios_metal_program_free((hakios_metal_program *)[v pointerValue]);
	}
	[_specialised release];
	[_fsAir release];
	if (_program != NULL) {
		hakios_metal_program_free(_program);   /* a draw in flight keeps its own reference */
	}
	[_hakiosDevice release];
	[super dealloc];
}

- (hakios_metal_program *)hakiosProgram { return _program; }

/* boot-arg metal_nospec: every draw with the pipeline's own program, no uber shader specialised */
static BOOL
hm_spec_off(void)
{
	static int off = -1;

	if (off < 0) {
		char args[1024] = {0};
		size_t size = sizeof(args) - 1;

		off = sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "metal_nospec") != NULL;
	}
	return off != 0;
}

/* An uber shader -- a fragment stage of thousands of instructions that reads a small constant buffer -- takes its path
 * through them by that buffer's bytes in every fragment: CoreAnimation's fixed_frag_lph_cpf is 15 000 instructions and
 * one of its draws took 9.6 ms over 1.2 million pixels with its textures' reads gone or not, when the path its
 * configuration takes is 16 to 48 instructions. Such a pipeline keeps its fragment function so that a program can be
 * compiled for each content of the buffer (hakios_metal_program_specialize). */
- (void)hakiosKeepFragment:(NSData *)air constants:(const hakios_metal_constant *)constants count:(unsigned)count
{
	_specBinding = -1;
	if (hm_spec_off() || hakios_metal_program_stage_words(_program, 1) < 4096) return;
	for (unsigned i = 0; i < hakios_metal_program_resource_count(_program, 1); i++) {
		unsigned kind, index, size;

		if (hakios_metal_program_resource(_program, 1, i, &kind, &index, &size) == 0 && kind == HAKIOS_METAL_RESOURCE_CONSTANT_BUFFER &&
		    size != 0 && size <= 256 && (_specBinding < 0 || (unsigned)index < (unsigned)_specBinding)) {
			_specBinding = (int)index;
			_specLength = size;
		}
	}
	if (_specBinding < 0) return;
	hakios_metal_program_constant_reads(_program, 1, (unsigned)_specBinding, _specMask, _specLength);
	_fsAir = [air retain];
	_fsConstantCount = count < 64 ? count : 64;
	memcpy(_fsConstants, constants, _fsConstantCount * sizeof(*constants));
	_specialised = [[NSMutableDictionary alloc] init];
}

/* the program for a draw whose fragment buffers are BUFFERS: the one compiled for what the deciding buffer holds, or
 * the pipeline's own while that one compiles (on a queue of its own: a compilation is 0.4 s on the host, and a frame
 * must not wait for it). 64 contents at most a pipeline; past them the pipeline's own. A content seen for the first time
 * whose stage an earlier boot compiled (the stage cache in /var/db, or the image's seed) is taken from there at once,
 * here: queued, it waited behind the queue's real compiles (200 to 380 ms each) while its draws ran the 31 000-word uber
 * shader -- the 33 to 39 ms passes of the windows with specialisations in v21. */
- (hakios_metal_program *)hakiosProgramFor:(hakios_metal_buffer *const *)buffers offsets:(const uint64_t *)offsets count:(unsigned)count
{
	static dispatch_queue_t compiling;
	static dispatch_once_t once;

	if (_specBinding < 0 || (unsigned)_specBinding >= count || buffers[_specBinding] == NULL) return _program;
	const uint8_t *bytes = (const uint8_t *)hakios_metal_buffer_contents(buffers[_specBinding]);
	const uint64_t length = hakios_metal_buffer_length(buffers[_specBinding]), at = offsets[_specBinding];
	if (bytes == NULL || at > length || length - at < _specLength) return _program;
	/* the bytes the stage never reads (CoreAnimation's FragmentShaderConfig: 18 of its 52, padding) are whatever the
	 * buffer held before: in the key they made one configuration many, compiled again every boot under new names */
	uint8_t content[256];
	for (unsigned i = 0; i < _specLength; i++) content[i] = bytes[at + i] & _specMask[i];
	NSData *key = [NSData dataWithBytes:content length:_specLength];
	hakios_metal_program *found = _program;
	BOOL start = NO;

	@synchronized(self) {
		id have = [_specialised objectForKey:key];

		if ([have isKindOfClass:[NSValue class]]) {
			found = (hakios_metal_program *)[have pointerValue];
		} else if (have == nil && [_specialised count] < 64) {
			[_specialised setObject:[NSNull null] forKey:key];
			start = YES;
		}
	}
	if (start) {
		hakios_metal_program *cached = hakios_metal_program_specialize_cached(_program, [_fsAir bytes], [_fsAir length], _fsConstants,
										      _fsConstantCount, (unsigned)_specBinding, [key bytes], _specMask,
										      [key length]);

		if (cached != NULL) {
			@synchronized(self) {
				[_specialised setObject:[NSValue valueWithPointer:cached] forKey:key];
			}
			if (hm_fps_on()) hm_print("specialise: %s from the stage cache at its first draw\n", hakios_metal_program_name(_program));
			return cached;
		}
		dispatch_once(&once, ^{
			compiling = dispatch_queue_create("hakios.metal.specialise",
				dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
		});
		[self retain];
		dispatch_async(compiling, ^{
			@autoreleasepool {
				struct timespec t0, t1;

				const bool previousPriority = hakios_metal_compiler_set_background(true);
				clock_gettime(CLOCK_MONOTONIC, &t0);
				hakios_metal_program *p = hakios_metal_program_specialize(_program, [_fsAir bytes], [_fsAir length], _fsConstants, _fsConstantCount,
											 (unsigned)_specBinding, [key bytes], _specMask, [key length]);
				hakios_metal_compiler_set_background(previousPriority);
				clock_gettime(CLOCK_MONOTONIC, &t1);
				if (p == NULL) {
					hm_print("specialise: %s for its buffer %d: %s; its own program goes on\n", hakios_metal_program_name(_program), _specBinding,
						 hakios_metal_error());
				} else if (hm_fps_on()) {
					unsigned read = 0;

					for (unsigned i = 0; i < _specLength; i++) read += _specMask[i] != 0;
					hm_print("specialise: %s for %u bytes (%u read) of its buffer %d: %u instruction words, not %u, in %.0f ms\n",
						 hakios_metal_program_name(_program), _specLength, read, _specBinding, hakios_metal_program_stage_words(p, 1),
						 hakios_metal_program_stage_words(_program, 1),
						 (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6);
				}
				@synchronized(self) {
					if (p != NULL) [_specialised setObject:[NSValue valueWithPointer:p] forKey:key];
				}
				[self release];
			}
		});
	}
	return found;
}

/* The base's uniqueIdentifier is a nil-stub and its gpuResourceID is the resourceIndex ivar (0): a pipeline would be
 * told apart from every other by nothing. Answered from the textures' counter, for the same reason (never 0, never an
 * address). Matters only to argument buffers and indirect command buffers, neither of which is here. */
- (uint64_t)uniqueIdentifier { return _hakiosUniqueIdentifier; }

- (MTLResourceID)gpuResourceID
{
	MTLResourceID rid = { _hakiosUniqueIdentifier };

	return rid;
}

@end

/* ============================================================================================================
 * The render encoder: one colour attachment, state by value, each draw one pass of hakios-metal's
 * ============================================================================================================ */

@implementation HakiosMetalRenderCommandEncoder

/* The public protocol is defined only in the AGX bundle on this phone (as MTLComputeCommandEncoder is); the @protocol()
 * reference compiles it into this image, and the catch-all finds every member's encoding through it. */
+ (void)load
{
	hm_adopt(self, @protocol(MTLRenderCommandEncoder), "MTLRenderCommandEncoder");
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
	NSMethodSignature *s = [super methodSignatureForSelector:sel];

	return s != nil ? s : hm_protocol_signature([self class], sel);
}

/* A refused binding or state (tile buffers, function tables, imageblocks ...) is remembered and the next draw is FAILED
 * by it, as the compute encoder does: a pass drawn without one of its inputs draws something, and that something would
 * look like a result. */
- (void)forwardInvocation:(NSInvocation *)invocation
{
	hm_forward(self, invocation);
	if (_refused[0] == '\0') {
		snprintf(_refused, sizeof(_refused), "-%s was refused on this encoder", sel_getName([invocation selector]));
	}
}

/* Reached for the 34 methods _MTLCommandEncoder declares ABSTRACT (their bodies are doesNotRecognizeSelector:): the
 * object and mesh stage setters, invalidateCompressedTexture: and setThreadgroupPackingDisabled: (overridden below).
 * They are members of <MTLRenderCommandEncoder>, so the usual sentence would be false; this one says what they are. */
- (void)doesNotRecognizeSelector:(SEL)sel
{
	hm_refusal(self, sel, hm_protocol_signature([self class], sel) != nil
			       ? "is abstract in Metal's _MTLCommandEncoder (an object/mesh stage or compressed-texture method); "
				 "mesh shading is not served here, and it raises as Metal's own body does"
			       : "is declared by no protocol in this process and implemented by nothing in its class chain; it raises");
	[super doesNotRecognizeSelector:sel];
}

- (instancetype)initWithHakiosCommandBuffer:(HakiosMetalCommandBuffer *)commandBuffer pass:(const struct hakios_metal_render_pass *)pass
			       colorTexture:(HakiosMetalTexture *)texture
{
	return [self initWithHakiosCommandBuffer:commandBuffer pass:pass colorTexture:texture sub:NULL];
}

/* where this encoder's work is recorded: the command buffer's, or a sub-encoder's own */
- (hakios_metal_cb *)hakiosCb
{
	return _sub != NULL ? _sub : [_commandBuffer hakiosCommandBuffer];
}

- (instancetype)initWithHakiosCommandBuffer:(HakiosMetalCommandBuffer *)commandBuffer pass:(const struct hakios_metal_render_pass *)pass
			       colorTexture:(HakiosMetalTexture *)texture sub:(hakios_metal_cb *)sub
{
	self = [super initWithCommandBuffer:commandBuffer];   /* retains the buffer; -endEncoding gives it back */
	if (self == nil) {
		return nil;
	}
	_commandBuffer = commandBuffer;
	_sub = sub;
	_colorTexture = [texture retain];
	_pass = *pass;
	_frontFacingWinding = MTLWindingClockwise;   /* Metal's default */
	return self;
}

- (void)hakiosSetYInvertWidth:(unsigned)width height:(unsigned)height
{
	_flipWidth = width;
	_flipHeight = width != 0 ? height : 0;
}

- (void)hakiosTakeResolves:(MTLRenderPassDescriptor *)descriptor
{
	for (NSUInteger i = 0; i < 8; i++) {
		MTLRenderPassColorAttachmentDescriptor *c = [[descriptor colorAttachments] objectAtIndexedSubscript:i];
		MTLStoreAction a = [c storeAction];

		if (c == nil || [c texture] == nil || [c resolveTexture] == nil) {
			continue;
		}
		_resolveFrom[i] = [(HakiosMetalTexture *)[c texture] retain];
		_resolveTo[i] = [(HakiosMetalTexture *)[c resolveTexture] retain];
		_resolveLevel[i] = (unsigned)[c resolveLevel];
		_resolving[i] = a == MTLStoreActionMultisampleResolve || a == MTLStoreActionStoreAndMultisampleResolve || a == MTLStoreActionUnknown;
	}
}

- (void)dealloc
{
	for (unsigned i = 0; i < 8; i++) {
		[_resolveFrom[i] release];
		[_resolveTo[i] release];
	}
	[_colorTexture release];
	[_pipeline release];
	for (unsigned i = 0; i < HM_MAX_BUFFERS; i++) {
		[_vsBuffers[i] release];
		[_fsBuffers[i] release];
	}
	for (unsigned i = 0; i < HM_MAX_TEXTURES; i++) {
		[_fsTextures[i] release];
		[_vsTextures[i] release];
	}
	for (unsigned i = 0; i < HM_MAX_SAMPLERS; i++) {
		[_fsSamplers[i] release];
		[_vsSamplers[i] release];
	}
	[_scratch release];
	[_visibilityCounted release];
	[super dealloc];
}

- (id)device { return [_commandBuffer device]; }

/* --- the pipeline --- */

- (void)setRenderPipelineState:(id)state
{
	if (state != nil && ![state isKindOfClass:[HakiosMetalRenderPipelineState class]]) {
		static int told;
		char what[160];
		snprintf(what, sizeof(what), "refused: a render pipeline state %p of class %s is not this device's:", (void *)state,
			 class_getName(object_getClass(state)));
		if (told++ < 4) hm_print_callers(what);
		else hm_print("%s\n", what);
		snprintf(_refused, sizeof(_refused), "the render pipeline state is not this device's");
		return;
	}
	[state retain];
	[_pipeline release];
	_pipeline = state;
}

/* --- viewport and scissor: stored, handed to the draw; unset means the whole attachment (znear 0, zfar 1) --- */

- (void)setViewport:(MTLViewport)viewport
{
	_viewport.x = viewport.originX;
	_viewport.y = viewport.originY;
	_viewport.width = viewport.width;
	_viewport.height = viewport.height;
	_viewport.znear = viewport.znear;
	_viewport.zfar = viewport.zfar;
	_hasViewport = YES;
}

- (void)setViewports:(const MTLViewport *)viewports count:(NSUInteger)count
{
	if (count != 1 || viewports == NULL) {
		hm_print("refused: %lu viewports; one viewport is served (no viewport arrays, no layer/viewport index output); the next draw is failed\n",
			 (unsigned long)count);
		snprintf(_refused, sizeof(_refused), "%lu viewports were set; one is served", (unsigned long)count);
		return;
	}
	[self setViewport:viewports[0]];
}

- (void)setScissorRect:(MTLScissorRect)rect
{
	_scissor.x = (unsigned)rect.x;
	_scissor.y = (unsigned)rect.y;
	_scissor.width = (unsigned)rect.width;
	_scissor.height = (unsigned)rect.height;
	_hasScissor = YES;
}

- (void)setScissorRects:(const MTLScissorRect *)rects count:(NSUInteger)count
{
	if (count != 1 || rects == NULL) {
		hm_print("refused: %lu scissor rectangles; one is served; the next draw is failed\n", (unsigned long)count);
		snprintf(_refused, sizeof(_refused), "%lu scissor rectangles were set; one is served", (unsigned long)count);
		return;
	}
	[self setScissorRect:rects[0]];
}

/* --- the buffer tables, one per stage, stored by index as the compute encoder stores its own --- */

/* a buffer of this device at INDEX of TABLE, or the reason it cannot be; nil unbinds */
- (void)hakiosBind:(id)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index stage:(const char *)stage
	     table:(HakiosMetalBuffer **)table offsets:(uint64_t *)offsets highest:(unsigned *)highest
{
	if (index >= HM_MAX_BUFFERS) {
		hm_print("refused: %s buffer index %lu is past Metal's table of %d\n", stage, (unsigned long)index, HM_MAX_BUFFERS);
		snprintf(_refused, sizeof(_refused), "a %s buffer index past %d", stage, HM_MAX_BUFFERS);
		return;
	}
	if (buffer != nil && ![buffer isKindOfClass:[HakiosMetalBuffer class]]) {
		hm_print("refused: the %s buffer at index %lu is a %s, not a buffer of this device\n", stage, (unsigned long)index,
			 class_getName(object_getClass(buffer)));
		snprintf(_refused, sizeof(_refused), "the %s buffer at index %lu is not this device's", stage, (unsigned long)index);
		return;
	}
	[buffer retain];
	[table[index] release];
	table[index] = buffer;
	offsets[index] = offset;
	if (buffer != nil && index + 1 > *highest) {
		*highest = (unsigned)index + 1;
	}
}

- (void)setVertexBuffer:(id)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	[self hakiosBind:buffer offset:offset atIndex:index stage:"vertex" table:_vsBuffers offsets:_vsOffsets highest:&_vsHighest];
}

- (void)setFragmentBuffer:(id)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	[self hakiosBind:buffer offset:offset atIndex:index stage:"fragment" table:_fsBuffers offsets:_fsOffsets highest:&_fsHighest];
}

/* Metal's rule: this moves a buffer already bound at the index, so with nothing bound there is nothing to move */
- (void)setVertexBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	if (index < HM_MAX_BUFFERS && _vsBuffers[index] != nil) {
		_vsOffsets[index] = offset;
	}
}

- (void)setFragmentBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	if (index < HM_MAX_BUFFERS && _fsBuffers[index] != nil) {
		_fsOffsets[index] = offset;
	}
}

- (void)setVertexBuffers:(const id *)buffers offsets:(const NSUInteger *)offsets withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setVertexBuffer:buffers[i] offset:offsets[i] atIndex:range.location + i];
	}
}

- (void)setFragmentBuffers:(const id *)buffers offsets:(const NSUInteger *)offsets withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setFragmentBuffer:buffers[i] offset:offsets[i] atIndex:range.location + i];
	}
}

/* Metal's shorthand for small constant data: a buffer here, because that is what a stage's binding is. The scratch buffer
 * is the encoder's until -endEncoding; hakios-metal keeps it alive past that until the GPU is done with it. */
- (HakiosMetalBuffer *)hakiosScratch:(const void *)bytes length:(NSUInteger)length stage:(const char *)stage index:(NSUInteger)index
{
	HakiosMetalBuffer *buffer = [[self device] newBufferWithBytes:bytes length:length options:0];

	if (buffer == nil) {
		snprintf(_refused, sizeof(_refused), "no scratch buffer for %lu %s bytes at index %lu", (unsigned long)length, stage, (unsigned long)index);
		return nil;
	}
	if (_scratch == nil) {
		_scratch = [[NSMutableArray alloc] init];
	}
	[_scratch addObject:buffer];
	[buffer release];
	return buffer;
}

- (void)setVertexBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index
{
	HakiosMetalBuffer *buffer = [self hakiosScratch:bytes length:length stage:"vertex" index:index];

	if (buffer != nil) {
		[self setVertexBuffer:buffer offset:0 atIndex:index];
	}
}

- (void)setFragmentBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index
{
	HakiosMetalBuffer *buffer = [self hakiosScratch:bytes length:length stage:"fragment" index:index];

	if (buffer != nil) {
		[self setFragmentBuffer:buffer offset:0 atIndex:index];
	}
}

/* --- textures and samplers in a render stage: the fragment stage's go to the draw calls (SB6_FS_TEX, the prefetch), the
 * vertex stage's to hakios_metal_cb_set_vertex_textures before each draw (SB6_VS_TEX); one path for both --- */
- (void)hakiosSetTexture:(id)texture atIndex:(NSUInteger)index vertex:(BOOL)vertex
{
	const char *stage = vertex ? "vertex" : "fragment";
	if (index >= HM_MAX_TEXTURES) {
		hm_print("refused: %s texture index %lu is past Metal's table of %d\n", stage, (unsigned long)index, HM_MAX_TEXTURES);
		snprintf(_refused, sizeof(_refused), "a %s texture index past %d", stage, HM_MAX_TEXTURES);
		return;
	}
	if (texture != nil && ![texture isKindOfClass:[HakiosMetalTexture class]]) {
		hm_print("refused: the %s texture at index %lu is a %s, not a texture of this device\n", stage, (unsigned long)index,
			 class_getName(object_getClass(texture)));
		snprintf(_refused, sizeof(_refused), "the %s texture at index %lu is not this device's", stage, (unsigned long)index);
		return;
	}
	HakiosMetalTexture **table = vertex ? _vsTextures : _fsTextures;
	unsigned *highest = vertex ? &_vsHighestTexture : &_fsHighestTexture;
	[texture retain];
	[table[index] release];
	table[index] = texture;
	[(HakiosMetalTexture *)texture hakiosRefreshShadow];
	[_commandBuffer hakiosTrackSample:texture];   /* a surface another buffer may still be writing back */
	if (texture != nil && index + 1 > *highest) {
		*highest = (unsigned)index + 1;
	}
}
- (void)hakiosSetSampler:(id)sampler atIndex:(NSUInteger)index vertex:(BOOL)vertex
{
	const char *stage = vertex ? "vertex" : "fragment";
	if (index >= HM_MAX_SAMPLERS) {
		hm_print("refused: %s sampler index %lu is past Metal's table of %d\n", stage, (unsigned long)index, HM_MAX_SAMPLERS);
		snprintf(_refused, sizeof(_refused), "a %s sampler index past %d", stage, HM_MAX_SAMPLERS);
		return;
	}
	if (sampler != nil && ![sampler isKindOfClass:[HakiosMetalSamplerState class]]) {
		hm_print("refused: the %s sampler at index %lu is a %s, not a sampler state of this device\n", stage, (unsigned long)index,
			 class_getName(object_getClass(sampler)));
		snprintf(_refused, sizeof(_refused), "the %s sampler at index %lu is not this device's", stage, (unsigned long)index);
		return;
	}
	HakiosMetalSamplerState **table = vertex ? _vsSamplers : _fsSamplers;
	unsigned *highest = vertex ? &_vsHighestSampler : &_fsHighestSampler;
	[sampler retain];
	[table[index] release];
	table[index] = sampler;
	if (sampler != nil && index + 1 > *highest) {
		*highest = (unsigned)index + 1;
	}
}
- (void)setVertexTexture:(id)texture atIndex:(NSUInteger)index           { [self hakiosSetTexture:texture atIndex:index vertex:YES]; }
- (void)setFragmentTexture:(id)texture atIndex:(NSUInteger)index         { [self hakiosSetTexture:texture atIndex:index vertex:NO]; }
- (void)setVertexSamplerState:(id)sampler atIndex:(NSUInteger)index      { [self hakiosSetSampler:sampler atIndex:index vertex:YES]; }
- (void)setFragmentSamplerState:(id)sampler atIndex:(NSUInteger)index    { [self hakiosSetSampler:sampler atIndex:index vertex:NO]; }

- (void)setVertexSamplerState:(id)sampler lodMinClamp:(float)lodMinClamp lodMaxClamp:(float)lodMaxClamp atIndex:(NSUInteger)index
{
	(void)lodMinClamp; (void)lodMaxClamp;
	[self setVertexSamplerState:sampler atIndex:index];
}

- (void)setFragmentSamplerState:(id)sampler lodMinClamp:(float)lodMinClamp lodMaxClamp:(float)lodMaxClamp atIndex:(NSUInteger)index
{
	(void)lodMinClamp; (void)lodMaxClamp;
	[self setFragmentSamplerState:sampler atIndex:index];
}

- (void)setVertexTextures:(const id *)textures withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setVertexTexture:textures[i] atIndex:range.location + i];
	}
}

- (void)setFragmentTextures:(const id *)textures withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setFragmentTexture:textures[i] atIndex:range.location + i];
	}
}

- (void)setVertexSamplerStates:(const id *)samplers withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setVertexSamplerState:samplers[i] atIndex:range.location + i];
	}
}

- (void)setFragmentSamplerStates:(const id *)samplers withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setFragmentSamplerState:samplers[i] atIndex:range.location + i];
	}
}

- (void)setVertexSamplerStates:(const id *)samplers lodMinClamps:(const float *)lodMinClamps lodMaxClamps:(const float *)lodMaxClamps withRange:(NSRange)range
{
	(void)lodMinClamps; (void)lodMaxClamps;
	[self setVertexSamplerStates:samplers withRange:range];
}

- (void)setFragmentSamplerStates:(const id *)samplers lodMinClamps:(const float *)lodMinClamps lodMaxClamps:(const float *)lodMaxClamps withRange:(NSRange)range
{
	(void)lodMinClamps; (void)lodMaxClamps;
	[self setFragmentSamplerStates:samplers withRange:range];
}

/* The SPI that binds a texture and its sampler in one message (QuartzCore's image passes send it): the two public
 * setters, each with its own index, as the selector's words say */
- (void)setFragmentTexture:(id)texture atTextureIndex:(NSUInteger)textureIndex samplerState:(id)sampler atSamplerIndex:(NSUInteger)samplerIndex
{
	[self setFragmentTexture:texture atIndex:textureIndex];
	[self setFragmentSamplerState:sampler atIndex:samplerIndex];
}

- (void)setVertexTexture:(id)texture atTextureIndex:(NSUInteger)textureIndex samplerState:(id)sampler atSamplerIndex:(NSUInteger)samplerIndex
{
	[self setVertexTexture:texture atIndex:textureIndex];
	[self setVertexSamplerState:sampler atIndex:samplerIndex];
}

/* --- rasterizer state: what step one fixes, said once when asked to change --- */

/* Culling and the front face: the pass struct's CULL_MODE and WINDING, which every draw after reads (hakios-metal's
 * GRAS_SU_CNTL; which winding FRONT_CW is was measured on the phone, probe 9cu) */
- (void)setCullMode:(MTLCullMode)cullMode
{
	_pass.cull_mode = (unsigned)cullMode;
}

- (void)setFrontFacingWinding:(MTLWinding)winding
{
	_frontFacingWinding = winding;
	_pass.winding = (unsigned)winding;
}

/* --- OpenGL ES's encoder SPI (AppleMetalGLRenderer sends these to Apple's encoder; each is a selector of a protocol that
 * is not in this process, so without a method here it would raise) --- */

/* NO for the renderer's own blits and clears (its default.metallib's clearVertex/texturedVertex2D over setVertexBytes):
 * the positions are window coordinates, drawn with the clipper, the viewport transform and the division off */
- (void)setViewportTransformEnabled:(BOOL)enabled
{
	_glNoTransform = !enabled;
}

/* lines are not drawn here (step one serves triangles), so their width is nothing to keep */
- (void)setLineWidth:(float)width
{
	if (width != 1.0f) {
		HM_ONCE("gles: a line width of %g; lines are not served here\n", (double)width);
	}
}

/* an indexed draw restarts at the all-ones index already (hakios-metal, as Metal has it): GL ES 3's fixed-index restart */
- (void)setPrimitiveRestartEnabled:(BOOL)enabled { (void)enabled; }

/* GL's flat varyings take a primitive's LAST vertex's value (mode 1, as the renderer sends it for GL; 0 is Metal's first):
 * PC_PRIMITIVE_CNTL_0.PROVOKING_VTX_LAST, HAKIOS_METAL_GL_PROVOKING_LAST at each draw */
- (void)setProvokingVertexMode:(NSUInteger)mode
{
	if (mode > 1) {
		HM_ONCE("gles: provoking vertex mode %lu: taken as the last vertex\n", (unsigned long)mode);
	}
	_glProvokingLast = mode != 0;
}

/* hints that the attachment was just cleared (Apple's tile memory skips a load); the load action already says it here */
- (void)setDepthCleared { }
- (void)setStencilCleared { }

/* GL ES 1's alpha test: the pipeline's flag is said not served (hakiosRenderPipelineWhy), its reference with it */
- (void)setAlphaTestReferenceValue:(float)value { (void)value; }

/* a debugging mode of Apple's command stream */
- (void)setCommandDataCorruptModeSPI:(NSUInteger)mode { (void)mode; }

/* glBlitFramebuffer's multisample resolve, named while the pass is open: resolved at -endEncoding, as a pass descriptor's
 * resolveTexture is (-hakiosTakeResolves:). Colour 0, the one attachment GL's resolves name, is served. */
- (void)setColorResolveTexture:(id)texture slice:(NSUInteger)slice depthPlane:(NSUInteger)plane level:(NSUInteger)level
		       yInvert:(BOOL)yInvert atIndex:(NSUInteger)index
{
	if (index != 0 || slice != 0 || plane != 0 || _colorTexture == nil || (texture != nil && ![texture isKindOfClass:[HakiosMetalTexture class]])) {
		hm_print("refused: a resolve into %s at colour %lu, slice %lu, plane %lu: colour 0 of a pass with one, into a texture of this "
			 "device, is served; nothing is resolved\n", texture != nil ? class_getName(object_getClass(texture)) : "nothing",
			 (unsigned long)index, (unsigned long)slice, (unsigned long)plane);
		return;
	}
	if (yInvert) {
		HM_ONCE("gles: a resolve with yInvert: resolved as it lies\n");
	}
	[_resolveTo[0] release];
	_resolveTo[0] = [(HakiosMetalTexture *)texture retain];
	if (_resolveFrom[0] == nil) _resolveFrom[0] = [_colorTexture retain];
	_resolveLevel[0] = (unsigned)level;
	_resolving[0] = texture != nil;
}

- (void)setColorResolveTexture:(id)texture slice:(NSUInteger)slice depthPlane:(NSUInteger)plane level:(NSUInteger)level atIndex:(NSUInteger)index
{
	[self setColorResolveTexture:texture slice:slice depthPlane:plane level:level yInvert:NO atIndex:index];
}

- (void)setTriangleFillMode:(MTLTriangleFillMode)fillMode
{
	if (fillMode != MTLTriangleFillModeFill) {
		hm_print("refused: triangle fill mode %lu (1 lines); VPC/PC_POLYGON_MODE are fixed at triangles in step one; the next draw is failed\n",
			 (unsigned long)fillMode);
		snprintf(_refused, sizeof(_refused), "triangle fill mode %lu is not served", (unsigned long)fillMode);
	}
}

/* Clip is Metal's default and what GRAS_CL_CNTL has (near and far clip enabled); clamping is a bit nothing sets yet */
- (void)setDepthClipMode:(MTLDepthClipMode)mode
{
	if (mode != MTLDepthClipModeClip) {
		HM_ONCE("depth clip mode %lu (clamp) was set; step one clips, and without a depth attachment the difference is not visible\n",
			(unsigned long)mode);
	}
}

/* The depth test each later draw runs (nil: Metal's default, no test). A foreign object fails the next draw by name;
 * a test with no depth attachment is hakios-metal's refusal at the draw. */
- (void)setDepthStencilState:(id)state
{
	if (state == nil) {
		_pass.depth_state_set = 0;
		_pass.stencil_state_set = 0;
		return;
	}
	if (![state isKindOfClass:[HakiosMetalDepthStencilState class]]) {
		hm_print("refused: a depth/stencil state that is a %s, not one of this device's; the next draw is failed\n", class_getName(object_getClass(state)));
		snprintf(_refused, sizeof(_refused), "a depth/stencil state that is not this device's was bound");
		return;
	}
	_pass.depth_state_set = 1;
	_pass.depth_compare = [(HakiosMetalDepthStencilState *)state hakiosDepthCompare];
	_pass.depth_write = [(HakiosMetalDepthStencilState *)state hakiosDepthWrite] ? 1 : 0;
	/* Metal ignores the stencil half on a pass with no stencil attachment; so does this, rather than fail the draw */
	_pass.stencil_state_set = [(HakiosMetalDepthStencilState *)state hakiosStencil] && _pass.stencil != NULL;
	_pass.stencil_front = *[(HakiosMetalDepthStencilState *)state hakiosStencilFront];
	_pass.stencil_back = *[(HakiosMetalDepthStencilState *)state hakiosStencilBack];
}

/* the blend colour is the encoder's state each later draw reads (the BlendColor / BlendAlpha factors) */
- (void)setBlendColorRed:(float)red green:(float)green blue:(float)blue alpha:(float)alpha
{
	_pass.blend_color[0] = red;
	_pass.blend_color[1] = green;
	_pass.blend_color[2] = blue;
	_pass.blend_color[3] = alpha;
}

/* inert given the fixed state, each said once: there is no depth and no stencil, so a depth bias or a stencil reference
 * changes nothing a draw here could show */

- (void)setDepthBias:(float)depthBias slopeScale:(float)slopeScale clamp:(float)clamp
{
	if (depthBias != 0.0f || slopeScale != 0.0f || clamp != 0.0f) {
		HM_ONCE("a depth bias (%g, slope %g, clamp %g) was set; there is no depth attachment, so it is not applied\n",
			(double)depthBias, (double)slopeScale, (double)clamp);
	}
}

/* the references each later draw compares against (Metal's are 32 bits; the plane is 8, and the test reads the low 8) */
- (void)setStencilReferenceValue:(uint32_t)value
{
	_pass.stencil_front_reference = value & 0xff;
	_pass.stencil_back_reference = value & 0xff;
}

- (void)setStencilFrontReferenceValue:(uint32_t)front backReferenceValue:(uint32_t)back
{
	_pass.stencil_front_reference = front & 0xff;
	_pass.stencil_back_reference = back & 0xff;
}

/* the draws after this count into the pass's visibility result buffer at OFFSET (hakios-metal checks the mode, the
 * buffer and the offset at each draw, and refuses by name) */
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)mode offset:(NSUInteger)offset
{
	_pass.visibility_mode = (unsigned)mode;
	_pass.visibility_offset = offset;
}

- (void)setVertexAmplificationCount:(NSUInteger)count viewMappings:(const MTLVertexAmplificationViewMapping *)mappings
{
	(void)mappings;
	if (count > 1) {
		hm_print("refused: vertex amplification count %lu; profile 0 amplifies nothing; the next draw is failed\n", (unsigned long)count);
		snprintf(_refused, sizeof(_refused), "vertex amplification count %lu is not served", (unsigned long)count);
	}
}

/* --- store actions set during the pass (Metal allows them when the descriptor said Unknown) --- */

- (void)setColorStoreAction:(MTLStoreAction)action atIndex:(NSUInteger)index
{
	BOOL resolves = action == MTLStoreActionMultisampleResolve || action == MTLStoreActionStoreAndMultisampleResolve;
	unsigned store;

	if (index >= 8 || (index == 0 ? _pass.color0 == NULL : _pass.more[index - 1].texture == NULL)) {
		hm_print("refused: a store action for colour attachment %lu, which this pass does not have; the next draw is failed\n", (unsigned long)index);
		snprintf(_refused, sizeof(_refused), "a store action for colour attachment %lu, which the pass does not have", (unsigned long)index);
		return;
	}
	if ((action != MTLStoreActionStore && action != MTLStoreActionDontCare && action != MTLStoreActionUnknown && !resolves) ||
	    (resolves && _resolveTo[index] == nil)) {
		hm_print("refused: colour store action %lu at %lu%s; Store, DontCare and a resolve into the pass's resolveTexture are served; the next "
			 "draw is failed\n", (unsigned long)action, (unsigned long)index, resolves ? " with no resolveTexture" : "");
		snprintf(_refused, sizeof(_refused), "colour store action %lu at %lu is not served", (unsigned long)action, (unsigned long)index);
		return;
	}
	_resolving[index] = resolves;
	store = action == MTLStoreActionMultisampleResolve ? (unsigned)MTLStoreActionDontCare
	      : action == MTLStoreActionStoreAndMultisampleResolve || action == MTLStoreActionUnknown ? (unsigned)MTLStoreActionStore : (unsigned)action;
	if (index == 0) {
		_pass.store_action = store;
	} else {
		_pass.more[index - 1].store_action = store;
	}
}

- (void)setDepthStoreAction:(MTLStoreAction)action
{
	if (_pass.depth == NULL) {
		HM_ONCE("a depth store action (%lu) was set on a pass with no depth attachment; nothing to store\n", (unsigned long)action);
		return;
	}
	_pass.depth_store_action = action == MTLStoreActionUnknown ? (unsigned)MTLStoreActionStore : (unsigned)action;
}

- (void)setStencilStoreAction:(MTLStoreAction)action
{
	if (_pass.stencil == NULL) {
		HM_ONCE("a stencil store action (%lu) was set on a pass with no stencil attachment; nothing to store\n", (unsigned long)action);
		return;
	}
	_pass.stencil_store_action = action == MTLStoreActionUnknown ? (unsigned)MTLStoreActionStore : (unsigned)action;
}

- (void)setColorStoreActionOptions:(MTLStoreActionOptions)options atIndex:(NSUInteger)index
{
	HM_ONCE("colour store action options %#lx at index %lu; one sample here, no custom sample positions to keep\n", (unsigned long)options, (unsigned long)index);
}

- (void)setDepthStoreActionOptions:(MTLStoreActionOptions)options
{
	HM_ONCE("depth store action options %#lx on a pass with no depth attachment\n", (unsigned long)options);
}

- (void)setStencilStoreActionOptions:(MTLStoreActionOptions)options
{
	HM_ONCE("stencil store action options %#lx on a pass with no stencil attachment\n", (unsigned long)options);
}

/* --- the draws --- */

/*
 * One whole pass of hakios-metal's per call (begin, the state, the draw, the flushes that put the colour in memory): the
 * C interface's shape, chosen over a pass object because the private tree measured 41 us of fixed cost per draw and
 * nothing here yet draws more than once per pass. In sysmem mode Load and DontCare are the same thing (the RB writes the
 * memory as it draws, there is no tile to load into). A Clear belongs to the pass, not to each draw: the first draw
 * carries it (hakios-metal fills the attachment with the 2D engine before that draw), and once it is recorded the
 * stored action becomes Load, so a second draw does not wipe the first; an encoder that ends with the Clear unspent
 * records it alone at -endEncoding. hakios-metal judges the rest -- the program against the attachment's format, the primitive,
 * a zero vertex count, an instance count other than 1, a viewport or scissor outside the target, the buffer tables (step
 * one: empty) -- and refuses by name; the command buffer then ends in error with that sentence, printed here as well.
 */
- (void)hakiosDraw:(MTLPrimitiveType)primitive vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count instanceCount:(NSUInteger)instances
{
	[self hakiosDraw:primitive vertexStart:start vertexCount:count instanceCount:instances indexBuffer:nil indexType:MTLIndexTypeUInt16
	     indexOffset:0 baseVertex:0 baseInstance:0];
}

/* the fragment constants each program was linked with, for the trace's lines (metal_trace, metal_skip) */
static NSMutableDictionary *hm_program_constants;

static void
hm_note_constants(const void *program, NSString *constants)
{
	@synchronized ([NSMutableDictionary class]) {
		if (hm_program_constants == nil) hm_program_constants = [[NSMutableDictionary alloc] init];
		[hm_program_constants setObject:constants forKey:[NSValue valueWithPointer:program]];
	}
}

static NSString *
hm_constants_of(const void *program)
{
	@synchronized ([NSMutableDictionary class]) {
		NSString *c = [hm_program_constants objectForKey:[NSValue valueWithPointer:program]];
		return c != nil ? c : @"";
	}
}

/* boot-arg metal_trace=1: each kind of draw said once -- its program, its target and the textures it samples -- so that
 * a wrong picture can be traced to the pass that made it. Off by default: a boot draws thousands. */
static BOOL
hm_tracing(void)
{
	static int on = -1;

	if (on < 0) {
		char args[1024] = "";
		size_t size = sizeof(args) - 1;

		/* (hakios) PosterBoard always: its home-screen preview's black blocks (WALLPAPER-umi.md) are traced from the
		 * log alone, the boot-args having no room for metal_trace=1 */
		on = (sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "metal_trace=1") != NULL) ||
		     strcmp(getprogname(), "PosterBoard") == 0;
	}
	return on == 1;
}

/* boot-arg metal_skip=WORD (a diagnostic, beside metal_trace): a draw whose trace line holds WORD, its spaces written
 * as '_', is not drawn -- to find which kind of draw makes a part of the picture by taking it away */
static const char *
hm_skip_word(void)
{
	static char word[128];
	static int read;

	if (!read) {
		char args[1024] = "";
		size_t size = sizeof(args) - 1;
		const char *at;

		read = 1;
		if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && (at = strstr(args, "metal_skip=")) != NULL) {
			at += strlen("metal_skip=");
			for (size_t i = 0; i + 1 < sizeof(word) && at[i] != '\0' && at[i] != ' '; i++) {
				word[i] = at[i] == '_' ? ' ' : at[i];
			}
		}
	}
	return word[0] != '\0' ? word : NULL;
}

/* boot-arg metal_dump=cfg:NAME (a diagnostic): for draws whose program's name holds NAME, the first 128 bytes of each
 * fragment buffer, each content once (40 at most). An uber shader's loops run as many times as its configuration's bytes
 * say, so what one of its draws costs is in this buffer, not in its code */
static void
hm_dump_config(const char *program, hakios_metal_buffer *const *buffers, const uint64_t *offsets, unsigned count)
{
	static char name[64];
	static int state = -1;
	static NSMutableSet *seen;

	if (state < 0) {
		char args[1024] = {0};
		size_t size = sizeof(args) - 1;
		const char *at;

		state = 0;
		if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && (at = strstr(args, "metal_dump=cfg:")) != NULL) {
			at += strlen("metal_dump=cfg:");
			for (size_t i = 0; i + 1 < sizeof(name) && at[i] != '\0' && at[i] != ' '; i++) name[i] = at[i];
			state = name[0] != '\0';
			seen = [[NSMutableSet alloc] init];
		} else if (strcmp(getprogname(), "PosterBoard") == 0) {
			/* (hakios) PosterBoard's every program, as hm_tracing: the material passes' constants (edr_scale, the
			 * colour ops' uniforms) beside the trace of its home-screen preview */
			state = 1;
			seen = [[NSMutableSet alloc] init];
		}
	}
	if (state != 1 || program == NULL || strstr(program, name) == NULL || [seen count] >= 40) return;
	for (unsigned i = 0; i < count; i++) {
		if (buffers[i] == NULL) continue;
		const uint8_t *bytes = (const uint8_t *)hakios_metal_buffer_contents(buffers[i]);
		const uint64_t length = hakios_metal_buffer_length(buffers[i]);
		if (bytes == NULL || offsets[i] >= length) continue;
		const uint64_t n = length - offsets[i] < 128 ? length - offsets[i] : 128;
		char hex[2 * 128 + 1];
		for (uint64_t k = 0; k < n; k++) snprintf(hex + 2 * k, 3, "%02x", bytes[offsets[i] + k]);
		NSString *key = [NSString stringWithFormat:@"%u:%s", i, hex];
		if ([seen containsObject:key]) continue;
		[seen addObject:key];
		hm_print("cfg: %s fragment buffer %u (%llu bytes from %llu): %s\n", program, i, (unsigned long long)(length - offsets[i]),
			 (unsigned long long)offsets[i], hex);
	}
}

/*
 * YES for a draw of luma_boost, unless boot-arg metal_luma_boost=1. A library that has its own (an iOS 17
 * QuartzCore's, CA_QC_METALLIB off a Mac: the colour already drawn, by framebuffer fetch, through a LUT) gets it
 * drawn as a full-screen pass at 1.5 ms a draw, 83% of the GPU's timed passes (logs/224205-run.log,
 * metal_fps=draws); its stand-in there, inplace_copy, stores through texture 3 as an image, which a draw cannot
 * (logs/225648-run.log: backboardd aborted). The picture as it is -- what inplace_copy stands for -- is the draw
 * left out.
 */
static BOOL
hm_luma_boost_left_out(const char *program)
{
	static int keep = -1;

	if (program == NULL || strstr(program, "+luma_boost_l") == NULL) {
		return NO;
	}
	if (keep < 0) {
		char args[1024] = "";
		size_t size = sizeof(args) - 1;

		keep = sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "metal_luma_boost=1") != NULL;
		HM_ONCE("luma_boost: %s (metal_luma_boost=1 draws it)\n", keep ? "drawn" : "left out, the picture as it is");
	}
	return !keep;
}

/* YES when the draw is to be left out (metal_skip); prints the kind once when tracing */
static BOOL
hm_trace_draw(const void *which, const char *program, const struct hakios_metal_render_pass *pass, hakios_metal_texture *const *textures, unsigned count,
	      unsigned primitive, unsigned blend)
{
	static NSMutableSet *seen;
	static unsigned printed;
	NSMutableString *line;
	const char *skip = hm_skip_word();
	BOOL skipped;

	if (!hm_tracing() && skip == NULL) {
		return NO;
	}
	line = [NSMutableString stringWithFormat:@"%s (%p fc%@) prim %u into %ux%u fmt %u load %u%s%s", program, which, hm_constants_of(which), primitive,
		pass->color0 != NULL ? hakios_metal_texture_width(pass->color0) : 0, pass->color0 != NULL ? hakios_metal_texture_height(pass->color0) : 0,
		pass->color0 != NULL ? hakios_metal_texture_format(pass->color0) : 0, pass->load_action,
		pass->color0 != NULL && hakios_metal_texture_iosurface(pass->color0) != 0 ? " (surface)" : "", blend ? " blend" : ""];
	for (unsigned i = 0; i < count; i++) {
		if (textures[i] == NULL) continue;
		[line appendFormat:@" t%u=%ux%u fmt %u%s", i, hakios_metal_texture_width(textures[i]), hakios_metal_texture_height(textures[i]),
			hakios_metal_texture_format(textures[i]), hakios_metal_texture_iosurface(textures[i]) != 0 ? " (surface)" : ""];
	}
	skipped = skip != NULL && strstr([line UTF8String], skip) != NULL;
	if (!hm_tracing() || printed >= 3000) {
		return skipped;
	}
	@synchronized ([NSMutableSet class]) {
		if (seen == nil) seen = [[NSMutableSet alloc] init];
		if ([seen containsObject:line]) return skipped;
		[seen addObject:line];
		printed++;
	}
	hm_print("trace: %s%s\n", [line UTF8String], skipped ? " (skipped)" : "");
	return skipped;
}

/* the draws in one: INDEX_BUFFER non-nil is an indexed draw (COUNT its indices, START unread); timed for metal_fps */
- (void)hakiosDraw:(MTLPrimitiveType)primitive vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count instanceCount:(NSUInteger)instances
       indexBuffer:(id)indexBuffer indexType:(MTLIndexType)indexType indexOffset:(NSUInteger)indexOffset baseVertex:(NSInteger)baseVertex
      baseInstance:(NSUInteger)baseInstance
{
	const double began = hm_fps_on() ? hm_now() : 0;
	uint64_t tpidr = 0;

	if (began != 0) __asm__ volatile("mrs %0, TPIDR_EL0" : "=r"(tpidr));   /* (the processor number: set_thread_registers, cswitch.s) */
	if (began != 0 && hm_sampling()) {
		static dispatch_once_t once;
		dispatch_once(&once, ^{
			pthread_t th;
			pthread_create(&th, NULL, hm_sampler, NULL);
		});
		hm_sample_thread = mach_thread_self();
	}
	[self hakiosDrawOnce:primitive vertexStart:start vertexCount:count instanceCount:instances indexBuffer:indexBuffer indexType:indexType
		 indexOffset:indexOffset baseVertex:baseVertex baseInstance:baseInstance];
	if (began != 0 && hm_sampling()) {
		const mach_port_t me = hm_sample_thread;
		hm_sample_thread = 0;
		mach_port_deallocate(mach_task_self(), me);
	}
	if (began != 0) hm_fps_drew(hm_now() - began, (unsigned)(tpidr & 0xfff));
	if (began != 0) hm_fps.lastTpidr = tpidr;
}

- (void)hakiosDrawOnce:(MTLPrimitiveType)primitive vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count instanceCount:(NSUInteger)instances
	   indexBuffer:(id)indexBuffer indexType:(MTLIndexType)indexType indexOffset:(NSUInteger)indexOffset baseVertex:(NSInteger)baseVertex
	  baseInstance:(NSUInteger)baseInstance
{
	hakios_metal_cb *cb = [self hakiosCb];
	int drawn;
	hakios_metal_buffer *vs[HM_MAX_BUFFERS], *fs[HM_MAX_BUFFERS];
	/* an indirect draw's buffer, taken here so that no return below leaves it for the next draw */
	id indirectArgs = _indirectArgs;
	NSUInteger indirectOffset = _indirectOffset;
	_indirectArgs = nil;
	hakios_metal_texture *fsTex[HM_MAX_TEXTURES], *vsTex[HM_MAX_TEXTURES];
	hakios_metal_sampler *fsSamp[HM_MAX_SAMPLERS], *vsSamp[HM_MAX_SAMPLERS];

	if (_pipeline == nil) {
		hm_print("refused: a draw with no render pipeline state; the command buffer is failed\n");
		hakios_metal_cb_refuse(cb, "a draw with no render pipeline state");
		return;
	}
	if (_refused[0] != '\0') {
		hm_print("refused: this draw, because %s; the command buffer is failed\n", _refused);
		hakios_metal_cb_refuse(cb, _refused);
		return;
	}
	/* every resource the draw binds is in this command buffer (-isComplete) */
	const uint64_t useSeq = [_commandBuffer hakiosUseSeq];
	if (indexBuffer != nil && [indexBuffer respondsToSelector:@selector(hakiosUsedBy:)]) [(HakiosMetalBuffer *)indexBuffer hakiosUsedBy:useSeq];
	if (indirectArgs != nil && [indirectArgs respondsToSelector:@selector(hakiosUsedBy:)]) [(HakiosMetalBuffer *)indirectArgs hakiosUsedBy:useSeq];
	for (unsigned i = 0; i < _vsHighest; i++) {
		vs[i] = _vsBuffers[i] != nil ? [_vsBuffers[i] hakiosBuffer] : NULL;
		[_vsBuffers[i] hakiosUsedBy:useSeq];
	}
	for (unsigned i = 0; i < _fsHighest; i++) {
		fs[i] = _fsBuffers[i] != nil ? [_fsBuffers[i] hakiosBuffer] : NULL;
		[_fsBuffers[i] hakiosUsedBy:useSeq];
	}
	for (unsigned i = 0; i < _fsHighestTexture; i++) {
		fsTex[i] = _fsTextures[i] != nil ? [_fsTextures[i] hakiosTexture] : NULL;
		[_fsTextures[i] hakiosUsedBy:useSeq];
		[_commandBuffer hakiosTrackTexture:_fsTextures[i] write:NO];
		if (_fsTextures[i] != nil && hm_read_race_on() && [_fsTextures[i] iosurface] != NULL && ![_fsTextures[i] hakiosIsShadow] &&
		    IOSurfaceGetPlaneCount([_fsTextures[i] iosurface]) <= 1) {
			[_commandBuffer hakiosNoteRead:[_fsTextures[i] iosurface]];   /* flicker-diag */
		}
		if (_fsTextures[i] != nil && hm_timeline_on()) {
			unsigned kind = [_fsTextures[i] hakiosStorageKind];
			const unsigned origin = hakios_metal_texture_origin([_fsTextures[i] hakiosTexture]);
			if (origin == 2) kind = 2;   /* (over a buffer's rows: counted where managed was, which iOS has not) */
			if (origin == 3) kind = 5;   /* (compressed) */
			const double bytes = 4.0 * [_fsTextures[i] width] * [_fsTextures[i] height];
			if (kind < 6 && bytes >= 65536) {
				pthread_mutex_lock(&hm_fps.lock);
				hm_fps.sampledBytes[kind] += bytes;
				/* ...and by size and origin, the 16 first kinds seen */
				const unsigned w = (unsigned)[_fsTextures[i] width], h = (unsigned)[_fsTextures[i] height];
				unsigned k = 0;
				while (k < 16 && hm_fps.bySize[k].bytes != 0 && !(hm_fps.bySize[k].w == w && hm_fps.bySize[k].h == h && hm_fps.bySize[k].origin == origin)) k++;
				if (k < 16) {
					hm_fps.bySize[k].w = w, hm_fps.bySize[k].h = h, hm_fps.bySize[k].origin = origin;
					hm_fps.bySize[k].bytes += bytes;
				}
				pthread_mutex_unlock(&hm_fps.lock);
			}
		}
	}
	for (unsigned i = 0; i < _fsHighestSampler; i++) {
		fsSamp[i] = _fsSamplers[i] != nil ? [_fsSamplers[i] hakiosSampler] : NULL;
	}
	for (unsigned i = 0; i < _vsHighestTexture; i++) {
		vsTex[i] = _vsTextures[i] != nil ? [_vsTextures[i] hakiosTexture] : NULL;
		[_vsTextures[i] hakiosUsedBy:useSeq];
		[_commandBuffer hakiosTrackTexture:_vsTextures[i] write:NO];
	}
	for (unsigned i = 0; i < _vsHighestSampler; i++) {
		vsSamp[i] = _vsSamplers[i] != nil ? [_vsSamplers[i] hakiosSampler] : NULL;
	}
	hakios_metal_cb_set_vertex_textures(cb, vsTex, _vsHighestTexture, vsSamp, _vsHighestSampler);
	hakios_metal_program *program = [_pipeline hakiosProgramFor:fs offsets:_fsOffsets count:_fsHighest];

	hm_dump_config(hakios_metal_program_name(program), fs, _fsOffsets, _fsHighest);
	if (hm_trace_draw([_pipeline hakiosProgram], hakios_metal_program_name([_pipeline hakiosProgram]), &_pass, fsTex, _fsHighestTexture, (unsigned)primitive, 0)) {
		return;
	}
	if (hm_luma_boost_left_out(hakios_metal_program_name([_pipeline hakiosProgram]))) {
		return;
	}
	if (indexBuffer != nil && ![indexBuffer isKindOfClass:[HakiosMetalBuffer class]]) {
		hm_print("refused: an indexed draw from a %s, not a buffer of this device; the command buffer is failed\n", class_getName(object_getClass(indexBuffer)));
		hakios_metal_cb_refuse(cb, "an indexed draw from a buffer that is not this device's");
		return;
	}
	/* a word this encoder has not counted into yet starts from zero: Metal's result is the pass's count */
	if (_pass.visibility_mode != 0) {
		if (_visibilityCounted == nil) _visibilityCounted = [[NSMutableIndexSet alloc] init];
		_pass.visibility_reset = ![_visibilityCounted containsIndex:(NSUInteger)(_pass.visibility_offset / 8)];
	}
	if (indirectArgs != nil) {
		if (![indirectArgs isKindOfClass:[HakiosMetalBuffer class]]) {
			hm_print("refused: an indirect draw whose arguments are in a %s, not a buffer of this device; the command buffer is failed\n",
				 class_getName(object_getClass(indirectArgs)));
			hakios_metal_cb_refuse(cb, "an indirect draw's arguments in a buffer that is not this device's");
			return;
		}
		hakios_metal_cb_set_indirect(cb, [(HakiosMetalBuffer *)indirectArgs hakiosBuffer], (uint64_t)indirectOffset);
	}
	/* OpenGL ES (hm_gl_mode): window coordinates for the renderer's blits, and GL's provoking vertex; the viewport (of
	 * negative height for a GL framebuffer), the scissor and the front face are the renderer's, as it set them */
	_pass.gl_mode = (_pass.gl_mode & HAKIOS_METAL_GL_DEPTH) | (_glNoTransform && _pass.gl_mode != 0 ? HAKIOS_METAL_GL_NO_XFORM : 0u) |
			(_glProvokingLast ? HAKIOS_METAL_GL_PROVOKING_LAST : 0u);
	if (_glNoTransform && (_pass.gl_mode & HAKIOS_METAL_GL_DEPTH) == 0) {
		HM_ONCE("gles: -setViewportTransformEnabled:NO outside an OpenGL ES pass: drawn with the transform\n");
	}
	/* a yInverted attachment (hm_yinvert_size): the draw turned about the target's height, as Apple's GPU stores it --
	 * the viewport (Metal's default, the whole target, when none was set) with its origin at H - y and its height
	 * negated, the scissor's rows mirrored, and the front face the other way, since the turn mirrors every triangle */
	struct hakios_metal_viewport viewport = _viewport;
	struct hakios_metal_scissor scissor = _scissor;
	BOOL hasViewport = _hasViewport;
	const unsigned winding = _pass.winding;

	if (_flipHeight != 0) {
		if (!hasViewport) {
			viewport = (struct hakios_metal_viewport){ 0.0, 0.0, (double)_flipWidth, (double)_flipHeight, 0.0, 1.0 };
			hasViewport = YES;
		}
		viewport.y = (double)_flipHeight - viewport.y;
		viewport.height = -viewport.height;
		if (_hasScissor && scissor.width != 0) {
			scissor.y = scissor.y + scissor.height <= _flipHeight ? _flipHeight - scissor.y - scissor.height : 0;
		}
		_pass.winding = winding ^ 1u;
		if ((_pass.gl_mode & HAKIOS_METAL_GL_NO_XFORM) != 0) {
			HM_ONCE("gles: a draw in window coordinates (-setViewportTransformEnabled:NO) into a yInverted attachment: its "
				"positions are drawn as they lie, not turned\n");
		}
	}
	const double coreBegan = hm_fps_on() ? hm_now() : 0;
	if (hm_maps_trace() && [_colorTexture sampleCount] > 1 && [_colorTexture width] >= 1000) {
		static unsigned said;
		const unsigned n = __atomic_fetch_add(&said, 1, __ATOMIC_RELAXED);
		if (n < 96) hm_print("maps-draw %u: %s colour %p load %u fetch %u depth %u/%u stencil %u refs %u/%u "
				     "front compare/fail/zfail/pass %u/%u/%u/%u masks %x/%x back %u/%u/%u/%u masks %x/%x\n", n,
				     hakios_metal_program_name(program), _colorTexture, _pass.load_action, hakios_metal_program_framebuffer_fetch(program),
				     _pass.depth_compare, _pass.depth_write, _pass.stencil_state_set, _pass.stencil_front_reference, _pass.stencil_back_reference,
				     _pass.stencil_front.compare, _pass.stencil_front.stencil_fail, _pass.stencil_front.depth_fail, _pass.stencil_front.pass,
				     _pass.stencil_front.read_mask, _pass.stencil_front.write_mask,
				     _pass.stencil_back.compare, _pass.stencil_back.stencil_fail, _pass.stencil_back.depth_fail, _pass.stencil_back.pass,
				     _pass.stencil_back.read_mask, _pass.stencil_back.write_mask);
	}
	if (indexBuffer != nil) {
		drawn = hakios_metal_cb_draw_indexed(cb, program, &_pass, hasViewport ? &viewport : NULL, _hasScissor ? &scissor : NULL,
						     (unsigned)primitive, (unsigned)count, (unsigned)indexType, [(HakiosMetalBuffer *)indexBuffer hakiosBuffer],
						     (uint64_t)indexOffset, (unsigned)instances, (int)baseVertex, (unsigned)baseInstance, vs, _vsOffsets, _vsHighest, fs,
						     _fsOffsets, _fsHighest, fsTex, _fsHighestTexture, fsSamp, _fsHighestSampler);
	} else {
		drawn = hakios_metal_cb_draw3(cb, program, &_pass, hasViewport ? &viewport : NULL, _hasScissor ? &scissor : NULL,
					      (unsigned)primitive, (unsigned)start, (unsigned)count, (unsigned)instances, (unsigned)baseInstance,
					      vs, _vsOffsets, _vsHighest, fs, _fsOffsets, _fsHighest, fsTex, _fsHighestTexture, fsSamp, _fsHighestSampler);
	}
	if (coreBegan != 0) hm_fps_core(hm_now() - coreBegan);
	_pass.winding = winding;   /* (the encoder's own, for the next draw: the turn is per draw) */
	if (drawn == 0 && _pass.visibility_mode != 0) {
		[_visibilityCounted addIndex:(NSUInteger)(_pass.visibility_offset / 8)];
	}
	if (drawn != 0) {
		/* one line the first time this program is refused for this reason (and when another reason follows it): the
		 * count of the period is in the two-second "refused: total ..." line, never a line a draw */
		if (hm_refusal_first([_pipeline hakiosProgram], hakios_metal_error())) {
			hm_print("refused: a draw of %s, primitive %lu, %lu vertices from %lu, %lu instance(s), load %u store %u, %u vertex and %u fragment "
				 "buffer slots: %s\n", hakios_metal_program_name([_pipeline hakiosProgram]), (unsigned long)primitive, (unsigned long)count,
				 (unsigned long)start, (unsigned long)instances, _pass.load_action, _pass.store_action, _vsHighest, _fsHighest, hakios_metal_error());
		}
		hakios_metal_cb_refuse(cb, hakios_metal_error());
		return;
	}
	if (_pass.depth != NULL || _pass.stencil != NULL) {
		hakios_metal_texture *zs = _pass.depth != NULL ? _pass.depth : _pass.stencil;
		HM_ONCE("depth-msaa: encoded sysmem depth/stencil draw, samples=%u, depth=%u, stencil=%u\n",
			hakios_metal_texture_samples(zs), _pass.depth != NULL, _pass.stencil != NULL);
	}
	hm_spend_clears(&_pass);   /* the fills are recorded: the pass's later draws load what they left */
}

- (void)drawPrimitives:(MTLPrimitiveType)primitive vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count
{
	[self hakiosDraw:primitive vertexStart:start vertexCount:count instanceCount:1];
}

- (void)drawPrimitives:(MTLPrimitiveType)primitive vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count instanceCount:(NSUInteger)instances
{
	[self hakiosDraw:primitive vertexStart:start vertexCount:count instanceCount:instances];
}

- (void)drawPrimitives:(MTLPrimitiveType)primitive vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count instanceCount:(NSUInteger)instances
	  baseInstance:(NSUInteger)baseInstance
{
	[self hakiosDraw:primitive vertexStart:start vertexCount:count instanceCount:instances indexBuffer:nil indexType:MTLIndexTypeUInt16
	     indexOffset:0 baseVertex:0 baseInstance:baseInstance];
}

/* Indirect, patch and mesh draws: each is refused by name AND fails the command buffer at once, because a draw that
 * vanishes without a word is the worst outcome available (the compute encoder's indirect dispatch rule). Indirect ones
 * need a grid read by the GPU, patches the tessellation stages (HS/DS off here), mesh draws the object/mesh stages. */
- (void)hakiosRefuseDraw:(SEL)sel what:(const char *)what
{
	hm_refusal(self, sel, what);
	hakios_metal_cb_refuse([self hakiosCb], "a draw of a kind that is not served (indexed, indirect, patches or mesh)");
}

/* Indexed draws: hakios-metal's 7-word CP_DRAW_INDX_OFFSET with Metal's primitive restart; it refuses by name what it
 * does not serve (a negative base vertex, an offset that is not a multiple of the index size) */
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitive indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType
		  indexBuffer:(id)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset
{
	if (indexBuffer == nil) {
		hm_print("refused: an indexed draw with no index buffer; the command buffer is failed\n");
		hakios_metal_cb_refuse([self hakiosCb], "an indexed draw with no index buffer");
		return;
	}
	[self hakiosDraw:primitive vertexStart:0 vertexCount:indexCount instanceCount:1 indexBuffer:indexBuffer indexType:indexType
	     indexOffset:indexBufferOffset baseVertex:0 baseInstance:0];
}

- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitive indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType
		  indexBuffer:(id)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset instanceCount:(NSUInteger)instances
{
	if (indexBuffer == nil) {
		hm_print("refused: an indexed draw with no index buffer; the command buffer is failed\n");
		hakios_metal_cb_refuse([self hakiosCb], "an indexed draw with no index buffer");
		return;
	}
	[self hakiosDraw:primitive vertexStart:0 vertexCount:indexCount instanceCount:instances indexBuffer:indexBuffer indexType:indexType
	     indexOffset:indexBufferOffset baseVertex:0 baseInstance:0];
}

- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitive indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType
		  indexBuffer:(id)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset instanceCount:(NSUInteger)instances
		   baseVertex:(NSInteger)baseVertex baseInstance:(NSUInteger)baseInstance
{
	if (indexBuffer == nil) {
		hm_print("refused: an indexed draw with no index buffer; the command buffer is failed\n");
		hakios_metal_cb_refuse([self hakiosCb], "an indexed draw with no index buffer");
		return;
	}
	[self hakiosDraw:primitive vertexStart:0 vertexCount:indexCount instanceCount:instances indexBuffer:indexBuffer indexType:indexType
	     indexOffset:indexBufferOffset baseVertex:baseVertex baseInstance:baseInstance];
}

/* Indirect draws: the counts, starts and bases are read by the GPU as it runs the draw (CP_DRAW_INDIRECT_MULTI), so
 * the counts handed on here are placeholders the core does not read */
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitive indexType:(MTLIndexType)indexType indexBuffer:(id)indexBuffer
	    indexBufferOffset:(NSUInteger)indexBufferOffset indirectBuffer:(id)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset
{
	if (indexBuffer == nil || indirectBuffer == nil) {
		hm_print("refused: an indirect indexed draw with no %s; the command buffer is failed\n", indexBuffer == nil ? "index buffer" : "argument buffer");
		hakios_metal_cb_refuse([self hakiosCb], "an indirect indexed draw with a buffer missing");
		return;
	}
	_indirectArgs = indirectBuffer;
	_indirectOffset = indirectBufferOffset;
	[self hakiosDraw:primitive vertexStart:0 vertexCount:1 instanceCount:1 indexBuffer:indexBuffer indexType:indexType
	     indexOffset:indexBufferOffset baseVertex:0 baseInstance:0];
}

- (void)drawPrimitives:(MTLPrimitiveType)primitive indirectBuffer:(id)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset
{
	if (indirectBuffer == nil) {
		hm_print("refused: an indirect draw with no argument buffer; the command buffer is failed\n");
		hakios_metal_cb_refuse([self hakiosCb], "an indirect draw with no argument buffer");
		return;
	}
	_indirectArgs = indirectBuffer;
	_indirectOffset = indirectBufferOffset;
	[self hakiosDraw:primitive vertexStart:0 vertexCount:1 instanceCount:1 indexBuffer:nil indexType:MTLIndexTypeUInt16
	     indexOffset:0 baseVertex:0 baseInstance:0];
}

- (void)drawPatches:(NSUInteger)patches patchStart:(NSUInteger)patchStart patchCount:(NSUInteger)patchCount patchIndexBuffer:(id)patchIndexBuffer
     patchIndexBufferOffset:(NSUInteger)patchIndexBufferOffset instanceCount:(NSUInteger)instances baseInstance:(NSUInteger)baseInstance
{
	(void)patches; (void)patchStart; (void)patchCount; (void)patchIndexBuffer; (void)patchIndexBufferOffset; (void)instances; (void)baseInstance;
	[self hakiosRefuseDraw:_cmd what:"has no tessellation stages (HS and DS are off); the command buffer is failed"];
}

- (void)drawPatches:(NSUInteger)patches patchIndexBuffer:(id)patchIndexBuffer patchIndexBufferOffset:(NSUInteger)patchIndexBufferOffset
     indirectBuffer:(id)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset
{
	(void)patches; (void)patchIndexBuffer; (void)patchIndexBufferOffset; (void)indirectBuffer; (void)indirectBufferOffset;
	[self hakiosRefuseDraw:_cmd what:"has no tessellation stages (HS and DS are off); the command buffer is failed"];
}

- (void)drawIndexedPatches:(NSUInteger)patches patchStart:(NSUInteger)patchStart patchCount:(NSUInteger)patchCount patchIndexBuffer:(id)patchIndexBuffer
    patchIndexBufferOffset:(NSUInteger)patchIndexBufferOffset controlPointIndexBuffer:(id)controlPointIndexBuffer
 controlPointIndexBufferOffset:(NSUInteger)controlPointIndexBufferOffset instanceCount:(NSUInteger)instances baseInstance:(NSUInteger)baseInstance
{
	(void)patches; (void)patchStart; (void)patchCount; (void)patchIndexBuffer; (void)patchIndexBufferOffset; (void)controlPointIndexBuffer;
	(void)controlPointIndexBufferOffset; (void)instances; (void)baseInstance;
	[self hakiosRefuseDraw:_cmd what:"has no tessellation stages (HS and DS are off); the command buffer is failed"];
}

- (void)drawIndexedPatches:(NSUInteger)patches patchIndexBuffer:(id)patchIndexBuffer patchIndexBufferOffset:(NSUInteger)patchIndexBufferOffset
   controlPointIndexBuffer:(id)controlPointIndexBuffer controlPointIndexBufferOffset:(NSUInteger)controlPointIndexBufferOffset
	    indirectBuffer:(id)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset
{
	(void)patches; (void)patchIndexBuffer; (void)patchIndexBufferOffset; (void)controlPointIndexBuffer; (void)controlPointIndexBufferOffset;
	(void)indirectBuffer; (void)indirectBufferOffset;
	[self hakiosRefuseDraw:_cmd what:"has no tessellation stages (HS and DS are off); the command buffer is failed"];
}

/* the mesh draws are REAL in _MTLCommandEncoder (they re-send themselves), so they are overridden rather than left to
 * reach code written for Apple's mesh encoder */
- (void)drawMeshThreadgroups:(MTLSize)groups threadsPerObjectThreadgroup:(MTLSize)objectThreads threadsPerMeshThreadgroup:(MTLSize)meshThreads
{
	(void)groups; (void)objectThreads; (void)meshThreads;
	[self hakiosRefuseDraw:_cmd what:"has no mesh or object stages; the command buffer is failed"];
}

- (void)drawMeshThreads:(MTLSize)threads threadsPerObjectThreadgroup:(MTLSize)objectThreads threadsPerMeshThreadgroup:(MTLSize)meshThreads
{
	(void)threads; (void)objectThreads; (void)meshThreads;
	[self hakiosRefuseDraw:_cmd what:"has no mesh or object stages; the command buffer is failed"];
}

- (void)drawMeshThreadgroupsWithIndirectBuffer:(id)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset
		   threadsPerObjectThreadgroup:(MTLSize)objectThreads threadsPerMeshThreadgroup:(MTLSize)meshThreads
{
	(void)indirectBuffer; (void)indirectBufferOffset; (void)objectThreads; (void)meshThreads;
	[self hakiosRefuseDraw:_cmd what:"has no mesh or object stages; the command buffer is failed"];
}

- (void)executeCommandsInBuffer:(id)icb withRange:(NSRange)range
{
	(void)icb; (void)range;
	[self hakiosRefuseDraw:_cmd what:"has no indirect command buffers (the GPU reads no draw arguments here); the command buffer is failed"];
}

- (void)executeCommandsInBuffer:(id)icb indirectBuffer:(id)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset
{
	(void)icb; (void)indirectBuffer; (void)indirectBufferOffset;
	[self hakiosRefuseDraw:_cmd what:"has no indirect command buffers (the GPU reads no draw arguments here); the command buffer is failed"];
}

/*
 * Served by construction, as in the compute encoder: each draw here is a whole pass whose tail flushes the CCU and the
 * caches (PC_CCU_FLUSH_COLOR_TS, CACHE_FLUSH_TS) and whose head invalidates them, one queue runs its command buffers
 * in commit order, and every allocation is resident for its whole life. A barrier, a fence or a residency request asks
 * for an ordering that is already the only one there is.
 */
- (void)updateFence:(id)fence afterStages:(MTLRenderStages)stages  { (void)fence; (void)stages; [_commandBuffer hakiosRequireSync:HAKIOS_METAL_DRAIN_CPU_SYNC]; }
- (void)waitForFence:(id)fence beforeStages:(MTLRenderStages)stages { (void)fence; (void)stages; [_commandBuffer hakiosRequireSync:HAKIOS_METAL_DRAIN_CPU_SYNC]; }
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope afterStages:(MTLRenderStages)after beforeStages:(MTLRenderStages)before
{
	(void)scope; (void)after; (void)before;
}
- (void)memoryBarrierWithResources:(const id *)resources count:(NSUInteger)count afterStages:(MTLRenderStages)after beforeStages:(MTLRenderStages)before
{
	(void)resources; (void)count; (void)after; (void)before;
}
- (void)useResource:(id)resource usage:(MTLResourceUsage)usage { (void)resource; (void)usage; }
- (void)useResource:(id)resource usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages { (void)resource; (void)usage; (void)stages; }
- (void)useResources:(const id *)resources count:(NSUInteger)count usage:(MTLResourceUsage)usage { (void)resources; (void)count; (void)usage; }
- (void)useResources:(const id *)resources count:(NSUInteger)count usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages
{
	(void)resources; (void)count; (void)usage; (void)stages;
}
- (void)useHeap:(id)heap { (void)heap; }
- (void)useHeap:(id)heap stages:(MTLRenderStages)stages { (void)heap; (void)stages; }
- (void)useHeaps:(const id *)heaps count:(NSUInteger)count { (void)heaps; (void)count; }
- (void)useHeaps:(const id *)heaps count:(NSUInteger)count stages:(MTLRenderStages)stages { (void)heaps; (void)count; (void)stages; }

/* abstract in _MTLCommandEncoder (inheriting it aborts); a packing hint the compiler decides for itself here */
- (void)setThreadgroupPackingDisabled:(BOOL)disabled { (void)disabled; }

/* The tile an Apple GPU's imageblock covers, which the protocol lets a client read at any time. This GPU draws straight
 * into memory and has no tile here; the honest number is 0, and a READER is not a binding -- left to the catch-all it
 * would fail the next draw, which only a dropped input deserves -- so both are answered here, with a line once. */
- (NSUInteger)tileWidth
{
	HM_ONCE("a render encoder's tile width or height was asked for; this GPU draws in sysmem with no tile memory, and 0 is answered\n");
	return 0;
}

- (NSUInteger)tileHeight
{
	HM_ONCE("a render encoder's tile width or height was asked for; this GPU draws in sysmem with no tile memory, and 0 is answered\n");
	return 0;
}

/* tile shading (setTileBytes:, dispatchThreadsPerTile:, setThreadgroupMemoryLength:offset:atIndex:), function tables,
 * tessellation factor buffers, counter sampling and the object/mesh setters are declared by <MTLRenderCommandEncoder>
 * and refused through -forwardInvocation: (or Metal's own abstract bodies) above, by name */

- (void)endEncoding
{
	/* a Clear no draw spent: the pass still owes it (a pass that only clears is how many clients wipe a drawable) */
	/* (not on a command buffer a refused draw already failed -- it holds an error before commit: its first sentence is the one that matters) */
	if (hm_owes_clear(&_pass) && hakios_metal_cb_error([self hakiosCb])[0] == '\0' &&
	    hakios_metal_cb_clear([self hakiosCb], &_pass) != 0) {
		hm_print("refused: a pass that only clears: %s\n", hakios_metal_error());
		hakios_metal_cb_refuse([self hakiosCb], hakios_metal_error());
	}
	hm_spend_clears(&_pass);
	/* the resolves, after the pass: each multisample attachment's samples into its resolveTexture, pixel for pixel. The
	 * core hands a resolve that follows a tiled pass to the pass, which does it from its tiles (the samples never reach
	 * memory: hakios_metal_cb_set_gmem_msaa_zs); otherwise the blit closes the pass first and reads what the draws wrote */
	for (unsigned i = 0; i < 8; i++) {
		if (!_resolving[i] || hakios_metal_cb_error([self hakiosCb])[0] != '\0') {
			continue;
		}
		if (hakios_metal_cb_blit([self hakiosCb], [_resolveFrom[i] hakiosTexture], 0, 0, 0, (unsigned)[_resolveFrom[i] width],
					 (unsigned)[_resolveFrom[i] height], [_resolveTo[i] hakiosTexture], _resolveLevel[i], 0, 0,
					 (unsigned)[_resolveFrom[i] width], (unsigned)[_resolveFrom[i] height], 0) != 0) {
			hm_print("refused: the resolve of colour attachment %u: %s\n", i, hakios_metal_error());
			hakios_metal_cb_refuse([self hakiosCb], hakios_metal_error());
		} else {
			HM_ONCE("depth-msaa: encoded colour resolve, samples=%lu\n", (unsigned long)[_resolveFrom[i] sampleCount]);
		}
	}
	/* the bindings were handed to hakios-metal at each draw, which holds them until the GPU is done */
	[_scratch release];
	_scratch = nil;
	[super endEncoding];   /* MUST: the base class retains the command buffer and this is what releases it */
}

@end

@implementation HakiosMetalParallelRenderCommandEncoder

+ (void)load
{
	hm_adopt(self, @protocol(MTLParallelRenderCommandEncoder), "MTLParallelRenderCommandEncoder");
}

HM_REFUSES_OUT_LOUD

- (instancetype)initWithHakiosCommandBuffer:(HakiosMetalCommandBuffer *)commandBuffer pass:(const struct hakios_metal_render_pass *)pass
			       colorTexture:(HakiosMetalTexture *)texture descriptor:(MTLRenderPassDescriptor *)descriptor
{
	self = [super initWithCommandBuffer:commandBuffer];   /* retains the buffer; -endEncoding gives it back */
	if (self == nil) {
		return nil;
	}
	_commandBuffer = commandBuffer;
	_pass = *pass;
	_colorTexture = [texture retain];
	_descriptor = [descriptor copy];
	_subs = [[NSMutableArray alloc] init];
	_lock = [[NSLock alloc] init];
	return self;
}

- (void)dealloc
{
	for (NSValue *v in _subs) hakios_metal_cb_free((hakios_metal_cb *)[v pointerValue]);
	[_subs release];
	[_lock release];
	[_descriptor release];
	[_colorTexture release];
	[super dealloc];
}

- (id)device { return [_commandBuffer device]; }

/* a sub-encoder: the pass as the descriptor gave it for the first, loading what came before for the rest; storing
 * always, since the next one (or the resolve) reads it */
- (id)renderCommandEncoder
{
	struct hakios_metal_render_pass pass = _pass;
	hakios_metal_cb *sub = hakios_metal_cb_new([(HakiosMetalCommandQueue *)[_commandBuffer commandQueue] hakiosQueue]);
	if (sub != NULL) {
		hakios_metal_cb *parent = [_commandBuffer hakiosCommandBuffer];

		/* everything the parent was given at creation -- GMEM/sysmem (metal_gmem=0 must reach these passes too: a new
		 * buffer is GMEM-eligible by default, and GMEM hung the GPU on this phone), pass-wfi, the timing (the
		 * sub-encoders record the passes Maps' summary names) and the refusal policy */
		if (parent != NULL) {
			hakios_metal_cb_inherit_settings(sub, parent);
		} else {
			hakios_metal_cb_skip_refused(sub, !hm_strict());
			hakios_metal_cb_set_profile(sub, hm_fps_on());
			hakios_metal_cb_set_profile_draws(sub, hm_fps_draws());
		}
	}

	[_lock lock];
	const BOOL first = [_subs count] == 0;
	[_subs addObject:[NSValue valueWithPointer:sub]];
	[_lock unlock];
	if (!first) {
		pass.load_action = MTLLoadActionLoad;
		pass.depth_load_action = MTLLoadActionLoad;
		pass.stencil_load_action = MTLLoadActionLoad;
		for (unsigned i = 0; i < 7; i++) pass.more[i].load_action = MTLLoadActionLoad;
	}
	pass.store_action = MTLStoreActionStore;
	pass.depth_store_action = MTLStoreActionStore;
	pass.stencil_store_action = MTLStoreActionStore;
	for (unsigned i = 0; i < 7; i++) pass.more[i].store_action = MTLStoreActionStore;
	HakiosMetalRenderCommandEncoder *encoder = [[[HakiosMetalRenderCommandEncoder alloc] initWithHakiosCommandBuffer:_commandBuffer pass:&pass
													     colorTexture:_colorTexture sub:sub] autorelease];
	unsigned turned[2];

	hm_yinvert_size(_descriptor, turned);   /* (each sub-encoder draws into the same attachment, turned as the pass is) */
	[encoder hakiosSetYInvertWidth:turned[0] height:turned[1]];
	return encoder;
}

/* every sub-encoder stores (above); a resolve asked for here is read from the descriptor's store action at the end */
- (void)setColorStoreAction:(MTLStoreAction)action atIndex:(NSUInteger)index
{
	if (index < 8) [[[_descriptor colorAttachments] objectAtIndexedSubscript:index] setStoreAction:action];
}
- (void)setColorStoreActionOptions:(MTLStoreActionOptions)options atIndex:(NSUInteger)index { (void)options; (void)index; }
- (void)setDepthStoreAction:(MTLStoreAction)action { (void)action; }
- (void)setDepthStoreActionOptions:(MTLStoreActionOptions)options { (void)options; }
- (void)setStencilStoreAction:(MTLStoreAction)action { (void)action; }
- (void)setStencilStoreActionOptions:(MTLStoreActionOptions)options { (void)options; }

- (void)endEncoding
{
	hakios_metal_cb *cb = [_commandBuffer hakiosCommandBuffer];

	[_lock lock];
	for (NSValue *v in _subs) {
		hakios_metal_cb *sub = (hakios_metal_cb *)[v pointerValue];

		if (hakios_metal_cb_append(cb, sub) != 0) {
			hm_print("refused: a parallel render pass's sub-encoder: %s\n", hakios_metal_error());
		}
		hakios_metal_cb_free(sub);
	}
	const BOOL none = [_subs count] == 0;
	[_subs removeAllObjects];
	[_lock unlock];
	/* no sub-encoder at all: the pass's own Clear is still owed */
	if (none && hm_owes_clear(&_pass) && hakios_metal_cb_error(cb)[0] == '\0' && hakios_metal_cb_clear(cb, &_pass) != 0) {
		hm_print("refused: a parallel pass that only clears: %s\n", hakios_metal_error());
		hakios_metal_cb_refuse(cb, hakios_metal_error());
	}
	/* the resolves, once, over everything the sub-encoders drew */
	for (NSUInteger i = 0; i < 8; i++) {
		MTLRenderPassColorAttachmentDescriptor *c = [[_descriptor colorAttachments] objectAtIndexedSubscript:i];
		const MTLStoreAction a = [c storeAction];
		HakiosMetalTexture *from = (HakiosMetalTexture *)[c texture], *to = (HakiosMetalTexture *)[c resolveTexture];

		if (from == nil || to == nil || hakios_metal_cb_error(cb)[0] != '\0' ||
		    !(a == MTLStoreActionMultisampleResolve || a == MTLStoreActionStoreAndMultisampleResolve || a == MTLStoreActionUnknown)) {
			continue;
		}
		if (hakios_metal_cb_blit(cb, [from hakiosTexture], 0, 0, 0, (unsigned)[from width], (unsigned)[from height], [to hakiosTexture],
					 (unsigned)[c resolveLevel], 0, 0, (unsigned)[from width], (unsigned)[from height], 0) != 0) {
			hm_print("refused: the resolve of colour attachment %lu: %s\n", (unsigned long)i, hakios_metal_error());
			hakios_metal_cb_refuse(cb, hakios_metal_error());
		} else {
			HM_ONCE("depth-msaa: encoded parallel colour resolve, samples=%lu\n", (unsigned long)[from sampleCount]);
		}
	}
	[super endEncoding];   /* MUST: the base class retains the command buffer and this is what releases it */
}

@end
