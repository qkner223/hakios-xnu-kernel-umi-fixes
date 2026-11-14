#!/usr/bin/env python3
"""Check AIR median3 lowering against a sorting reference through NIR folding.

Run with LLVM 16's llvm-as on PATH. AIR2NIR may name another host frontend.
NaN inputs have undefined results in Metal median3: test acceptance, no payload
or numeric-result promise. Signed zeros compare equal; their sign is not tested.
"""
import importlib.util
import itertools
import math
import os
from pathlib import Path
import tempfile

root = Path(__file__).resolve().parents[2]
os.environ.setdefault("AIR2NIR", str(root / "xnu-deps/build/mesa-host/build/src/compiler/air/air2nir"))
spec = importlib.util.spec_from_file_location("intrincheck", root / "tools/air/intrincheck.py")
ic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ic)

triples = list(itertools.permutations((-4.0, 0.5, 3.0)))
triples += list(itertools.permutations((-math.inf, 2.0, math.inf)))
triples += [(2.0, 2.0, -1.0), (-2.0, -2.0, 7.0), (0.0, -0.0, 1.0),
            (-0.0, 0.0, -1.0), (math.inf, math.inf, 0.0),
            (-math.inf, -math.inf, 0.0)]
checks = 0
with tempfile.TemporaryDirectory(prefix="hakios-median3-") as tmp:
    for bits, ty in ((16, "half"), (32, "float")):
        for width in (1, 2, 3, 4):
            llvm_ty = ty if width == 1 else f"<{width} x {ty}>"
            name = f"air.fmedian3.{'' if width == 1 else f'v{width}'}f{bits}"
            decl = f"declare {llvm_ty} @{name}({llvm_ty}, {llvm_ty}, {llvm_ty})"
            for triple in triples + [(math.nan, 1.0, 2.0), (1.0, math.nan, 2.0), (1.0, 2.0, math.nan)]:
                # A different permutation per lane catches accidental scalarization.
                args = [[triple[(j + lane) % 3] for lane in range(width)] for j in range(3)]
                got, error = ic.emit(decl, name, [llvm_ty] * 3, llvm_ty, [args], tmp, False)
                assert error is None, (name, triple, error)
                if not any(math.isnan(x) for x in triple):
                    want = sorted(triple)[1]
                    assert got[0] == [want] * width, (name, triple, got, want)
                    checks += width
print(f"median3: {checks} numeric component checks passed; all NaN placements accepted (undefined result)")
