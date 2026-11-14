// macOS host regression for the exact CoreAnimation path (driven by tools/test-ca-exact.py, which documents the cases):
// iOS 16.5's own QuartzCore library, this Mac's real Metal, only the NAMED constants CoreAnimation sets, and the
// plug-in's own code (userland/src/HakiosMetalCAExact.h) reading them back before hakios-metal's compiler.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#include <cstdio>
#include <memory>
#include <string>
#include "hakios-metal/compiler.hpp"
#include "hakios-metal/hakios_metal.h"
#include "hakios-metal/texture.hpp"
using namespace hakios::metal;
#define hm_print printf
#define HM_ONCE(...) do { } while (0)
#include "../../userland/src/HakiosMetalCAExact.h"

namespace {

id<MTLFunction> baseFunction(id<MTLLibrary> lib, NSString *name) {
    return [(id)[lib newFunctionWithName:name] autorelease];
}

id<MTLFunction> makeFunction(id<MTLLibrary> lib, NSString *name, NSDictionary *constants, NSDictionary *types, std::string *why) {
    MTLFunctionConstantValues *values = [[MTLFunctionConstantValues new] autorelease];
    for (NSString *key in constants) {
        NSData *bytes = constants[key];
        [values setConstantValue:[bytes bytes] type:(MTLDataType)[types[key] unsignedIntegerValue] withName:key];
    }
    NSError *error = nil;
    id<MTLFunction> f = [lib newFunctionWithName:name constantValues:values error:&error];
    if (f == nil) *why = std::string("Metal made no ") + [name UTF8String] + ": " + [[error description] UTF8String];
    return [(id)f autorelease];
}

NSData *bitcodeOf(id<MTLFunction> f) {
    return ((NSData *(*)(id, SEL))objc_msgSend)(f, sel_getUid("bitcodeData"));
}

// What the plug-in reads off FUNCTION (as Metal specialised it with the named CONSTANTS), checked against what was set:
// every named value the generic function declares must arrive at its index with its bytes (the root cause of "missing
// named constant fc_vertex_layout" was that none did). BASE is the library's unspecialised function: its AIR is what the
// phone compiles (bitcodeData of a function Metal could not specialise there), and its declarations name the indices.
bool readBack(id<MTLFunction> f, id<MTLFunction> base, NSDictionary *constants, FunctionConstants *out, std::string *why) {
    hakios_metal_constant c[64];
    unsigned n = hm_function_constants(f, c, 64);
    if (NSString *no = hm_ca_exact_why_not(f, bitcodeOf(base), c, n)) {
        *why = [no UTF8String];
        return false;
    }
    NSDictionary *declared = [base functionConstantsDictionary];
    unsigned expected = 0;
    for (NSString *key in constants) {
        MTLFunctionConstant *d = declared[key];
        if (d == nil) continue;
        ++expected;
        uint64_t want = 0;
        memcpy(&want, [constants[key] bytes], [constants[key] length]);
        bool found = false;
        for (unsigned i = 0; i < n; i++) {
            if (c[i].index != [d index]) continue;
            found = true;
            if (c[i].bits != want) {
                *why = std::string([key UTF8String]) + ": the value read back differs from the one set";
                return false;
            }
        }
        if (!found) {
            *why = std::string([key UTF8String]) + ": set by name, not read back";
            return false;
        }
    }
    if (n != expected) {
        *why = "read back " + std::to_string(n) + " values, " + std::to_string(expected) + " were set";
        return false;
    }
    out->clear();
    for (unsigned i = 0; i < n; i++) out->push_back({c[i].index, c[i].bits});
    return true;
}

std::unique_ptr<CompiledProgram> compile(NSData *vsAir, const FunctionConstants &vc, NSData *fsAir, const FunctionConstants &fc,
                                         unsigned format, std::string *why) {
    std::shared_ptr<CompiledStage> vs = compileStage([vsAir bytes], [vsAir length], why, vc);
    if (!vs) return nullptr;
    std::shared_ptr<CompiledStage> fs = compileStage([fsAir bytes], [fsAir length], why, fc, vs->stage.k.numSsbos);
    if (!fs) return nullptr;
    return linkProgram(vs, fs, PixelFormat(format), why);
}

// the program from the generic function and Apple's precompiled one: the same colour outputs (of the pass's
// ATTACHMENTS: the generic configuration's third target, with two attachments, is one Apple's compiler keeps because
// fc_dest_index is not set, and this one drops because an unset constant reads as zero; there is nothing behind it),
// textures, API samplers and fragment inputs. A constexpr sampler takes the index after the API samplers the function
// declares, so the specialised variant, which declares fewer, numbers it lower: counted, not compared by index.
bool same(const CompiledProgram &a, const CompiledProgram &b, unsigned attachments, std::string *why) {
    const Kernel &x = a.program.fs.k, &y = b.program.fs.k;
    const uint32_t outputs = attachments >= 8 ? ~0u : (1u << (4 * attachments)) - 1;
    auto split = [](const CompiledStage &s, uint32_t mask, uint32_t *api, unsigned *inlined) {
        uint32_t own = 0;
        for (const auto &i : s.inlineSamplers) own |= 1u << i.first;
        *api = mask & ~own;
        *inlined = __builtin_popcount(mask & own);
    };
    uint32_t apiA, apiB;
    unsigned inA, inB;
    split(*a.fs, x.samplerMask, &apiA, &inA);
    split(*b.fs, y.samplerMask, &apiB, &inB);
    if ((a.program.link.mrtComponents & outputs) != (b.program.link.mrtComponents & outputs)) *why = "colour outputs differ";
    else if (x.numTextureSlots != y.numTextureSlots) *why = "texture slots differ";
    else if (apiA != apiB || inA != inB) *why = "samplers differ";
    else if (a.fs->varyingNames != b.fs->varyingNames) *why = "fragment inputs differ";
    else return true;
    char counts[160];
    snprintf(counts, sizeof counts, " (mrt %#x/%#x, tex %u/%u, samplers %#x+%u/%#x+%u)", a.program.link.mrtComponents,
             b.program.link.mrtComponents, x.numTextureSlots, y.numTextureSlots, apiA, inA, apiB, inB);
    *why += counts;
    return false;
}

// the vertex record a fragment record's pipelines use: fixed_vert_lph_spc (or _gen for the generic configuration) with
// the fragment's layout and texture coordinates
NSDictionary *vertexFor(NSArray *records, NSDictionary *frag) {
    NSDictionary *fc = frag[@"constants"];
    BOOL generic = ((const uint8_t *)[fc[@"fc_generic"] bytes])[0] != 0;
    for (NSDictionary *v in records) {
        if (![v[@"name"] isEqual:generic ? @"fixed_vert_lph_gen" : @"fixed_vert_lph_spc"]) continue;
        BOOL match = YES;
        for (NSString *key in @[@"fc_vertex_layout", @"fc_texcoord_count0", @"fc_texcoord_count1"]) {
            if (v[@"constants"][key] && fc[key] && ![v[@"constants"][key] isEqual:fc[key]]) match = NO;
        }
        if (match) return v;
    }
    return nil;
}

}  // namespace

int main(int argc, const char **argv) {
    if (argc != 3) return 2;
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *error = nil;
        id<MTLLibrary> lib = [[device newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&error] autorelease];
        if (lib == nil) {
            printf("FAIL: %s: %s\n", argv[1], [[error description] UTF8String]);
            return 1;
        }
        NSDictionary *cases = [NSDictionary dictionaryWithContentsOfFile:@(argv[2])];
        NSArray *records = cases[@"records"];
        unsigned recordsTried = 0, recordsFailed = 0, deviceTried = 0, deviceFailed = 0, constantsRead = 0;

        // 1. every precompiled function of the pipeline library, from the generic function and its named constants
        for (NSDictionary *r in records) {
            if (![r[@"name"] hasPrefix:@"fixed_frag"]) continue;
            ++recordsTried;
            std::string why;
            NSDictionary *v = vertexFor(records, r);
            id<MTLFunction> vf = v ? makeFunction(lib, v[@"name"], v[@"constants"], v[@"types"], &why) : nil;
            id<MTLFunction> ff = makeFunction(lib, r[@"name"], r[@"constants"], r[@"types"], &why);
            FunctionConstants vc, fc;
            id<MTLFunction> vb = v ? baseFunction(lib, v[@"name"]) : nil, fb = baseFunction(lib, r[@"name"]);
            bool ok = v != nil && vf != nil && ff != nil && readBack(vf, vb, v[@"constants"], &vc, &why) &&
                readBack(ff, fb, r[@"constants"], &fc, &why);
            if (v == nil) why = "no vertex record for it";
            if (ok) {
                constantsRead += fc.size() + vc.size();
                std::unique_ptr<CompiledProgram> exact = compile(bitcodeOf(vb), vc, bitcodeOf(fb), fc, 80, &why);
                std::unique_ptr<CompiledProgram> apple = exact ? compile(v[@"air"], {}, r[@"air"], {}, 80, &why) : nullptr;
                unsigned attachments = ((const uint8_t *)[r[@"constants"][@"fc_attachment_count"] bytes])[0];
                ok = exact && apple && same(*exact, *apple, attachments, &why);
            }
            if (!ok) {
                ++recordsFailed;
                printf("FAIL record %s: %s\n", [r[@"label"] UTF8String], why.c_str());
            }
        }

        // 2. every pipeline the phone logged as missing
        for (NSDictionary *d in cases[@"device"]) {
            ++deviceTried;
            std::string why;
            NSDictionary *v = d[@"vertex"], *f = d[@"fragment"];
            id<MTLFunction> vf = makeFunction(lib, v[@"name"], v[@"constants"], v[@"types"], &why);
            id<MTLFunction> ff = vf ? makeFunction(lib, f[@"name"], f[@"constants"], f[@"types"], &why) : nil;
            FunctionConstants vc, fc;
            id<MTLFunction> vb = baseFunction(lib, v[@"name"]), fb = baseFunction(lib, f[@"name"]);
            bool ok = vf && ff && readBack(vf, vb, v[@"constants"], &vc, &why) && readBack(ff, fb, f[@"constants"], &fc, &why);
            std::unique_ptr<CompiledProgram> exact;
            if (ok) {
                exact = compile(bitcodeOf(vb), vc, bitcodeOf(fb), fc, [d[@"format"] unsignedIntValue], &why);
                ok = exact != nullptr;
            }
            if (ok && [f[@"name"] isEqual:@"fixed_frag_lph_cph"]) {
                // the colour output is the one fc_dest_index names (S1: target 1), and nothing else
                unsigned target = ((const uint8_t *)[f[@"constants"][@"fc_dest_index"] bytes])[0];
                ok = exact->program.link.mrtComponents == 0xfu << (4 * target);
                if (!ok) why = "writes colour outputs " + std::to_string(exact->program.link.mrtComponents);
            }
            if (!ok) {
                ++deviceFailed;
                printf("FAIL device %s (%s+%s): %s\n", [d[@"spec"] UTF8String], [v[@"name"] UTF8String], [f[@"name"] UTF8String], why.c_str());
            } else {
                printf("ok   %s: %s (%zu) + %s (%zu)\n", [d[@"spec"] UTF8String], [v[@"name"] UTF8String], vc.size(), [f[@"name"] UTF8String], fc.size());
            }
        }

        // 3. the library of before: a pipelinelib variant as fixed_frag_lph_cph, whose values Metal drops
        bool staleOk = false;
        {
            NSDictionary *s = cases[@"stale"];
            id<MTLLibrary> old = [[device newLibraryWithURL:[NSURL fileURLWithPath:s[@"path"]] error:&error] autorelease];
            std::string why;
            id<MTLFunction> f = old ? makeFunction(old, s[@"name"], s[@"constants"], s[@"types"], &why) : nil;
            hakios_metal_constant c[64];
            unsigned n = f ? hm_function_constants(f, c, 64) : 0;
            NSString *no = f ? hm_ca_exact_why_not(f, bitcodeOf(f), c, n) : nil;
            staleOk = no != nil && [no rangeOfString:@"is a pipelinelib variant"].location != NSNotFound;
            printf("%s stale library: %s\n", staleOk ? "ok  " : "FAIL", no ? [no UTF8String] : why.c_str());
        }

        printf("%u pipelinelib fragment functions compiled from the generic function with their named constants "
               "(%u values read back), %u differ from Apple's variant\n", recordsTried, constantsRead, recordsFailed);
        printf("%u pipelines from the device log compiled exactly, %u failed\n", deviceTried - deviceFailed, deviceFailed);
        return recordsFailed || deviceFailed || deviceTried != 56 || recordsTried != 444 || !staleOk;
    }
}
