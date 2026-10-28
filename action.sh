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
[ -z "$WANT_LMK" ] && WANT_LMK="18432:0,23040:100,27648:200,32256:250,55296:900,80640:950"
[ -z "$ZRAM_SIZE" ] && ZRAM_SIZE=6442450944

echo "======== xaga_lagfix v2.11 ========"

# ---------- swappiness ----------
cur=$(cat /proc/sys/vm/swappiness 2>/dev/null)
if [ "$cur" = "$WANT_SWAPPINESS" ]; then
  echo "swappiness        : $cur  [OK]"
else
  echo "$WANT_SWAPPINESS" > /proc/sys/vm/swappiness 2>/dev/null
  now=$(cat /proc/sys/vm/swappiness 2>/dev/null)
  if [ "$now" = "$WANT_SWAPPINESS" ]; then
    echo "swappiness        : $cur -> $now  [已修正]"
    log "swappiness: $cur -> $now"
  else
    echo "swappiness        : $cur -> 写入失败(now=$now)  [失败]"
    log "swappiness: $cur -> $WANT_SWAPPINESS (write failed, now=$now)"
  fi
fi

# ---------- lmkd 阈值 ----------
cur=$(getprop sys.lmk.minfree_levels 2>/dev/null)
if [ "$cur" = "$WANT_LMK" ]; then
  echo "sys.lmk.minfree   : $cur  [OK]"
else
  setprop sys.lmk.minfree_levels "$WANT_LMK" 2>/dev/null
  now=$(getprop sys.lmk.minfree_levels 2>/dev/null)
  if [ "$now" = "$WANT_LMK" ]; then
    echo "sys.lmk.minfree   : $cur -> $now  [已修正]"
    log "sys.lmk.minfree_levels: $cur -> $now"
  else
    echo "sys.lmk.minfree   : $cur -> 写入失败(now=$now)  [失败]"
    log "sys.lmk.minfree_levels: $cur -> $WANT_LMK (write failed, now=$now)"
  fi
fi

# ---------- swappiness 源头属性 ----------
for p in sys.mem.swappiness_on_launcher sys.mem.swappiness_on_start; do
  v=$(getprop $p 2>/dev/null)
  if [ "$v" != "$WANT_SWAPPINESS" ]; then
    setprop $p "$WANT_SWAPPINESS" 2>/dev/null
    log "$p: $v -> $(getprop $p 2>/dev/null)"
  fi
done

# ---------- ZRAM(只报告, 不重建) ----------
zsize=$(cat /sys/block/zram0/disksize 2>/dev/null)
if [ "$zsize" = "$ZRAM_SIZE" ]; then
  echo "zram disksize     : $zsize  [OK]"
elif [ -z "$zsize" ]; then
  echo "zram disksize     : 读不到(zram0 不存在?)  [异常]"
else
  echo "zram disksize     : $zsize  [非期望值, 需重启才能安全重建]"
  log "WARN zram disksize=$zsize (期望 $ZRAM_SIZE), 需重启重建"
fi

# ---------- swap 实时占用 ----------
swap_lines=$(cat /proc/swaps 2>/dev/null | tail -n +2)
if [ -n "$swap_lines" ]; then
  echo "swap 实际         :"
  echo "$swap_lines" | while read -r line; do echo "  $line"; done
else
  echo "swap 实际         : 无"
fi

# ---------- 守护存活: 优先看心跳, ps 兜底 ----------
alive=0
if [ -f "$HB" ]; then
  hb=$(cat "$HB" 2>/dev/null)
  now_ts=$(date +%s)
  if [ -n "$hb" ]; then
    age=$((now_ts - hb))
    if [ "$age" -lt 150 ]; then
      echo "守护进程          : 运行中(心跳 ${age}s 前)  [OK]"
      alive=1
    else
      echo "守护进程          : 心跳已过期(${age}s 前), 守护已停止"
    fi
  fi
else
  echo "守护进程          : 无心跳文件"
fi

if [ "$alive" = "0" ]; then
  # ps 兜底: 万一心跳文件没写成功但进程还在
  if ps -A -o ARGS 2>/dev/null | grep -q "guard.sh"; then
    echo "                    (ps 显示 guard.sh 仍在运行)"
    alive=1
  fi
fi

if [ "$alive" = "0" ]; then
  # 尝试复活守护(用 setsid 独立会话, 与 service.sh 同样的方式)
  if [ -f "$MODDIR/guard.sh" ]; then
    setsid sh "$MODDIR/guard.sh" >/dev/null 2>&1 &
    echo "                    -> 已尝试重新拉起守护(约 45 秒后生效)"
    log "[action] 尝试重新拉起守护"
  else
    echo "                    -> 找不到 guard.sh, 无法拉起"
  fi
fi

# ---------- 反复复活的进程(杀→拉起→再杀 的循环) ----------
# 判据: 最近 logcat 里被 lmkd 杀掉次数 >= 5 的进程
# 常见原因: 控制中心磁贴(QuickService / MiShareTileService)被 SystemUI 反复拉起
echo "-------- 反复复活进程 --------"
kills=$(logcat -d -t 3000 -s lowmemorykiller 2>/dev/null \
        | grep -oE "Kill '[^']+'" | sed "s/Kill '//;s/'//" \
        | sort | uniq -c | sort -rn | head -5)
if [ -n "$kills" ]; then
  loopfound=0
  echo "$kills" | while read -r cnt pkg; do
    [ -z "$pkg" ] && continue
    if [ "$cnt" -ge 5 ] 2>/dev/null; then
      echo "  $pkg  被杀 $cnt 次  [疑似循环, 建议查它的拉起源]"
    fi
  done
  top=$(echo "$kills" | head -n1 | awk '{print $1}')
  if [ -n "$top" ] && [ "$top" -lt 5 ] 2>/dev/null; then
    echo "  (无明显循环, 最高被杀 $top 次)"
  fi
  echo "  提示: com.miui.screenrecorder / com.miui.mishare.connectivity 反复被杀,"
  echo "        通常是控制中心磁贴被 SystemUI 反复拉起, 把对应磁贴移出快捷设置即可"
else
  echo "  (logcat 读不到 lmkd 记录)"
fi

# ---------- 最近日志 ----------
echo "-------- 最近日志 --------"
if [ -f "$LOG" ]; then
  tail -n 8 "$LOG" 2>/dev/null
else
  echo "(无日志, guard.sh 可能未执行)"
fi
echo "================================"
