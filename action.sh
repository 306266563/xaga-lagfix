#!/system/bin/sh
# 一键应用参数 + 显示状态 + 复活守护
# 用途: 管理器里模块卡片的「执行 / Action」按钮; 也可手动 sh 运行
# 不改 ZRAM(需重启才安全重建), 只检查并报告
#
# v2.13 起自检面板分成三个「谁在杀进程」的视角, 因为实测发现动手的不是内核:
#   MIUI 视角  killinfo          —— MIUI 自己的水位机制, 实测占绝对多数
#   内核视角  lowmemorykiller    —— 模块调参真正影响的那一侧
#   AMS 视角  am_kill            —— 系统进程管理, 带杀死原因
# 另外补上 PSI 压力、内存与换页累计、拉起次数与短命进程、ANR。

MODDIR=/data/adb/modules/xaga_lagfix
[ -f "$MODDIR/lib.sh" ] && . "$MODDIR/lib.sh"

# lib.sh 读取失败时的兜底(避免整脚本崩)
[ -z "$LOG" ] && LOG=/data/local/tmp/xaga_lagfix.log
[ -z "$HB" ] && HB=/data/local/tmp/xaga_lagfix.hb
[ -z "$WANT_SWAPPINESS" ] && WANT_SWAPPINESS=60
[ -z "$ZRAM_SIZE" ] && ZRAM_SIZE=6442450944
command -v log >/dev/null 2>&1 || log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null; }

echo "======== xaga_lagfix v2.13 ========"

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

# lmkd 阈值只报告不设置: 系统自己会动态重算, 写回去只会来回抢写
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

# ---------- ZRAM(只报告, 不重建) ----------
zsize=$(cat /sys/block/zram0/disksize 2>/dev/null)
if [ -z "$zsize" ]; then
  echo "  zram disksize     读不到(zram0 不存在?)  [异常]"
elif [ "$zsize" = "$ZRAM_SIZE" ]; then
  echo "  zram disksize     $zsize  [OK]"
else
  echo "  zram disksize     $zsize  [非期望值, 需重启才能安全重建]"
  log "WARN zram disksize=$zsize (期望 $ZRAM_SIZE), 需重启重建"
fi

# 压缩算法: 方括号里的是当前生效的
zalg=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)
[ -n "$zalg" ] && echo "  压缩算法          $zalg"

# swap 占用只报「已用 / 总量」
set -- $(awk 'NR==2{print $3, $4}' /proc/swaps 2>/dev/null)
if [ -n "$1" ] && [ "$1" -gt 0 ] 2>/dev/null; then
  echo "  swap 占用         $2 / $1 kB  ($(( $2 * 100 / $1 ))%)"
else
  echo "  swap 占用         无"
fi

# ---------- 守护存活: 优先看心跳, ps 兜底 ----------
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

# ps 兜底: 万一心跳没写成功但进程还在
if [ "$alive" = "0" ] && ps -A -o ARGS 2>/dev/null | grep -q "guard.sh"; then
  echo "  (ps 显示 guard.sh 仍在运行)"
  alive=1
fi

# 复活守护(用 setsid 独立会话, 与 service.sh 同样的方式)
if [ "$alive" = "0" ]; then
  if [ -f "$MODDIR/guard.sh" ]; then
    setsid sh "$MODDIR/guard.sh" >/dev/null 2>&1 &
    echo "  -> 已尝试重新拉起, 约 45 秒后生效"
    log "[action] 尝试重新拉起守护"
  else
    echo "  -> 找不到 guard.sh, 无法拉起"
  fi
fi

# ---------- 内存与换页累计 ----------
echo "---- 内存 ----"
awk '/^MemTotal:|^MemFree:|^MemAvailable:|^SwapTotal:|^SwapFree:/{printf "  %-14s %s kB\n", $1, $2}' /proc/meminfo 2>/dev/null
# 换页累计用来判断「设备是不是在拿 zram 当内存使」: 数字大=频繁换出换入
vm=$(awk '/^pswpin |^pswpout |^pgmajfault |^pgsteal_kswapd |^pgsteal_direct /{printf "%s=%s ", $1, $2}' /proc/vmstat 2>/dev/null)
[ -n "$vm" ] && echo "  开机累计        $vm"

# ---------- 压力(PSI) ----------
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

# ---------- 一次性把 events 缓冲区落盘 ----------
# events 缓冲区比 main 小得多, 保留更久; 下面所有统计都从这份文件读,
# 避免反复跑 logcat。用 -v epoch 是为了能算进程存活时长。
EV=/data/local/tmp/xaga_lagfix_events.tmp
echo
echo "(正在读取系统日志, 约需十几秒...)"
logcat -d -b events -v epoch 2>/dev/null > "$EV"

# ---------- 统计窗口 ----------
if [ -s "$EV" ]; then
  # 别直接拿第一行算时间: events 缓冲区首行是 "--------- beginning of events"
  span=$(awk '!/^---------/ { if (f == "") f = $1 + 0; l = $1 + 0 } END { if (f > 0) printf "%d", l - f }' "$EV" 2>/dev/null)
  if [ -n "$span" ] && [ "$span" -gt 0 ] 2>/dev/null; then
    echo "---- 统计窗口 ----"
    echo "  events 缓冲区覆盖约 $(( span / 60 )) 分钟(重启后清零), 下面所有次数都在此窗口内"
  fi
fi

# ---------- 被杀: MIUI 视角 ----------
# killinfo 由 MIUI 自己打(pid 433), 字段:
#   [pid, 包名, uid, adj, ?, rss, ?, MemTotal, MemFree, ..., mem_some, mem_full, io_some, io_full, cpu_some]
# 实测杀进程的绝大多数来自这里
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
# 这条才是模块调参真正影响的一侧; 只要这里计数很低, 说明瓶颈不在内核
echo "---- 被杀: 内核视角 (lowmemorykiller) ----"
lk=$(logcat -d -s lowmemorykiller 2>/dev/null | grep -oE "Kill '[^']+'" | sed "s/Kill '//;s/'//")
if [ -n "$lk" ]; then
  printf '%s\n' "$lk" | sort | uniq -c | sort -rn | head -6 | sed 's/^/    /'
else
  echo "    (无记录 — 内核侧基本没动手)"
fi

# ---------- 被杀: AMS 视角 ----------
# am_kill 的 reason 会直接写明是谁下的手, 例如 MiuiMemoryService(started-services)
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

  # 存活时长: 把 am_proc_start 与 am_proc_died 按 pid 配对
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

# ---------- 清理临时文件 ----------
rm -f "$EV" 2>/dev/null

# ---------- 最近日志 ----------
echo "---- 最近日志 ----"
if [ -f "$LOG" ]; then
  tail -n 8 "$LOG" 2>/dev/null | sed "s/^/  /"
else
  echo "  (无日志, guard.sh 可能未执行)"
fi
echo "================================"
