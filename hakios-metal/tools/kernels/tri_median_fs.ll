; Median3 regression: dynamic scalar and vector2/3/4 calls at both precisions. MIT.
source_filename = "tri_median_fs"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios16.5.0"

define <4 x float> @tri_median_fs(<4 x float> %a, <4 x float> %b, <4 x float> %c) {
  %rawa_16_1 = extractelement <4 x float> %a, i32 0
  %a_16_1 = fptrunc float %rawa_16_1 to half
  %rawb_16_1 = extractelement <4 x float> %b, i32 0
  %b_16_1 = fptrunc float %rawb_16_1 to half
  %rawc_16_1 = extractelement <4 x float> %c, i32 0
  %c_16_1 = fptrunc float %rawc_16_1 to half
  %m_16_1 = call half @air.fmedian3.f16(half %a_16_1, half %b_16_1, half %c_16_1)
  %f_16_1 = fpext half %m_16_1 to float
  %rawa_16_2 = shufflevector <4 x float> %a, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %a_16_2 = fptrunc <2 x float> %rawa_16_2 to <2 x half>
  %rawb_16_2 = shufflevector <4 x float> %b, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %b_16_2 = fptrunc <2 x float> %rawb_16_2 to <2 x half>
  %rawc_16_2 = shufflevector <4 x float> %c, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %c_16_2 = fptrunc <2 x float> %rawc_16_2 to <2 x half>
  %m_16_2 = call <2 x half> @air.fmedian3.v2f16(<2 x half> %a_16_2, <2 x half> %b_16_2, <2 x half> %c_16_2)
  %e_16_2 = extractelement <2 x half> %m_16_2, i32 1
  %f_16_2 = fpext half %e_16_2 to float
  %rawa_16_3 = shufflevector <4 x float> %a, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %a_16_3 = fptrunc <3 x float> %rawa_16_3 to <3 x half>
  %rawb_16_3 = shufflevector <4 x float> %b, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %b_16_3 = fptrunc <3 x float> %rawb_16_3 to <3 x half>
  %rawc_16_3 = shufflevector <4 x float> %c, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %c_16_3 = fptrunc <3 x float> %rawc_16_3 to <3 x half>
  %m_16_3 = call <3 x half> @air.fmedian3.v3f16(<3 x half> %a_16_3, <3 x half> %b_16_3, <3 x half> %c_16_3)
  %e_16_3 = extractelement <3 x half> %m_16_3, i32 2
  %f_16_3 = fpext half %e_16_3 to float
  %a_16_4 = fptrunc <4 x float> %a to <4 x half>
  %b_16_4 = fptrunc <4 x float> %b to <4 x half>
  %c_16_4 = fptrunc <4 x float> %c to <4 x half>
  %m_16_4 = call <4 x half> @air.fmedian3.v4f16(<4 x half> %a_16_4, <4 x half> %b_16_4, <4 x half> %c_16_4)
  %e_16_4 = extractelement <4 x half> %m_16_4, i32 3
  %f_16_4 = fpext half %e_16_4 to float
  %rawa_32_1 = extractelement <4 x float> %a, i32 0
  %rawb_32_1 = extractelement <4 x float> %b, i32 0
  %rawc_32_1 = extractelement <4 x float> %c, i32 0
  %m_32_1 = call float @air.fmedian3.f32(float %rawa_32_1, float %rawb_32_1, float %rawc_32_1)
  %rawa_32_2 = shufflevector <4 x float> %a, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %rawb_32_2 = shufflevector <4 x float> %b, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %rawc_32_2 = shufflevector <4 x float> %c, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %m_32_2 = call <2 x float> @air.fmedian3.v2f32(<2 x float> %rawa_32_2, <2 x float> %rawb_32_2, <2 x float> %rawc_32_2)
  %e_32_2 = extractelement <2 x float> %m_32_2, i32 1
  %rawa_32_3 = shufflevector <4 x float> %a, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %rawb_32_3 = shufflevector <4 x float> %b, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %rawc_32_3 = shufflevector <4 x float> %c, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %m_32_3 = call <3 x float> @air.fmedian3.v3f32(<3 x float> %rawa_32_3, <3 x float> %rawb_32_3, <3 x float> %rawc_32_3)
  %e_32_3 = extractelement <3 x float> %m_32_3, i32 2
  %m_32_4 = call <4 x float> @air.fmedian3.v4f32(<4 x float> %a, <4 x float> %b, <4 x float> %c)
  %e_32_4 = extractelement <4 x float> %m_32_4, i32 3
  %s0 = fadd float %f_16_1, %m_32_1
  %s1 = fadd float %f_16_2, %e_32_2
  %s2 = fadd float %f_16_3, %e_32_3
  %s3 = fadd float %f_16_4, %e_32_4
  %r0 = insertelement <4 x float> undef, float %s0, i32 0
  %r1 = insertelement <4 x float> %r0, float %s1, i32 1
  %r2 = insertelement <4 x float> %r1, float %s2, i32 2
  %r3 = insertelement <4 x float> %r2, float %s3, i32 3
  ret <4 x float> %r3
}

declare half @air.fmedian3.f16(half, half, half)
declare <2 x half> @air.fmedian3.v2f16(<2 x half>, <2 x half>, <2 x half>)
declare <3 x half> @air.fmedian3.v3f16(<3 x half>, <3 x half>, <3 x half>)
declare <4 x half> @air.fmedian3.v4f16(<4 x half>, <4 x half>, <4 x half>)
declare float @air.fmedian3.f32(float, float, float)
declare <2 x float> @air.fmedian3.v2f32(<2 x float>, <2 x float>, <2 x float>)
declare <3 x float> @air.fmedian3.v3f32(<3 x float>, <3 x float>, <3 x float>)
declare <4 x float> @air.fmedian3.v4f32(<4 x float>, <4 x float>, <4 x float>)

!air.version = !{!0}
!air.language_version = !{!1}
!air.fragment = !{!2}

!0 = !{i32 2, i32 5, i32 0}
!1 = !{!"Metal", i32 3, i32 0, i32 0}
!2 = !{ptr @tri_median_fs, !3, !5}
!3 = !{!4}
!4 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4"}
!5 = !{!6, !7, !8}
!6 = !{i32 0, !"air.fragment_input", !"generated(a)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float4", !"air.arg_name", !"a"}
!7 = !{i32 1, !"air.fragment_input", !"generated(b)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float4", !"air.arg_name", !"b"}
!8 = !{i32 2, !"air.fragment_input", !"generated(c)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float4", !"air.arg_name", !"c"}
