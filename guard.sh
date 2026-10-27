#!/system/bin/sh
# 守护进程 —— 由 service.sh 用 setsid 拉起(独立会话, 否则会被进程组清理连带杀掉)
# 职责: 首次重建 ZRAM + 常驻核对参数 + 写心跳供 action.sh 判断存活

MODDIR=${0%/*}
. "$MODDIR/lib.sh"

log "=== guard start (v2.6) ==="

# 等系统建好 zram0 + mem daemon 跑完
sleep 45

# 首次允许重建 ZRAM
apply_all 1
trim_log
date +%s > "$HB" 2>/dev/null

# 常驻核对, 被改回就补
while true; do
  sleep 60
  apply_all 0
  date +%s > "$HB" 2>/dev/null
  trim_log
done
