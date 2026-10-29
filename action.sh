#!/system/bin/sh
# 一键应用参数 + 显示状态 + 复活守护
# 用途: 管理器里模块卡片的「执行 / Action」按钮; 也可手动 sh 运行
# 不改 ZRAM(需重启才安全重建), 只检查并报告

MODDIR=/data/adb/modules/xaga_lagfix
[ -f "$MODDIR/lib.sh" ] && . "$MODDIR/lib.sh"

# lib.sh 读取失败时的兜底(避免整脚本崩)
[ -z "$LOG" ] && LOG=/data/local/tmp/xaga_lagfix.log
[ -z "$HB" ] && HB=/data/local/tmp/xaga_lagfix.hb
[ -z "$WANT_SWAPPINESS" ] && WANT_SWAPPINESS=60
[ -z "$ZRAM_SIZE" ] && ZRAM_SIZE=6442450944
command -v log >/dev/null 2>&1 || log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null; }

echo "======== xaga_lagfix v2.12 ========"

# ---------- swappiness ----------
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

# swap 占用只报「已用 / 总量」, 不贴 /proc/swaps 原始行(列宽对不齐, 看着乱)
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

# ---------- 杀→拉起 循环 ----------
echo "---- 循环(杀→拉起→再杀) ----"
# 被杀次数必须读全量 lowmemorykiller tag。原先用 logcat -t 3000, 只取缓冲区最后
# 3000 行——日志量大时几十秒就冲过去了, 08:26 杀的那几十次到 08:48 早滑出窗口,
# 于是只数到 2 次, 把恶性循环报成「无明显循环」。
kills=$(logcat -d -s lowmemorykiller 2>/dev/null \
        | grep -oE "Kill '[^']+'" | sed "s/Kill '//;s/'//" \
        | sort | uniq -c | sort -rn | head -6)

if [ -n "$kills" ]; then
  echo "  被杀最多(范围: logcat 缓冲区, 重启后清零):"
  echo "$kills" | while read -r cnt pkg; do
    [ -z "$pkg" ] && continue
    if [ "$cnt" -ge 5 ] 2>/dev/null; then
      echo "    $pkg  被杀 $cnt 次  [疑似循环]"
    else
      echo "    $pkg  被杀 $cnt 次"
    fi
  done
  top=$(echo "$kills" | head -n1 | awk '{print $1}')
  if [ "$top" -ge 5 ] 2>/dev/null; then
    echo "  提示: 反复被杀多半是入口被系统反复拉起, 控制中心磁贴最常见。"
    echo "        把对应磁贴移出快捷设置即可, 不用禁用组件。"
  fi
else
  echo "  (logcat 读不到 lowmemorykiller 记录)"
fi

# 被拉起次数(events buffer 比 main buffer 小得多, 保留更久)
starts=$(logcat -d -b events 2>/dev/null | grep "am_proc_start" \
         | awk -F, '{gsub(/^ +/,"",$4); print $4}' | sort | uniq -c | sort -rn | head -4)
if [ -n "$starts" ]; then
  echo "  被拉起最多:"
  echo "$starts" | while read -r cnt pkg; do
    [ -z "$pkg" ] && continue
    echo "    $pkg  拉起 $cnt 次"
  done
fi

# ---------- 最近日志 ----------
echo "---- 最近日志 ----"
if [ -f "$LOG" ]; then
  tail -n 8 "$LOG" 2>/dev/null | sed "s/^/  /"
else
  echo "  (无日志, guard.sh 可能未执行)"
fi
echo "================================"
