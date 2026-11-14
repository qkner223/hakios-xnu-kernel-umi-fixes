; gl_ijk_vs: ijkplayer's vertex shader (IJK_GLES2_getVertexShader_default) as GL compiles it
;
; What AppleMetalGLRenderer's shaders are once Apple's own GL code generator has turned them into AIR: the GLES IR a GL
; program hands -[MTLDevice newFunctionWithGLESIR:inputsDescription:functionType:] goes through
; OpenGLES.framework/libGLVMPlugin.dylib (oglCodeGenServiceGenerateIR) and LLVM's mem2reg + simplifycfg, which is what
; HakiosMetalCA.m does on the phone. Captured on the host from the macOS twin of that plug-in (OpenGL.framework's
; libGLVMPlugin, the same front end for desktop GLSL) and retyped for today's llvm-as: opaque pointers, the iOS triple,
; "OpenGL ES GLSL". The SHAPE is Apple's: a function named "#main" returning a literal struct, varyings named
; user(slotN), the default-uniform block as an air.buffer with its air.buffer_size, textures and samplers as arguments.
;
;     attribute highp vec4 av4_Position; attribute highp vec2 av2_Texcoord; uniform mat4 um4_ModelViewProjection;
;     varying highp vec2 vv2_Texcoord;
;     void main() { gl_Position = um4_ModelViewProjection * av4_Position; vv2_Texcoord = av2_Texcoord.xy; }
;
; The matrix is the first 64 bytes of the 144-byte uniform block at buffer 0; the attributes are [[attribute(0)]] (a
; float4) and [[attribute(1)]] (a float2), fetched through the pipeline's vertex descriptor.
;
;   llvm-as gl_ijk_vs.ll -o gl_ijk_vs.bc

target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios16.5.0"

define { <4 x float>, <2 x float> } @"#main"(<4 x float>, <2 x float>, ptr addrspace(2)) {
allocaBlock:
  %3 = getelementptr <4 x float>, ptr addrspace(2) %2, i32 3
  %4 = getelementptr <4 x float>, ptr addrspace(2) %2, i32 2
  %5 = getelementptr <4 x float>, ptr addrspace(2) %2, i32 1
  %6 = getelementptr <4 x float>, ptr addrspace(2) %2, i32 0
  %7 = load <4 x float>, ptr addrspace(2) %3
  %8 = shufflevector <4 x float> %0, <4 x float> %0, <4 x i32> <i32 3, i32 3, i32 3, i32 3>
  %9 = load <4 x float>, ptr addrspace(2) %4
  %10 = shufflevector <4 x float> %0, <4 x float> %0, <4 x i32> <i32 2, i32 2, i32 2, i32 2>
  %11 = load <4 x float>, ptr addrspace(2) %5
  %12 = shufflevector <4 x float> %0, <4 x float> %0, <4 x i32> <i32 1, i32 1, i32 1, i32 1>
  %13 = load <4 x float>, ptr addrspace(2) %6
  %14 = shufflevector <4 x float> %0, <4 x float> %0, <4 x i32> zeroinitializer
  %15 = fmul fast <4 x float> %13, %14
  %16 = call <4 x float> @air.fma.v4f32(<4 x float> %11, <4 x float> %12, <4 x float> %15)
  %17 = call <4 x float> @air.fma.v4f32(<4 x float> %9, <4 x float> %10, <4 x float> %16)
  %18 = call <4 x float> @air.fma.v4f32(<4 x float> %7, <4 x float> %8, <4 x float> %17)
  %19 = shufflevector <2 x float> %1, <2 x float> %1, <2 x i32> <i32 0, i32 1>
  %20 = insertvalue { <4 x float>, <2 x float> } undef, <2 x float> %19, 1
  %21 = insertvalue { <4 x float>, <2 x float> } %20, <4 x float> %18, 0
  ret { <4 x float>, <2 x float> } %21
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
