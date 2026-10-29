#!/system/bin/sh
# post-fs-data 阶段: 开机早期一次性写 /proc、/sys
# (ZRAM 重建与持久守护在 guard.sh, 由 service.sh 拉起)

# ---------- 内存/回写 ----------
# swappiness 60: 原厂 100 换出太积极, 前台要数据时又得解压回来, 来回折腾吃满 CPU
echo 60 > /proc/sys/vm/swappiness 2>/dev/null || true
# 脏页回写水位: 攒批量回写, 减少小 IO 抖动
echo 20 > /proc/sys/vm/dirty_ratio 2>/dev/null || true
echo 10 > /proc/sys/vm/dirty_background_ratio 2>/dev/null || true
echo 6000 > /proc/sys/vm/dirty_expire_centisecs 2>/dev/null || true
echo 1500 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null || true
# 少回收 inode/dentry 缓存, 冷启动/切应用/滑列表更快
echo 50 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null || true
# overcommit: 减少 malloc 失败导致的崩溃(日志 dex2oat 正因此 SIGABRT)
echo 1 > /proc/sys/vm/overcommit_memory 2>/dev/null || true
# 允许回收 unevictable 页, 减少 compaction 唤醒
echo 1 > /proc/sys/vm/compact_unevictable_allowed 2>/dev/null || true

# ---------- IO 调度 ----------
# xaga 的 UFS 主盘是 sda/sdb/sdc(无 mmcblk0); 实测默认即 [mq-deadline], 写死兜底。
# nr_requests 128→256: UFS 连续读写吞吐略好
for dev in sda sdb sdc; do
  d=/sys/block/$dev/queue
  [ -d "$d" ] || continue
  echo mq-deadline > "$d/scheduler" 2>/dev/null || true
  echo 256 > "$d/nr_requests" 2>/dev/null || true
done

exit 0
