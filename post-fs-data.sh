#!/system/bin/sh
# post-fs-data 阶段: 开机早期一次性写 /proc、/sys
# (ZRAM 重建与持久守护在 guard.sh, 由 service.sh 拉起)

# ---------- 内存/回写 ----------
# 原厂 100 换出太积极, 前台要数据又得解压回来, 来回折腾
echo 60 > /proc/sys/vm/swappiness 2>/dev/null || true
# 脏页回写水位: 攒批量回写, 减少小 IO 抖动
echo 20 > /proc/sys/vm/dirty_ratio 2>/dev/null || true
echo 10 > /proc/sys/vm/dirty_background_ratio 2>/dev/null || true
echo 6000 > /proc/sys/vm/dirty_expire_centisecs 2>/dev/null || true
echo 1500 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null || true
# 少回收 inode/dentry 缓存, 冷启动/切应用/滑列表更快
echo 50 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null || true
# 减少 malloc 失败崩溃(dex2oat 曾因此 SIGABRT)
echo 1 > /proc/sys/vm/overcommit_memory 2>/dev/null || true
# 允许回收 unevictable 页, 少唤醒 compaction
echo 1 > /proc/sys/vm/compact_unevictable_allowed 2>/dev/null || true

# ---------- IO 调度 ----------
# UFS 主盘 sda/sdb/sdc(无 mmcblk0; 默认即 mq-deadline, 这里写死兜底); nr_requests 128→256
for dev in sda sdb sdc; do
  d=/sys/block/$dev/queue
  [ -d "$d" ] || continue
  echo mq-deadline > "$d/scheduler" 2>/dev/null || true
  echo 256 > "$d/nr_requests" 2>/dev/null || true
done

exit 0
