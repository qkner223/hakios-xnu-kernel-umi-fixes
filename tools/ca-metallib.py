#!/usr/bin/env python3
"""ca-metallib.py OUTDIR [SYSIMAGE]: QuartzCore's default.metallib for CoreAnimation drawing through Metal.

OUTDIR/QuartzCore-default.metallib is iOS 16.5's (20F66) own QuartzCore.framework/default.metallib, byte for byte:
the 141 functions this CoreAnimation asks for, the four uber shaders (fixed_vert_lph_gen/_spc, fixed_frag_lph_cpf/_cph)
generic, with the function constants CoreAnimation specialises them with BY NAME (fc_vertex_layout, fc_texture_function,
... 58 for the fragment uber shaders). The system image leaves the file out (sysimage/select-system.py), so it is taken
from the IPSW's root filesystem where it lies:

  1. CA_IOS_METALLIB=FILE, when set;
  2. SYSIMAGE/System/Library/Frameworks/QuartzCore.framework/default.metallib, when the image has it;
  3. sysimage/ios-qc/default.metallib, the copy step 4 leaves;
  4. out of sysimage/rootfs.dmg with 7z (unpack.sh KEEP=1 keeps the dmg), into sysimage/ios-qc/.

Nothing of it goes into the repository (sysimage/ and out/ are not tracked). The library made before 9 November, the
air64 slice of a Mac's later QuartzCore with pipelinelib variants in place of the uber shaders, is not made any more:
a variant declares no function constants, so Metal dropped every named value CoreAnimation passed for a pipeline the
pipeline library lacks ("exact CA configuration: missing named constant fc_vertex_layout" on the phone), and the
Mac's other functions (edr_scale, the blurs' vertex functions) are a later CoreAnimation's, not this one's.

A stale OUTDIR/QuartzCore-exact.plist (the old sidecar) is removed. Build the image with EXTRA_SHARE=OUTDIR.
"""
import hashlib
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import merge_metallib  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
IN_IMAGE = 'System/Library/Frameworks/QuartzCore.framework/default.metallib'
SHA256_20F66 = 'd7cdaaaf3e496bbed67ca83193075e2e0f040aee6567a278587cd81dbd5c4eb9'
UBER = ('fixed_vert_lph_spc', 'fixed_vert_lph_gen', 'fixed_frag_lph_cph', 'fixed_frag_lph_cpf')


def find(image):
    if os.environ.get('CA_IOS_METALLIB'):
        return os.environ['CA_IOS_METALLIB']
    for path in (os.path.join(image, IN_IMAGE), os.path.join(ROOT, 'sysimage/ios-qc/default.metallib')):
        if os.path.isfile(path):
            return path
    dmg = os.path.join(ROOT, 'sysimage/rootfs.dmg')
    if not os.path.isfile(dmg):
        raise SystemExit('no iOS 16.5 QuartzCore default.metallib: set CA_IOS_METALLIB=FILE, or keep sysimage/rootfs.dmg '
                         '(sysimage/unpack.sh KEEP=1) so that it can be taken from there')
    out = os.path.join(ROOT, 'sysimage/ios-qc')
    os.makedirs(out, exist_ok=True)
    seven = shutil.which('7zz') or shutil.which('7z')
    if seven is None:
        raise SystemExit('7z (7-Zip 23 or newer, it reads APFS) is needed to take %s out of %s' % (IN_IMAGE, dmg))
    subprocess.run([seven, 'e', '-y', '-o' + out, dmg, IN_IMAGE], check=True, stdout=subprocess.DEVNULL)
    return os.path.join(out, 'default.metallib')


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    out = sys.argv[1]
    image = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, 'sysimage', 'rootfs')
    src = find(image)
    data = open(src, 'rb').read()
    lib = merge_metallib.read(src)
    names = [dict(f['tags'])[b'NAME'].rstrip(b'\0').decode() for f in lib['funcs']]
    missing = [n for n in UBER if n not in names]
    if missing:
        raise SystemExit('%s: not iOS QuartzCore\'s library (no %s)' % (src, ', '.join(missing)))
    digest = hashlib.sha256(data).hexdigest()
    if digest != SHA256_20F66:
        print('%s: sha256 %s is not 20F66\'s (%s); used as it is' % (src, digest, SHA256_20F66))
    os.makedirs(out, exist_ok=True)
    dst = os.path.join(out, 'QuartzCore-default.metallib')
    with open(dst + '.part', 'wb') as f:
        f.write(data)
    os.replace(dst + '.part', dst)
    stale = os.path.join(out, 'QuartzCore-exact.plist')
    if os.path.exists(stale):
        os.remove(stale)
    print('%s: %d functions, iOS QuartzCore\'s own (%s, sha256 %s)' % (dst, len(names), src, digest))


if __name__ == '__main__':
    main()
