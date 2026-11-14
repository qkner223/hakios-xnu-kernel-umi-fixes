# Maps v28：黑底、缺少面填充与缩放残影（2026-11-11）

本次只修改、测试主机上的用户态代码；没有访问手机，没有修改内核 GPU 驱动、调度或 boot-args。真机画面仍需 supervisor 验证。

## 证据与两个缺陷

输入是 `../../logs/v28-snap/v28-maps.log`、完整的 `../../logs/test-1111-172537-umi-v28.kernel.log`，以及 `../../logs/v28-snap/img/IMG_0968.jpg`、`IMG_0969.jpg`。两份日志下列行号相同。0968 中道路、文字、图标正常而面填充全黑；0969 中上一帧的线条、文字、盾牌累积，只有零星灰色填充。

1. **GMEM 转 sysmem 丢掉同一 pass 的前半段，包括 clear、面填充和 stencil。**
   - 日志 L263579、L279338：Maps pid 305/417 使用 `metal_gmem_draws=1`。L263583 是 memoryless 请求；L263675–263679 是 Clear 管线与 4× depth/stencil；L263834–263839 是 Grid、Clear 与 4× colour resolve。
   - L281767–281768、L282455–282456 出现 `a framebuffer fetch of a multisample target`。L292351 的同一统计窗口同时有 1125×2436 的 1434 draws/102 tiles 和 440 draws/sysmem，以及 copy。这是实际存在两种执行模式的证据；旧日志没有逐 draw 的附件标识，不能单靠它重建每一帧的精确序列。
   - `hakios-metal/src/render.cpp:3109`：后续不能进 tile 的 draw 让现有 GMEM pass 转 sysmem。旧代码在 bar=1 时不保留 sysmem recording（约 L3155）。`gmemDrawOk`（L2470）明确把 MSAA framebuffer fetch 留在 sysmem。
   - 对只在 tile 内存在的 MSAA/memoryless colour 和 Z/S，结束 GMEM 前缀不会写回它们；插件在第一次成功 draw 后已用 `hm_spend_clears` 将 Clear 改为 Load。随后 sysmem 从旧 backing allocation 开始，原始 Clear、先前画好的 polygon 和 stencil 都不见了。之后的 resolve 确实执行，但 resolve 的是残留样本。这个路径同时解释“背景不清、前帧积累”和“先画的面消失、后画的线与字仍在”。
   - 修复 `render.cpp:3172`：若 GMEM pass 带 depth/stencil 或 DontCare colour store，从原始 load actions 保留整个 pass 的 sysmem recording。后续 draw 不能进 GMEM 时，整个 pass 一起转 sysmem，而不是关闭并丢掉前缀。始终可进 GMEM 的 pass 仍正常从 tile resolve；普通可存储 colour pass 的既有选择策略不变。此修复默认启用，是附件内容正确性要求。
   - 回归 `tests/render_test.cpp:6378` 用非零旧内容、Clear colour/Z/S、后续附件读取强制转 sysmem，再 resolve；覆盖 1/2/4 samples、bar=1/8。修复前观察到 14 个失败检查（包括 clear 像素 0/1105、旧 depth/stencil）；修复后全部通过。

2. **MSAA framebuffer fetch 的读地址、sample 与执行频率错误。**
   - 旧 `compiler.cpp::lowerFbRead` 一律生成普通 2D `txf(lod=0)`，并把 lowering 引入的 sample ID 变成 0。旧 `render.cpp::stageTextures` 绑定 `levelDescriptor()`，不带 MSAA SAMPLES 信息。
   - `texture.cpp:827` 的 `sampledDescriptor()` 才保留真实采样数；MSAA 样本沿 X 存放。把这个内存当单采样纹理读，并不等于读取“当前像素的 sample 0”：像素/sample 地址本身就错了。programmable blending 因而使用错误背景值。
   - 修复：编译 FS 时传真实 raster sample count，lower 成 `txf_ms` + 当前 `sample_id`，强制 per-sample execution；stage texture 使用 MSAA descriptor；Adreno 的 RB/GRAS sample 状态及坐标模式按 Mesa Turnip 设置。编译缓存键包含 sample count，特化保留原 FS 的采样模式。
   - 主机已验证 2×/4× FS 有 `isamm`、sample-id register、perSamp 标志，能链接；encoder 测试检查实际 descriptor、RB/GRAS register 及 framebuffer-fetch barrier。
   - **该硬件路径尚未做真机像素验证，因此仅在 `/var/db/hakios-metal-cache/msaa-fbfetch-on` 存在时启用。**不存在时明确记录 legacy single-sample read；默认的整 pass 保留修复仍生效。没有新增备用 shader 或逐层 fallback。

两处代码缺陷可以独立证明，但 v28 日志没有每个 shader 的 fbRead 标志与逐 pass stencil 状态，不能断言所有 PolygonFill/PolygonSolidFill/Grid/ground_base 都使用 framebuffer fetch。新增 trace 用于把缺陷映射到实际管线；没有声称已在手机上修复画面。

## 已检查的其他假设

`fetches through a vertex descriptor` 是实际 VFD 路径的信息日志，不是拒绝。SDK `MTLVertexDescriptor.h` 与核心格式表一致：

| 数值 | MTLVertexFormat | Adreno 格式 | 字节 |
| --- | --- | --- | --- |
| 19 | UShort2Normalized | 16_16_UNORM | 4 |
| 21 | UShort4Normalized | 16_16_16_16_UNORM | 8 |
| 22 | Short2Normalized | 16_16_SNORM | 4 |
| 31 | Float4 | 32_32_32_32_FLOAT | 16 |

四者都是 FLOAT decode、WZYX；新增测试检查四者在足够 stride 下接受并写出正确 VFD decode word。日志 L264378、L264412、L264616、L282707 对应 PolygonSolidFill/PolygonFill/ground_base/SolidRibbon；工作正常的 SolidRibbon 同样使用格式 19。没有发现需要修改的格式转换。

插件 `hm_store_of` 已把 MultisampleResolve 映射为 DontCare store，并在 encoder endEncoding 处理全部 colour resolveTexture；StoreAndMultisampleResolve 保留 Store。不是 resolve 未实现。现有回归覆盖 tile resolve，新增回归覆盖转 sysmem 后的 clear + resolve。

stencil compare/op 枚举对应 Metal；已证明的 Z/S 缺陷是 GMEM 前缀丢失。fake GPU 不光栅化 stencil fill，尚不能由主机测试证明 VectorKit 的每个 stencil 算法都正确。

最新 PURPLE-umi.md 的 yInvert 代码按附件 yInvert 执行，**并非硬性只允许 GL**；原日志 Maps 没有 `gles: ... yInverted` / OpenGL-mode 记录。本次未修改它，新增 trace 同时输出 GL 与 yInvert 位。没有证据把双缓冲或缺少跨 pass wait 认定为根因，也没有增加全局等待。

## Weather：median3 与失败重编译

完整日志 L86992：`Textured::texture_sRGB_blend_fragment` 因 `air.fmedian3.f16` 被拒；L91052 的两秒窗口有 `147 compiled (147 failed)`。失败 stage 原先不保存，调用者每帧重建 pipeline，重复进入前端。

- `tools/mesa/air/air_intrinsics.c:591` 实现 `fmedian3`（以及同义 fast 形式）：`max(min(a,b), min(max(a,b),c))`。NIR 运算保留 half/float 精度，逐分量处理 scalar、vector2/3/4。它不是把两个未排序边界交给 clamp。
- MSL 的 common functions `median3` 对任何 NaN 输入不规定结果；因此没有添加“必须传播 NaN”或“必须返回另外两个数的中值”的额外规则。测试检查三个 NaN 位置都能编译，不对未定义的数值结果作断言。参考：[Metal Shading Language Specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf)，common functions / median3。
- `compiler.cpp:1554`、`compileStage` 增加进程内负缓存：完整 stage key（bitcode、常量、known buffer、IBO base、sample count、compiler build）→ 原始错误。并发调用在取得 compiler lock 后再次检查，所以同一失败只实际编译一次；cached-only 调用也能读到原始失败。失败不写进持久缓存，重启即重试。
- 插件 `hm_first_compile_failure` 对相同 pipeline 编译失败只打印一次，每次调用仍返回 NSError/nil。没有把失败冒充成功。
- `tri_median_fs.ll` 通过真实 IR3 编译动态的两种精度、四种宽度；`tests/median3_test.py` 通过 AIR→NIR constant folding 与排序参考比较全部排列、负数、相等值、零和无穷：360 个数值分量检查通过。三个 NaN 位置均接受。该测试不等于 Adreno 数值运行验证。
- `tri_unsupported_fs.ll` 故意调用未知 intrinsic，8 个并发请求断言只有一次 miss/failure、错误一致；改变常量或 sample count 会重新尝试。

## 主机验证与产物

从 `work/umi-v23` 运行：

```sh
make -C hakios-metal test
PATH=/opt/homebrew/opt/llvm@16/bin:$PATH make -C hakios-metal test MESA=1
PATH=/opt/homebrew/opt/llvm@16/bin:$PATH python3 hakios-metal/tests/median3_test.py
/Users/xm666/X/umi-ios/build-lock.sh make -C hakios-metal ios MESA=1
bash /tmp/hakios-maps-check/compile-plugin.sh
nm -u -m /tmp/hakios-maps-check/HakiosMetal | grep 'dynamically looked up' | grep -v weak
```

普通测试 **306 tests, 0 failed checks**；Mesa **307 tests, 16 failed checks**，仍为已知 fixture 差异（五个原有 test 中的 16 个检查），本次新增测试全部通过。新 `.ll` 用 LLVM 16；本机 LLVM 23 的 module record 20 不在 AIR reader 支持范围，不能用它重生成这些输入。未运行已知基线不能编译的 test-metal-pencil.py。

host/iOS Mesa `libair.a` 已单独更新；iOS 核心 archive/probe 的锁定构建通过。插件只单独编译链接，使用 build.sh 的 SDK/framework/Mesa archives，并保留 bundle 的 `-undefined dynamic_lookup`。产物 `/tmp/hakios-maps-check/HakiosMetal` 的 **nonweak dynamic lookup symbols = 0**。脚本、nm 输出、compile.log 在同目录；主机测试日志 `/tmp/maps-host-test.log`、`/tmp/maps-mesa-test.log`，iOS 日志 `/tmp/maps-ios-build.log`。没有运行完整 userland payload build。

已读取 CLAUDE.md、CA-METAL-umi.md、METAL-umi.md、PURPLE-umi.md（含最新 yInvert）。工作区未找到请求中的 METAL-ALL-umi.md。

## supervisor 真机检查（本 agent 未执行）

1. 装入新核心和插件后，先只使用默认的整 pass 保留修复，记录静态地图及连续平移/捏合。不要增加 boot-args。记录旧帧是否还累积、背景/水面/公园/街区是否恢复。不要仅用文字和道路出现判断通过。
2. 在 Maps 启动前准备 `/var/db/hakios-metal-cache/msaa-fbfetch-on` 和 `maps-trace` 两个空文件，然后重新启动 Maps（文件状态按进程缓存）。这是完整 MSAA-fetch 修正的测试。去掉前一文件并重启可对比 legacy 路径；测试后去掉 maps-trace。
3. 好日志：`msaa-fetch: <具体管线>, 4 samples: current-sample texture read, per-sample shading (msaa-fbfetch-on)`；`maps-pass` 给出全屏 MSAA colour、storage、load、原始 store、clear RGBA、非空 resolve、Z/S loads/clear，预期 Maps 为 `GL 0 yInvert 0`。Metal load=2 是 Clear，1 是 Load，0 是 DontCare；store=2 是 MultisampleResolve，3 是 StoreAndMultisampleResolve。memoryless 请求可能被插件报告为实际 backing 的 storageMode，不能单凭 storage 字段判断。
4. `maps-draw` 记录管线名、colour 指针、load、fetch=0/1、depth compare/write、stencil references/compare/fail/zfail/pass/masks。结合 colour 指针对齐同一 pass，确认 PolygonFill/PolygonSolidFill/Grid/ground_base 是否 fetch、是否依赖 stencil；第一 draw 之后 load 变 1 本身是正常的 Clear 消耗。trace 只取前 24 个宽度≥1000 的 MSAA pass 和前 96 个对应 draw；如未覆盖目标管线，需重启/调整诊断采样后补证。
5. `a pass left in sysmem: a framebuffer fetch of a multisample target` **仍可正常出现**：修正的是整个 pass 的内容保留和 sysmem 读取，不是强行让 fetch 进 GMEM。坏信号是 `refused: ... sample id/per sample`、`refused: the resolve`、GPU fault/timeout，或静态面仍缺失/交互后仍累积旧图。
6. Weather：重启后检查 `Textured::texture_vertex+Textured::texture_sRGB_blend_fragment` 成功 linked，原 fmedian3 拒绝消失，动画背景出现；同一未知 shader 的失败日志最多一次，后续窗口不应再出现同一失败驱动的 `147 compiled (147 failed)`。若有新的未知 intrinsic，保留那一次完整错误。

剩余边界：fake GPU 不执行 polygon shader，未证明实际混合像素与 stencil coverage；sysmem framebuffer-fetch 的 barrier 排序已有 draw，单个 draw 内重叠 primitive 的 coherent fetch 仍需硬件检查。若修正后仍有局部填充错误，按 trace/具体 shader 继续定位，不能直接用另一层 fallback 遮盖。
