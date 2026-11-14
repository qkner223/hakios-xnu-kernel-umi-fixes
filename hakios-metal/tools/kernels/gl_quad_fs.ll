; gl_quad_fs: a textured quad's fragment shader as GL compiles it
;
; What AppleMetalGLRenderer's shaders are once Apple's own GL code generator has turned them into AIR: the GLES IR a GL
; program hands -[MTLDevice newFunctionWithGLESIR:inputsDescription:functionType:] goes through
; OpenGLES.framework/libGLVMPlugin.dylib (oglCodeGenServiceGenerateIR) and LLVM's mem2reg + simplifycfg, which is what
; HakiosMetalCA.m does on the phone. Captured on the host from the macOS twin of that plug-in (OpenGL.framework's
; libGLVMPlugin, the same front end for desktop GLSL) and retyped for today's llvm-as: opaque pointers, the iOS triple,
; "OpenGL ES GLSL". The SHAPE is Apple's: a function named "#main" returning a literal struct, varyings named
; user(slotN), the default-uniform block as an air.buffer with its air.buffer_size, textures and samplers as arguments.
;
;     uniform sampler2D t; varying vec2 v; void main() { gl_FragColor = texture2D(t, v); }
;
;   llvm-as gl_quad_fs.ll -o gl_quad_fs.bc

target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios16.5.0"

define { <4 x float> } @"#main"(<2 x float>, ptr addrspace(2), ptr addrspace(1), ptr addrspace(2)) {
allocaBlock:
  %4 = shufflevector <2 x float> %0, <2 x float> %0, <4 x i32> <i32 0, i32 1, i32 1, i32 1>
  %5 = shufflevector <4 x float> %4, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %6 = call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) %2, ptr addrspace(2) %3, <2 x float> %5, i1 false, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0)
  %7 = extractvalue { <4 x float>, i8 } %6, 0
  %8 = insertvalue { <4 x float> } undef, <4 x float> %7, 0
  ret { <4 x float> } %8
}

declare { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1), ptr addrspace(2), <2 x float>, i1, <2 x i32>, i1, float, float, i32)

!air.fragment = !{!0}
!air.version = !{!8}
!air.language_version = !{!9}
!air.compile_options = !{!10, !11, !12, !13}

!0 = !{ptr @"#main", !1, !3}
!1 = !{!2}
!2 = !{!"air.render_target", i32 0, i32 0}
!3 = !{!4, !5, !6, !7}
!4 = !{i32 0, !"air.fragment_input", !"user(slot8)", !"air.perspective", !"air.center", !"air.arg_type_name", !"float2"}
!5 = !{i32 1, !"air.buffer", !"air.buffer_size", i32 16, !"air.location_index", i32 0, i32 1, !"air.read"}
!6 = !{i32 2, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>"}
!7 = !{i32 3, !"air.sampler", !"air.location_index", i32 0, i32 1}
!8 = !{i32 2, i32 3, i32 0}
!9 = !{!"OpenGL ES GLSL", i32 1, i32 0, i32 0}
!10 = !{!"air.compile.fast_math_enable"}
!11 = !{!"air.compile.denorms_disable"}
!12 = !{!"air.compile.native_double_disable"}
!13 = !{!"air.compile.framebuffer_fetch_disable"}
