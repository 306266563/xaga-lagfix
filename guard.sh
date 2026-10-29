#!/system/bin/sh
# 守护进程 —— 由 service.sh 用 setsid 拉起(独立会话, 否则会被进程组清理连带杀掉)
# 职责: 首次重建 ZRAM + 常驻核对参数 + 写心跳供 action.sh 判断存活

MODDIR=${0%/*}
. "$MODDIR/lib.sh"

log "=== guard start (v2.15) ==="

# ZRAM 重建必须赶在 zram0 刚挂上 swap 时 —— 里面还没换出页, swapoff 零风险;
# 等久了压缩页解不回物理内存会跳空。判据: zram0 出现在 /proc/swaps, 最多等 120 秒。
n=0
while [ "$n" -lt 120 ]; do
  grep -q zram0 /proc/swaps 2>/dev/null && { sleep 2; break; }
  sleep 1
  n=$((n+1))
done

# 立刻重建 ZRAM, 趁 swap 为空
apply_all 1
trim_log
date +%s > "$HB" 2>/dev/null

# mem daemon 在开机后期会把 swappiness 拉回 120, 等它跑完再开始常驻核对
sleep 45
apply_all 0
trim_log

# 常驻核对, 被改回就补
while true; do
  sleep 60
  apply_all 0
  date +%s > "$HB" 2>/dev/null
  trim_log
done
