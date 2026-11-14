; gl_ijk_vs_raw: gl_ijk_vs before mem2reg: the generator's own allocas and branches
;
; What AppleMetalGLRenderer's shaders are once Apple's own GL code generator has turned them into AIR: the GLES IR a GL
; program hands -[MTLDevice newFunctionWithGLESIR:inputsDescription:functionType:] goes through
; OpenGLES.framework/libGLVMPlugin.dylib (oglCodeGenServiceGenerateIR) and LLVM's mem2reg + simplifycfg, which is what
; HakiosMetalCA.m does on the phone. Captured on the host from the macOS twin of that plug-in (OpenGL.framework's
; libGLVMPlugin, the same front end for desktop GLSL) and retyped for today's llvm-as: opaque pointers, the iOS triple,
; "OpenGL ES GLSL". The SHAPE is Apple's: a function named "#main" returning a literal struct, varyings named
; user(slotN), the default-uniform block as an air.buffer with its air.buffer_size, textures and samplers as arguments.
;
;     (the source is gl_ijk_vs's) -- what a phone without the LLVM passes (a libLLVM missing the C entry points) would compile
;
;   llvm-as gl_ijk_vs_raw.ll -o gl_ijk_vs_raw.bc

target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios16.5.0"

define { <4 x float>, <2 x float> } @"#main"(<4 x float>, <2 x float>, ptr addrspace(2)) {
allocaBlock:
  %3 = alloca <4 x float>
  %4 = alloca <2 x float>
  %5 = alloca <2 x float>
  %6 = alloca <4 x float>
  %7 = alloca <4 x float>
  %8 = alloca <4 x float>
  %9 = alloca <2 x float>
  %10 = alloca <4 x float>
  %11 = alloca <2 x float>
  br label %globalBlock

globalBlock:                                      ; preds = %allocaBlock
  %12 = getelementptr <4 x float>, ptr addrspace(2) %2, i32 3
  %13 = getelementptr <4 x float>, ptr addrspace(2) %2, i32 2
  %14 = getelementptr <4 x float>, ptr addrspace(2) %2, i32 1
  %15 = getelementptr <4 x float>, ptr addrspace(2) %2, i32 0
  br label %block

block:                                            ; preds = %globalBlock
  store <4 x float> %0, ptr %3
  store <2 x float> %1, ptr %4
  %16 = load <2 x float>, ptr %4
  store <2 x float> %16, ptr %5
  %17 = load <4 x float>, ptr %3
  store <4 x float> %17, ptr %6
  %18 = load <4 x float>, ptr addrspace(2) %12
  %19 = load <4 x float>, ptr %6
  %20 = shufflevector <4 x float> %19, <4 x float> %19, <4 x i32> <i32 3, i32 3, i32 3, i32 3>
  %21 = load <4 x float>, ptr addrspace(2) %13
  %22 = load <4 x float>, ptr %6
  %23 = shufflevector <4 x float> %22, <4 x float> %22, <4 x i32> <i32 2, i32 2, i32 2, i32 2>
  %24 = load <4 x float>, ptr addrspace(2) %14
  %25 = load <4 x float>, ptr %6
  %26 = shufflevector <4 x float> %25, <4 x float> %25, <4 x i32> <i32 1, i32 1, i32 1, i32 1>
  %27 = load <4 x float>, ptr addrspace(2) %15
  %28 = load <4 x float>, ptr %6
  %29 = shufflevector <4 x float> %28, <4 x float> %28, <4 x i32> zeroinitializer
  %30 = fmul fast <4 x float> %27, %29
  %31 = call <4 x float> @air.fma.v4f32(<4 x float> %24, <4 x float> %26, <4 x float> %30)
  %32 = call <4 x float> @air.fma.v4f32(<4 x float> %21, <4 x float> %23, <4 x float> %31)
  %33 = call <4 x float> @air.fma.v4f32(<4 x float> %18, <4 x float> %20, <4 x float> %32)
  store <4 x float> %33, ptr %7
  %34 = load <4 x float>, ptr %7
  store <4 x float> %34, ptr %8
  %35 = load <2 x float>, ptr %5
  %36 = shufflevector <2 x float> %35, <2 x float> %35, <2 x i32> <i32 0, i32 1>
  store <2 x float> %36, ptr %9
  %37 = load <4 x float>, ptr %8
  store <4 x float> %37, ptr %10
  %38 = load <2 x float>, ptr %9
  store <2 x float> %38, ptr %11
  %39 = load <2 x float>, ptr %11
  %40 = insertvalue { <4 x float>, <2 x float> } undef, <2 x float> %39, 1
  %41 = load <4 x float>, ptr %10
  %42 = insertvalue { <4 x float>, <2 x float> } %40, <4 x float> %41, 0
  ret { <4 x float>, <2 x float> } %42
}

declare <4 x float> @air.fma.v4f32(<4 x float>, <4 x float>, <4 x float>)

!air.vertex = !{!0}
!air.version = !{!8}
!air.language_version = !{!9}
!air.compile_options = !{!10, !11, !12, !13}

!0 = !{ptr @"#main", !1, !4}
!1 = !{!2, !3}
!2 = !{!"air.position"}
!3 = !{!"air.vertex_output", !"user(slot8)"}
!4 = !{!5, !6, !7}
!5 = !{i32 0, !"air.vertex_input", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"float4", !"air.arg_name", !"attrib0"}
!6 = !{i32 1, !"air.vertex_input", !"air.location_index", i32 1, i32 1, !"air.arg_type_name", !"float2", !"air.arg_name", !"attrib1"}
!7 = !{i32 2, !"air.buffer", !"air.buffer_size", i32 144, !"air.location_index", i32 0, i32 1, !"air.read"}
!8 = !{i32 2, i32 3, i32 0}
!9 = !{!"OpenGL ES GLSL", i32 1, i32 0, i32 0}
!10 = !{!"air.compile.fast_math_enable"}
!11 = !{!"air.compile.denorms_disable"}
!12 = !{!"air.compile.native_double_disable"}
!13 = !{!"air.compile.framebuffer_fetch_disable"}
