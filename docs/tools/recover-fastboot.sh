#!/usr/bin/env bash
# recover-fastboot.sh -- 把卡在 LK fastboot 的 warsaw 拉回 Android
#
# 默认只读：打印设备状态、两个槽的元数据、关键分区尺寸，不做任何写入。
#
#   bash recover-fastboot.sh                 # 只诊断
#   bash recover-fastboot.sh --set-active b   # 重写槽位控制块（写 misc 的 bootloader_control 段）
#   bash recover-fastboot.sh --erase-misc --yes  # 清启动控制块（会一起清掉槽位元数据，随后自动 set_active）
#
# 为什么需要 --erase-misc：本机 ABL 没有独立 bootctrl 分区，A/B 槽位元数据就存在 misc 里
# （bootloader_message 在前 2 KB，bootloader_control 在偏移 2048）。fastboot boot 留下的一次性
# 启动记录也在这里。清掉之后必须紧接着 set_active 把槽位控制写回一份有效值，否则 ABL 看到
# CRC 不对会认为两个槽都不可启动。
#
# 不碰：userdata / super / boot / dtbo / vbmeta / persist / devinfo。

set -u

ADB_DIR=${ADB_DIR:-/c/Users/Administrator/Desktop/adb}
FB=$ADB_DIR/fastboot.exe
ADB=$ADB_DIR/adb.exe

DO_SET_ACTIVE=""
DO_ERASE=0
CONFIRM=0

while [ $# -gt 0 ]; do
	case "$1" in
	--set-active) DO_SET_ACTIVE=$2; shift ;;
	--erase-misc) DO_ERASE=1 ;;
	--yes) CONFIRM=1 ;;
	-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
	*) echo "未知参数 $1" >&2; exit 2 ;;
	esac
	shift
done

[ -x "$FB" ] || { echo "找不到 fastboot：$FB" >&2; exit 1; }

say() { printf '%s\n' "$*"; }
hr()  { printf '%s\n' "------------------------------------------------------------"; }

state() {
	local fb ad
	fb=$("$FB" devices 2>/dev/null | tr -d '\r' | grep -v '^$' | tr '\n' ' ')
	ad=$("$ADB" devices 2>/dev/null | tr -d '\r' | grep -v 'List of\|daemon\|^\*' | grep -v '^$' | tr '\n' ' ')
	say "fastboot: [${fb}]"
	say "adb     : [${ad}]"
}

gv() { "$FB" getvar "$1" 2>&1 | tr -d '\r' | grep -v '^$\|^Finished' | head -1 | sed 's/^fastboot: *//'; }

# ------------------------------------------------------------------ 诊断
hr
say "设备状态"
hr
state

if ! "$FB" devices 2>/dev/null | grep -q fastboot; then
	say
	say "不在 fastboot 里，没什么要恢复的。"
	exit 0
fi

say
say "槽位元数据"
for v in current-slot slot-successful:a slot-unbootable:a slot-retry-count:a \
         slot-successful:b slot-unbootable:b slot-retry-count:b \
         snapshot-update-status unlocked; do
	printf '  %-24s %s\n' "$v" "$(gv "$v")"
done

say
say "关键分区（确认存储在线、尺寸正常）"
for p in boot_a boot_b misc userdata super devinfo; do
	printf '  %-10s %s\n' "$p" "$(gv "partition-size:$p")"
done

if [ -z "$DO_SET_ACTIVE" ] && [ "$DO_ERASE" = 0 ]; then
	say
	say "以上为只读诊断。要动手，用 --set-active <slot> 或 --erase-misc --yes。"
	exit 0
fi

# ------------------------------------------------------------------ 写操作
if [ "$CONFIRM" != 1 ]; then
	say
	say "这会对 misc 分区写入。加 --yes 表示你确认（不碰 userdata / super / boot）。"
	exit 3
fi

TARGET=${DO_SET_ACTIVE:-$(gv current-slot | sed 's/.*: *//')}
case "$TARGET" in a|b) ;; *) say "槽位必须是 a 或 b，拿到的是 '$TARGET'" >&2; exit 2 ;; esac

if [ "$DO_ERASE" = 1 ]; then
	hr
	say "1/3 清 misc（启动控制块 + 槽位元数据）"
	hr
	"$FB" erase misc 2>&1 | tr -d '\r'
fi

hr
say "2/3 把槽位控制写回 $TARGET 槽（retry 复位、标记可启动）"
hr
"$FB" set_active "$TARGET" 2>&1 | tr -d '\r'

hr
say "3/3 重启"
hr
"$FB" reboot 2>&1 | tr -d '\r'

say
say "等待 90 秒，看它进 Android 还是又回 fastboot："
for i in $(seq 1 45); do
	ad=$("$ADB" devices 2>/dev/null | tr -d '\r' | grep -v 'List of\|daemon\|^\*' | grep -v '^$' | tr '\n' ' ')
	if [ -n "$ad" ]; then
		say "  t=$((i * 2))s  adb 出现：$ad"
		say
		say "已回到 Android。"
		exit 0
	fi
	fb=$("$FB" devices 2>/dev/null | tr -d '\r' | grep -v '^$' | tr '\n' ' ')
	[ $((i % 5)) -eq 0 ] && say "  t=$((i * 2))s  fb=[$fb] adb=[]"
	sleep 2
done

say
say "90 秒内没回 Android。下一步：拔掉 USB，长按电源 20 秒彻底断电，等 3 秒再开机。"
exit 1
