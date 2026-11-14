; gl_ijk_fs: ijkplayer's NV12 fragment shader (IJK_GLES2_getFragmentShader_yuv420sp) as GL compiles it
;
; What AppleMetalGLRenderer's shaders are once Apple's own GL code generator has turned them into AIR: the GLES IR a GL
; program hands -[MTLDevice newFunctionWithGLESIR:inputsDescription:functionType:] goes through
; OpenGLES.framework/libGLVMPlugin.dylib (oglCodeGenServiceGenerateIR) and LLVM's mem2reg + simplifycfg, which is what
; HakiosMetalCA.m does on the phone. Captured on the host from the macOS twin of that plug-in (OpenGL.framework's
; libGLVMPlugin, the same front end for desktop GLSL) and retyped for today's llvm-as: opaque pointers, the iOS triple,
; "OpenGL ES GLSL". The SHAPE is Apple's: a function named "#main" returning a literal struct, varyings named
; user(slotN), the default-uniform block as an air.buffer with its air.buffer_size, textures and samplers as arguments.
;
;     varying highp vec2 vv2_Texcoord; uniform mat3 um3_ColorConversion;
;     uniform lowp sampler2D us2_SamplerX; uniform lowp sampler2D us2_SamplerY;
;     void main() { mediump vec3 yuv; lowp vec3 rgb;
;       yuv.x = (texture2D(us2_SamplerX, vv2_Texcoord).r - (16.0 / 255.0));
;       yuv.yz = (texture2D(us2_SamplerY, vv2_Texcoord).rg - vec2(0.5, 0.5));
;       rgb = um3_ColorConversion * yuv; gl_FragColor = vec4(rgb, 1); }
;
; The Y plane at [[texture(0)]] (R8 over the IOSurface's plane 0) and CbCr at [[texture(1)]] (RG8 over plane 1), each with
; its own [[sampler(n)]]; the mat3 is three float4 columns at bytes 96..143 of the uniform block; the varying is user(slot8),
; as the vertex function writes it.
;
;   llvm-as gl_ijk_fs.ll -o gl_ijk_fs.bc

target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios16.5.0"

define { <4 x float> } @"#main"(<2 x float>, ptr addrspace(2), ptr addrspace(1), ptr addrspace(1), ptr addrspace(2), ptr addrspace(2)) {
allocaBlock:
  %6 = getelementptr <4 x float>, ptr addrspace(2) %1, i32 8
  %7 = getelementptr <4 x float>, ptr addrspace(2) %1, i32 7
  %8 = getelementptr <4 x float>, ptr addrspace(2) %1, i32 6
  %9 = shufflevector <2 x float> %0, <2 x float> %0, <4 x i32> <i32 0, i32 1, i32 1, i32 1>
  %10 = shufflevector <4 x float> %9, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %11 = call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) %2, ptr addrspace(2) %4, <2 x float> %10, i1 false, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0)
  %12 = extractvalue { <4 x float>, i8 } %11, 0
  %13 = extractelement <4 x float> %12, i32 0
  %14 = fsub fast float %13, 0x3FB0101020000000
  %15 = insertelement <3 x float> undef, float %14, i32 0
  %16 = shufflevector <2 x float> %0, <2 x float> %0, <4 x i32> <i32 0, i32 1, i32 1, i32 1>
  %17 = shufflevector <4 x float> %16, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %18 = call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) %3, ptr addrspace(2) %5, <2 x float> %17, i1 false, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0)
  %19 = extractvalue { <4 x float>, i8 } %18, 0
  %20 = shufflevector <4 x float> %19, <4 x float> %19, <2 x i32> <i32 0, i32 1>
  %21 = fsub fast <2 x float> %20, <float 5.000000e-01, float 5.000000e-01>
  %22 = shufflevector <2 x float> %21, <2 x float> undef, <3 x i32> <i32 2, i32 0, i32 1>
  %23 = shufflevector <3 x float> %15, <3 x float> %22, <3 x i32> <i32 0, i32 4, i32 5>
  %24 = bitcast ptr addrspace(2) %6 to ptr addrspace(2)
  %25 = load <3 x float>, ptr addrspace(2) %24
  %26 = shufflevector <3 x float> %23, <3 x float> %23, <3 x i32> <i32 2, i32 2, i32 2>
  %27 = bitcast ptr addrspace(2) %7 to ptr addrspace(2)
  %28 = load <3 x float>, ptr addrspace(2) %27
  %29 = shufflevector <3 x float> %23, <3 x float> %23, <3 x i32> <i32 1, i32 1, i32 1>
  %30 = bitcast ptr addrspace(2) %8 to ptr addrspace(2)
  %31 = load <3 x float>, ptr addrspace(2) %30
  %32 = shufflevector <3 x float> %23, <3 x float> %23, <3 x i32> zeroinitializer
  %33 = fmul fast <3 x float> %31, %32
  %34 = call <3 x float> @air.fma.v3f32(<3 x float> %28, <3 x float> %29, <3 x float> %33)
  %35 = call <3 x float> @air.fma.v3f32(<3 x float> %25, <3 x float> %26, <3 x float> %34)
  %36 = shufflevector <3 x float> %35, <3 x float> <float 1.000000e+00, float undef, float undef>, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %37 = insertvalue { <4 x float> } undef, <4 x float> %36, 0
  ret { <4 x float> } %37
}

declare { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1), ptr addrspace(2), <2 x float>, i1, <2 x i32>, i1, float, float, i32)

declare <3 x float> @air.fma.v3f32(<3 x float>, <3 x float>, <3 x float>)

!air.fragment = !{!0}
!air.version = !{!10}
!air.language_version = !{!11}
!air.compile_options = !{!12, !13, !14, !15}

!0 = !{ptr @"#main", !1, !3}
!1 = !{!2}
!2 = !{!"air.render_target", i32 0, i32 0}
!3 = !{!4, !5, !6, !7, !8, !9}
!4 = !{i32 0, !"air.fragment_input", !"user(slot8)", !"air.perspective", !"air.center", !"air.arg_type_name", !"float2"}
!5 = !{i32 1, !"air.buffer", !"air.buffer_size", i32 144, !"air.location_index", i32 0, i32 1, !"air.read"}
!6 = !{i32 2, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>"}
!7 = !{i32 3, !"air.texture", !"air.location_index", i32 1, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>"}
!8 = !{i32 4, !"air.sampler", !"air.location_index", i32 0, i32 1}
!9 = !{i32 5, !"air.sampler", !"air.location_index", i32 1, i32 1}
!10 = !{i32 2, i32 3, i32 0}
!11 = !{!"OpenGL ES GLSL", i32 1, i32 0, i32 0}
!12 = !{!"air.compile.fast_math_enable"}
!13 = !{!"air.compile.denorms_disable"}
!14 = !{!"air.compile.native_double_disable"}
!15 = !{!"air.compile.framebuffer_fetch_disable"}
