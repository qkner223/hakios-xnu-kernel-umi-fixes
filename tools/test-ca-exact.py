#!/usr/bin/env python3
"""Host-only regression for the exact CoreAnimation path: test-ca-exact.py CA_EXACT_BINARY [LIBRARY]

The binary (hakios-metal/tests/ca_exact.mm) loads iOS 16.5's own QuartzCore default.metallib (the one
tools/ca-metallib.py puts in ca-share; LIBRARY overrides) with this Mac's real Metal, makes each function exactly as
CoreAnimation does -- -[MTLLibrary newFunctionWithName:constantValues:error:] with ONLY the named, typed constants
CoreAnimation sets (MTLFunctionConstantValues setConstantValue:type:withName:) -- reads the values back with the
plug-in's own code (userland/src/HakiosMetalCAExact.h) and compiles the function's own AIR with them. Cases:

  records   every precompiled function of the pipeline library (451) with the named constants pipelines.desc
            records for it. The program compiled from the generic function must match Apple's precompiled variant
            (colour outputs, texture slots, samplers, fragment inputs).
  device    every pipeline the phone logged as missing on 2026-11-09 (logs/test-1109-175406-umi-ca-flash-v2b,
            "exact CA configuration unavailable for ..."), 56 in all. Their named constants are derived from the
            pipeline's label by the decoder below, which first has to reproduce the recorded constants of every
            labelled pipelinelib function exactly; the dedicated functions (blurs, downsamples, home affordance,
            attachment clear, luma boost) are paired with the vertex function the phone linked them with.
  stale     a pipelinelib variant standing in as the library's fixed_frag_lph_cph (the ca-share of before): the
            exact path must refuse it with the precise reason, not compile something else.
"""
import importlib
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / 'sysimage/rootfs'

# --- the label decoder ---------------------------------------------------------------------------------------------
# com.apple.coreanimation.frag.[T<texture function>][B<blend>][D<destination>]A<attachments>[S<dest index>][L<layout>]
# X<flags>(_I<image>[N<inputs>O<opcodes>][Xq][C<coord>][M<memoryless>][Fbx])*. The values of the codes are read off the
# pipelinelib's own records (learn()), with the few the phone used that no record has taken from QuartzCore's name
# tables, whose order is the enum's (texture functions: ... vcm 45, vdk 46, vlt 47, map 48, mpc 49 ...; image
# functions: ... srg 29, ryb 30, wht 31, grn 32, blu 33 ...).
LABEL = re.compile(r'^(?:T([a-z0-9]{3}))?(?:B([a-z0-9]{3}))?(?:D([a-z0-9]{2}))?A(\d)(?:S(\d))?(?:L([a-z]+))?X([a-z]*)((?:_I.*)?)$')
TEXTURE = {'vdk': 46}
BLEND, DESTINATION = {}, {}
# image function: (fc_image_function, planes, texcoords, has_image A B C)
IMAGE_FN = {'src': (0, 1, 1, '100'), 'xrg': (1, 1, 1, '100'), 'sar': (2, 1, 1, '100'), 'sxr': (3, 1, 1, '100'),
            'ara': (6, 1, 1, '100'), 'sqr': (9, 0, 1, '000'), 'cir': (10, 0, 1, '000'), 'sup': (11, 0, 1, '000'),
            'uec': (13, 0, 1, '000'), 'clr': (15, 0, 0, '000'), 'red': (16, 1, 1, '100'), 'alp': (17, 1, 1, '100'),
            'ybr': (20, 2, 2, '110'), 'sr1': (28, 1, 1, '100'), 'srg': (29, 1, 1, '100'), 'wht': (31, 1, 1, '100'),
            'grn': (32, 1, 1, '100'), 'blu': (33, 1, 1, '100'), 'y3p': (35, 3, 2, '111'), 'dst': (36, 0, 0, '000')}
OPS = {'N3Oc0c4nl': ('020600', 3), 'N3Oc3c4nl': ('050600', 3), 'N3Oc3mtc4': ('050106', 3)}
COORD = {'Ccl': 5, 'Clm': 4, 'Crd': 1, 'Ctl': 3}
READS_DESTINATION = ('vcm', 'vdk', 'vlt', 'bds', 'aup')   # texture functions with fc_dest_count 1
TYPES = {}


def learn(records):
    for r in records:
        if not r['name'].startswith('fixed_frag'):
            continue
        TYPES.update(r['types'])
        m = LABEL.match(r['label'].split('.')[-1])
        if m is None:
            continue
        k = r['constants']
        if m.group(1) and 'fc_texture_function' in k:
            TEXTURE[m.group(1)] = k['fc_texture_function'][0]
        if m.group(2) and 'fc_blend_function' in k:
            BLEND[m.group(2)] = k['fc_blend_function'][0]
        if m.group(3) and 'fc_destination_function' in k:
            DESTINATION[m.group(3)] = k['fc_destination_function'][0]


def decode(spec):
    """The 58 named constants CoreAnimation passes to fixed_frag_lph_cph / _cpf for a fragment label."""
    T, B, D, A, S, L, X, I = LABEL.match(spec).groups()
    b = lambda v: bytes([int(v)])
    k = {'fc_generic': b('g' in X), 'fc_framebuffer_fetch': b(1), 'fc_framebuffer_sample': b(0),
         'fc_attachment_count': b(A), 'fc_vertex_layout': b(L == 'ln')}
    for n in ('lod_bias', 'noise_scale', 'ycbcr_matrix', 'gamma_luts', 'asg_77_weights', 'noise_tex', 'color_params',
              'lut_tex', 'attachment_0', 'attachment_1', 'attachment_2'):
        k['fc_has_' + n] = b(0)
    for i in range(2):
        k['fc_has_color_trc%d' % i] = k['fc_has_color_cube%d' % i] = b(0)
        for s in 'ABC':
            k['fc_has_image_%d%s' % (i, s)] = b(0)
    if 'g' in X:   # the generic configuration: every resource there, the rest in the configuration buffer
        for n in k:
            if n.startswith('fc_has_') and not n.startswith('fc_has_attachment'):
                k[n] = b(1)
        return k
    n = 'n' in X
    k.update({'fc_texture_function': b(TEXTURE[T] if T else 0), 'fc_blend_function': b(BLEND[B] if B else 54),
              'fc_destination_function': b(DESTINATION[D] if D else 0), 'fc_dest_index': b(S or 0),
              'fc_clamp_color': b(0), 'fc_debug_xr': b(0), 'fc_has_premultiply': b(0), 'fc_has_hdr_scale': b(0),
              'fc_has_edr_factor': b(0), 'fc_extended_range': b('x' in X), 'fc_unbounded_range': b('u' in X),
              'fc_noise_width': b(32 if n else 0), 'fc_has_noise_tex': b(n), 'fc_has_noise_scale': b(n),
              'fc_has_lut_tex': b(T == '3dl')})
    images = I.split('_I')[1:] if I else []
    k['fc_image_count'] = b(len(images))
    for i in range(2):
        for f in ('image_function', 'coord_function', 'filter', 'color_inputs', 'color_opaque', 'plane_count',
                  'texcoord_count', 'memoryless_index'):
            k['fc_%s%d' % (f, i)] = b(0)
        k['fc_color_opcodes%d' % i] = bytes(3)
    dest = lod = params = ycbcr = 0
    for i, seg in enumerate(images):
        code, rest = seg[:3], seg[3:]
        fn, planes, texcoords, has = IMAGE_FN[code]
        ops, xq, coord, mem, fbx = re.match(r'^(N\d+O[a-z0-9]+?)?(Xq)?(C[a-z]{2})?(M\d)?(Fbx)?$', rest).groups()
        k['fc_image_function%d' % i] = b(fn)
        k['fc_plane_count%d' % i] = b(planes)
        k['fc_texcoord_count%d' % i] = b(texcoords)
        if ops:
            k['fc_color_opcodes%d' % i] = bytes.fromhex(OPS[ops][0])
            k['fc_color_inputs%d' % i] = b(OPS[ops][1])
            params = 1
        if xq:
            k['fc_color_opaque%d' % i] = b(1)
        if coord:
            k['fc_coord_function%d' % i] = b(COORD[coord])
        if fbx:
            k['fc_filter%d' % i] = b(4)
        if mem:   # read from a memoryless attachment (index + 1), not a texture
            k['fc_memoryless_index%d' % i] = b(int(mem[1:]) + 1)
            has = '000'
        for j, s in enumerate('ABC'):
            k['fc_has_image_%d%s' % (i, s)] = b(has[j])
        lod |= planes > 0
        dest |= code == 'dst'
        ycbcr |= code in ('ybr', 'y3p')
    k['fc_dest_count'] = b(bool(dest or B or D or T in READS_DESTINATION))
    k['fc_has_lod_bias'] = b(lod)
    k['fc_has_color_params'] = b(params)
    k['fc_has_ycbcr_matrix'] = b(ycbcr)
    return k


# --- what the phone logged ------------------------------------------------------------------------------------------
DEVICE = '''PBGRABsapXm_TimgA2S1Xhf_Ixrg PBGRABsapXm_TmuaA2S1Xhf_Ixrg_Isqr PBGRABsovXm_Tc33A2Xhf_Isrc
PBGRABsovXm_TcimA2S1Xhf_Igrn PBGRABsovXm_TcimA2S1Xhfn_IsrcN3Oc3mtc4 PBGRABsovXm_TcimA2Xhf_Iclr PBGRABsovXm_TcimA2Xhf_Isqr
PBGRABsovXm_TcimA2Xhf_IxrgN3Oc3c4nlXq PBGRABsovXm_TcimA2Xhfn_IsrcN3Oc3mtc4 PBGRABsovXm_Tds4A2Xhf_Isrc
PBGRABsovXm_Tds8A2Xhf_Isrc PBGRABsovXm_TimgA2S1Xhf_Ired PBGRABsovXm_TimgA2Xhf_Isqr PBGRABsovXm_TmuaA2S1Xhf_Isrc_Isqr
PBGRABsovXm_TmuaA2S1Xhfn_IsrcCcl_Isup PBGRABsovXm_TmuaA2Xhf_Iclr_Isqr PBGRABsovXm_TmuaA2Xhf_Ired_Icir
PBGRABsovXm_TmuaA2Xhf_IsrcCcl_Isrg PBGRABsovXm_TmuaA2Xhf_IsrcM1_Isqr PBGRABsovXm_TmuaA2Xhf_IxrgN3Oc3c4nlXq_Isup
PBGRABsovXm_TmuaA2Xhfn_Isrc_Isqr PBGRABsovXm_TmuaA2Xhfn_IsrcCcl_Icir PBGRABsovXm_TvdkA2Xhf_Isrc PBGRAXm_TatcA2S1Xhf
PBGRAXm_TbdsA2Xhf_Isrg_IsrcM1 PBGRAXm_Tc33A2S1Xhf_Idst PBGRAXm_TcimBdsoA2Xhf_Icir PBGRAXm_TcimBpldA2Xhf_Isup
PBGRAXm_TcimBvcmA2Xhf_Icir PBGRAXm_TcimBvcmA2Xhf_Isrg PBGRAXm_TcmaBpldA2LlnXhf PBGRAXm_Tds4A2Xhf_Isrc
PBGRAXm_Tds8A2Xhf_Isrc PBGRAXm_ThomA2Xhf_Isrc_Isrc PBGRAXm_TidaA2Xhf_Isrc PBGRAXm_TimgA2S1Xhfn_IsrcN3Oc3mtc4
PBGRAXm_TimgA2Xhf_Isqr PBGRAXm_TimgA2Xhf_IxrgN3Oc3c4nlXq PBGRAXm_TimgA2Xhfn_IsrcN3Oc3mtc4 PBGRAXm_TimgBdsoA2Xhfn_Isrc
PBGRAXm_TimgBvcmA2Xhf_Isrg PBGRAXm_TlubA2Xhf_Isrc PBGRAXm_TmapA2Xhf_Idst_Isr1Clm PBGRAXm_TmpcA2S1Xhf_Idst
PBGRAXm_TmuaA2Xhf_IxrgN3Oc3c4nlXq_Isup PBGRAXm_TmuaBvcmA2Xhf_Iwht_Isup PBGRAXm_Tn11A2Xhf_Isrc PBGRAXm_Tn15A2Xhf_Isrc
PBGRAXm_Tn19A2Xhf_Isrc PBGRAXm_Tn23A2Xhf_Isrc PBGRAXm_Tn27A2Xhf_Isrc PBGRAXm_Tnb7A2Xhf_Isrc PBGRAXm_Tsb3A2Xhf_Isrc
PBGRAXm_TvrbA2Xhfn_Isrc_Isrc PBGRAXm_TvrdA2Xhf_Isrc PRGhAXm_Tn23A2Xhf_Isrc'''.split()
# texture functions that are functions of their own (QuartzCore's texture_function_info names them), with the vertex
# function the phone linked each with ("linked downsample_blur_vert_lph+downsample_4_frag_lph ...")
DEDICATED = {'ds4': ('downsample_blur_vert_lph', 'downsample_4_frag_lph'),
             'ds8': ('downsample_blur_vert_lph', 'downsample_8_frag_lph'),
             'nb7': ('downsample_blur_vert_lph', 'narrow_blur_7_frag_lph'),
             'n11': ('downsample_blur_vert_lph', 'narrow_blur_11_frag_lph'),
             'n15': ('downsample_blur_vert_lph', 'narrow_blur_15_frag_lph'),
             'n19': ('downsample_blur_vert_lph', 'narrow_blur_19_frag_lph'),
             'n23': ('downsample_blur_vert_lph', 'narrow_blur_23_frag_lph'),
             'n27': ('downsample_blur_vert_lph', 'narrow_blur_27_frag_lph'),
             'sb3': ('downsample_blur_vert_lph', 'single_pass_blur_3_lph'),
             'vrd': ('downsample_blur_vert_lph', 'variable_blur_downsample_frag_lph'),
             'vrb': ('variable_blur_vert_lph', 'variable_blur_frag_lph'),
             'hom': ('std_vert1_lph', 'home_affordance_base_lph'),
             'lub': ('std_vert1_lph', 'luma_boost_lph'),
             'atc': ('path_blit_vert_lph', 'attachment_clear_frag_lph')}
FORMATS = {'BGRA': 80, 'RGhA': 115}   # MTLPixelFormatBGRA8Unorm, MTLPixelFormatRGBA16Float


def device_case(pipeline):
    draw, spec = pipeline.split('_', 1)
    texture = spec[1:4] if spec.startswith('T') else ''
    case = dict(spec=pipeline, format=FORMATS[draw[1:5]])
    if texture in DEDICATED:
        vs, fs = DEDICATED[texture]
        case.update(vertex=dict(name=vs, constants={}, types={}), fragment=dict(name=fs, constants={}, types={}))
        return case
    fc = decode(spec)
    vc = {n: fc[n] for n in ('fc_vertex_layout', 'fc_texcoord_count0', 'fc_texcoord_count1')}
    vc['fc_generic'] = bytes([0])
    case.update(vertex=dict(name='fixed_vert_lph_spc', constants=vc, types={n: TYPES[n] for n in vc}),
                fragment=dict(name='fixed_frag_lph_cph', constants=fc, types={n: TYPES[n] for n in fc}))
    return case


def main():
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='umi-ca-exact-') as directory:
        library = sys.argv[2] if len(sys.argv) > 2 else importlib.import_module('ca-metallib').find(str(IMAGE))
        records = importlib.import_module('ca-exact').records(IMAGE, directory)
        learn(records)
        labelled = decoded = 0
        for r in records:
            if not r['name'].startswith('fixed_frag'):
                continue
            labelled += 1
            got = decode(r['label'].split('.')[-1])
            if got != r['constants']:
                diff = sorted(n for n in set(got) | set(r['constants']) if got.get(n) != r['constants'].get(n))
                sys.exit('decoder: %s does not reproduce the recorded constants (%s)' % (r['label'], ', '.join(diff)))
            decoded += 1
        print('label decoder: %d of %d labelled pipelinelib fragment functions reproduced exactly' % (decoded, labelled))
        assert len(DEVICE) == 56 and len(set(DEVICE)) == 56
        stale = next(r for r in records if r['name'] == 'fixed_frag_lph_cph')
        Path(directory, 'stale.metallib').write_bytes(stale['metallib'])
        cases = dict(records=[{k: v for k, v in r.items() if k != 'metallib'} for r in records],
                     device=[device_case(p) for p in DEVICE],
                     stale=dict(path=str(Path(directory, 'stale.metallib')), name=stale['name'], label=stale['label'],
                                constants=stale['constants'], types=stale['types']))
        Path(directory, 'cases.plist').write_bytes(plistlib.dumps(cases))
        subprocess.run([str(binary), str(library), str(Path(directory, 'cases.plist'))],
                       env=dict(os.environ, HAKIOS_METAL_LISTING='0'), check=True)


if __name__ == '__main__':
    main()
