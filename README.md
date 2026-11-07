# warsaw-xnu-kernel — Redmi K90 至尊版 / iOS 26 真机移植

XNU 12377 / iOS 26.6.2 在 **Redmi K90 至尊版**（`warsaw`，高通 SM8750-AB）上的移植记录。
路线照搬上游 [iola1999/hackios-redmi-k90-annibale](https://github.com/iola1999/hackios-redmi-k90-annibale)（同 SoC、同 DTB，仅面板 1280×2772 与 annibale 的 1156×2510 不同），
本仓库只收源码、文档、取证脚本与上屏截图；**Apple 系统内容、IPSW、厂商固件一律不上传**。

> 致谢：上游 HackiOS 由 OOSEX GANG 开发 [@oodze](https://t.me/oodze) / [@netusd](https://t.me/netusd) /
> [@wannqn](https://t.me/wannqn) / [@hxfuxyyXD](https://t.me/hxfuxyyXD)，动态见 [t.me/oosexgangdevs](https://t.me/oosexgangdevs)。
> 本仓库是同机型开发者的本地工作分支，没有上游授权，不是上游官方仓库。

## 当前进展（v37，2026-11-07）

**iOS 26 锁屏已上屏且时钟在前进。** 这是 V35 → V37 三轮迭代的结果：

| 版本 | 启动时间 | 状态 |
|---|---|---|
| v35 | 320 s（自设 `loader_return_after=320` 到期停机） | ✅ SpringBoard 上屏 / WebKit 报错页 / 触摸响应 / 卡顿 |
| v36 | 0 s（载荷格式错） | ❌ 核心未起，秒回 Android |
| v37 | 仍在运行 | ✅ **iOS 26 锁屏**（StandBy 风格粉色大数字时钟 / `向上轻扫以打开`），时钟从 00:05 推进到 00:07 |

锁屏截图见 `docs/v37/lock-00-07.png`。SpringBoard pid 132，wifid[34]、backboardd[209]、
runningboardd[30]、containermanagerd[38]、usermanagerd[44] 都起来了。

锁屏实际时间 `00:07` ≈ 启动后 7 分钟，与现实一致，证明内核在持续运行。

## 启动参数（v37，真机实测可进入锁屏）

```
debug=0x10e rootdev=md0 launchd_unsecure_cache=1 panic_on_crash_disabled=1
cpus=7 bootcpu=7 small_cores_after=0
adreno8=23 adreno8_pause=0 adreno8_fine=0 adreno8_watch=0 adreno8_keep=1 adreno8_return=0
adreno8_speed=14 adreno8_secure_preflight=4
touchscreen=2 buttons=1 battery=1
gpu_coherent=1 metal=1
cpufreq=1
fb_threads=2 fb_flip=2
applog=2
```

每项的含义（同机型可参考）：

- `bootcpu=7 cpus=7`：loader 留在核 0 服务 USB 诊断口，内核跑超核（核 7）。少了它，内核运行期间 loader 与 USB 整体灭活，看不到任何日志。
- `small_cores_after=0`：smalls 核 immediately 在 bootcpu 使能后下电，避免 loader 那侧产生干扰。
- `adreno8=23 + adreno8_keep=1 + adreno8_return=0`：逐个跑完 23 个 Adreno 上电阶段，保持 GMU 不掉，loader 不收回控制权；`metal=1`：接通 Metal 用户态驱动 → backboardd 才能合成。
- `cpufreq=1`：调 SCMI 把核频从引导期低频抬上来，否则滑动卡顿；内核打印 `cpufreq: SCMI domain 0 "NCC0": 16 levels ... 384/0 .. 3532/15`，目前抬到 1.0–1.8 GHz 档运行。
- `fb_threads=2 fb_flip=2`：双线程渲染、双缓冲翻转，对应 1280×2772 面板。
- `applog=2`：把程序 stderr/os_log 全打到 console，调试必备。
- **`epoch=<unix-time>`**：不可省略，否则内核时钟错乱（clock 服务不工作）。
- **不能带 `loader_return_after=N`**：那是取证参数，会到期停机。

## 上机一次的完整步骤

工具脚本见 `docs/tools/`。事先准备好的产物（都不上传到本仓库）：

- `Mu-warsaw-xnu-k10.img`：BootShim + UEFI FD + XNUP 载荷 + warsaw.dtb，Android boot v1 / pagesize 2048
- `payload-v37.bin`：用 `xnuloader/mkpayload.py` 装的 XNUP 容器（loader.efi + kernel + ramdisk + cmdline + memsize + identity + usb）
- `system26.apfs`：5.5 GiB 的 iOS 26 系统盘，从 IPSW 取，APFS inode mode 已用 `patch-apfs-modes.py` 修正为 1062 个块

```sh
# 危险提示：本仓库目标机是真机；本仓库的步骤只为同机型参考。
# 不要把任何东西 flash：用 `fastboot boot` 时一重启就回安卓。

ADB_DIR=/path/to/platform-tools OBSERVE=600 SHOTS="90 240 420 570" OUTDIR=$PWD/once-v37 \
  bash docs/tools/boot-once-v2.sh Mu-warsaw-xnu-k10.img payload-v37.bin system26.apfs
```

启动链（真机实测）：

1. `fastboot boot` 加载 BootShim → UEFI → XnuLoader → 把载荷搬到 `PAYLOAD_BASE=0xF0000000` → `loader.efi`（USB 诊断口 `xnuloader` 用 `18D1:D00D`）
2. 菜单期 `oem recovery`×3 进 USB 诊断
3. `oem ramdisk begin` + 每 256 MiB `fastboot stage` 上传 `system26.apfs`（`md0` = 根）
4. `fastboot stage payload` + `oem run`：内核起，launchd 起，桌面合成

## warsaw 适配的具体差异（相对 annibale）

- 面板：1280×2772（annibale 是 1156×2510）。`fbwidth`/`fbheight` 不能照抄，warsaw DTB 里是写好的（`common/devices/warsaw.dtb`），不需要在 cmdline 里再带。
- DTB 与上游 annibale **实测完全一致**（除了面板 / 背光时序），其余适配（USB、UFS、PMIC、ADSP、goodix、Adreno、BQ27Z561 等）都是同款 SoC 自带的。
- `device` 配置：`common/devices/warsaw.conf`。UEFI 加 `-DWARSAW`、loader 加 `-DDIRECT_PHONE_PLAT`。
- GPT 无 darwin 分区：warsaw 的 GPT 只有 stock Android（super 241664..3518463、userdata 3518464..64041978，LBA=4096B），所以 `loader_panic_sync_ufs` 落盘通道用不了，日志只能靠 loader（`bootcpu=7`）拿。

## 已知问题与修复记录

完整的开发日志见 `docs/V35-STATUS.md`、`docs/v35/`、`docs/v37/` 与时间线文件。关键里程碑：

- v25 修复 `launchd_cache_loader` SIGABRT（系统盘缺 `launchd.plist`，靠 bind 顶替但 bind 不遮盖非空目录 → 改为系统盘自带）。
- v28 跑通全部 launchd boot task (`Early boot complete`)，触摸响应（goodix 1280×2772）。
- v29 Adreno 830 全 23 个上电阶段跑通，MDSS/DSI 帧缓冲翻转。
- v34 实锤 `launchd.ios[1] kill(0xfffffec9, 0xf)` 死循环根因：`system.manifest` CRLF 污染让所有顶层符号链接目标带 `\r`，`/etc/master.passwd` 打不开 → 所有 job ENOENT 秒退。修复：mkapfs 剥 `\r` + manifest 全文转 LF + 重建系统盘。
- v35 SpringBoard[211] 首次真正上屏（状态栏 / WebKit 报错页 / home 指示条）。
- v37   iOS 26 **锁屏**跑出来，时钟在前进。

## 重要陷阱（同机型请注意）

- **Windows + system 全局 `core.autocrlf=true`**：checkout 或 cp 文本配置时会 LF → CRLF，导致 `exec /redwood/sbin/launchd.ios\r` ENOENT。所有 `rc*`、`var.skel*`、plist 必须 cp 后强制转 LF 并断言 CR=0。
- **手动重打 XNUP 必须补结尾空条目**：`<16sII>` 全零的 24 字节是结束哨兵，漏了 loader 解析越界、内核不发起、手机秒回 Android。换 cmdline 一律用 `mkpayload.py`，不要手抠。
- **`loader_return_after=N` 是自设取证参数**：到期 loader 收回控制权、内核整片停。生产轮千万不能带。
- **`adreno8=N` = 执行前 N 个上电阶段**（共 23 个）。0 = 完全不碰 GPU。
- **取证必须带 `bootcpu=7 cpus=7`**：loader 留在核 0 监视，fastboot/`oem log` 全程可用；没它内核运行期间 loader 整体灭活。
- **`oem stage ADDR LEN`** 两者都是裸十六进制，传十进制会被当 hex 解析超窗失败。
- **手写 launchd job 缓存**：iOS 26 的 launchd 不扫目录，只用 `mkcache.py` 产生的 `/System/Library/xpc/launchd.plist`。要补 `com.apple.sleepd` 等服务，必须进这个缓存，否则 SpringBoard 会因为找不到服务死循环重连。

## 默认分支

`main`。所有提交在 `main` 上线性前进。tags 标记关键版本：`v35`（首次上屏）、`v37`（锁屏前进）。

## 许可证

按 [APSL 2.0](LICENSE) 发布。`xnu/`、`xnu26/` 是 XNU 的衍生作品。`prebuilt/` 内含的内核含 ath11k (BSD-3-Clause-Clear) 与 FreeBSD LinuxKPI (BSD-2-Clause)；libzbitmap/libdeflate 保留原 MIT。仓库不含 IPSW、iOS 文件、厂商固件。