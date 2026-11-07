# v37 — iOS 26 锁屏上屏且时钟前进（2026-11-07）

## 一句话

继 v35 第一次把 iOS 26 的 SpringBoard 合成上屏之后，v37（去掉 `loader_return_after=320`、
加 `cpufreq=1`、载荷用 `mkpayload.py` 正确重建）让 **iOS 26 锁屏跑出来，并且时钟真的在前进**：
抓屏第一次显示 `00:05`，21 秒后第二次显示 `00:07`。

锁屏样式是 iOS 26 的 StandBy 风格 —— 黑色壁纸，巨大粉色数字时钟居中，底部白色 "向上轻扫以打开"
和 home 指示条。顶部右上角电量 `99%`。这就是一台开机后正在锁屏状态的 iPhone。

![v37 锁屏 00:07](v37/lock-00-07.png)

## v37 与 v35 的差异

仅改启动参数（其他都没动）：

| boot-arg | v35 | v37 |
|---|---|---|
| `loader_return_after` | `320`（自设取证停机） | **去掉** |
| `cpufreq` | 未带 | **`1`** |
| `systrace` | `1`（每个 syscall 进 console，本身拖性能） | **去掉** |

载荷重建：v36 因为手抠 XNUP 漏了结尾空条目，loader 解析越界秒回 Android；v37 用
`xnuloader/mkpayload.py` 正确重建（结构 7 项 + END 与 v35 完全一致）。

## 已启动的进程（v37，截屏时）

```
wifid[34]                 # 系统 Wi-Fi 守护进程（无 radio 时它仍在跑，找 MobileGestalt 缓存）
runningboardd[30]         # 进程生命周期与 RBS assertions
backboardd[37]            # 触摸事件分发 / 显示合成
containermanagerd[38]     # 沙箱容器
usermanagerd[44]          # 用户态
distnoted[42]
fseventsd[41]
ACCHWComponentAuthService[48]
SpringBoard[132]          # pid 132，5733 行日志
```

## 内核日志关键事件

- `cpufreq: SCMI domain 0 "NCC0": 16 levels ... 384/0 ... 3532/15`
- `cpufreq: cluster 0 37.0 C, cluster 1 37.6 C, GPU 36.6 C; SCMI channel status 0x1; a chain of adds at 1017 MHz on core 0x10100`
- 第一次抓屏（启动后约 5 分钟）→ 第二次抓屏（21 秒后）→ 时钟从 00:05 → 00:07

## 已知未完成项

1. **WiFi / 蓝牙未驱动**：内核里有 `redwood_wifi.c`（要 boot-arg `wifi=1`）与蓝牙
   （要 `pcie=N` + `bt=4`），v37 没带这些 boot-arg；且 Wi-Fi 还缺 `fw/wpss.mdt`+分段固件，
   本机 modemfirmware 分区只有 `kiwi/`、`peach/` 扁平 `amss.bin`、没有 MDT。
2. **`com.apple.sleepd` 缺失**：SpringBoard 找 `com.apple.sleepd.sleepserver` 一直在死循环
   重连（HKSPSleepStore 报 4099 "No such process"）。`mkcache.py` 没把这个 label 收进 launchd
   job 缓存。补 sleepd 可以消除大量噪声日志、减少进程负担。
3. **滑动还有轻微滞后感**：虽然提频到 1 GHz 档了，但 `touch_lat=1` 与 `touch_poll_us=4000` 还没加，
   `fb_hz=120 fb_ca_hz=120` 也没带。下一轮可以一起加。

## 产物（留在本地，未上传）

| 文件 | 大小 | sha256 |
|---|---|---|
| `payload-v37.bin` | 24 MiB | `2c90feaf1604f567bbc30962224002e84350c3ed3fed1b431bf38ca9f80d6dd5` |
| `Mu-warsaw-xnu-k10.img` | 11 MiB | （与 v35 同镜像） |
| `system26.apfs` | 5.5 GiB | 本地构建，含 Apple 内容，不入库 |

## 上机步骤

见根 README 的「上机一次的完整步骤」一节。本仓库不提供二进制产物，需要同机型开发者自行
用上游仓库构建内核、loader 与系统盘后，按上述 boot-arg 启动。