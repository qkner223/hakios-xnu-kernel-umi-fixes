; GPU YCbCr conversion from aligned R8 luma and RG8 chroma plane copies.
source_filename = "ycbcr_convert"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios16.5.0"

declare { <4 x float>, i8 } @air.read_texture_2d.v4f32(ptr addrspace(1), <2 x i32>, i32, i32)
declare void @air.write_texture_2d.v4f32(ptr addrspace(1), <2 x i32>, <4 x float>, i32, i32)

; params = { y_bias, y_scale, cb_bias, cr_bias, r_cr, g_cb, g_cr, b_cb }
define void @ycbcr_convert(ptr addrspace(1) %luma, ptr addrspace(1) %chroma, ptr addrspace(1) %out,
                           ptr addrspace(2) %params, <2 x i32> %gid,
                           <2 x i32> %grid) local_unnamed_addr {
  %p0 = getelementptr inbounds float, ptr addrspace(2) %params, i32 0
  %p1 = getelementptr inbounds float, ptr addrspace(2) %params, i32 1
  %p2 = getelementptr inbounds float, ptr addrspace(2) %params, i32 2
  %p3 = getelementptr inbounds float, ptr addrspace(2) %params, i32 3
  %p4 = getelementptr inbounds float, ptr addrspace(2) %params, i32 4
  %p5 = getelementptr inbounds float, ptr addrspace(2) %params, i32 5
  %p6 = getelementptr inbounds float, ptr addrspace(2) %params, i32 6
  %p7 = getelementptr inbounds float, ptr addrspace(2) %params, i32 7
  %yb = load float, ptr addrspace(2) %p0, align 4
  %ys = load float, ptr addrspace(2) %p1, align 4
  %cb = load float, ptr addrspace(2) %p2, align 4
  %cr = load float, ptr addrspace(2) %p3, align 4
  %rc = load float, ptr addrspace(2) %p4, align 4
  %gc = load float, ptr addrspace(2) %p5, align 4
  %gd = load float, ptr addrspace(2) %p6, align 4
  %bc = load float, ptr addrspace(2) %p7, align 4
  %cxy = lshr <2 x i32> %gid, <i32 1, i32 1>
  %ry = call { <4 x float>, i8 } @air.read_texture_2d.v4f32(ptr addrspace(1) %luma, <2 x i32> %gid, i32 0, i32 0)
  %rcbcr = call { <4 x float>, i8 } @air.read_texture_2d.v4f32(ptr addrspace(1) %chroma, <2 x i32> %cxy, i32 0, i32 0)
  %yv = extractvalue { <4 x float>, i8 } %ry, 0
  %cv = extractvalue { <4 x float>, i8 } %rcbcr, 0
  %y0 = extractelement <4 x float> %yv, i32 0
  %u0 = extractelement <4 x float> %cv, i32 0
  %v0 = extractelement <4 x float> %cv, i32 1
  %y1 = fsub float %y0, %yb
  %y = fmul float %y1, %ys
  %u = fsub float %u0, %cb
  %vv = fsub float %v0, %cr
  %r1 = fmul float %vv, %rc
  %r = fadd float %y, %r1
  %g1 = fmul float %u, %gc
  %g2 = fmul float %vv, %gd
  %g3 = fadd float %g1, %g2
  %g = fsub float %y, %g3
  %b1 = fmul float %u, %bc
  %b = fadd float %y, %b1
  %rlo = call float @air.fast_fmax.f32(float %r, float 0.000000e+00)
  %rhi = call float @air.fast_fmin.f32(float %rlo, float 1.000000e+00)
  %glo = call float @air.fast_fmax.f32(float %g, float 0.000000e+00)
  %ghi = call float @air.fast_fmin.f32(float %glo, float 1.000000e+00)
  %blo = call float @air.fast_fmax.f32(float %b, float 0.000000e+00)
  %bhi = call float @air.fast_fmin.f32(float %blo, float 1.000000e+00)
  %o0 = insertelement <4 x float> undef, float %rhi, i32 0
  %o1 = insertelement <4 x float> %o0, float %ghi, i32 1
  %o2 = insertelement <4 x float> %o1, float %bhi, i32 2
  %o3 = insertelement <4 x float> %o2, float 1.000000e+00, i32 3
  call void @air.write_texture_2d.v4f32(ptr addrspace(1) %out, <2 x i32> %gid, <4 x float> %o3, i32 0, i32 0)
  ret void
}

declare float @air.fast_fmax.f32(float, float)
declare float @air.fast_fmin.f32(float, float)

!air.version = !{!0}
!air.language_version = !{!1}
!air.kernel = !{!2}
!0 = !{i32 2, i32 5, i32 0}
!1 = !{!"Metal", i32 3, i32 0, i32 0}
!2 = !{ptr @ycbcr_convert, !3, !4}
!3 = !{}
!4 = !{!5, !6, !7, !8, !9, !10}
!5 = !{i32 0, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.read", !"air.arg_type_name", !"texture2d<float, read>", !"air.arg_name", !"luma"}
!6 = !{i32 1, !"air.texture", !"air.location_index", i32 1, i32 1, !"air.read", !"air.arg_type_name", !"texture2d<float, read>", !"air.arg_name", !"chroma"}
!7 = !{i32 2, !"air.texture", !"air.location_index", i32 2, i32 1, !"air.write", !"air.arg_type_name", !"texture2d<float, write>", !"air.arg_name", !"out"}
!8 = !{i32 3, !"air.buffer", !"air.buffer_size", i32 32, !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 32, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"float8", !"air.arg_name", !"params"}
!9 = !{i32 4, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint2", !"air.arg_name", !"gid"}
!10 = !{i32 5, !"air.threads_per_grid", !"air.arg_type_name", !"uint2", !"air.arg_name", !"grid"}
