#!/system/bin/sh
# 守护进程 —— 由 service.sh 用 setsid 拉起(独立会话, 否则会被进程组清理连带杀掉)
# 职责: 首次重建 ZRAM + 常驻核对参数 + 写心跳供 action.sh 判断存活

MODDIR=${0%/*}
. "$MODDIR/lib.sh"

log "=== guard start (v2.13) ==="

# ZRAM 重建必须赶在系统刚把 zram0 挂上 swap 的那一刻。
# 系统在开机约 80 秒把 zram0 设为 4GB 并 swapon, 此时里面一页都还没有,
# swapoff 秒成、零风险。等久了系统按原厂 swappiness 120 把内存陆续换进去,
# swapoff 要把压缩页全部解回物理内存, 空闲不够直接失败, 重建跳空(10-28 故障)。
# 判据: zram0 出现在 /proc/swaps 即系统已挂完, 最多等 120 秒。
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
