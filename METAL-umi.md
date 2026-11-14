# Metal on Xiaomi Mi 10 (UMI)

This port is in the isolated `umi-v23` worktree, based on HakiOS 2.3.4
(`63fc2b4`). The current UMI worktree was not edited and no phone command was
run. Build outputs belong to `out/xiaomi-mi-10` in this tree.

## Milestones

* **Assessment:** the UMI device directory, loader, overlays, firmware
  packaging, and boot-argument whitelist were staged onto 2.3.4. The device is
  registered as `xiaomi-mi-10` in `devices/manifest.conf`.
* **FD650 path:** hakios-metal now names UMI's `0x06050002` GPU. It uses Mesa's
  A650 row: three SP/CCU cores, 1,179,648-byte GMEM, 96x16 tile alignment,
  32 VSC pipes, highest bank bit 16, no LPAC, and the FD650 static-register
  values. The fake GPU and geometry tests use the same values.
* **Host validation:** `make -C hakios-metal test` passes all 261 tests. The
  host and arm64 iOS hakios-metal archives build with the locked build command
  below. The loader argument test covers native Metal and `metal_m2v=1`, and
  the UMI selector/template test passes. `build-loader.sh` also produces
  `out/xiaomi-mi-10/loader.efi`.
* **Step 0 image:** with the local iOS 16.5 extraction and firmware, the
  default userland build produces both `root.apfs` and `system.apfs`, including
  the HakiosMetal bundle and UMI firmware packaging. The clean 2.3.4 kernel
  now builds with the complete HFS implementation reconstructed from the
  upstream pre-fetch snapshot and is at the path below. No hardware result is
  claimed here.

## Reproduce the code-only build

Run every build while holding the shared lock, after loading the repository
environment:

```sh
cd /Users/xm666/X/umi-ios/work/umi-v23
source /Users/xm666/X/umi-ios/env.sh

# FD650 host tests and the arm64 Metal archive/probe
/Users/xm666/X/umi-ios/build-lock.sh make -C hakios-metal test
/Users/xm666/X/umi-ios/build-lock.sh devices/xiaomi-mi-10/build-metal.sh

# UMI loader (does not contact a device)
/Users/xm666/X/umi-ios/build-lock.sh devices/xiaomi-mi-10/build-loader.sh

# Kernel and loader prerequisites. BUILD_DSYM=0 avoids the macOS dSYM helper's
# process-substitution requirement in the restricted build environment.
/Users/xm666/X/umi-ios/build-lock.sh devices/xiaomi-mi-10/build-kernel.sh BUILD_DSYM=0 -j8

# Build root.apfs and system.apfs after sysimage/ has been populated with the
# iOS 16.5 files. PREBUILT=1 is useful for the small image only.
/Users/xm666/X/umi-ios/build-lock.sh devices/xiaomi-mi-10/build-userland.sh
```

The resulting paths are:

```text
out/xiaomi-mi-10/xnu/BUILD/obj/DEVELOPMENT_ARM64_BCM2837/mach.development.bcm2837
out/xiaomi-mi-10/loader.efi
out/xiaomi-mi-10/root.apfs
out/xiaomi-mi-10/system.apfs
```

The loader accepts the native Metal arguments and the Vulkan fallback selector
`metal_m2v=1`; unknown arguments still abort before the kernel is entered.

The HFS cache used for this build is in
`work/umi-v23/xnu-src/hfs-627.100.6`; it has the expected tag revision
`31d5ec238dfab485e78a9a30b8b92d13e8914f03`. If a clean checkout is used
instead, it must provide that exact tagged source at the same path. A missing
cache is reported as `UMI kernel needs Apple hfs-627.100.6`.

`devices/xiaomi-mi-10/metal.args` selects `fb_hz=120`, six framebuffer
workers, and a 4 ms touch poll. The UMI loader whitelist includes these Metal
and framebuffer arguments, as well as the arguments emitted by
`tools/metal-run.sh` (`metal_fps`, `metal_defer`, `ca_metallib`, and the
diagnostic arguments).

## Supervisor hardware test plan

These are commands for the supervisor to run on the phone. Do not run them in
the build workspace. The eight-core UMI configuration can disappear from USB;
use `bootcpu=7 cpus=7` for live logs.

**Step 0 — boot with Metal disabled.** Set `metal=0` (or remove it), while
keeping `gpu=1`, and boot the generated image:

```sh
cd /Users/xm666/X/umi-ios/work/umi-v23
source /Users/xm666/X/umi-ios/env.sh
export XL_KERNEL=/Users/xm666/X/umi-ios/work/umi-v23/out/xiaomi-mi-10/xnu/BUILD/obj/DEVELOPMENT_ARM64_BCM2837/mach.development.bcm2837
export XL_LOADER=/Users/xm666/X/umi-ios/work/umi-v23/out/xiaomi-mi-10/loader.efi
export UEFI_FD=/Users/xm666/X/umi-ios/backup/SILICIUM_UEFI.noufs.fd
export XL_CMDLINE="bootcpu=7 cpus=7 umi_touch=1 umi_keys=1 umi_haptic=5 adsp=1 adsp_umi=1 sound=4 gpu=1 fb_scan=1 fb_threads=6 fb_filter=0 cpufreq=1 wifi=1 umi_bt=1 torch=3 battery=1 ufs=2 umi_mic=4 metal=0"
devices/xiaomi-mi-10/run.sh ramdisk
devices/xiaomi-mi-10/run.sh run
```

Pass indicators are SpringBoard, touch/key events, Wi-Fi and Bluetooth
initialization, audio (`sound=4` and ADSP), and a log line beginning
`display: UMI/Kona scan registers`. A line saying `the display clock
controller's bus clock does not take` is the known UEFI clock issue; repeat
with the `SILICIUM_UEFI.noufs.fd` fallback above. A loader “unknown boot
argument” is a command-line/whitelist failure, not a GPU failure.

**Step 1 — Metal self-tests.** Boot the same command line with `metal=1`, add
`metal_fps=1`, and select the diagnostic jobs in the image. Build and run the
native diagnostic image with:

```sh
/Users/xm666/X/umi-ios/build-lock.sh env UMI_METAL_TEST=1 devices/xiaomi-mi-10/build-userland.sh
devices/xiaomi-mi-10/run.sh ramdisk
devices/xiaomi-mi-10/run-metal-test.sh
```

For native hakios-metal, inspect the bundled probe's completion/fence output:

```text
metal=1 metal_fps=1 RC_JOBS=rc.jobs.umi-metal
```

For the Metal-on-Vulkan fallback, build and boot with:

```sh
/Users/xm666/X/umi-ios/build-lock.sh env TURNIP=1 M2V=1 devices/xiaomi-mi-10/build-userland.sh
devices/xiaomi-mi-10/run.sh ramdisk
XL_CMDLINE="bootcpu=7 cpus=7 gpu=1 metal=1 metal_m2v=1" RC_JOBS=rc.jobs.vktest devices/xiaomi-mi-10/run.sh run
XL_CMDLINE="bootcpu=7 cpus=7 gpu=1 metal=1 metal_m2v=1" RC_JOBS=rc.jobs.m2vtest devices/xiaomi-mi-10/run.sh run
```

A pass is a completed `vk_test` fill/fence check or `m2v_test` device, blit,
clear, and pixel check. Refusal by chip name means the FD650 ID did not reach
the kernel or compiler; a GPU fault/reset means the packet or register path
needs a device log.

**Step 2 — CoreAnimation window server on native Metal.** Supply the
CoreAnimation metallib made by `tools/ca-metallib.py` and boot with the native
plugin:

```sh
export XL_CMDLINE="bootcpu=7 cpus=7 gpu=1 metal=1 metal_fps=1 metal_defer=1 ca_metallib=/redwood/share/ca-share/QuartzCore-default.metallib fb_hz=120 fb_threads=6 touch_poll_us=4000 fb_measure=1 wallpaper_freeze=1"
devices/xiaomi-mi-10/run.sh run
```

Pass indicators are a `HakiosMetal` device, successful shader/program setup,
repeated `fps:` lines without `refuse`, `fault`, or GPU reset messages, and a
responsive SpringBoard. A visible desktop with only OpenGL logs means
`metal=1` or the Metal bundle was not selected. Use `gpu=1 metal=1 metal_m2v=1`
only with an image built using `TURNIP=1 M2V=1`; compare its `vk_test` and
`m2v_test` results with the native path.

The native path is the default recommendation for UMI. Metal-on-Vulkan remains
the fallback while FD650 packet behavior is verified on hardware. Turnip and
metal2vulkan are build-only dependencies covered by the license note in
`THIRD_PARTY_LICENSES.md`; do not distribute those artifacts.
