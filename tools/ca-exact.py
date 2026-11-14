"""The pipeline library's records: each precompiled CoreAnimation function of iOS 16.5 with the NAMED, typed
constants CoreAnimation specialised it with (pipelines.desc) and its module (functions). For the host regression
(tools/test-ca-exact.py); the plug-in reads the same files itself (HakiosMetalCA.m, hm_ca_load)."""
import struct
from pathlib import Path

import merge_metallib

LIB = 'System/Library/Frameworks/QuartzCore.framework/default.pipelinelib'


def records(image, scratch):
    """[{label, name, constants{name: bytes}, types{name: MTLDataType}, air, metallib}], in the functions file's order."""
    functions = Path(image, LIB, 'functions').read_bytes()
    libs, at = [], 0
    while (at := functions.find(b'MTLB', at)) >= 0:
        size = struct.unpack_from('<Q', functions, at + 16)[0]
        part = Path(scratch, 'part.metallib')
        part.write_bytes(functions[at:at + size])
        libs.append((functions[at:at + size], merge_metallib.read(part)['funcs'][0]['bitcode']))
        at += size
    data = Path(image, LIB, 'pipelines.desc').read_bytes()
    sections = struct.unpack_from('<11I', data, 4)

    def entries(section):
        start = sections[section]
        count = struct.unpack_from('<I', data, start)[0]
        offsets = struct.unpack_from('<' + 'I' * count, data, start + 4)
        ends = offsets[1:] + (sections[section + 1] - start,)
        return [data[start + a:start + b] for a, b in zip(offsets, ends)]
    labels = [e[16:].split(b'\0')[0].decode() for e in entries(1)]
    out = []
    for label, record, (metallib, air) in zip(labels, entries(5), libs):
        name_end = record.index(b'\0', 32)
        name = record[32:name_end].decode()
        start = (name_end + 4) & ~3
        n = struct.unpack_from('<I', record, start)[0]
        offsets = struct.unpack_from('<' + 'I' * n, record, start + 4)
        values, types = {}, {}
        for offset in offsets:
            e = record[start + offset:]
            # a typed value: the MTLDataType at +9, the byte count at +14, the bytes, then the constant's name
            assert e[:3] == b'\x03\x01\x04' and e[3] in (0x10, 0x12)
            size = e[14]
            assert e[13] == 3 and size in (1, 2, 3, 4, 8)
            key = e[15 + size:].split(b'\0')[0].decode()
            assert key.startswith('fc_')
            values[key] = e[15:15 + size]
            types[key] = struct.unpack_from('<I', e, 9)[0]
        out.append(dict(label=label, name=name, constants=values, types=types, air=air, metallib=metallib))
    return out
