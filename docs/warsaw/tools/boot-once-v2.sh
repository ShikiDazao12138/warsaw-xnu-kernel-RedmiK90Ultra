#!/bin/bash
# 单轮桌面启动，完整取证：上传 system26.apfs -> stage payload -> oem run，
# 期间持续抓 live 内核日志、屏幕，内核若返回则再把完整日志从内存 dump 出来。
# 用法: boot-once-v2.sh <boot.img> <payload.bin> [system26.apfs]
# env: WINDOW, OBSERVE (default 170), SHOTS ("5 15 30 60 90 130")
set -uo pipefail
ROOT=${ROOT:-/c/Users/Administrator/WorkBuddy/2026-11-06-17-23-24}
ADB_DIR=${ADB_DIR:-$ROOT/.tools/platform-tools}
ADB=$ADB_DIR/adb.exe; [ -x "$ADB" ] || ADB=$ADB_DIR/adb
FB=$ADB_DIR/fastboot.exe; [ -x "$FB" ] || FB=$ADB_DIR/fastboot
IMG=${1:-}; PAY=${2:-}; SYSIMG=${3:-F:/warsaw-ios26/tree/userland/system26.apfs}
WINDOW=${WINDOW:-0x300000000}; OBSERVE=${OBSERVE:-170}
SHOTS=${SHOTS:-"5 15 30 60 90 130"}
OUTDIR=${OUTDIR:-$ROOT/build-out/warsaw-20261107-xnu/once-$(date +%H%M%S)}
[ -f "$IMG" ] && [ -f "$PAY" ] || { echo "用法: boot-once-v2.sh <boot.img> <payload.bin> [system26.apfs]" >&2; exit 2; }
IMG=$(cd "$(dirname "$IMG")" && pwd)/$(basename "$IMG")
PAY=$(cd "$(dirname "$PAY")" && pwd)/$(basename "$PAY")
mkdir -p "$OUTDIR/snaps"
q() { tr -d '\r'; }
fblist() { "$FB" devices 2>/dev/null | q | awk 'NF{$1=$1; print}'; }
fbser()  { fblist | awk 'NF{print $1}' | tr '\n' ' '; }
addev()  { "$ADB" devices 2>/dev/null | q | awk '/\tdevice$/{print $1}'; }
T0=$(date +%s); el() { echo $(( $(date +%s) - T0 )); }
log() { echo "[$(el)s] $*" | tee -a "$OUTDIR/timeline.txt"; }
getlog() { "$FB" oem log >/dev/null 2>&1; "$FB" get_staged "$1" >/dev/null 2>&1; [ -s "$1" ] && wc -c < "$1" || echo 0; }
getscreen() {
	"$FB" oem screenshot >/dev/null 2>&1
	"$FB" get_staged "$1" >/dev/null 2>&1
	[ -s "$1" ] && wc -c < "$1" || echo 0
}
topng() {
	python - "$1" "$2" <<'PY' 2>/dev/null
import sys
from PIL import Image
d = open(sys.argv[1], 'rb').read(); w, h = 1280, 2772; need = w*h*4
if len(d) >= need:
    im = Image.frombytes('RGBA', (w,h), d[:need], 'raw', 'BGRA', w*4, 1).convert('RGB')
    im.save(sys.argv[2]); im.resize((w//3,h//3)).save(sys.argv[2].replace('.png','-small.png'))
PY
}
dumpfull() {
	# loader 日志里有 "kernel returned: log at HEX, N bytes" -> 直接从内存读出全量日志
	local SRC=$1 DST=$2
	local LINE; LINE=$(grep -m1 'kernel returned: log at' "$SRC" 2>/dev/null || true)
	[ -n "$LINE" ] || { log "  没有 kernel returned 行，跳过全量 dump"; return; }
	local AT LEN
	AT=$(echo "$LINE" | sed -n 's/.*log at \([0-9a-fA-F]*\),.*/\1/p')
	LEN=$(echo "$LINE" | sed -n 's/.*, \([0-9]*\) bytes.*/\1/p')
	[ -n "$AT" ] && [ -n "$LEN" ] && [ "$LEN" -gt 0 ] || { log "  解析失败: $LINE"; return; }
	# loader parses BOTH ADDRESS and LENGTH as bare hexadecimal; the log line's
	# byte count is decimal, so convert it (a decimal 91700 used to be read as
	# 0x91700, overflowing the window and leaving stale staged data behind).
	HEXLEN=$(printf '%x' "$LEN")
	log "  全量日志: oem stage $AT $HEXLEN (=$LEN 字节)"
	"$FB" oem stage "$AT" "$HEXLEN" 2>&1 | q | tail -1 | sed 's/^/    /'
	"$FB" get_staged "$DST" >/dev/null 2>&1
	[ -s "$DST" ] && log "  ✓ 全量内核日志 $(wc -c < "$DST") B" || log "  ✗ 全量日志为空"
}

export CODEBUDDY_SAFE_DELETE_ENABLED=0
WD_FBW=$(cygpath -w "$FB" 2>/dev/null || echo "$FB")
export WD_FB="$WD_FBW" WD_SYSIMG="$SYSIMG" WD_WINDOW="$WINDOW" WD_OUTDIR="$OUTDIR"
log "镜像 $(basename "$IMG") / 载荷 $(basename "$PAY") / 系统盘 $SYSIMG"
"$ADB" kill-server >/dev/null 2>&1; "$ADB" start-server >/dev/null 2>&1
if [ -n "$(addev)" ]; then log "从 Android 重启进 bootloader"; "$ADB" reboot bootloader >/dev/null 2>&1; fi
for i in $(seq 1 45); do [ -n "$(fblist)" ] && break; sleep 1; done
[ -n "$(fblist)" ] || { log "等不到 fastboot"; exit 3; }
log "fastboot boot → $("$FB" boot "$IMG" 2>&1 | q | tail -2 | tr '\n' ' ')"
SAW=0
for i in $(seq 1 600); do case "$(fbser)" in *xnuloader*) SAW=1; break ;; esac; sleep 0.1; done
[ "$SAW" = 1 ] || { log "没等到 xnuloader"; exit 5; }
log "★ xnuloader 出现"
for i in $(seq 1 60); do
	N=$(getlog "$OUTDIR/pre-menu.txt")
	[ "$N" -gt 0 ] && grep -q "menu: spmi buttons" "$OUTDIR/pre-menu.txt" 2>/dev/null && break
	sleep 0.2
done
for i in 1 2 3; do "$FB" oem recovery >/dev/null 2>&1; sleep 0.2; done
sleep 8
case "$(fbser)" in *xnuloader*) log "✓ USB 诊断模式" ;; *) log "✗ 没进诊断模式"; exit 6 ;; esac

log "分段上传 system26.apfs"
python - <<'PY' 2>&1 | tee -a "$OUTDIR/stage-system.txt"
import os, re, subprocess, time
FB = os.environ['WD_FB']; IMG = os.environ['WD_SYSIMG']
WINDOW = int(os.environ['WD_WINDOW'], 16); SERIAL = 'xnuloader'
BLOCK = 256 * 1024 * 1024; BLOCKFILE = 'F:/warsaw-ios26/_stage_block.bin'
def fb(*args, timeout=90):
    r = subprocess.run([FB, '-s', SERIAL, *args], capture_output=True, timeout=timeout)
    out = (r.stdout + r.stderr).decode('utf-8', 'replace').replace('\r', '')
    if r.returncode or 'FAILED' in out:
        raise RuntimeError('fastboot %s -> rc=%d %s' % (' '.join(args), r.returncode, out.strip()[:300]))
    return out
def var(name):
    out = fb('getvar', name)
    m = re.search(r'(?:^|\n)(?:\(bootloader\)[ \t]*)?' + re.escape(name) + r':[ \t]*([^\r\n]*)', out)
    if not m: raise RuntimeError('loader did not report %s' % name)
    return m.group(1).strip()
def check(state, received, total):
    parts = var('ramdisk-state').split()
    if (len(parts) != 4 or parts[0] != state or
            [int(v,16) for v in parts[1:]] != [received,total,WINDOW]):
        raise RuntimeError('unexpected ramdisk progress: %s' % ' '.join(parts))
total = os.path.getsize(IMG)
fb('oem','ramdisk','begin',format(total,'x'),format(WINDOW,'x'))
check('receiving',0,total)
t0=time.time(); got=0
with open(IMG,'rb') as src:
    while got<total:
        n=min(BLOCK,total-got)
        with open(BLOCKFILE,'wb') as dst:
            left=n
            while left:
                b=src.read(min(left,4*1024*1024))
                if not b: raise RuntimeError('system image ended early')
                dst.write(b); left-=len(b)
        fb('stage',BLOCKFILE,timeout=900); got+=n
        check('ready' if got==total else 'receiving',got,total)
        print('  %d/%d MiB (%.1f MB/s)'%(got>>20,total>>20,(got/(1<<20))/max(time.time()-t0,0.1)),flush=True)
print('Transferred %d bytes into loader RAM.'%total,flush=True)
PY
RC=${PIPESTATUS[0]}; [ "$RC" = 0 ] || { log "上传失败 rc=$RC"; exit 7; }

log "stage 载荷"
"$FB" stage "$PAY" 2>&1 | q | tail -3 | tee -a "$OUTDIR/timeline.txt"
log "oem run"
"$FB" oem run 2>&1 | q | tail -3 | tee -a "$OUTDIR/timeline.txt"

BEST=0; PREV_RESULT=""; LAST_HASH=""; NLOG=0; SHOT_DONE=""; DUMPED=0; T1=$(date +%s)
END=$(( T1 + OBSERVE ))
while [ "$(date +%s)" -lt "$END" ]; do
	NOW=$(( $(date +%s) - T1 ))
	F=$OUTDIR/live.tmp
	N=$(getlog "$F")
	if [ "$N" -gt 0 ]; then
		H=$(sha256sum "$F" 2>/dev/null | cut -c1-12)
		if [ "$H" != "$LAST_HASH" ]; then
			LAST_HASH=$H; NLOG=$((NLOG+1))
			cp "$F" "$OUTDIR/live-$(printf '%03d' $NLOG)-t${NOW}s.txt"
			[ "$N" -gt "$BEST" ] && { BEST=$N; cp "$F" "$OUTDIR/best.txt"; }
			log "  日志 #$NLOG t=${NOW}s  $N B"
		fi
	fi
	R=$("$FB" getvar result 2>&1 | q | head -1)
	[ "$R" != "$PREV_RESULT" ] && { log "  result: $R"; PREV_RESULT=$R; }
	# The kernel's full log is only readable while this loader session is alive.
	# Grab it the instant the kernel returns, not after the observation window.
	if [ "$DUMPED" = 0 ] && echo "$R" | grep -qi 'returned'; then
		DUMPED=1
		log "  ★ 内核已返回，立即拉取全量日志"
		[ -s "$OUTDIR/best.txt" ] && dumpfull "$OUTDIR/best.txt" "$OUTDIR/kernel-full.txt"
	fi
	for S in $SHOTS; do
		case " $SHOT_DONE " in *" $S "*) continue ;; esac
		[ "$NOW" -ge "$S" ] || continue
		SHOT_DONE="$SHOT_DONE $S"
		G=$(getscreen "$OUTDIR/snaps/screen-$S.raw")
		log "  抓屏 @${S}s = $G B"
		[ "$G" -gt 1000000 ] && topng "$OUTDIR/snaps/screen-$S.raw" "$OUTDIR/snaps/screen-$S.png"
	done
	sleep 0.5
done
G=$(getscreen "$OUTDIR/snaps/screen-final.raw"); log "最终屏幕 $G B"
[ "$G" -gt 1000000 ] && topng "$OUTDIR/snaps/screen-final.raw" "$OUTDIR/snaps/screen-final.png"
log "观察结束：最长日志 $BEST B，共 $NLOG 个不同快照"
[ "$DUMPED" = 1 ] || { [ -s "$OUTDIR/best.txt" ] && dumpfull "$OUTDIR/best.txt" "$OUTDIR/kernel-full.txt"; }
KF=$OUTDIR/kernel-full.txt; [ -s "$KF" ] || KF=$OUTDIR/best.txt
log "===== 关键行 ====="
grep -niE 'adreno8|gmu|metal|stage0|cannot|launchd|SpringBoard|backboardd|panic|error|FAIL|Permission|No such|execve|returned|halt|init:|Using unsecure|Skipping boot-task|Skipping|deny|exited|signal' "$KF" 2>/dev/null | tail -70 | tee -a "$OUTDIR/timeline.txt"
log "===== 日志尾部 50 行 ====="
tail -50 "$KF" 2>/dev/null | tee -a "$OUTDIR/timeline.txt"
log "产物 $OUTDIR"
