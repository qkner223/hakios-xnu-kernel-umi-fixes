# UMI forward port

This tree carries the complete Xiaomi Mi 10 (umi) port from the HakiOS 2.1.13 tree onto the HakiOS 2.3.4 base at `63fc2b4`. The forward port includes the USB device handoff, optional external X55 modem path and staging tools, screen off power policy and DVFS hooks, scheduler/cpugov plus framebuffer dirty tracking, Wi-Fi power and scan updates, battery/mic/RPMh updates, purple EAGL diagnostics, timer image selection, and the UEFI display clock/probe work. The existing Metal FD650 integration remains in place, including `metal.args`, FD650 `0x06050002`, M2V/Turnip options, and the upstream sync test.

Where 2.3.4 changed common files, the current 2.3.4 file was used as the base and the OLD umi delta was re-applied. The loader whitelist is the union of the Metal, modem, USB, sleep, scheduler, Wi-Fi, and purple diagnostic arguments. The framebuffer source-limit publication and Metal options were retained while adding OLD's screen off/frame dirty behavior. OLD's scheduler files were synchronized last after the other merges. The timer fix keeps `mobiletimerd` in the userland jobs and retains the mobiletimer notification bundle in `system.apfs`.

The modem firmware import/staging scripts accept a private source directory through `UMI_MODEM_FW_DIR`; proprietary firmware is not part of this tree. The private Wi-Fi MAC is read from `fw-wifi/mac`; `devices/xiaomi-mi-10/tools/stage-runtime.py` regenerates `out/xiaomi-mi-10/wifi-boot.args` whenever `wifi=1` is selected. `run.sh` sets `DEVICE=xiaomi-mi-10` and defaults `XL_FIRMWARE=silicium`, avoiding xl's Redwood-only firmware probe. xl's fastboot home/recovery, log fetch, reboot-after, and `XL_FOLLOW` paths are generic fastboot/loader flows and require no Redwood changes; the generated runtime still uses `XL_HOME`, `XL_REBOOT_AFTER`, and `XL_FOLLOW` unchanged. On this 2.3.4 loader, `loader_return_after` includes the roughly 92-second payload upload interval observed by the supervisor; interpret `XL_SECS` and the resulting timeout window accordingly.

The userland overlay is based on the current 2.3.4 `userland/build.sh`, with the UMI Bluetooth, firmware, camera-table, X55 staging, timer-job, Metal and audio additions reapplied. This preserves 2.3.4's `launchd.darwin` filename, `mkhighrate.py`, Turnip/M2V handling and CoreAnimation Metal plugin. `build-userland.sh` sets `RC_JOBS=rc.jobs` unless the caller selects `RC_JOBS=rc.jobs.umi-boot`, `UMI_METAL_TEST=1`, or `UMI_METAL_SHADERS=1`. Stage-0 `/sbin/launchd` runs `/redwood/etc/rc`, which execs Apple's `/sbin/launchd.darwin`; that launchd starts `com.hakios.demo` (which runs the selected `rc.jobs`) alongside the stock list ending in `com.apple.SpringBoard`. The earlier halt came from the stale `.ios` name in the OLD overlay, so the rebuilt image now contains both the stage-0 `/sbin/launchd` and Apple's `/sbin/launchd.darwin`.

Verification commands (all builds use the shared lock):

```sh
cd /Users/xm666/X/umi-ios/work/umi-v23
source /Users/xm666/X/umi-ios/env.sh
python3 devices/xiaomi-mi-10/prepare.py verify
/Users/xm666/X/umi-ios/build-lock.sh make -C hakios-metal test
/Users/xm666/X/umi-ios/build-lock.sh devices/xiaomi-mi-10/build-metal.sh
/Users/xm666/X/umi-ios/build-lock.sh devices/xiaomi-mi-10/build-loader.sh
/Users/xm666/X/umi-ios/build-lock.sh devices/xiaomi-mi-10/build-kernel.sh BUILD_DSYM=0 -j8
/Users/xm666/X/umi-ios/build-lock.sh env SYSTEM=1 devices/xiaomi-mi-10/build-userland.sh
for test in devices/xiaomi-mi-10/tools/test-*.py; do python3 "$test"; done
```

`build-userland.sh` defaults to `RC_JOBS=rc.jobs`, which keeps the normal
Darwin launchd job list and lets it start SpringBoard. `RC_JOBS=rc.jobs.umi-boot` is an explicit hello_dyn
diagnostic image; `UMI_METAL_TEST=1` and `UMI_METAL_SHADERS=1` select their
diagnostic job lists. `SYSTEM=1` forces fresh root and system images, while
`REST=1` only controls the optional job pruning. The UMI loader accepts
`metal=1`, `metal=2`, or `metal=3` when `gpu=1`; `metal=0` is rejected, so the
supervisor smoke command leaves the option out.

After the userland build, verify the timer plist checks from `TIMER-umi.md` against the newly produced `out/xiaomi-mi-10/root.apfs` and `system.apfs`:

```sh
python3 tools/apfs/apfs.py cat out/xiaomi-mi-10/root.apfs /LaunchDaemons/com.apple.mobiletimerd.plist | python3 -c 'import plistlib,sys; p=plistlib.loads(sys.stdin.buffer.read()); assert p["LaunchEvents"]["com.apple.alarm"] is True and p["RunAtLoad"] is True; print("alarm stream + startup: OK")'
python3 tools/apfs/apfs.py cat out/xiaomi-mi-10/system.apfs /System/Library/UserNotifications/Bundles/com.apple.mobiletimer.bundle/Info.plist | python3 -c 'import plistlib,sys; p=plistlib.loads(sys.stdin.buffer.read()); s=p["UNUserNotificationCenter"]["UNDefaultSettings"]; assert p["CFBundleIdentifier"] == "com.apple.mobiletimer" and all(s[k] for k in ["UNSettingSounds","UNSettingAlerts","UNSettingLockScreen","UNSettingModalAlertStyle"]); print("Clock notification defaults: OK")'
```

`test-camera-tables.py` reports a clean skip when its two private vendor table arguments are absent; no proprietary table is included here. The other `test-*.py` scripts run as host-only checks.

Supervisor smoke test, after the code and image checks pass:

```sh
source /Users/xm666/X/umi-ios/env.sh
export UEFI_FD=/Users/xm666/X/umi-ios/backup/SILICIUM_UEFI.noufs.fd
export XL_CMDLINE="bootcpu=7 cpus=7 umi_touch=1 umi_keys=1 umi_haptic=5 adsp=1 adsp_umi=1 sound=4 gpu=1 fb_scan=1 fb_threads=6 fb_filter=0 cpufreq=1 wifi=1 umi_bt=1 torch=3 battery=1 ufs=2 umi_mic=4"
devices/xiaomi-mi-10/run.sh reload
devices/xiaomi-mi-10/run.sh run
```

The smoke test is supervisor-only and is intentionally outside the code/build verification above; this task itself does not run phone-facing commands.
