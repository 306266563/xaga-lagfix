#!/system/bin/sh
# 一键自检 + 应用参数 + 复活守护。管理器 Action 按钮或手动 sh 运行。
# 不改 ZRAM(运行中重建不安全), 只检查并报告。
# 杀进程分三个视角看, 因为它们不是同一伙人:
#   killinfo        MIUI 水位机制 —— 实测占绝对多数
#   lowmemorykiller 内核 lmkd    —— 模块调参影响的那一侧
#   am_kill         AMS          —— 带杀死原因

MODDIR=/data/adb/modules/xaga_lagfix
[ -f "$MODDIR/lib.sh" ] && . "$MODDIR/lib.sh"

# lib.sh 读取失败时的兜底
[ -z "$LOG" ] && LOG=/data/local/tmp/xaga_lagfix.log
[ -z "$HB" ] && HB=/data/local/tmp/xaga_lagfix.hb
[ -z "$WANT_SWAPPINESS" ] && WANT_SWAPPINESS=100
[ -z "$ZRAM_SIZE" ] && ZRAM_SIZE=6442450944
command -v log >/dev/null 2>&1 || log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null; }

echo "======== xaga_lagfix v2.15 ========"

# ---------- 参数 ----------
echo "---- 参数 ----"
cur=$(cat /proc/sys/vm/swappiness 2>/dev/null)
if [ "$cur" = "$WANT_SWAPPINESS" ]; then
  echo "  swappiness        $cur  [OK]"
else
  echo "$WANT_SWAPPINESS" > /proc/sys/vm/swappiness 2>/dev/null
  now=$(cat /proc/sys/vm/swappiness 2>/dev/null)
  if [ "$now" = "$WANT_SWAPPINESS" ]; then
    echo "  swappiness        $cur -> $now  [已修正]"
    log "swappiness: $cur -> $now"
  else
    echo "  swappiness        $cur -> 写入失败(now=$now)  [失败]"
    log "swappiness: $cur -> $WANT_SWAPPINESS (write failed, now=$now)"
  fi
fi

# lmkd 阈值只报告: 系统每分钟自己重算, 写回去只会来回抢写
cur=$(getprop sys.lmk.minfree_levels 2>/dev/null)
echo "  sys.lmk.minfree   ${cur:-未设置}  [系统自管]"

# swappiness 源头属性(daemon 读这两个决定要不要拉回 120)
for p in sys.mem.swappiness_on_launcher sys.mem.swappiness_on_start; do
  v=$(getprop $p 2>/dev/null)
  if [ "$v" != "$WANT_SWAPPINESS" ]; then
    setprop $p "$WANT_SWAPPINESS" 2>/dev/null
    log "$p: $v -> $(getprop $p 2>/dev/null)"
  fi
done

# ---------- ZRAM(只报告) ----------
zsize=$(cat /sys/block/zram0/disksize 2>/dev/null)
if [ -z "$zsize" ]; then
  echo "  zram disksize     读不到(zram0 不存在?)  [异常]"
elif [ "$zsize" = "$ZRAM_SIZE" ]; then
  echo "  zram disksize     $zsize  [OK]"
else
  echo "  zram disksize     $zsize  [非期望值, 需重启才能安全重建]"
  log "WARN zram disksize=$zsize (期望 $ZRAM_SIZE), 需重启重建"
fi

# 方括号里的是当前生效的算法
zalg=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)
[ -n "$zalg" ] && echo "  压缩算法          $zalg"

set -- $(awk 'NR==2{print $3, $4}' /proc/swaps 2>/dev/null)
if [ -n "$1" ] && [ "$1" -gt 0 ] 2>/dev/null; then
  echo "  swap 占用         $2 / $1 kB  ($(( $2 * 100 / $1 ))%)"
else
  echo "  swap 占用         无"
fi

# ---------- 守护存活 ----------
echo "---- 守护 ----"
alive=0
if [ -f "$HB" ]; then
  hb=$(cat "$HB" 2>/dev/null)
  if [ -n "$hb" ]; then
    age=$(( $(date +%s) - hb ))
    if [ "$age" -lt 150 ]; then
      echo "  运行中(心跳 ${age}s 前)  [OK]"
      alive=1
    else
      echo "  心跳已过期(${age}s 前), 守护已停止"
    fi
  else
    echo "  心跳文件是空的"
  fi
else
  echo "  无心跳文件"
fi

# ps 兜底: 心跳没写成功但进程还在。必须精确匹配, 宽匹配会把执行本脚本的 shell 也算进去
if [ "$alive" = "0" ] && ps -A -o ARGS 2>/dev/null | grep -qE "(^|[[:space:]])sh[[:space:]]+$MODDIR/guard\.sh$"; then
  echo "  (ps 显示 guard.sh 仍在运行)"
  alive=1
fi

if [ "$alive" = "0" ]; then
  if [ -f "$MODDIR/guard.sh" ]; then
    setsid sh "$MODDIR/guard.sh" >/dev/null 2>&1 &
    echo "  -> 已尝试重新拉起, 约 45 秒后生效"
    log "[action] 尝试重新拉起守护"
  else
    echo "  -> 找不到 guard.sh, 无法拉起"
  fi
fi

# ---------- 内存与换页 ----------
echo "---- 内存 ----"
awk '/^MemTotal:|^MemFree:|^MemAvailable:|^SwapTotal:|^SwapFree:/{printf "  %-14s %s kB\n", $1, $2}' /proc/meminfo 2>/dev/null
# 换页累计: 数字大说明设备在拿 zram 当内存使
vm=$(awk '/^pswpin |^pswpout |^pgmajfault |^pgsteal_kswapd |^pgsteal_direct /{printf "%s=%s ", $1, $2}' /proc/vmstat 2>/dev/null)
[ -n "$vm" ] && echo "  开机累计        $vm"

# ---------- PSI ----------
echo "---- 压力 PSI (some/full 的 avg10 avg60 avg300) ----"
for p in memory cpu io; do
  f="/proc/pressure/$p"
  if [ -r "$f" ]; then
    awk -v n="$p" '
      $1=="some" || $1=="full" {
        a=$2; b=$3; c=$4
        sub(/^[^=]*=/,"",a); sub(/^[^=]*=/,"",b); sub(/^[^=]*=/,"",c)
        printf "  %-7s %-5s %.2f %.2f %.2f\n", n, $1, a+0, b+0, c+0
      }' "$f"
  else
    echo "  $p  读不到(需 root)"
  fi
done

# ---------- events 缓冲区落盘 ----------
# 下面所有事件统计都从这一份读, 避免反复跑 logcat; -v epoch 才能算进程存活时长。
# 路径带 pid: 并发跑两个实例时共用固定路径会互相截断。
EV="/data/local/tmp/xaga_lagfix_events.$$.tmp"
trap 'rm -f "$EV"' EXIT INT TERM
echo
echo "(正在读取系统日志, 约需十几秒...)"
logcat -d -b events -v epoch 2>/dev/null > "$EV"
# 掉电重启后 f2fs 可能让文件混进 NUL, 先剔掉再统计
tr -d '\000' < "$EV" > "$EV.c" 2>/dev/null && mv "$EV.c" "$EV" 2>/dev/null

# ---------- 统计窗口 ----------
if [ -s "$EV" ]; then
  # 只认 epoch 量级($1 > 1e9)的行; auditd 等行打的是开机相对秒(如 0.328)
  span=$(awk '!/^---------/ { t = $1 + 0; if (t > 1000000000) { if (f == 0) f = t; l = t } } END { if (f > 0 && l > f) printf "%d", l - f }' "$EV" 2>/dev/null)
  # 超过 24 小时说明读到了脏数据, 报异常而不是报假数字
  if [ -n "$span" ] && [ "$span" -gt 0 ] 2>/dev/null && [ "$span" -lt 86400 ]; then
    echo "---- 统计窗口 ----"
    echo "  events 缓冲区覆盖约 $(( span / 60 )) 分钟(重启后清零), 下面所有次数都在此窗口内"
  else
    echo "---- 统计窗口 ----"
    echo "  events 窗口读数异常, 下面次数仅作参考"
  fi
fi

# ---------- 被杀: MIUI 视角 ----------
# killinfo 由 MIUI 自己打(pid 433), 字段序:
#   [pid, 包名, uid, adj, ?, rss, ?, MemTotal, MemFree, ..., mem_some, mem_full, io_some, io_full, cpu_some]
echo "---- 被杀: MIUI 视角 (killinfo) ----"
if [ -s "$EV" ]; then
  kin=$(grep -c "killinfo" "$EV" 2>/dev/null)
  echo "  共 ${kin:-0} 条, 被杀最多:"
  grep "killinfo" "$EV" 2>/dev/null | sed 's/.*killinfo[ ]*: *\[//; s/\].*$//' \
    | awk -F, 'NF>=2{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' \
    | sort | uniq -c | sort -rn | head -6 | sed 's/^/    /'
else
  echo "  (读不到 events 缓冲区)"
fi

# ---------- 被杀: 内核视角 ----------
# 这条才是模块调参真正影响的一侧; 计数低说明瓶颈不在内核
echo "---- 被杀: 内核视角 (lowmemorykiller) ----"
lk=$(logcat -d -s lowmemorykiller 2>/dev/null | grep -oE "Kill '[^']+'" | sed "s/Kill '//;s/'//")
if [ -n "$lk" ]; then
  printf '%s\n' "$lk" | sort | uniq -c | sort -rn | head -6 | sed 's/^/    /'
else
  echo "    (无记录 — 内核侧基本没动手)"
fi

# ---------- 被杀: AMS 视角 ----------
# reason 直接写明是谁下的手, 如 MiuiMemoryService(started-services)
echo "---- 被杀: AMS 视角 (am_kill) ----"
if [ -s "$EV" ]; then
  akn=$(grep -c "am_kill" "$EV" 2>/dev/null)
  echo "  共 ${akn:-0} 次"
  echo "  按原因:"
  grep "am_kill" "$EV" 2>/dev/null | sed 's/.*am_kill[ ]*: *\[//; s/\].*$//' \
    | awk -F, 'NF>=5{print $5}' | sort | uniq -c | sort -rn | head -5 | sed 's/^/    /'
  echo "  按进程:"
  grep "am_kill" "$EV" 2>/dev/null | sed 's/.*am_kill[ ]*: *\[//; s/\].*$//' \
    | awk -F, 'NF>=3{print $3}' | sort | uniq -c | sort -rn | head -5 | sed 's/^/    /'
else
  echo "  (读不到 events 缓冲区)"
fi

# ---------- 拉起与存活 ----------
echo "---- 拉起与存活 ----"
if [ -s "$EV" ]; then
  echo "  被拉起最多:"
  grep "am_proc_start" "$EV" 2>/dev/null | sed 's/.*am_proc_start[ ]*: *\[//; s/\].*$//' \
    | awk -F, 'NF>=4{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}' \
    | sort | uniq -c | sort -rn | head -5 | sed 's/^/    /'

  # 存活时长: am_proc_start 与 am_proc_died 按 pid 配对
  echo "  短命进程(拉起后 30 秒内就被杀, 按次数):"
  awk '
    {
      ts = $1 + 0
      if ($0 ~ /am_proc_start/) {
        line = $0
        sub(/.*am_proc_start[ ]*: *\[/, "", line); sub(/\].*$/, "", line)
        n = split(line, a, ",")
        if (n >= 4) {
          p = a[2] + 0; nm = a[4]
          gsub(/^[ \t]+|[ \t]+$/, "", nm)
          if (p > 0 && nm != "") { st[p] = ts; sn[p] = nm }
        }
      } else if ($0 ~ /am_proc_died/) {
        line = $0
        sub(/.*am_proc_died[ ]*: *\[/, "", line); sub(/\].*$/, "", line)
        n = split(line, a, ",")
        if (n >= 3) {
          p = a[2] + 0
          if (p in st) {
            life = ts - st[p]
            if (life >= 0 && life < 30) {
              cnt[sn[p]]++
              if (!(sn[p] in mn) || life < mn[sn[p]]) mn[sn[p]] = life
            }
            delete st[p]; delete sn[p]
          }
        }
      }
    }
    END { for (k in cnt) printf "%d %.1f %s\n", cnt[k], mn[k], k }
  ' "$EV" 2>/dev/null | sort -rn | head -5 | awk '{printf "    %-40s 短命 %s 次, 最短 %s 秒\n", $3, $1, $2}'
else
  echo "  (读不到 events 缓冲区)"
fi

# ---------- ANR ----------
echo "---- ANR ----"
if [ -s "$EV" ]; then
  an=$(grep -c "am_anr" "$EV" 2>/dev/null)
  echo "  次数: ${an:-0}"
  grep "am_anr" "$EV" 2>/dev/null | tail -2 | cut -c1-110 | sed 's/^/    /'
else
  echo "  次数: 0"
fi

rm -f "$EV" 2>/dev/null

# ---------- 最近日志 ----------
echo "---- 最近日志 ----"
if [ -f "$LOG" ]; then
  tr -d '\000' < "$LOG" 2>/dev/null | tail -n 8 | sed "s/^/  /"
else
  echo "  (无日志, guard.sh 可能未执行)"
fi
echo "================================"
